{-# LANGUAGE ForeignFunctionInterface #-}

module Server where

import Control.Monad (unless)
import Network.Socket hiding (recv)
import qualified Data.ByteString as S
import qualified Data.ByteString.Char8 as C
import Network.Socket.ByteString (recv, send)
import Data.Word
import Data.List (span)
import System.IO
import Parser
import FlowControllerLang
import FlowController (State)
import EmitFML
import Control.Concurrent
import Data.IORef

foreign import ccall unsafe "htons" htons :: Word16 -> Word16

serverLoop serverSock state = do
  (clientSock, _) <- accept serverSock
  forkIO (authUser clientSock state)
  serverLoop serverSock state 

serverMain :: Word16 -> State -> IO ()
serverMain port state = withSocketsDo $ do
    sock <- socket AF_INET Stream 0
    setSocketOption sock ReuseAddr 1
    bindSocket sock (SockAddrInet (PortNum (htons port)) iNADDR_ANY)
    listen sock 2
    stateRef <- newIORef state    
    serverLoop sock stateRef


serverAction cmd stRef = do
  (b, st') <- atomicModifyIORef stRef -- TODO: use a real lock so emitFML is inside as well
         (\st -> let (result, st') = runDNP cmd st in (st', (result, st')))
  case b of
    True -> do
      putStrLn "--> ACCEPTED"
      let (t, _) = runDNP getTimeM st'
      putStrLn ("--> BEGIN NEW FML CONFIGURATION. TIME = " ++ (show t))
      putStrLn (emitFML st')
      putStrLn "--> END NEW FML CONFIGURATION"
    False -> do
      putStrLn "--> REJECTED"
  return stRef

authUser conn st = do
   -- TODO: what if command longer than 1024? or falls over a boundary?
  msg <- recv conn 1024
  let msgStr = C.unpack msg
  let (spk, _:restMsg)  = span (/='.') msgStr
  processLoop spk conn st restMsg

processLoop spk conn st msg = do
  putStr (spk ++ " : ")
  putStrLn msg
  st' <- parseInteractive' spk msg serverAction st
  msg' <- recv conn 1024
  processLoop spk conn st' (C.unpack msg')
