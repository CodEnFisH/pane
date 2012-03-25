module CombinedPaneMac where

import Base
import ShareSemantics
import qualified Nettle.OpenFlow as OF
import MacLearning
import Parser (paneMan)

combinedPaneMac :: Chan (OF.SwitchID, Bool)
                -> Chan (Integer, OF.SwitchID, OF.PacketInfo)
                -> Chan (Speaker, String)
                -> Chan Integer
                -> IO (Chan MatchTable, Chan (Speaker, String), PacketOutChan)
combinedPaneMac switch packet paneReq time = do
  (paneTbl, paneResp) <- paneMan paneReq time
  (macLearnedTbl, pktOutChan) <- macLearning switch packet
  let cmb pt mt = do
        return $ condense (unionTable (\p _ -> p) pt mt)
  combinedTbl <- unionChan cmb
                           (emptyTable, paneTbl) 
                           (emptyTable, macLearnedTbl)
  
  return (combinedTbl, paneResp, pktOutChan)
