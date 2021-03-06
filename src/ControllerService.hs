module ControllerService
  ( controller
  , PacketIn
  , ControllerConfig (..)
  ) where

import Prelude hiding (catch)
import Base
import Data.Map (Map)
import MacLearning (PacketOutChan)
import qualified NIB
import qualified Nettle.OpenFlow as OF
import Nettle.OpenFlow.Switch (showSwID)
import qualified Nettle.Servers.Server as OFS
import qualified Data.Map as Map
import qualified Data.Set as Set
import qualified Data.List as List
import System.Process
import System.Exit

type PacketIn = (OF.TransactionID, Integer, OF.SwitchID, OF.PacketInfo)

data ControllerConfig = ControllerConfig
  { controllerPort  :: Word16
  , ovsSetQueue     :: String
  , ovsDeleteQueue  :: String
  }

controller :: Chan NIB.Snapshot  -- ^input channel (from Compiler)
           -> Chan NIB.Msg       -- ^output channel (headed to NIB module)
           -> Chan PacketIn      -- ^output channel (headed to MAC Learning)
           -> Chan (OF.SwitchID, Bool) -- ^output channel (for MAC Learning;
                                       -- switches connecting & disconnecting)
           -> PacketOutChan      -- ^input channel (from MAC Learning)
           -> ControllerConfig
           -> IO ()
controller nibSnapshot toNIB packets switches pktOut config = do
  server <- OFS.startOpenFlowServer Nothing (controllerPort config)
  -- actually send packets sent by MAC learning module
  forkIO $ forever $ do
    (swID, xid, pktOut) <- readChan pktOut
    -- putStrLn $ "SEND packet-out" ++ show (OF.bufferIDData pktOut)
    ignoreExns "send pkt from controller"
               (OFS.sendToSwitchWithID server swID (xid, OF.PacketOut pktOut))
  -- process new switches
  forever $ do
    (switch, switchFeatures) <- retryOnExns "accept switch"
                                            (OFS.acceptSwitch server)
    putStrLn $ "OpenFlow controller connected to new switch."
    writeChan toNIB (NIB.NewSwitch switch switchFeatures)
    writeChan switches (OFS.handle2SwitchID switch, True)
    nibSnapshot <- dupChan nibSnapshot
    forkIO (handleSwitch packets toNIB switches switch)
    forkIO (configureSwitch nibSnapshot switch NIB.emptySwitch config)
    ignoreExns "stats request" $
        OFS.sendToSwitch switch (0, OF.StatsRequest OF.DescriptionRequest)
  OFS.closeServer server

--
-- Functions to handle messages from switches
-- 

handleSwitch :: Chan PacketIn  -- ^output channel (headed to MAC Learning)
             -> Chan NIB.Msg   -- ^output channel (headed to NIB module)
             -> Chan (OF.SwitchID, Bool) -- ^output channel (for MAC Learning;
                                         -- switches connecting & disconnecting)
             -> OFS.SwitchHandle
             -> IO ()
handleSwitch packets toNIB switches switch = do
  let swID = OFS.handle2SwitchID switch
  ignoreExns ("clear flowtable on switch with ID: " ++ showSwID swID)
             (OFS.sendToSwitch switch
                  (0, OF.FlowMod $ OF.DeleteFlows OF.matchAny Nothing))
  OFS.untilNothing 
    (retryOnExns ("receive from switch with ID: " ++ showSwID swID)
                 (OFS.receiveFromSwitch switch))
    (\msg -> ignoreExns "msgHandler" (messageHandler packets toNIB switch msg))
  ignoreExns ("close handle for switch with ID: " ++ showSwID swID)
             (OFS.closeSwitchHandle switch)
  writeChan switches (swID, False)
  -- TODO(adf): also inform NIB that switch is gone? could be transient...
  putStrLn $ "Connection to switch " ++ showSwID swID ++ " closed."

messageHandler :: Chan PacketIn -- ^output channel (headed to MAC Learning)
               -> Chan NIB.Msg  -- ^output channel (headed to NIB module)
               -> OFS.SwitchHandle
               -> (OF.TransactionID, OF.SCMessage) -- ^coming from Nettle
               -> IO ()
