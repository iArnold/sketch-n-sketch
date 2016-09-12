module Eval (run, parseAndRun, parseAndRun_, evalDelta, eval, initEnv, match) where

import Debug
import Dict
import String

import Lang exposing (..)
import LangUnparser exposing (unparse, unparsePat)
import LangParser2 as Parser
import Types
import Utils

------------------------------------------------------------------------------
-- Big-Step Operational Semantics

match : (Pat, Val) -> Maybe Env
match (p,v) = case (p.val, v.v_) of
  (PVar _ x _, _) -> Just [(x,v)]
  (PAs _ x _ innerPat, _) ->
    case match (innerPat, v) of
      Just env -> Just ((x,v)::env)
      Nothing -> Nothing
  (PList _ ps _ Nothing _, VList vs) ->
    Utils.bindMaybe matchList (Utils.maybeZip ps vs)
  (PList _ ps _ (Just rest) _, VList vs) ->
    let (n,m) = (List.length ps, List.length vs) in
    if n > m then Nothing
    else
      let (vs1,vs2) = Utils.split n vs in
      (rest, vList vs2) `cons` (matchList (Utils.zip ps vs1))
        -- dummy VTrace, since VList itself doesn't matter
  (PList _ _ _ _ _, _) -> Nothing
  (PConst _ n, VConst (n',_)) -> if n == n' then Just [] else Nothing
  (PBase _ bv, VBase bv') -> if (eBaseToVBase bv) == bv' then Just [] else Nothing
  _ -> Debug.crash <| "Little evaluator bug: Eval.match " ++ (toString p.val) ++ " vs " ++ (toString v.v_)


matchList : List (Pat, Val) -> Maybe Env
matchList pvs =
  List.foldl (\pv acc ->
    case (acc, match pv) of
      (Just old, Just new) -> Just (new ++ old)
      _                    -> Nothing
  ) (Just []) pvs


cons : (Pat, Val) -> Maybe Env -> Maybe Env
cons pv menv =
  case (menv, match pv) of
    (Just env, Just env') -> Just (env' ++ env)
    _                     -> Nothing


lookupVar env bt x pos =
  case Utils.maybeFind x env of
    Just v  -> Ok v
    Nothing -> errorWithBacktrace bt <| strPos pos ++ " variable not found: " ++ x ++ "\nVariables in scope: " ++ (String.join " " <| List.map fst env)


mkCap mcap l =
  let s =
    case (mcap, l) of
      (Just cap, _)       -> cap.val
      (Nothing, (_,_,"")) -> strLoc l
      (Nothing, (_,_,x))  -> x
  in
  s ++ ": "


-- eval propagates output environment in order to extract
-- initial environment from prelude

-- eval inserts dummyPos during evaluation

eval_ : Env -> Backtrace -> Exp -> Result String (Val, Widgets)
eval_ env bt e = Result.map fst <| eval env bt e


eval : Env -> Backtrace -> Exp -> Result String ((Val, Widgets), Env)
eval env bt e =

  let ret v_                         = ((Val v_ [e.val.eid], []), env) in
  let retAdd eid (v,envOut)          = ((Val v.v_ (eid::v.vtrace), []), envOut) in
  let retAddWs eid ((v,ws),envOut)   = ((Val v.v_ (eid::v.vtrace), ws), envOut) in
  let retAddThis_ (v,envOut)         = retAdd e.val.eid (v,envOut) in
  let retAddThis v                   = retAddThis_ (v, env) in
  let retBoth (v,w)                  = (({v | vtrace = e.val.eid :: v.vtrace},w), env) in
  let replaceEnv envOut (v,_)        = (v, envOut) in
  let addWidgets ws1 ((v1,ws2),env1) = ((v1, ws1 ++ ws2), env1) in

  let bt' =
    if e.start.line >= 1 -- Ignore desugared internal expressions
    then e::bt
    else bt
  in

  case e.val.e__ of

  EConst _ i l wd ->
    let v_ = VConst (i, TrLoc l) in
    case wd.val of
      NoWidgetDecl         -> Ok <| ret v_
      IntSlider a _ b mcap -> Ok <| retBoth (Val v_ [], [WIntSlider a.val b.val (mkCap mcap l) (floor i) l])
      NumSlider a _ b mcap -> Ok <| retBoth (Val v_ [], [WNumSlider a.val b.val (mkCap mcap l) i l])

  EBase _ v      -> Ok <| ret <| VBase (eBaseToVBase v)
  EVar _ x       -> Result.map retAddThis <| lookupVar env (e::bt) x e.start
  EFun _ [p] e _ -> Ok <| ret <| VClosure Nothing p e env
  EOp _ op es _  -> Result.map (\res -> retAddWs e.val.eid (res, env)) <| evalOp env (e::bt) op es

  EList _ es _ m _ ->
    case Utils.projOk <| List.map (eval_ env bt') es of
      Err s -> Err s
      Ok results ->
        let (vs,wss) = List.unzip results in
        let ws = List.concat wss in
        case m of
          Nothing   -> Ok <| retBoth <| (Val (VList vs) [], ws)
          Just rest ->
            case eval_ env bt' rest of
              Err s -> Err s
              Ok (vRest, ws') ->
                case vRest.v_ of
                  VList vs' -> Ok <| retBoth <| (Val (VList (vs ++ vs')) [], ws ++ ws')
                  _         -> errorWithBacktrace (e::bt) <| strPos rest.start ++ " rest expression not a list."

  EIndList _ rs _ ->
    case Utils.projOk <| List.map rangeToList rs of
      Err s -> errorWithBacktrace (e::bt) <| s
      Ok listOfVLists ->
        let vs = List.concat listOfVLists in
        if isSorted vs
        then Ok <| ret <| VList vs
        else errorWithBacktrace (e::bt) <| "indices not strictly increasing: " ++ strVal (vList vs)

  EIf _ e1 e2 e3 _ ->
    case eval_ env bt e1 of
      Err s -> Err s
      Ok (v1,ws1) ->
        case v1.v_ of
          VBase (VBool True)  -> Result.map (addWidgets ws1) <| eval env bt e2
          VBase (VBool False) -> Result.map (addWidgets ws1) <| eval env bt e3
          _                   -> errorWithBacktrace (e::bt) <| strPos e1.start ++ " if-exp expected a Bool but got something else."

  ECase _ e1 bs _ ->
    case eval_ env (e::bt) e1 of
      Err s -> Err s
      Ok (v1,ws1) ->
        case evalBranches env (e::bt) v1 bs of
          Ok (Just (v2,ws2)) -> Ok <| retBoth (v2, ws1 ++ ws2)
          Err s              -> Err s
          _                  -> errorWithBacktrace (e::bt) <| strPos e1.start ++ " non-exhaustive case statement"

  ETypeCase _ scrutineeExp tbranches _ ->
    case eval_ env (e::bt) scrutineeExp of
      Err s -> Err s
      Ok (scrutineeVal,ws1) ->
        case evalTBranches env (e::bt) scrutineeVal tbranches of
          Ok (Just (v2,ws2)) -> Ok <| retBoth (v2, ws1 ++ ws2)
          Err s              -> Err s
          _                  -> errorWithBacktrace (e::bt) <| strPos scrutineeExp.start ++ " non-exhaustive typecase statement"

  EApp _ e1 [e2] _ ->
    -- Return env of the call site
    Result.map (replaceEnv env) <| evalSimpleApp env bt bt' e1 e2

  ELet _ _ False p e1 e2 _ ->
    -- Return env that the let body returns (so that programs return their final top-level environment)
    Result.map (retAddWs e2.val.eid) <| evalSimpleApp env bt bt' (eFun [p] e2) e1

  ELet _ _ True p e1 e2 _ ->
    case eval_ env bt' e1 of
      Err s       -> Err s
      Ok (v1,ws1) ->
        case (p.val, v1.v_) of
          (PVar _ f _, VClosure Nothing x body env') ->
            let _   = Utils.assert "eval letrec" (env == env') in
            let v1' = Val (VClosure (Just f) x body env) v1.vtrace in
            case (pVar f, v1') `cons` Just env of
              Just env' -> Result.map (addWidgets ws1) <| eval env' bt' e2
              _         -> errorWithBacktrace (e::bt) <| strPos e.start ++ "bad ELet"
          (PList _ _ _ _ _, _) ->
            errorWithBacktrace (e::bt) <|
              strPos e1.start ++
              "mutually recursive functions (i.e. letrec [...] [...] e) \
               not yet implemented"
               -- Implementation also requires modifications to LangTransform.simply
               -- so that clean up doesn't prune the funtions.
          _ ->
            errorWithBacktrace (e::bt) <| strPos e.start ++ "bad ELet"

  EComment _ _ e1       -> eval env bt e1
  EOption _ _ _ _ e1    -> eval env bt e1
  ETyp _ _ _ e1 _       -> eval env bt e1
  EColonType _ e1 _ _ _ -> eval env bt e1
  ETypeAlias _ _ _ e1 _ -> eval env bt e1

  -- abstract syntactic sugar

  EFun _ ps e1 _  -> Result.map (retAddWs e1.val.eid) <| eval env bt' (eFun ps e1)
  EApp _ e1 [] _  -> errorWithBacktrace (e::bt) <| strPos e1.start ++ " application with no arguments"
  EApp _ e1 es _  -> Result.map (retAddWs e.val.eid)  <| eval env bt' (eAppExpand e1 es)

  -- Sure, we could just return the val or dict but they really shouldn't be there.
  EVal val   -> Debug.crash "Should not be evaluating an exp with an EVal"
  EDict dict -> Debug.crash "Should not be evaluating an exp with an EDict"



-- Returns augmented environment (for let/def)
evalSimpleApp env bt bt' funcExp singleArgExp =
  let addWidgets ws1 ((v1,ws2),env1) = ((v1, ws1 ++ ws2), env1) in
  case eval_ env bt' funcExp of
    Err s       -> Err s
    Ok (v1,ws1) ->
      case eval_ env bt' singleArgExp of
        Err s       -> Err s
        Ok (v2,ws2) ->
          let ws = ws1 ++ ws2 in
          case v1.v_ of
            VClosure Nothing p eBody env' ->
              case (p, v2) `cons` Just env' of
                Just env'' -> Result.map (addWidgets ws) <| eval env'' bt' eBody -- TODO add eid to vTrace
                _          -> errorWithBacktrace bt' <| strPos funcExp.start ++ "bad environment"
            VClosure (Just f) p eBody env' ->
              case (pVar f, v1) `cons` ((p, v2) `cons` Just env') of
                Just env'' -> Result.map (addWidgets ws) <| eval env'' bt' eBody -- TODO add eid to vTrace
                _          -> errorWithBacktrace bt' <| strPos funcExp.start ++ "bad environment"
            _ ->
              errorWithBacktrace bt' <| strPos funcExp.start ++ " not a function"

evalOp env bt opWithInfo es =
  let (op,opStart) = (opWithInfo.val, opWithInfo.start) in
  let argsEvaledRes = List.map (eval_ env bt) es |> Utils.projOk in
  case argsEvaledRes of
    Err s -> Err s
    Ok argsEvaled ->
      let (vs,wss) = List.unzip argsEvaled in
      let error () =
        errorWithBacktrace bt
          <| "Bad arguments to " ++ strOp op ++ " operator " ++ strPos opStart
          ++ ":\n" ++ Utils.lines (Utils.zip vs es |> List.map (\(v,e) -> (strVal v) ++ " from " ++ (unparse e)))
      in
      let emptyVTrace val_   = Val val_ [] in
      let emptyVTraceOk val_ = Ok (emptyVTrace val_) in
      let nullaryOp args retVal =
        case args of
          [] -> emptyVTraceOk retVal
          _  -> error ()
      in
      let unaryMathOp op args =
        case args of
          [VConst (n,t)] -> VConst (evalDelta bt op [n], TrOp op [t]) |> emptyVTraceOk
          _              -> error ()
      in
      let binMathOp op args =
        case args of
          [VConst (i,it), VConst (j,jt)] -> VConst (evalDelta bt op [i,j], TrOp op [it,jt]) |> emptyVTraceOk
          _                              -> error ()
      in
      let args = List.map .v_ vs in
      let newValRes =
        case op of
          Plus    -> case args of
            [VBase (VString s1), VBase (VString s2)] -> VBase (VString (s1 ++ s2)) |> emptyVTraceOk
            _                                        -> binMathOp op args
          Minus     -> binMathOp op args
          Mult      -> binMathOp op args
          Div       -> binMathOp op args
          Mod       -> binMathOp op args
          Pow       -> binMathOp op args
          ArcTan2   -> binMathOp op args
          Lt        -> case args of
            [VConst (i,it), VConst (j,jt)] -> VBase (VBool (i < j)) |> emptyVTraceOk
            _                              -> error ()
          Eq        -> case args of
            [VConst (i,it), VConst (j,jt)]           -> VBase (VBool (i == j)) |> emptyVTraceOk
            [VBase (VString s1), VBase (VString s2)] -> VBase (VBool (s1 == s2)) |> emptyVTraceOk
            [_, _]                                   -> VBase (VBool False) |> emptyVTraceOk -- polymorphic inequality, added for Prelude.addExtras
            _                                        -> error ()
          Pi         -> nullaryOp args (VConst (pi, TrOp op []))
          DictEmpty  -> nullaryOp args (VDict Dict.empty)
          DictInsert -> case vs of
            [vkey, val, {v_}] -> case v_ of
              VDict d -> valToDictKey bt vkey.v_ |> Result.map (\dkey -> VDict (Dict.insert dkey val d) |> emptyVTrace)
              _       -> error()
            _                 -> error ()
          DictGet    -> case args of
            [key, VDict d] -> valToDictKey bt key |> Result.map (\dkey -> Utils.getWithDefault dkey (VBase VNull |> emptyVTrace) d)
            _              -> error ()
          DictRemove -> case args of
            [key, VDict d] -> valToDictKey bt key |> Result.map (\dkey -> VDict (Dict.remove dkey d) |> emptyVTrace)
            _              -> error ()
          Cos        -> unaryMathOp op args
          Sin        -> unaryMathOp op args
          ArcCos     -> unaryMathOp op args
          ArcSin     -> unaryMathOp op args
          Floor      -> unaryMathOp op args
          Ceil       -> unaryMathOp op args
          Round      -> unaryMathOp op args
          Sqrt       -> unaryMathOp op args
          Explode    -> case args of
            [VBase (VString s)] -> VList (List.map (vStr << String.fromChar) (String.toList s)) |> emptyVTraceOk
            _                   -> error ()
          DebugLog   -> case vs of
            [v] -> let _ = Debug.log (strVal v) v in Ok v
            _   -> error ()
          ToStr      -> case vs of
            [val] -> VBase (VString (strVal val)) |> emptyVTraceOk
            _     -> error ()
          RangeOffset _ -> error ()
      in
      newValRes
      |> Result.map (\newVal -> (newVal, List.concat wss))


-- Returns Ok Nothing if no branch matches
-- Returns Ok (Just results) if branch matches and no execution errors
-- Returns Err s if execution error
evalBranches env bt v bs =
  List.foldl (\(Branch_ _ pat exp _) acc ->
    case (acc, (pat,v) `cons` Just env) of
      (Ok (Just done), _)     -> acc
      (Ok Nothing, Just env') -> eval_ env' bt exp |> Result.map Just
      (Err s, _)              -> acc
      _                       -> Ok Nothing

  ) (Ok Nothing) (List.map .val bs)


-- Returns Ok Nothing if no branch matches
-- Returns Ok (Just results) if branch matches and no execution errors
-- Returns Err s if execution error
evalTBranches env bt val tbranches =
  List.foldl (\(TBranch_ _ tipe exp _) acc ->
    case acc of
      Ok (Just done) ->
        acc

      Ok Nothing ->
        if Types.valIsType val tipe then
          eval_ env bt exp |> Result.map Just
        else
          acc

      Err s ->
        acc
  ) (Ok Nothing) (List.map .val tbranches)


evalDelta bt op is =
  case (op, is) of

    (Plus,    [i,j]) -> (+) i j
    (Minus,   [i,j]) -> (-) i j
    (Mult,    [i,j]) -> (*) i j
    (Div,     [i,j]) -> (/) i j
    (Pow,     [i,j]) -> (^) i j
    (Mod,     [i,j]) -> toFloat <| (%) (floor i) (floor j)
                         -- might want an error/warning for non-int
    (ArcTan2, [i,j]) -> atan2 i j

    (Cos,     [n])   -> cos n
    (Sin,     [n])   -> sin n
    (ArcCos,  [n])   -> acos n
    (ArcSin,  [n])   -> asin n
    (Floor,   [n])   -> toFloat <| floor n
    (Ceil,    [n])   -> toFloat <| ceiling n
    (Round,   [n])   -> toFloat <| round n
    (Sqrt,    [n])   -> sqrt n

    (Pi,      [])    -> pi

    (RangeOffset i, [n1,n2]) ->
      let m = n1 + toFloat i in
      if m > n2 then n2 else m

    _                -> crashWithBacktrace bt <| "Little evaluator bug: Eval.evalDelta " ++ strOp op


eBaseToVBase eBaseVal =
  case eBaseVal of
    EBool b     -> VBool b
    EString _ b -> VString b
    ENull       -> VNull


valToDictKey : Backtrace -> Val_ -> Result String (String, String)
valToDictKey bt val_ =
  case val_ of
    VConst (n, tr)    -> Ok <| (toString n, "num")
    VBase (VBool b)   -> Ok <| (toString b, "bool")
    VBase (VString s) -> Ok <| (toString s, "string")
    VBase VNull       -> Ok <| ("", "null")
    VList vals        ->
      vals
      |> List.map ((valToDictKey bt) << .v_)
      |> Utils.projOk
      |> Result.map (\keyStrings -> (toString keyStrings, "list"))
    _                 -> errorWithBacktrace bt <| "Cannot use " ++ (strVal (val val_)) ++ " in a key to a dictionary."

initEnvRes = Result.map snd <| (eval [] [] Parser.prelude)
initEnv = Utils.fromOk "Eval.initEnv" <| initEnvRes

run : Exp -> Result String (Val, Widgets)
run e = eval_ initEnv [] e

parseAndRun : String -> String
parseAndRun = strVal << fst << Utils.fromOk_ << run << Utils.fromOkay "parseAndRun" << Parser.parseE

parseAndRun_ = strValLocs << fst << Utils.fromOk_ << run << Utils.fromOkay "parseAndRun_" << Parser.parseE

rangeOff l1 i l2 = TrOp (RangeOffset i) [TrLoc l1, TrLoc l2]

-- Inflates a range to a list, which is then Concat-ed in eval
rangeToList : Range -> Result String (List Val)
rangeToList r =
  let err () = errorMsg "Range not specified with numeric constants" in
  case r.val of
    -- dummy VTraces...
    -- TODO: maybe add widgets
    RPoint e -> case e.val.e__ of
      EConst _ n l _ -> Ok [ vConst (n, rangeOff l 0 l) ]
      _              -> err ()
    RInterval e1 _ e2 -> case (e1.val.e__, e2.val.e__) of
      (EConst _ n1 l1 _, EConst _ n2 l2 _) ->
        let walkVal i =
          let m = n1 + toFloat i in
          let tr = rangeOff l1 i l2 in
          if m < n2
            then vConst (m,  tr) :: walkVal (i + 1)
            else vConst (n2, tr) :: []
        in
        Ok <| walkVal 0
      _ -> err ()

-- Could compute this in one pass along with rangeToList
isSorted = isSorted_ Nothing
isSorted_ mlast vs = case vs of
  []     -> True
  v::vs' ->
    case v.v_ of
      VConst (j,_) ->
        case mlast of
          Nothing -> isSorted_ (Just j) vs'
          Just i  -> if i < j
                       then isSorted_ (Just j) vs'
                       else False
      _ ->
        Debug.crash "isSorted"

btString : Backtrace -> String
btString bt =
  case bt of
    [] -> ""
    mostRecentExp::others ->
      let singleLineExpStrs =
        others
        |> List.map (Utils.head_ << String.lines << String.trimLeft << unparse)
        |> List.reverse
        |> String.join "\n"
      in
      singleLineExpStrs ++ "\n" ++ (unparse mostRecentExp)


errorWithBacktrace bt message =
  errorMsg <| (btString bt) ++ "\n" ++ message

crashWithBacktrace bt message =
  crashWithMsg <| (btString bt) ++ "\n" ++ message
