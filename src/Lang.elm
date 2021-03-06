module Lang where

import String
import Debug
import Dict
import Set
import Debug

import OurParser2 as P
import Utils

------------------------------------------------------------------------------

type alias Loc = (LocId, Frozen, Ident)  -- "" rather than Nothing b/c comparable
type alias LocId = Int
type alias Ident = String
type alias Num = Float
  -- may want to preserve decimal point for whole floats,
  -- so that parse/unparse are inverses and for WidgetDecls

type alias Frozen = String -- b/c comparable
(frozen, unann, thawed, assignOnlyOnce) = ("!", "", "?", "~")

type alias LocSet = Set.Set Loc

type alias Pat     = P.WithInfo Pat_
type alias Exp     = P.WithInfo Exp_
type alias Type    = P.WithInfo Type_
type alias Op      = P.WithInfo Op_
type alias Branch  = P.WithInfo Branch_
type alias TBranch = P.WithInfo TBranch_

-- TODO add constant literals to patterns, and match 'svg'
type Pat_
  = PVar WS Ident WidgetDecl
  | PConst WS Num
  | PBase WS EBaseVal
  | PList WS (List Pat) WS (Maybe Pat) WS
  | PAs WS Ident WS Pat

type Op_
  -- nullary ops
  = Pi
  | DictEmpty
  -- unary ops
  | Cos | Sin | ArcCos | ArcSin
  | Floor | Ceil | Round
  | ToStr
  | Sqrt
  | Explode
  | DebugLog
  --  | DictMem   -- TODO: add this
  -- binary ops
  | Plus | Minus | Mult | Div
  | Lt | Eq
  | Mod | Pow
  | ArcTan2
  | DictGet
  | DictRemove
  -- trinary ops
  | DictInsert

type alias EId  = Int
type alias Exp_ = { e__ : Exp__, eid : EId }

type Exp__
  = EConst WS Num Loc WidgetDecl
  | EBase WS EBaseVal
  | EVar WS Ident
  | EFun WS (List Pat) Exp WS -- WS: before (, before )
  -- TODO remember paren whitespace for multiple pats, like TForall
  -- | EFun WS (OneOrMany Pat) Exp WS
  | EApp WS Exp (List Exp) WS
  | EOp WS Op (List Exp) WS
  | EList WS (List Exp) WS (Maybe Exp) WS
  | EIf WS Exp Exp Exp WS
  | ECase WS Exp (List Branch) WS
  | ETypeCase WS Pat (List TBranch) WS
  | ELet WS LetKind Rec Pat Exp Exp WS
  | EComment WS String Exp
  | EOption WS (P.WithInfo String) WS (P.WithInfo String) Exp
  | ETyp WS Pat Type Exp WS
  | EColonType WS Exp WS Type WS
  | ETypeAlias WS Pat Type Exp WS

    -- EFun [] e     impossible
    -- EFun [p] e    (\p. e)
    -- EFun ps e     (\(p1 ... pn) e) === (\p1 (\p2 (... (\pn e) ...)))

    -- EApp f []     impossible
    -- EApp f [x]    (f x)
    -- EApp f xs     (f x1 ... xn) === ((... ((f x1) x2) ...) xn)

type Type_
  = TNum WS
  | TBool WS
  | TString WS
  | TNull WS
  | TList WS Type WS
  | TDict WS Type Type WS
  | TTuple WS (List Type) WS (Maybe Type) WS
  | TArrow WS (List Type) WS
  | TUnion WS (List Type) WS
  | TNamed WS Ident
  | TVar WS Ident
  | TForall WS (OneOrMany (WS, Ident)) Type WS
  | TWildcard WS

type alias WS = String

type OneOrMany a          -- track concrete syntax for:
  = One a                 --   x
  | Many WS (List a) WS   --   ws1~(x1~...~xn-ws2)

type Branch_  = Branch_ WS Pat Exp WS
type TBranch_ = TBranch_ WS Type Exp WS

