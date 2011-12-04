module EmitFML 
  ( emitFML
  ) where

import FlowController
import Text.PrettyPrint.HughesPJ
import qualified Data.Maybe as Maybe
import qualified Set as Set
import Set (Set)

emitFML :: State
        -> String
emitFML st = render (reservations (stateReservations st))

reservations resv = case Set.toList resv of
  Nothing -> error "infinite set of reservations!"
  Just lst -> vcat $ map reservation lst

data Flow = Flow (Maybe User) (Maybe User) (Maybe Port) (Maybe Port)


var _ Nothing = Nothing
var v (Just s) = Just (text v <+> text "=" <+> text (show s))



flow (Flow su ru sp rp) =
  parens $ cat $ punctuate (text ", ") $ 
    Maybe.catMaybes [ var "U_s" su, var "U_r" ru, 
                      var "P_s" sp, var "P_r" rp ]



expandFlowGroup :: FlowGroup -> [Flow]
expandFlowGroup (FlowGroup sendUser recvUser sendPort recvPort) = 
  [ Flow su ru sp rp | su <- toList' sendUser, ru <- toList' recvUser,
                       sp <- toList' sendPort, rp <- toList' recvPort ]
    where toList' s = case Set.toList s of
            Just lst -> map Just lst
            Nothing -> [Nothing]

reservation (flowGroup, n) = 
  vcat [ text "bandwidth(" <> text (show n) <> text ") <=" <+> flow  f
           | f <- expandFlowGroup flowGroup ]

--  text "bandwidth(" $$ text (show n) $$ text ") <=" $+$ flow f