messageHandler packets toNIB switch (xid, msg) = case msg of
  OF.PacketIn pkt -> do
    now <- readIORef sysTime
    writeChan packets (xid, now, OFS.handle2SwitchID switch, pkt)
    writeChan toNIB (NIB.PacketIn (OFS.handle2SwitchID switch) pkt)
  OF.StatsReply pkt -> do
    writeChan toNIB (NIB.StatsReply (OFS.handle2SwitchID switch) pkt)
  otherwise -> do
    putStrLn $ "unhandled message from switch " ++ 
                (showSwID $ OFS.handle2SwitchID switch) ++ "\n" ++ show msg
    return ()

--
-- Functions to reconfigure switches
--

-- |Block until new snapshot appears, then reconfigure switch based
-- on updated NIB.
configureSwitch :: Chan NIB.Snapshot -- ^input channel (from the Compiler)
                -> OFS.SwitchHandle
                -> NIB.Switch
                -> ControllerConfig
                -> IO ()
configureSwitch nibSnapshot switchHandle oldSw@(NIB.Switch oldPorts oldTbl _) config = do
  let switchID = OFS.handle2SwitchID switchHandle
  snapshot <- readChan nibSnapshot
  case Map.lookup switchID snapshot of
    Nothing -> do
      putStrLn $ "configureSwitch did not find " ++ showSwID switchID ++
                 " in the NIB snapshot."
      configureSwitch nibSnapshot switchHandle oldSw config
    Just sw@(NIB.Switch newPorts newTbl swType) -> do
      now <- readIORef sysTime
      let (portActions, deleteQueueTimers, msgs') =
           case swType of
             NIB.ReferenceSwitch -> mkPortModsExt now oldPorts newPorts
                                      (OFS.sendToSwitch switchHandle)
             NIB.OpenVSwitch     -> mkPortModsOVS now oldPorts newPorts switchID config
             NIB.ProntoSwitch    -> mkPortModsExt now oldPorts newPorts
                                      (OFS.sendToSwitch switchHandle)
             otherwise           -> -- putStrLn $ "Don't know how to create queues for " ++ show swType
                                    (return(), return(), [])
      let msgs = msgs' ++ mkFlowMods now newTbl oldTbl
{- TODO(adf): re-enable this code when we have propper logging
      unless (null msgs) $ do
         putStrLn $ "Controller modifying tables on " ++ showSwID switchID
         putStrLn $ "sending " ++ show (length msgs) ++ " messages; oldTbl size = " ++ show (Set.size oldTbl) ++ " newTbl size = " ++ show (Set.size newTbl)
         mapM_ (\x -> putStrLn $ "   " ++ show x) msgs
         putStrLn "-------------------------------------------------"
         return ()
-}
      -- TODO(adf): should do something smarter here than silently ignoring
      -- exceptions while writing config to switch...
      portActions
      ignoreExns ("configuring switch with ID: " ++ showSwID switchID)
                 (mapM_ (OFS.sendToSwitch switchHandle) (zip [0 ..] msgs))
      deleteQueueTimers
      configureSwitch nibSnapshot switchHandle sw config

mkFlowMods :: Integer
           -> NIB.FlowTbl
           -> NIB.FlowTbl
           -> [OF.CSMessage]
mkFlowMods now newTbl oldTbl = map OF.FlowMod (delMsgs ++ addMsgs)
  where delMsgs = mapMaybe mkDelFlow (Set.toList oldRules)
        addMsgs = mapMaybe mkAddFlow (Set.toList newRules)
        mkAddFlow (prio, match, acts, expiry) = case expiry <= fromInteger now of
          True -> Nothing -- rule is expiring
          False ->
            Just (OF.AddFlow {
              OF.match = match,
              OF.priority = prio,
              OF.actions = acts,
              OF.cookie = 0,
              OF.idleTimeOut = OF.Permanent,
              OF.hardTimeOut = toTimeout now expiry ,
              OF.notifyWhenRemoved = False,
              OF.applyToPacket = Nothing,
              OF.overlapAllowed = True
            })
        mkDelFlow (prio, match, _, expiry) = case expiry <= fromInteger now of
          True -> Nothing -- rule would've been automatically deleted by switch
          False -> Just (OF.DeleteExactFlow match Nothing prio)
        newRules = Set.difference newTbl oldTbl
        oldRules = Set.difference oldTbl newTbl

-- |We cannot have queues automatically expire with the slicing extension.
-- So, we return an action that sets up timers to delete queues.
mkPortModsExt :: Integer
              -> Map OF.PortID NIB.PortCfg
              -> Map OF.PortID NIB.PortCfg
              -> ((OF.TransactionID, OF.CSMessage) -> IO ())
              -> (IO (), IO (), [OF.CSMessage])
mkPortModsExt now portsNow portsNext sendCmd = (addActions, delTimers, addMsgs)
  where addActions = return ()
        addMsgs = map newQueueMsg newQueues
        delTimers = sequence_ (map delQueueAction newQueues)

        newQueueMsg ((pid, qid), NIB.Queue resv _) =
          OF.ExtQueueModify pid 
            [OF.QueueConfig qid [OF.MinRateQueue (OF.Enabled resv)]]

        delQueueAction ((_, _), NIB.Queue _ NoLimit) = return ()
        delQueueAction ((pid, qid), NIB.Queue _ (DiscreteLimit end)) = do
          forkIO $ do
            threadDelay (10^6 * (fromIntegral $ end - now))
            -- TODO(adf): awaiting logging code...
            -- putStrLn $ "Deleting queue " ++ show qid ++ " on port " ++ show pid
            ignoreExns ("deleting queue " ++ show qid)
                    (sendCmd (0, OF.ExtQueueDelete pid [OF.QueueConfig qid []]))
          return ()

        qCmpLeft ql qr = if ql == qr then Nothing else (Just ql)
        newQueues = Map.toList $
          Map.differenceWith qCmpLeft (flatten portsNext) (flatten portsNow)
        flatten portMap = Map.fromList $
          concatMap (\(pid, NIB.PortCfg qMap) ->
                      map (\(qid, q) -> ((pid, qid), q)) (Map.toList qMap))
                    (Map.toList portMap)

-- |We cannot have queues automatically expire with Open vSwitch, either.
-- So, we return an action that sets up timers to delete queues.
mkPortModsOVS :: Integer
              -> Map OF.PortID NIB.PortCfg
              -> Map OF.PortID NIB.PortCfg
              -> OF.SwitchID
              -> ControllerConfig
              -> (IO (), IO (), [OF.CSMessage])
mkPortModsOVS now portsNow portsNext swid config = (addActions, delTimers, addMsgs)
  where addMsgs = [] -- No OpenFlow messages needed
        addActions = sequence_ (map newQueueAction newQueues)
        delTimers = sequence_ (map delQueueAction newQueues)

        newQueueAction ((pid, qid), NIB.Queue resv _) = do
            -- TODO(adf): awaiting logging code...
            -- putStrLn $ "Creating queue " ++ show qid ++ " on port " ++ show pid ++ " switch " ++ show swid
          exitcode <- rawSystem (ovsSetQueue config) [show swid, show pid, show qid, show resv]
          case exitcode of
            ExitSuccess   -> return ()
            ExitFailure n -> putStrLn $ "Exception (ignoring): " ++
                                        "failed to create OVS queue: " ++ show swid ++ " " ++
                                        show pid ++ " " ++ show qid ++ "; ExitFailure: " ++ show n

        delQueueAction ((_, _), NIB.Queue _ NoLimit) = return ()
        delQueueAction ((pid, qid), NIB.Queue _ (DiscreteLimit end)) = do
          forkIO $ do
            threadDelay (10^6 * (fromIntegral $ end - now))
            -- TODO(adf): awaiting logging code...
            -- putStrLn $ "Deleting queue " ++ show qid ++ " on port " ++ show pid
            exitcode <- rawSystem (ovsDeleteQueue config) [show swid, show pid, show qid]
            case exitcode of
              ExitSuccess   -> return ()
              ExitFailure n -> putStrLn $ "Exception (ignoring): " ++
                                          "failed to delete OVS queue: " ++ show swid ++ " " ++
                                          show pid ++ " " ++ show qid ++ "; ExitFailure: " ++ show n
            return()
          return ()

        qCmpLeft ql qr = if ql == qr then Nothing else (Just ql)
        newQueues = Map.toList $
          Map.differenceWith qCmpLeft (flatten portsNext) (flatten portsNow)
        flatten portMap = Map.fromList $
          concatMap (\(pid, NIB.PortCfg qMap) ->
                      map (\(qid, q) -> ((pid, qid), q)) (Map.toList qMap))
                    (Map.toList portMap)

            
-- TODO(arjun): toTimeout will fail if (end - now) does not fit in a Word16
toTimeout :: Integer -> Limit -> OF.TimeOut
toTimeout _   NoLimit = 
  OF.Permanent
toTimeout now (DiscreteLimit end) = 
  OF.ExpireAfter (fromInteger (end - fromInteger now))