type LetKind = Let | Def
type alias Rec = Bool

type alias WidgetDecl = P.WithInfo WidgetDecl_

type WidgetDecl_
  = IntSlider (P.WithInfo Int) Token (P.WithInfo Int) Caption
  | NumSlider (P.WithInfo Num) Token (P.WithInfo Num) Caption
  | NoWidgetDecl -- rather than Nothing, to work around parser types

type Widget
  = WIntSlider Int Int String Int Loc
  | WNumSlider Num Num String Num Loc
  | WPointSlider NumTr NumTr

type alias Widgets = List Widget

type alias Token = P.WithInfo String

type alias Caption = Maybe (P.WithInfo String)

type alias VTrace = List EId
type alias Val    = { v_ : Val_, vtrace : VTrace }

type Val_
  = VConst NumTr
  | VBase VBaseVal
  | VClosure (Maybe Ident) Pat Exp Env
  | VList (List Val)
  | VDict VDict_

type alias VDict_ = Dict.Dict (String, String) Val

type alias NumTr = (Num, Trace)

defaultQuoteChar = "'"
type alias QuoteChar = String

-- TODO combine all base exps/vals into PBase/EBase/VBase
type VBaseVal -- unlike Ints, these cannot be changed by Sync
  = VBool Bool
  | VString String
  | VNull

type EBaseVal
  = EBool Bool
  | EString QuoteChar String
  | ENull

type Trace = TrLoc Loc | TrOp Op_ (List Trace)

type alias Env = List (Ident, Val)
type alias Backtrace = List Exp

------------------------------------------------------------------------------
-- Unparsing

strBaseVal v = case v of
  VBool True  -> "true"
  VBool False -> "false"
  VString s   -> "'" ++ s ++ "'"
  VNull       -> "null"

strVal     = strVal_ False
strValLocs = strVal_ True

strNum     = toString
-- strNumDot  = strNum >> (\s -> if String.contains "[.]" s then s else s ++ ".0")

strNumTrunc k =
  strNum >> (\s -> if String.length s > k then String.left k s ++ ".." else s)

strVal_ : Bool -> Val -> String
strVal_ showTraces v =
  let foo = strVal_ showTraces in
  let sTrace = if showTraces then Utils.braces (toString v.vtrace) else "" in
  sTrace ++
  case v.v_ of
    VConst (i,tr)    -> strNum i ++ if showTraces then Utils.braces (strTrace tr) else ""
    VBase b          -> strBaseVal b
    VClosure _ _ _ _ -> "<fun>"
    VList vs         -> Utils.bracks (String.join " " (List.map foo vs))
    VDict d          -> "<dict " ++ (Dict.toList d |> List.map (\(k, v) -> (toString k) ++ ":" ++ (foo v)) |> String.join " ") ++ ">"

strOp op = case op of
  Plus          -> "+"
  Minus         -> "-"
  Mult          -> "*"
  Div           -> "/"
  Lt            -> "<"
  Eq            -> "="
  Pi            -> "pi"
  Cos           -> "cos"
  Sin           -> "sin"
  ArcCos        -> "arccos"
  ArcSin        -> "arcsin"
  ArcTan2       -> "arctan2"
  Floor         -> "floor"
  Ceil          -> "ceiling"
  Round         -> "round"
  ToStr         -> "toString"
  Explode       -> "explode"
  Sqrt          -> "sqrt"
  Mod           -> "mod"
  Pow           -> "pow"
  DictEmpty     -> "empty"
  DictInsert    -> "insert"
  DictGet       -> "get"
  DictRemove    -> "remove"
  DebugLog      -> "debug"

strLoc (k, b, mx) =
  "k" ++ toString k ++ (if mx == "" then "" else "_" ++ mx) ++ b

strTrace tr = case tr of
  TrLoc l   -> strLoc l
  TrOp op l ->
    Utils.parens (String.concat
      [strOp op, " ", String.join " " (List.map strTrace l)])

