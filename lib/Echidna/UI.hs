{-# LANGUAGE CPP #-}

module Echidna.UI where

import Brick
import Brick.BChan
import Brick.Widgets.Dialog qualified as B
import Control.Concurrent (killThread, threadDelay)
import Control.Exception (AsyncException)
import Control.Monad
import Control.Monad.Catch
import Control.Monad.Reader
import Control.Monad.State.Strict hiding (state)
import Control.Monad.ST (RealWorld)
import Data.ByteString.Lazy qualified as BS
import Data.List.Split (chunksOf)
import Data.Map (Map)
import Data.Maybe (isJust)
import Data.Sequence ((|>))
import Data.Text (Text)
import Data.Time
import Graphics.Vty.Config (VtyUserConfig, defaultConfig, configInputMap)
import Graphics.Vty.CrossPlatform (mkVty)
import Graphics.Vty.Input.Events
import Graphics.Vty qualified as Vty
import System.Console.ANSI (hNowSupportsANSI)
import System.Signal
import UnliftIO
  ( MonadUnliftIO, IORef, newIORef, readIORef, hFlush, stdout , writeIORef, timeout)
import UnliftIO.Concurrent hiding (killThread, threadDelay)

import EVM.Types (Addr, Contract, VM, VMType(Concrete), W256)

import Echidna.ABI
import Echidna.Campaign (runWorker, spawnListener)
import Echidna.Output.Corpus (saveCorpusEvent)
import Echidna.Output.JSON qualified
import Echidna.Server (runSSEServer)
import Echidna.SourceAnalysis.Slither (isEmptySlitherInfo)
import Echidna.Types.Campaign
import Echidna.Types.Config
import Echidna.Types.Corpus qualified as Corpus
import Echidna.Types.Coverage (coverageStats)
import Echidna.Types.Test (EchidnaTest(..), didFail, isOptimizationTest)
import Echidna.Types.Tx (Tx)
import Echidna.UI.Report
import Echidna.UI.Widgets
import Echidna.Utility (timePrefix, getTimestamp)

data UIEvent =
  CampaignUpdated LocalTime [EchidnaTest] [WorkerState]
  | FetchCacheUpdated (Map Addr (Maybe Contract))
                      (Map Addr (Map W256 (Maybe W256)))
  | EventReceived (LocalTime, CampaignEvent)

-- | Gas tracking state for calculating gas consumption rate
data GasTracker = GasTracker
  { lastUpdateTime :: LocalTime
  , totalGasConsumed :: Int
  }

-- | Set up and run an Echidna 'Campaign' and display interactive UI or
-- print non-interactive output in desired format at the end
ui
  :: (MonadCatch m, MonadReader Env m, MonadUnliftIO m)
  => VM Concrete RealWorld -- ^ Initial VM state
  -> GenDict
  -> [(FilePath, [Tx])]
  -> Maybe Text
  -> m [WorkerState]
ui vm dict initialCorpus cliSelectedContract = do
  env <- ask
  conf <- asks (.cfg)
  terminalPresent <- liftIO isTerminal

  let
    nFuzzWorkers = getNFuzzWorkers conf.campaignConf
    nworkers = getNWorkers conf.campaignConf

    effectiveMode = case conf.uiConf.operationMode of
      Interactive | not terminalPresent -> NonInteractive Text
      other -> other

    -- Distribute over all workers, could be slightly bigger overall due to
    -- ceiling but this doesn't matter
    perWorkerTestLimit = ceiling
      (fromIntegral conf.campaignConf.testLimit / fromIntegral nFuzzWorkers :: Double)

    chunkSize = ceiling
      (fromIntegral (length initialCorpus) / fromIntegral nFuzzWorkers :: Double)
    corpusChunks = chunksOf chunkSize initialCorpus ++ repeat []

  corpusSaverStopVar <- spawnListener (saveCorpusEvent env)

  workers <- forM (zip corpusChunks [0..(nworkers-1)]) $
    uncurry (spawnWorker env perWorkerTestLimit)

  case effectiveMode of
    Interactive -> do
      -- Channel to push events to update UI
      uiChannel <- liftIO $ newBChan 1000
      let forwardEvent = void . writeBChanNonBlocking uiChannel . EventReceived
      uiEventsForwarderStopVar <- spawnListener forwardEvent

      ticker <- liftIO . forkIO . forever $ do
        threadDelay 200_000 -- 200 ms

        now <- getTimestamp
        tests <- traverse readIORef env.testRefs
        states <- workerStates workers
        writeBChan uiChannel (CampaignUpdated now tests states)

        -- TODO: remove and use events for this
        c <- readIORef env.fetchContractCache
        s <- readIORef env.fetchSlotCache
        writeBChan uiChannel (FetchCacheUpdated c s)

      -- UI initialization
      let buildVty = do
            v <- mkVty =<< vtyConfig
            let output = Vty.outputIface v
            when (Vty.supportsMode output Vty.Mouse) $
              Vty.setMode output Vty.Mouse True
            pure v
      initialVty <- liftIO buildVty
      app <- customMain initialVty buildVty (Just uiChannel) <$> monitor

      liftIO $ do
        tests <- traverse readIORef env.testRefs
        now <- getTimestamp
        let uiState = UIState {
            campaigns = [initialWorkerState] -- ugly, fix me
          , workersAlive = nworkers
          , status = Uninitialized
          , timeStarted = now
          , timeStopped = Nothing
          , now = now
          , slitherSucceeded = not $ isEmptySlitherInfo env.slitherInfo
          , fetchedContracts = mempty
          , fetchedSlots = mempty
          , fetchedDialog = B.dialog (Just $ str " Fetched contracts/slots ") Nothing 80
          , displayFetchedDialog = False
          , displayLogPane = True
          , displayTestsPane = True
          , focusedPane = TestsPane
          , events = mempty
          , corpusSize = 0
          , coverage = 0
          , numCodehashes = 0
          , lastNewCov = now
          , tests
          , campaignWidget = emptyWidget -- temporary, will be overwritten below
          }
        initialCampaignWidget <- runReaderT (campaignStatus uiState) env
        void $ app uiState { campaignWidget = initialCampaignWidget }

      -- Exited from the UI, stop the workers, not needed anymore
      stopWorkers workers

      -- wait for all events to be processed
      forM_ [uiEventsForwarderStopVar, corpusSaverStopVar] takeMVar

      liftIO $ killThread ticker

      states <- workerStates workers
      liftIO . putStrLn =<< ppCampaign states

      pure states

    NonInteractive outputFormat -> do
      serverStopVar <- newEmptyMVar

      -- Handles ctrl-c
      liftIO $ forM_ [sigINT, sigTERM] $ \sig ->
        let handler _ = do
              stopWorkers workers
              void $ tryPutMVar serverStopVar ()
        in installHandler sig handler

      let forwardEvent ev = putStrLn =<< runReaderT (ppLogLine vm ev) env
      uiEventsForwarderStopVar <- spawnListener forwardEvent

      -- Track last update time and gas for delta calculation
      startTime <- liftIO getTimestamp
      lastUpdateRef <- liftIO $ newIORef $ GasTracker startTime 0

      let printStatus = do
            states <- liftIO $ workerStates workers
            time <- timePrefix <$> getTimestamp
            line <- statusLine env states lastUpdateRef
            putStrLn $ time <> "[status] " <> line
            hFlush stdout

      case conf.campaignConf.serverPort of
        Just port -> liftIO $ runSSEServer serverStopVar env port nworkers
        Nothing -> pure ()

      ticker <- liftIO . forkIO . forever $ do
        threadDelay 3_000_000 -- 3 seconds
        printStatus

      -- wait for all events to be processed
      forM_ [uiEventsForwarderStopVar, corpusSaverStopVar] takeMVar

      liftIO $ killThread ticker

      -- print final status regardless of the last scheduled update
      liftIO printStatus

      when (isJust conf.campaignConf.serverPort) $ do
        -- wait until we send all SSE events
        liftIO $ putStrLn "Waiting until all SSE are received..."
        readMVar serverStopVar

      states <- liftIO $ workerStates workers

      case outputFormat of
        JSON ->
          liftIO $ BS.putStr =<< Echidna.Output.JSON.encodeCampaign env states
        Text -> do
          liftIO . putStrLn =<< ppCampaign  states
        None ->
          pure ()
      pure states

  where

  spawnWorker env testLimit corpusChunk workerId = do
    stateRef <- newIORef initialWorkerState

    threadId <- forkIO $ do
      -- TODO: maybe figure this out with forkFinally?
      let workerType = workerIDToType env.cfg.campaignConf workerId
      stopReason <- catches (do
          let
            timeoutUsecs = maybe (-1) (*1_000_000) env.cfg.uiConf.maxTime
            corpus = if workerType == SymbolicWorker then initialCorpus else corpusChunk
          maybeResult <- timeout timeoutUsecs $
            runWorker workerType (get >>= writeIORef stateRef)
                      vm dict workerId corpus testLimit cliSelectedContract
          pure $ case maybeResult of
            Just (stopReason, _finalState) -> stopReason
            Nothing -> TimeLimitReached
        )
        [ Handler $ \(e :: AsyncException) -> pure $ Killed (show e)
        , Handler $ \(e :: SomeException)  -> pure $ Crashed (show e)
        ]

      time <- liftIO getTimestamp
      writeChan env.eventQueue (time, WorkerEvent workerId workerType (WorkerStopped stopReason))

    pure (threadId, stateRef)

  -- | Get a snapshot of all worker states
  workerStates workers =
    forM workers $ \(_, stateRef) -> readIORef stateRef

 -- | Order the workers to stop immediately
stopWorkers :: MonadIO m => [(ThreadId, IORef WorkerState)] -> m ()
stopWorkers workers =
  forM_ workers $ \(threadId, workerStateRef) -> do
    workerState <- readIORef workerStateRef
    liftIO $ mapM_ killThread (threadId : workerState.runningThreads)

vtyConfig :: IO VtyUserConfig
vtyConfig = do
  pure defaultConfig { configInputMap = [
    (Nothing, "\ESC[6;2~", EvKey KPageDown [MShift]),
    (Nothing, "\ESC[5;2~", EvKey KPageUp [MShift])
    ] }

-- | Check if we should stop drawing (or updating) the dashboard, then do the right thing.
monitor :: MonadReader Env m => m (App UIState UIEvent Name)
monitor = do
  let
    drawUI :: UIState -> [Widget Name]
    drawUI uiState =
      [ if uiState.displayFetchedDialog
           then fetchedDialogWidget uiState
           else emptyWidget
      , uiState.campaignWidget ]

    toggleFocus :: UIState -> UIState
    toggleFocus state =
      case state.focusedPane of
        TestsPane | state.displayLogPane   -> state { focusedPane = LogPane }
        LogPane   | state.displayTestsPane -> state { focusedPane = TestsPane }
        _ -> state

    refocusIfNeeded :: UIState -> UIState
    refocusIfNeeded state = if
      (state.focusedPane == TestsPane && not state.displayTestsPane) ||
      (state.focusedPane == LogPane && not state.displayLogPane)
      then toggleFocus state else state

    focusedViewportScroll :: UIState -> ViewportScroll Name
    focusedViewportScroll state = case state.focusedPane of
      TestsPane -> viewportScroll TestsViewPort
      LogPane   -> viewportScroll LogViewPort

    onEvent env = \case
      AppEvent (CampaignUpdated now tests c') -> do
        state <- get
        let updatedState = state { campaigns = c', status = Running, now, tests }
        newWidget <- liftIO $ runReaderT (campaignStatus updatedState) env
        -- intentionally using lazy modify here, so unnecessary widget states don't get computed
        modify $ const updatedState { campaignWidget = newWidget }
      AppEvent (FetchCacheUpdated contracts slots) ->
        modify' $ \state ->
          state { fetchedContracts = contracts
                , fetchedSlots = slots }
      AppEvent (EventReceived event@(time,campaignEvent)) -> do
        modify' $ \state -> state { events = state.events |> event }

        case campaignEvent of
          WorkerEvent _ _ (NewCoverage { points, numCodehashes, corpusSize }) ->
            modify' $ \state ->
              state { coverage = max state.coverage points -- max not really needed
                    , corpusSize
                    , numCodehashes
                    , lastNewCov = time
                    }
          WorkerEvent _ _ (WorkerStopped _) ->
            modify' $ \state ->
              state { workersAlive = state.workersAlive - 1
                    , timeStopped = if state.workersAlive == 1
                                       then Just time else Nothing
                    }

          _ -> pure ()
      VtyEvent (EvKey (KChar 'f') _) ->
        modify' $ \state ->
          state { displayFetchedDialog = not state.displayFetchedDialog }
      VtyEvent (EvKey (KChar 'l') _) ->
        modify' $ \state ->
          refocusIfNeeded $ state { displayLogPane = not state.displayLogPane }
      VtyEvent (EvKey (KChar 't') _) ->
        modify' $ \state ->
          refocusIfNeeded $ state { displayTestsPane = not state.displayTestsPane }
      VtyEvent (EvKey direction _) | direction == KPageUp || direction == KPageDown -> do
        state <- get
        let vp = focusedViewportScroll state
        vScrollPage vp (if direction == KPageDown then Down else Up)
      VtyEvent (EvKey direction _) | direction == KUp || direction == KDown -> do
        state <- get
        let vp = focusedViewportScroll state
        vScrollBy vp (if direction == KDown then 1 else -1)
      VtyEvent (EvKey k []) | k == KChar '\t' || k ==  KBackTab ->
        -- just two panes, so both keybindings just toggle the active one
        modify' toggleFocus
      VtyEvent (EvKey KEsc _)                         -> halt
      VtyEvent (EvKey (KChar 'c') l) | MCtrl `elem` l -> halt
      MouseDown (SBClick el n) _ _ _ ->
        case n of
          TestsViewPort -> do
            modify' $ \state -> state { focusedPane = TestsPane }
            let vp = viewportScroll TestsViewPort
            case el of
              SBHandleBefore -> vScrollBy vp (-1)
              SBHandleAfter  -> vScrollBy vp 1
              SBTroughBefore -> vScrollBy vp (-10)
              SBTroughAfter  -> vScrollBy vp 10
              SBBar          -> pure ()
          LogViewPort -> do
            modify' $ \state -> state { focusedPane = LogPane }
            let vp = viewportScroll LogViewPort
            case el of
              SBHandleBefore -> vScrollBy vp (-1)
              SBHandleAfter  -> vScrollBy vp 1
              SBTroughBefore -> vScrollBy vp (-10)
              SBTroughAfter  -> vScrollBy vp 10
              SBBar          -> pure ()
          _ -> pure ()
      _ -> pure ()

  env <- ask
  pure $ App { appDraw = drawUI
             , appStartEvent = pure ()
             , appHandleEvent = onEvent env
             , appAttrMap = const attrs
             , appChooseCursor = neverShowCursor
             }

-- | Heuristic check that we're in a sensible terminal (not a pipe)
isTerminal :: IO Bool
isTerminal = hNowSupportsANSI stdout

-- | Composes a compact text status line of the campaign
statusLine
  :: Env
  -> [WorkerState]
  -> IORef GasTracker  -- Gas consumption tracking state
  -> IO String
statusLine env states lastUpdateRef = do
  tests <- traverse readIORef env.testRefs
  (points, _) <- coverageStats env.coverageRefInit env.coverageRefRuntime
  corpus <- readIORef env.corpusRef
  now <- getTimestamp
  let totalCalls = sum ((.ncalls) <$> states)
  let totalGas = sum ((.totalGas) <$> states)

  -- Calculate delta-based gas/s
  gasTracker <- readIORef lastUpdateRef
  let deltaTime = round $ diffLocalTime now gasTracker.lastUpdateTime
  let deltaGas = totalGas - gasTracker.totalGasConsumed
  let gasPerSecond = if deltaTime > 0 then deltaGas `div` deltaTime else 0
  writeIORef lastUpdateRef $ GasTracker now totalGas

  pure $ "tests: " <> show (length $ filter didFail tests) <> "/" <> show (length tests)
    <> ", fuzzing: " <> show totalCalls <> "/" <> show env.cfg.campaignConf.testLimit
    <> ", values: " <> show ((.value) <$> filter isOptimizationTest tests)
    <> ", cov: " <> show points
    <> ", corpus: " <> show (Corpus.corpusSize corpus)
    <> ", gas/s: " <> show gasPerSecond