tab k = String.repeat k "  "

-- TODO take into account indent and other prefix of current line
fitsOnLine s =
  if String.length s > 70 then False
  else if List.member '\n' (String.toList s) then False
  else True

isLet e = case e.val.e__ of
  ELet _ _ _ _ _ _ _ -> True
  EComment _ _ e1    -> isLet e1
  _                  -> False


------------------------------------------------------------------------------
-- Mapping WithInfo/WithPos

mapValField f r = { r | val = f r.val }


------------------------------------------------------------------------------
-- Mapping

mapExp : (Exp -> Exp) -> Exp -> Exp
mapExp f e =
  let recurse = mapExp f in
  let wrap e__ = P.WithInfo (Exp_ e__ e.val.eid) e.start e.end in
  let wrapAndMap = f << wrap in
  case e.val.e__ of
    EConst _ _ _ _         -> f e
    EBase _ _              -> f e
    EVar _ _               -> f e
    EFun ws1 ps e' ws2     -> wrapAndMap (EFun ws1 ps (recurse e') ws2)
    EApp ws1 e1 es ws2     -> wrapAndMap (EApp ws1 (recurse e1) (List.map recurse es) ws2)
    EOp ws1 op es ws2      -> wrapAndMap (EOp ws1 op (List.map recurse es) ws2)
    EList ws1 es ws2 m ws3 -> wrapAndMap (EList ws1 (List.map recurse es) ws2 (Utils.mapMaybe recurse m) ws3)
    EIf ws1 e1 e2 e3 ws2      -> wrapAndMap (EIf ws1 (recurse e1) (recurse e2) (recurse e3) ws2)
    ECase ws1 e1 branches ws2 ->
      let newE1 = recurse e1 in
      let newBranches =
        List.map
            (mapValField (\(Branch_ bws1 p ei bws2) -> Branch_ bws1 p (recurse ei) bws2))
            branches
      in
      wrapAndMap (ECase ws1 newE1 newBranches ws2)
    ETypeCase ws1 pat tbranches ws2 ->
      let newBranches =
        List.map
            (mapValField (\(TBranch_ bws1 t ei bws2) -> TBranch_ bws1 t (recurse ei) bws2))
            tbranches
      in
      wrapAndMap (ETypeCase ws1 pat newBranches ws2)
    EComment ws s e1              -> wrapAndMap (EComment ws s (recurse e1))
    EOption ws1 s1 ws2 s2 e1      -> wrapAndMap (EOption ws1 s1 ws2 s2 (recurse e1))
    ELet ws1 k b p e1 e2 ws2      -> wrapAndMap (ELet ws1 k b p (recurse e1) (recurse e2) ws2)
    ETyp ws1 pat tipe e ws2       -> wrapAndMap (ETyp ws1 pat tipe (recurse e) ws2)
    EColonType ws1 e ws2 tipe ws3 -> wrapAndMap (EColonType ws1 (recurse e) ws2 tipe ws3)
    ETypeAlias ws1 pat tipe e ws2 -> wrapAndMap (ETypeAlias ws1 pat tipe (recurse e) ws2)

mapExpViaExp__ : (Exp__ -> Exp__) -> Exp -> Exp
mapExpViaExp__ f e =
  let wrap e__ = P.WithInfo (Exp_ e__ e.val.eid) e.start e.end in
  let f' exp = wrap (f exp.val.e__) in
  mapExp f' e

mapVal : (Val -> Val) -> Val -> Val
mapVal f v = case v.v_ of
  VList vs         -> f { v | v_ = VList (List.map (mapVal f) vs) }
  VDict d          -> f { v | v_ = VDict (Dict.map (\_ v -> mapVal f v) d) } -- keys ignored
  VConst _         -> f v
  VBase _          -> f v
  VClosure _ _ _ _ -> f v

foldVal : (Val -> a -> a) -> Val -> a -> a
foldVal f v a = case v.v_ of
  VList vs         -> f v (List.foldl (foldVal f) a vs)
  VDict d          -> f v (List.foldl (foldVal f) a (Dict.values d)) -- keys ignored
  VConst _         -> f v a
  VBase _          -> f v a
  VClosure _ _ _ _ -> f v a

-- Fold through preorder traversal
foldExp : (Exp -> a -> a) -> a -> Exp -> a
foldExp f acc exp =
  List.foldl f acc (flattenExpTree exp)

foldExpViaE__ : (Exp__ -> a -> a) -> a -> Exp -> a
foldExpViaE__ f acc exp =
  let f' exp = f exp.val.e__ in
  foldExp f' acc exp

replaceExpNode : Exp -> Exp -> Exp -> Exp
replaceExpNode oldNode newNode root =
  let esubst = Dict.singleton oldNode.val.eid newNode.val.e__ in
  applyESubst esubst root

mapType : (Type -> Type) -> Type -> Type
mapType f tipe =
  let recurse = mapType f in
  let wrap t_ = P.WithInfo t_ tipe.start tipe.end in
  case tipe.val of
    TNum _       -> f tipe
    TBool _      -> f tipe
    TString _    -> f tipe
    TNull _      -> f tipe
    TNamed _ _   -> f tipe
    TVar _ _     -> f tipe
    TWildcard _  -> f tipe

    TList ws1 t1 ws2        -> f (wrap (TList ws1 (recurse t1) ws2))
    TDict ws1 t1 t2 ws2     -> f (wrap (TDict ws1 (recurse t1) (recurse t2) ws2))
    TArrow ws1 ts ws2       -> f (wrap (TArrow ws1 (List.map recurse ts) ws2))
    TUnion ws1 ts ws2       -> f (wrap (TUnion ws1 (List.map recurse ts) ws2))
    TForall ws1 vars t1 ws2 -> f (wrap (TForall ws1 vars (recurse t1) ws2))

    TTuple ws1 ts ws2 mt ws3 ->
      f (wrap (TTuple ws1 (List.map recurse ts) ws2 (Utils.mapMaybe recurse mt) ws3))

foldType : (Type -> a -> a) -> Type -> a -> a
foldType f tipe acc =
  let foldTypes f tipes acc = List.foldl (\t acc -> foldType f t acc) acc tipes in
  case tipe.val of
    TNum _          -> acc |> f tipe
    TBool _         -> acc |> f tipe
    TString _       -> acc |> f tipe
    TNull _         -> acc |> f tipe
    TNamed _ _      -> acc |> f tipe
    TVar _ _        -> acc |> f tipe
    TWildcard _     -> acc |> f tipe
    TList _ t _     -> acc |> foldType f t |> f tipe
    TDict _ t1 t2 _ -> acc |> foldType f t1 |> foldType f t2 |> f tipe
    TForall _ _ t _ -> acc |> foldType f t |> f tipe
    TArrow _ ts _   -> acc |> foldTypes f ts |> f tipe
    TUnion _ ts _   -> acc |> foldTypes f ts |> f tipe

    TTuple _ ts _ Nothing _  -> acc |> foldTypes f ts |> f tipe
    TTuple _ ts _ (Just t) _ -> acc |> foldTypes f (ts++[t]) |> f tipe


------------------------------------------------------------------------------
-- Traversing

-- Returns pre-order list of expressions
-- O(n^2) memory
flattenExpTree : Exp -> List Exp
flattenExpTree exp =
  exp :: List.concatMap flattenExpTree (childExps exp)

-- For each node for which `predicate` returns True, return it and its ancestors
-- For each matching node, ancestors appear in order: root first, match last.
findAllWithAncestors : (Exp -> Bool) -> Exp -> List (List Exp)
findAllWithAncestors predicate exp =
  findAllWithAncestors_ predicate [] exp

findAllWithAncestors_ : (Exp -> Bool) -> List Exp -> Exp -> List (List Exp)
findAllWithAncestors_ predicate ancestors exp =
  let ancestorsAndThis = ancestors ++ [exp] in
  let thisResult       = if predicate exp then [ancestorsAndThis] else [] in
  let recurse exp      = findAllWithAncestors_ predicate ancestorsAndThis exp in
  thisResult ++ List.concatMap recurse (childExps exp)

childExps : Exp -> List Exp
childExps e =
  case e.val.e__ of
    EConst _ _ _ _          -> []
    EBase _ _               -> []
    EVar _ _                -> []
    EFun ws1 ps e' ws2      -> [e']
    EOp ws1 op es ws2       -> es
    EList ws1 es ws2 m ws3  ->
      case m of
        Just e  -> es ++ [e]
        Nothing -> es
    EApp ws1 f es ws2               -> f :: es
    ELet ws1 k b p e1 e2 ws2        -> [e1, e2]
    EIf ws1 e1 e2 e3 ws2            -> [e1, e2, e3]
    ECase ws1 e branches ws2        -> e :: (branchExps branches)
    ETypeCase ws1 pat tbranches ws2 -> tbranchExps tbranches
    EComment ws s e1                -> [e1]
    EOption ws1 s1 ws2 s2 e1        -> [e1]
    ETyp ws1 pat tipe e ws2         -> [e]
    EColonType ws1 e ws2 tipe ws3   -> [e]
    ETypeAlias ws1 pat tipe e ws2   -> [e]


------------------------------------------------------------------------------
-- Conversion

valToTrace : Val -> Trace
valToTrace v = case v.v_ of
  VConst (_, trace) -> trace
  _                 -> Debug.crash "valToTrace"


------------------------------------------------------------------------------
-- Location Substitutions
-- Expression Substitutions

type alias Subst = Dict.Dict LocId Num
type alias SubstPlus = Dict.Dict LocId (P.WithInfo Num)
type alias SubstMaybeNum = Dict.Dict LocId (Maybe Num)

type alias ESubst = Dict.Dict EId Exp__

type alias TwoSubsts = { lsubst : Subst, esubst : ESubst }

-- For unparsing traces, possibily inserting variables: d
type alias SubstStr = Dict.Dict LocId String

applyLocSubst : Subst -> Exp -> Exp
applyLocSubst s = applySubst { lsubst = s, esubst = Dict.empty }

applyESubst : ESubst -> Exp -> Exp
applyESubst s = applySubst { lsubst = Dict.empty, esubst = s }

applySubst : TwoSubsts -> Exp -> Exp
applySubst subst exp =
  let replacer =
    (\e ->
      let e__ = e.val.e__ in
      let e__ConstReplaced =
        case e__ of
          EConst ws n loc wd ->
            let locId = Utils.fst3 loc in
            case Dict.get locId subst.lsubst of
              Just n' -> EConst ws n' loc wd
              Nothing -> e__
              -- 10/28: substs from createMousePosCallbackSlider only bind
              -- updated values (unlike substs from Sync)
          _ -> e__
      in
      let e__' =
        case Dict.get e.val.eid subst.esubst of
          Just e__New -> e__New
          Nothing     -> e__ConstReplaced
      in
      P.WithInfo (Exp_ e__' e.val.eid) e.start e.end
    )
  in
  mapExp replacer exp


{-
-- for now, LocId instead of EId
type alias ESubst = Dict.Dict LocId Exp__

applyESubst : ESubst -> Exp -> Exp
applyESubst esubst =
  mapExpViaExp__ <| \e__ -> case e__ of
    EConst _ i -> case Dict.get (Utils.fst3 i) esubst of
                    Nothing   -> e__
                    Just e__' -> e__'
    _          -> e__
-}


-----------------------------------------------------------------------------
-- Utility

branchExps : List Branch -> List Exp
branchExps branches =
  List.map
    (\b -> let (Branch_ _ _ exp _) = b.val in exp)
    branches

tbranchExps : List TBranch -> List Exp
tbranchExps tbranches =
  List.map
    (\b -> let (TBranch_ _ _ exp _) = b.val in exp)
    tbranches

branchPats : List Branch -> List Pat
branchPats branches =
  List.map
    (\b -> let (Branch_ _ pat _ _) = b.val in pat)
    branches

-- Need parent expression since case expression branches into several scopes
isScope : Maybe Exp -> Exp -> Bool
isScope maybeParent exp =
  let isObviouslyScope =
    case exp.val.e__ of
      ELet _ _ _ _ _ _ _ -> True
      EFun _ _ _ _       -> True
      _                  -> False
  in
  case maybeParent of
    Just parent ->
      case parent.val.e__ of
        ECase _ predicate branches _ -> predicate /= exp
        _                            -> isObviouslyScope
    Nothing -> isObviouslyScope

varsOfPat : Pat -> List Ident
varsOfPat pat =
  case pat.val of
    PConst _ _              -> []
    PBase _ _               -> []
    PVar _ x _              -> [x]
    PList _ ps _ Nothing _  -> List.concatMap varsOfPat ps
    PList _ ps _ (Just p) _ -> List.concatMap varsOfPat (p::ps)
    PAs _ x _ p             -> x::(varsOfPat p)


-----------------------------------------------------------------------------
-- Lang Options

-- all options should appear before the first non-comment expression

getOptions : Exp -> List (String, String)
getOptions e = case e.val.e__ of
  EOption _ s1 _ s2 e1 -> (s1.val, s2.val) :: getOptions e1
  EComment _ _ e1      -> getOptions e1
  _                    -> []


------------------------------------------------------------------------------
-- Error Messages

errorPrefix = "[Little Error]" -- NOTE: same as errorPrefix in Native/codeBox.js
crashWithMsg s  = Debug.crash <| errorPrefix ++ "\n\n" ++ s
errorMsg s      = Err <| errorPrefix ++ "\n\n" ++ s

strPos = P.strPos


------------------------------------------------------------------------------
-- Abstract Syntax Helpers

-- NOTE: the Exp builders use dummyPos

val : Val_ -> Val
val = flip Val [-1]

exp_ : Exp__ -> Exp_
exp_ = flip Exp_ (-1)

withDummyRange x  = P.WithInfo x P.dummyPos P.dummyPos
withDummyPos e__  = P.WithInfo (exp_ e__) P.dummyPos P.dummyPos
  -- TODO rename withDummyPos

replaceE__ : Exp -> Exp__ -> Exp
replaceE__ e e__ = let e_ = e.val in { e | val = { e_ | e__ = e__ } }

dummyLoc_ b = (0, b, "")
dummyTrace_ b = TrLoc (dummyLoc_ b)

dummyLoc = dummyLoc_ unann
dummyTrace = dummyTrace_ unann

ePlus e1 e2 = withDummyPos <| EOp "" (withDummyRange Plus) [e1,e2] ""

eBool  = withDummyPos << EBase " " << EBool
eStr   = withDummyPos << EBase " " << EString defaultQuoteChar
eStr0  = withDummyPos << EBase "" << EString defaultQuoteChar
eTrue  = eBool True
eFalse = eBool False

eApp e es = case es of
  []      -> Debug.crash "eApp"
  [e1]    -> withDummyPos <| EApp "\n" e [e1] ""
  e1::es' -> eApp (withDummyPos <| EApp " " e [e1] "") es'

eFun ps e = case ps of
  []      -> Debug.crash "eFun"
  [p]     -> withDummyPos <| EFun " " [p] e ""
  p::ps'  -> withDummyPos <| EFun " " [p] (eFun ps' e) ""

ePair e1 e2 = withDummyPos <| EList " " [e1,e2] "" Nothing ""

noWidgetDecl = withDummyRange NoWidgetDecl

rangeSlider kind a b =
  withDummyRange <|
    kind (withDummyRange a) (withDummyRange "-") (withDummyRange b) Nothing

intSlider = rangeSlider IntSlider
numSlider = rangeSlider NumSlider

colorNumberSlider = intSlider 0 499

eLets xes eBody = case xes of
  (x,e)::xes' -> withDummyPos <|
                   ELet "\n" Let False (withDummyRange (PVar " " x noWidgetDecl)) e (eLets xes' eBody) ""
  []          -> eBody

eVar0 a        = withDummyPos <| EVar "" a
eVar a         = withDummyPos <| EVar " " a
eConst0 a b    = withDummyPos <| EConst "" a b noWidgetDecl
eConst a b     = withDummyPos <| EConst " " a b noWidgetDecl
eList0 a b     = withDummyPos <| EList "" a "" b ""
eList a b      = withDummyPos <| EList " " a "" b ""
eComment a b   = withDummyPos <| EComment " " a b

pVar0 a        = withDummyRange <| PVar "" a noWidgetDecl
pVar a         = withDummyRange <| PVar " " a noWidgetDecl
pList0 ps      = withDummyRange <| PList "" ps "" Nothing ""
pList ps       = withDummyRange <| PList " " ps "" Nothing ""
pAs x p        = withDummyRange <| PAs " " x " " p

-- note: dummy ids...
vTrue    = vBool True
vFalse   = vBool False
vBool    = val << VBase << VBool
vStr     = val << VBase << VString
vConst   = val << VConst
vBase    = val << VBase
vList    = val << VList
vDict    = val << VDict

unwrapVList : Val -> Maybe (List Val_)
unwrapVList v =
  case v.v_ of
    VList vs -> Just <| List.map .v_ vs
    _        -> Nothing

-- TODO names/types

unwrapVList_ : String -> Val -> List Val_
unwrapVList_ s v = case v.v_ of
  VList vs -> List.map .v_ vs
  _        -> Debug.crash <| "unwrapVList_: " ++ s

unwrapVBaseString_ : String -> Val_ -> String
unwrapVBaseString_ s v_ = case v_ of
  VBase (VString k) -> k
  _                 -> Debug.crash <| "unwrapVBaseString_: " ++ s


eRaw__ = EVar
eRaw0  = eVar0
eRaw   = eVar

listOfRaw = listOfVars

listOfVars xs =
  case xs of
    []     -> []
    x::xs' -> eVar0 x :: List.map eVar xs'

listOfPVars xs =
  case xs of
    []     -> []
    x::xs' -> pVar0 x :: List.map pVar xs'

listOfNums ns =
  case ns of
    []     -> []
    n::ns' -> eConst0 n dummyLoc :: List.map (flip eConst dummyLoc) ns'

-- listOfNums1 = List.map (flip eConst dummyLoc)

type alias AnnotatedNum = (Num, Frozen, WidgetDecl)
  -- may want to move this up into EConst

listOfAnnotatedNums : List AnnotatedNum -> List Exp
listOfAnnotatedNums list =
  case list of
    [] -> []
    (n,ann,wd) :: list' ->
      withDummyPos (EConst "" n (dummyLoc_ ann) wd) :: listOfAnnotatedNums1 list'

listOfAnnotatedNums1 =
 List.map (\(n,ann,wd) -> withDummyPos (EConst " " n (dummyLoc_ ann) wd))

minMax x y             = (min x y, max x y)
minNumTr (a,t1) (b,t2) = if a <= b then (a,t1) else (b,t2)
maxNumTr (a,t1) (b,t2) = if a >= b then (a,t1) else (b,t2)
minMaxNumTr nt1 nt2    = (minNumTr nt1 nt2, maxNumTr nt1 nt2)

plusNumTr (n1,t1) (n2,t2)  = (n1 + n2, TrOp Plus [t1, t2])
minusNumTr (n1,t1) (n2,t2) = (n1 + n2, TrOp Minus [t1, t2])
