module InterfaceView2 (view) where

--Import the little language and its parsing utilities
import Lang exposing (..) --For access to what makes up the Vals
import LangTools
import LangParser2 as Parser exposing (parseE)
import LangUnparser exposing (unparse)
import Draw
import Sync
import Eval
import Utils
import Keys
import InterfaceModel exposing (..)
import LangSvg exposing (NodeId, ShapeKind, attr)
import ShapeWidgets exposing (..) -- to expose X, Y, D, O, etc.
import ExamplesGenerated as Examples
import Config exposing (params)
import OurParser2 as P
import Either exposing (Either(..))

import VirtualDom

--Core Libraries
import List
import Dict
import Set
import String
import Graphics.Element as GE
import Graphics.Collage as GC
import Graphics.Input as GI
import Graphics.Input.Field as GIF
import Text as T exposing (defaultStyle)
import Color
import Json.Decode

--Signaling Libraries
import Mouse
import Window
import Task exposing (Task, andThen)

--Storage Libraries
import InterfaceStorage exposing (taskMailbox, saveStateLocally, loadLocalState,
                                  checkAndSave, getLocalSaves, clearLocalSaves,
                                  deleteLocalSave)

--Library for Ace
import CodeBox exposing (saveRequestInfo, runRequestInfo)

--Html Libraries
import Html
import Html.Attributes as Attr
import Html.Events as Events
import Html.Lazy

--Svg Libraries
import Svg
import Svg.Attributes
import Svg.Events
import Svg.Lazy

--Error Checking Libraries
import Debug

--------------------------------------------------------------------------------

debugLog = Config.debugLog Config.debugView

--------------------------------------------------------------------------------

svgLine      = flip Svg.line []
svgRect      = flip Svg.rect []
svgCircle    = flip Svg.circle []
svgEllipse   = flip Svg.ellipse []
svgPolygon   = flip Svg.polygon []
svgPath      = flip Svg.path []

-- TODO use these more below

--------------------------------------------------------------------------------

dimToPix d = String.append (toString d) "px"

interfaceColor = Color.rgba 52 73 94 1.0
strInterfaceColor = "rgba(52,73,94,1.0)"
strButtonTopColor = "rgba(231,76,60,1.0)" -- from InterfaceButtons example
textColor = "white"

titleStyle =
  { defaultStyle | typeface = ["Courier", "monospace"]
                 , height = Just 18
                 , bold = False
                 , color = Color.white}

imgPath s = "img/" ++ s

-- Creates an Html button with the text properly offset
type ButtonStatus = Raised | Highlighted | Depressed | Disabled
type ButtonKind   = Regular | Selected | Unselected
type alias ButtonState = (ButtonKind, ButtonStatus)

-- Currently assumes:
--  font-size is 16px
--  the top of the button occupies 90% of the height of the button
--  the depressed button should move the text down 3/50 of the total height of the
--   button
makeButton : ButtonState -> Int -> Int -> String -> GE.Element
makeButton (kind, status) w h text =
  let fontsize = 16
      topprop = 0.9
      depdip = 0.06
      raisedoffset = round <| 0.5 * topprop * toFloat h - 0.5 * fontsize
      depressedoffset = round <| toFloat raisedoffset + depdip * toFloat h
      prefix = case kind of
        Regular    -> ""
        Selected   -> ""
        Unselected -> "unselected_"
      (img, dip) = case status of
        Raised      -> (imgPath <| prefix ++ "button_raised.svg", raisedoffset)
        Highlighted -> (imgPath <| prefix ++ "button_highlighted.svg", raisedoffset)
        Depressed   -> (imgPath <| prefix ++ "button_depressed.svg", depressedoffset)
        Disabled    -> (imgPath <| prefix ++ "button_disabled.svg", raisedoffset)
  in
  GE.flow GE.outward
    [ GE.image w h img
    , Html.toElement w h <|
        Html.div
          [ Attr.style
              [ ("color", textColor)
              , ("font-family", params.mainSection.widgets.font)
              , ("font-size", "16px")
              , ("text-align", "center")
              , ("width", dimToPix w)
              , ("height", dimToPix h)
              , ("transform", "translate(0px," ++ dimToPix dip ++ ")")
              ]
          ] [ Html.text text ]
    ]


--------------------------------------------------------------------------------
-- Zone Options (per shape)

-- TODO need to add something back in to allow hideZonesTail, basicZonesTail, etc.

{-
type alias ZoneOptions =
  { showBasic : Bool , addBasic : Bool , addRot : Bool , addColor : Bool
  , addDelete : Bool , addSelect : Bool, addSelectShapes : Bool
  }

zoneOptions0 =
  { showBasic = False , addBasic = False , addRot = False , addColor = False
  , addDelete = False , addSelect = False, addSelectShapes = False
  }

optionsOf : ShowZones -> ZoneOptions
optionsOf x =
  if x == showZonesNone       then { zoneOptions0 | addBasic = True }
  else if x == showZonesBasic then { zoneOptions0 | addBasic = True, showBasic = True }
  else if x == showZonesExtra then { zoneOptions0 | addRot = True, addColor = True }
  else if x == showZonesDel   then { zoneOptions0 | addDelete = True }
  -- TODO temporary
  -- else if x == showZonesSelectAttrs  then { zoneOptions0 | addSelect = True }
  else if x == showZonesSelectAttrs  then { zoneOptions0 | addSelect = True, addRot = True, addColor = True }
  else if x == showZonesSelectShapes then { zoneOptions0 | addSelectShapes = True }
  else
    Debug.crash "optionsOf"
-}


--------------------------------------------------------------------------------
-- Compiling to Svg

buildSvg : (Model, Bool) -> LangSvg.RootedIndexedTree -> Svg.Svg
buildSvg options (i,d) = buildSvg_ options d i

buildSvg_ : (Model, Bool) -> LangSvg.IndexedTree -> LangSvg.NodeId -> Svg.Svg
buildSvg_ stuff d i =
  let (model, addZones) = stuff in
  case Utils.justGet_ ("buildSvg_ " ++ toString i) i d of
   LangSvg.TextNode text -> VirtualDom.text text
   LangSvg.SvgNode shape attrs js ->
    case (model.showGhosts, Utils.maybeRemoveFirst "HIDDEN" attrs) of
     (False, Just _) -> Svg.svg [] []
     _ ->
      -- TODO: figure out: (LangSvg.attr "draggable" "false")
      let (zones, attrs') =
        case (addZones, Utils.maybeRemoveFirst "ZONES" attrs) of
          (False, Nothing)     -> ([], attrs)
          (False, Just (_, l)) -> ([], l)
          (True, Nothing) ->
            (makeZones model shape i attrs, attrs)
          (True, Just (aval, l)) -> case aval.av_ of
            _ ->
              (makeZones model shape i attrs, l)
            -- TODO breaking these for now; see ZoneOptions comment.
{-
            LangSvg.AString "none" ->
              (makeZones model zoneOptions0 shape i attrs, l)
            LangSvg.AString "basic" ->
              let options' = { options | addRot = False, addColor = False } in
              (makeZones model options' shape i attrs, l)
            _ -> Debug.crash "buildSvg_"
-}
      in
      let children = List.map (buildSvg_ stuff d) js in
      -- let mainshape = (Svg.node shape) (LangSvg.compileAttrs attrs') children in
      let mainshape =
        let (rawKind, rawAttrs) = LangSvg.desugarShapeAttrs shape attrs' in
        (Svg.node rawKind) (LangSvg.compileAttrs rawAttrs) children in
      if zones == []
        then mainshape
        else Svg.svg [] (mainshape :: zones)


--------------------------------------------------------------------------------

dragZoneEvents zoneKey =
  [ onMouseDown (ClickZone zoneKey)
  , onMouseOver (turnOnCaptionAndHighlights zoneKey)
  , onMouseOut turnOffCaptionAndHighlights
  ]

zoneEvents id shape zone = dragZoneEvents (Left (id, shape, zone))
sliderZoneEvents i string = dragZoneEvents (Right (i, string))


--------------------------------------------------------------------------------
-- Widget Layer

buildSvgWidgets : Int -> Int -> Model -> Svg.Svg
buildSvgWidgets wCanvas hCanvas model =
  let
    widgets        = model.widgets

    pad            = params.mainSection.uiWidgets.pad
    wSlider        = params.mainSection.uiWidgets.wSlider
    hSlider        = params.mainSection.uiWidgets.hSlider
    wCaption       = params.mainSection.uiWidgets.wCaption

    numWidgets    = List.length widgets
    wWidget       = wSlider + wCaption + 2*pad
    hWidget       = hSlider + 2*pad
    wToolBoxMax   = wCanvas - 2*pad
    numCols       = floor (wToolBoxMax / wWidget)
    numRows       = ceiling (toFloat numWidgets / toFloat numCols)
    wToolBox      = numCols * wWidget
    hToolBox      = numRows * hWidget
    xL            = pad
    yBL           = hCanvas - hWidget - pad
  in

  let drawNumWidget i_ intOrNum widget locId cap_ minVal maxVal curVal =
    let i = i_ - 1 in
    let
      (r,c) = (i % numRows, i // numRows)
      xi    = xL  + c*wWidget
      yi    = yBL - r*hWidget
      xi'   = xi + pad
      yi'   = yi + pad
    in
    let region =
      flip Svg.rect [] <|
        [ attr "fill" "lightgray"
        , attr "stroke" strInterfaceColor , attr "stroke-width" "3px"
        , attr "rx" "9px" , attr "ry" "9px"
        , attr "x" (toString (xL  + c*wWidget))
        , attr "y" (toString (yBL - r*hWidget))
        , attr "width" (toString wWidget) , attr "height" (toString hWidget)
        ]
    in
    let box =
      let color =
        let feature =
          (ShapeWidgets.selectedTypeWidget, -1, "widget" ++ (toString locId))
        in
        case model.tool of
          Cursor ->
            if Set.member feature model.selectedFeatures
              then colorPointSelected
              else strInterfaceColor -- colorPointNotSelected
          _ -> strInterfaceColor
      in
      flip Svg.rect [] <|
        [ attr "fill" color
        , attr "stroke" "20px", attr "stroke-width" "20px"
        , attr "x" (toString (xL  + c*wWidget + pad))
        , attr "y" (toString (yBL - r*hWidget + pad))
        , attr "width" (toString wSlider) , attr "height" (toString hSlider)
        , onMouseDown (toggleSelectedWidget locId)
        ]
    in
    let ball =
      let (range, diff) = (maxVal - minVal, curVal - minVal) in
      let pct = diff / range in
      let cx = xi + pad + round (pct*wSlider) in
      let cy = yi + pad + (hSlider//2) in
      flip Svg.circle [] <|
        [ attr "stroke" "black" , attr "stroke-width" "2px"
        , attr "fill" strButtonTopColor
        , attr "r" params.mainSection.uiWidgets.rBall
        , attr "cx" (toString cx) , attr "cy" (toString cy)
        , cursorOfZone "SliderBall" "default"
        ] ++ sliderZoneEvents i_ intOrNum
    in
    let text =
      let cap = cap_ ++ strNumTrunc 5 curVal in
      flip Svg.text' [VirtualDom.text cap] <|
        [ attr "fill" "black"
        , attr "font-family" params.mainSection.uiWidgets.font
        , attr "font-size" params.mainSection.uiWidgets.fontSize
        , attr "x" (toString (xi' + wSlider + 10))
        , attr "y" (toString (yi' + 18))
        ]
    in
    [region, box, text, ball]
  in

  let drawPointWidget i_ widget cx cy =
    -- copied from ball above
    let ball =
      flip Svg.circle [] <|
        [ attr "stroke" "black" , attr "stroke-width" "2px"
        , attr "fill" strButtonTopColor
        , attr "r" params.mainSection.uiWidgets.rBall
        , attr "cx" (toString cx) , attr "cy" (toString cy)
        , cursorOfZone "SliderBall" "default"
        ] ++ sliderZoneEvents i_ "Point"
    in
    [ball]
  in

  let draw (i_, widget) =
    case widget of

      WNumSlider minVal maxVal cap curVal (k,_,_) ->
        drawNumWidget i_ "Num" widget k cap minVal maxVal curVal

      WIntSlider a b cap c (k,_,_) ->
        let (minVal, maxVal, curVal) = (toFloat a, toFloat b, toFloat c) in
        drawNumWidget i_ "Int" widget k cap minVal maxVal curVal

      WPointSlider (xVal, _) (yVal, _) ->
        drawPointWidget i_ widget xVal yVal
  in

  Svg.svg [] <| List.concat <| Utils.mapi draw widgets

-- abstract the following with toggleSelected and toggleSelectedBlob
toggleSelectedWidget locId =
  let feature =
    (ShapeWidgets.selectedTypeWidget, -1, "widget" ++ (toString locId))
  in
  UpdateModel <| \model ->
    let update =
      if Set.member feature model.selectedFeatures
        then Set.remove
        else Set.insert
    in
    { model | selectedFeatures = update feature model.selectedFeatures }


--------------------------------------------------------------------------------
-- Defining Zones

-- okay to use dummy VTraces/Traces here, b/c compileAttr throws them away
attrNum k n    = LangSvg.compileAttr k (LangSvg.aNum (n, dummyTrace))
attrNumTr k nt = LangSvg.compileAttr k (LangSvg.aNum nt)

onMouseDown = Svg.Events.onMouseDown << Signal.message events.address
onMouseUp   = Svg.Events.onMouseUp   << Signal.message events.address
onMouseOver = Svg.Events.onMouseOver << Signal.message events.address
onMouseOut  = Svg.Events.onMouseOut  << Signal.message events.address

onMouseEnter = Events.onMouseEnter events.address
onMouseLeave = Events.onMouseLeave events.address

onMouseDownAndStop = handleEventAndStop "mousedown"

handleEventAndStop : String -> Event -> Svg.Attribute
handleEventAndStop eventName eventHandler =
  let defaultOptions = Events.defaultOptions in
  Events.onWithOptions eventName
    { defaultOptions | stopPropagation = True}
    Json.Decode.value
    (\_ -> Signal.message events.address eventHandler)

-- TODO use RealZones rather than Zones more

removeHoveredShape id =
  UpdateModel <| \m ->
    { m | hoveredShapes = Set.remove id m.hoveredShapes }

addHoveredShape id =
  UpdateModel <| \m ->
    { m | hoveredShapes = Set.singleton id }
    -- { m | hoveredShapes = Set.insert id m.hoveredShapes }

addHoveredCrosshair tuple =
  UpdateModel <| \m ->
    { m | hoveredCrosshairs = Set.insert tuple m.hoveredCrosshairs }

removeHoveredCrosshair tuple =
  UpdateModel <| \m ->
    { m | hoveredCrosshairs = Set.remove tuple m.hoveredCrosshairs }

cursorStyle s = LangSvg.attr "cursor" s

-- TODO should take into account disabled zones in Live mode
cursorOfZone zone default = case ShapeWidgets.parseZone zone of

  -- primary manipulation zones
  ZInterior        -> cursorStyle "move"
  ZPoint LeftEdge  -> cursorStyle "ew-resize"
  ZPoint RightEdge -> cursorStyle "ew-resize"
  ZPoint TopLeft   -> cursorStyle "nwse-resize"
  ZPoint BotRight  -> cursorStyle "nwse-resize"
  ZPoint TopEdge   -> cursorStyle "ns-resize"
  ZPoint BotEdge   -> cursorStyle "ns-resize"
  ZPoint BotLeft   -> cursorStyle "nesw-resize"
  ZPoint TopRight  -> cursorStyle "nesw-resize"
  ZLineEdge        -> cursorStyle "pointer"
  ZPolyEdge _      -> cursorStyle "pointer"

  -- indirect manipulation zones
  ZOther _         -> cursorStyle "pointer"
  ZSlider          -> cursorStyle "pointer"

  _                -> cursorStyle default

isPrimaryZone zone =
  case zone of
    "FillBall"        -> False
    "StrokeBall"      -> False
    "FillOpacityBall"   -> False
    "StrokeOpacityBall" -> False
    "StrokeWidthBall" -> False
    "RotateBall"      -> False
    "SliderBall"      -> False
    _                 -> True

isFillStrokeZone zone =
  case zone of
    "FillBall"        -> True
    "StrokeBall"      -> True
    "FillOpacityBall"   -> True
    "StrokeOpacityBall" -> True
    "StrokeWidthBall" -> True
    _                 -> False

isRotateZone zone =
  case zone of
    "RotateBall"      -> True
    _                 -> False


-- Stuff for Basic Zones -------------------------------------------------------

draggableZone svgFunc addStroke model id shape zone attrs =
  let showStroke = False in -- set to True for debugging
  flip svgFunc [] <|
    attrs ++
    zoneEvents id shape zone ++
    [ cursorOfZone zone "default"
    , LangSvg.attr "fill" "rgba(0,0,0,0.0)"
    , LangSvg.attr "stroke-width" <| if addStroke then "10" else "0"
    , LangSvg.attr "stroke" <| if showStroke
                               then "rgba(255,0,0,0.5)"
                               else "rgba(0,0,0,0.0)"
    ]

objectZoneIsCurrentlyBeingManipulated model nodeId zonePred =
  case model.mouseMode of
    MouseDragZone (Left (id, _, zone)) _ -> nodeId == id && zonePred zone
    _                                    -> False

objectIsCurrentlyBeingManipulated model nodeId =
  objectZoneIsCurrentlyBeingManipulated model nodeId (always True)

boundingBoxZones model id (left, top, right, bot) shapeWidgets =
  let pad = 10 in
  let maybeBackgroundBox =
    if objectIsCurrentlyBeingManipulated model id then []
    else if not (Set.member id model.hoveredShapes) then []
    else
      Utils.singleton <| svgRect <|
        [ LangSvg.attr "x" (toString (left - pad))
        , LangSvg.attr "y" (toString (top - pad))
        , LangSvg.attr "width" (toString (right - left + 2 * pad))
        , LangSvg.attr "height" (toString (bot - top + 2 * pad))
        , LangSvg.attr "fill" "rgba(100,100,100,0.0)"
        , LangSvg.attr "stroke" "lightgray"
        , LangSvg.attr "stroke-width" "1"
        ]
  in
  -- using group so that the onMouseLeave handler gets attached to
  -- all the nested widgets. probably not needed if pad >> 0, since
  -- will have to mouseLeave the backgroundBox after any other shapes.
  Svg.g
    [onMouseLeave (removeHoveredShape id) ]
    (maybeBackgroundBox ++ shapeWidgets)

minLengthForMiddleZones = 30

eightCardinalZones model id shape transform (left, top, right, bot) =
  let (width, height) = (right - left, bot - top) in
  let ifEnoughSpace len xs = if len < minLengthForMiddleZones then [] else xs in
  let mkPoint zone cx cy =
    zonePoint model id shape zone transform [attrNum "cx" cx, attrNum "cy" cy]
  in
    mkPoint "TopLeft" left top ++
    mkPoint "TopRight" right top ++
    mkPoint "BotLeft" left bot ++
    mkPoint "BotRight" right bot ++
    ifEnoughSpace height (mkPoint "LeftEdge" left (top + height / 2)) ++
    ifEnoughSpace height (mkPoint "RightEdge" right (top + height / 2)) ++
    ifEnoughSpace width (mkPoint "TopEdge" (left + width / 2) top) ++
    ifEnoughSpace width (mkPoint "BotEdge" (left + width / 2) bot)

pointZoneStyles =
  { radius = "6"
  , stroke = "black"
  , strokeWidth = "2"
  , fill =
      { shown = "white" -- "silver" -- "rgba(255,0,0,0.5)"
      , selectedShape = "yellow"
      , selectedBlob = "aqua" -- "rgba(255,255,0,1.0)"
      , hidden = "rgba(0,0,0,0.0)"
      }
  }

pointZoneStylesFillSelected model nodeId =
  let d = Dict.filter (\_ nodeId' -> nodeId == nodeId') model.selectedBlobs in
  if Dict.isEmpty d
    then pointZoneStyles.fill.selectedShape
    else pointZoneStyles.fill.selectedBlob

zonePoint model id shape zone transform attrs =
  let maybeStyles =
    let maybeStyles_ () =
      if objectZoneIsCurrentlyBeingManipulated model id ((==) zone) then
        Just (pointZoneStylesFillSelected model id)
      else if objectIsCurrentlyBeingManipulated model id then
        Nothing
      else if Set.member id model.selectedShapes then
        Just (pointZoneStylesFillSelected model id)
      else if Set.member id model.hoveredShapes then
        Just pointZoneStyles.fill.shown
      else
        Nothing
    in
    case ShapeWidgets.zoneToCrosshair shape zone of
      Nothing -> maybeStyles_ ()
      Just (xFeature, yFeature) ->
        if Set.member (id, xFeature, yFeature) model.hoveredCrosshairs
        then Nothing
        else maybeStyles_ ()
  in
  case maybeStyles of
    Nothing -> []
    Just fill ->
      Utils.singleton <| svgCircle <|
        [ LangSvg.attr "r" pointZoneStyles.radius
        , LangSvg.attr "fill" fill
        , LangSvg.attr "stroke" pointZoneStyles.stroke
        , LangSvg.attr "stroke-width" pointZoneStyles.strokeWidth
        , cursorOfZone zone "pointer"
        ] ++
        zoneEvents id shape zone ++
        transform ++
        attrs

zonePoints model id shape transform pts =
  List.concat <| flip Utils.mapi pts <| \(i, (x,y)) ->
    zonePoint model id shape ("Point" ++ toString i) transform
      [ attrNumTr "cx" x, attrNumTr "cy" y ]

-- TODO rename this once original zonePoints is removed
zonePoints2 model id shape transform pts =
  List.concat <| flip Utils.mapi pts <| \(i, (x,y)) ->
    zonePoint model id shape ("Point" ++ toString i) transform
      [ attrNum "cx" x, attrNum "cy" y ]

zoneLine model id shape zone (x1,y1) (x2,y2) attrs =
  draggableZone Svg.line True model id shape zone <|
    [ attrNumTr "x1" x1 , attrNumTr "y1" y1
    , attrNumTr "x2" x2 , attrNumTr "y2" y2
    , cursorStyle "pointer"
    ] ++ attrs

-- TODO rename this once original zoneLine is removed
zoneLine2 model id shape zone (x1,y1) (x2,y2) attrs =
  draggableZone Svg.line True model id shape zone <|
    [ attrNum "x1" x1 , attrNum "y1" y1
    , attrNum "x2" x2 , attrNum "y2" y2
    , cursorStyle "pointer"
    ] ++ attrs

-- Stuff for Rotate Zones ------------------------------------------------------

rotZoneDelta = 20

maybeTransformCmds : List LangSvg.Attr -> Maybe (List LangSvg.TransformCmd)
maybeTransformCmds l =
  case Utils.maybeFind "transform" l of
    Just aval -> case aval.av_ of
      LangSvg.ATransform cmds -> Just cmds
      _                       -> Nothing
    _                         -> Nothing

transformAttr cmds =
  [LangSvg.compileAttr "transform" (LangSvg.aTransform cmds)]

maybeTransformAttr l =
  case maybeTransformCmds l of
    Just cmds -> transformAttr cmds
    Nothing   -> []

zoneRotate model id shape (cx,cy) r maybeCmds =
  let pred z = isPrimaryZone z || isFillStrokeZone z in
  case ( Set.member id model.selectedShapes
       , objectZoneIsCurrentlyBeingManipulated model id pred
       , maybeCmds ) of
    (True, False, Just cmds) -> zoneRotate_ model id shape cx cy r cmds
    _                        -> []

zoneRotate_ model id shape cx cy r cmds =
  let (a, stroke, strokeWidth, rBall) =
      (20, "rgba(192,192,192,0.5)", "5", "7") in
  let (fillBall, swBall) = ("silver", "2") in
  let transform = transformAttr cmds in
  let circle =
    flip Svg.circle [] <|
      [ LangSvg.attr "fill" "none"
      , LangSvg.attr "stroke" stroke , LangSvg.attr "stroke-width" strokeWidth
      , LangSvg.attr "cx" (toString cx) , LangSvg.attr "cy" (toString cy)
      , LangSvg.attr "r"  (toString r)
      ]
  in
  let ball =
    flip Svg.circle [] <|
      [ LangSvg.attr "stroke" "black" , LangSvg.attr "stroke-width" swBall
      , LangSvg.attr "fill" fillBall
      , LangSvg.attr "cx" (toString cx) , LangSvg.attr "cy" (toString (cy - r))
      , LangSvg.attr "r"  rBall
      , cursorOfZone "RotateBall" "default"
      ] ++ transform
        ++ zoneEvents id shape "RotateBall"
  in
  let line =
    let (strokeColor, maybeEventHandler) =
      case (cmds, model.tool) of
        ([LangSvg.Rot (_,trace) _ _], Cursor) ->
          let typeAndNodeIdAndFeature = (ShapeWidgets.selectedTypeShapeFeature, id, ShapeWidgets.shapeRotation) in
          let handler = [onMouseDown (toggleSelected [typeAndNodeIdAndFeature])] in
          if Set.member typeAndNodeIdAndFeature model.selectedFeatures
            then (colorPointSelected, handler)
            else (colorPointNotSelected, handler)
        _ ->
          (stroke, [])
    in
    flip Svg.line [] <|
      [ LangSvg.attr "stroke" strokeColor , LangSvg.attr "stroke-width" strokeWidth
      , LangSvg.attr "x1" (toString cx) , LangSvg.attr "y1" (toString cy)
      , LangSvg.attr "x2" (toString cx) , LangSvg.attr "y2" (toString (cy - r))
      ] ++ transform
        ++ maybeEventHandler
  in
  [circle, line, ball]

halfwayBetween (x1,y1) (x2,y2) = ((x1 + x2) / 2, (y1 + y2) / 2)
distance (x1,y1) (x2,y2)       = sqrt ((x2-x1)^2 + (y2-y1)^2)

projPt (x,y)                   = (fst x, fst y)
halfwayBetween_ pt1 pt2        = halfwayBetween (projPt pt1) (projPt pt2)
distance_ pt1 pt2              = distance (projPt pt1) (projPt pt2)

-- TODO redo callsite
zoneRotatePolyOrPath model id kind pts nodeAttrs =
  let (xMin, xMax, yMin, yMax) =
    Draw.boundingBoxOfPoints_ (List.map (\(x,y) -> (fst x, fst y)) pts) in
  let (w, h) = (xMax - xMin, yMax - yMin) in
  let (xMiddle, yMiddle) = (xMin + 0.5 * w, yMin + 0.5 * h) in
  let r = ((max w h) / 2) + rotZoneDelta in
  zoneRotate model id kind (xMiddle, yMiddle) r (maybeTransformCmds nodeAttrs)


--------------------------------------------------------------------------------

zonesStroke model id shape x y l =
  let (maybeColor, maybeOpacity) = maybeColorNumAttr "stroke" l in
  let maybeStrokeWidth = maybeStrokeWidthNumAttr l in
  zoneStrokeOpacity model id shape (x - wOpacityBox - 5) y maybeOpacity ++
  zoneStrokeColor model id shape x y maybeColor ++
  zoneStrokeWidth model id shape (x + wGradient + 5) y maybeStrokeWidth

zonesFill model id shape x y l =
  let (maybeColor, maybeOpacity) = maybeColorNumAttr "fill" l in
  zoneFillOpacity model id shape (x - wOpacityBox - 5) y maybeOpacity ++
  zoneFillColor model id shape x y maybeColor

zonesFillAndStroke model id shape x y l =
  zonesFill model id shape x y l ++
  zonesStroke model id shape x (y - hZoneColor - 5) l

zoneFillColor   = zoneColor "FillBall" ShapeWidgets.shapeFill
zoneStrokeColor = zoneColor "StrokeBall" ShapeWidgets.shapeStroke

zoneFillOpacity   = zoneOpacity "FillOpacityBall" ShapeWidgets.shapeFillOpacity
zoneStrokeOpacity = zoneOpacity "StrokeOpacityBall" ShapeWidgets.shapeStrokeOpacity


-- Stuff for Color Zones -------------------------------------------------------

wGradient = ShapeWidgets.wColorSlider
hZoneColor = 20

maybeColorNumAttr : String -> List LangSvg.Attr -> (Maybe NumTr, Maybe NumTr)
maybeColorNumAttr k l =
  case Utils.maybeFind k l of
    Just aval -> case aval.av_ of
      LangSvg.AColorNum (nt, maybeOpacity) -> (Just nt, maybeOpacity)
      _                                    -> (Nothing, Nothing)
    _                                      -> (Nothing, Nothing)

zoneColor zoneName shapeFeature model id shape x y maybeColor =
  let pred z = isPrimaryZone z || isRotateZone z in
  let shapeSelected = Set.member id model.selectedShapes in
  let featureSelected =
    Set.member (ShapeWidgets.selectedTypeShapeFeature, id, shapeFeature)
               model.selectedFeatures in
  case ( shapeSelected || featureSelected
       , objectZoneIsCurrentlyBeingManipulated model id pred
       , maybeColor ) of
    (True, False, Just nt) -> zoneColor_ zoneName shapeFeature model id shape x y nt
    _                      -> []

zoneColor_ : Zone -> ShapeFeature -> Model -> NodeId -> ShapeKind
          -> Num -> Num -> NumTr -> List Svg.Svg
zoneColor_ zoneName shapeFeature model id shape x y (n, trace) =
  let (w, h, a, stroke, strokeWidth, rBall) =
      (wGradient, hZoneColor, 20, "silver", "2", "7") in
  let yOff = a + rotZoneDelta in
  let typeAndNodeIdAndFeature = (ShapeWidgets.selectedTypeShapeFeature, id, shapeFeature) in
  let ball =
    let cx = x + (n / LangSvg.maxColorNum) * wGradient in
    let cy = y - yOff + (h/2) in
    flip Svg.circle [] <|
      [ LangSvg.attr "stroke" "black" , LangSvg.attr "stroke-width" strokeWidth
      , LangSvg.attr "fill" stroke
      , LangSvg.attr "cx" (toString cx) , LangSvg.attr "cy" (toString cy)
      , LangSvg.attr "r"  rBall
      , cursorOfZone zoneName "default"
      ] ++ zoneEvents id shape zoneName
  in
  let box =
    flip Svg.rect [] <|
      [ LangSvg.attr "fill" <|
          if Set.member typeAndNodeIdAndFeature model.selectedFeatures
            then colorPointSelected
            else "none" -- colorPointNotSelected
      , LangSvg.attr "stroke" stroke , LangSvg.attr "stroke-width" strokeWidth
      , LangSvg.attr "x" (toString x) , LangSvg.attr "y" (toString (y - yOff))
      , LangSvg.attr "width" (toString w) , LangSvg.attr "height" (toString h)
      ]
  in
  -- TODO would probably be faster with an image...
  let gradient () =
    List.map (\i ->
      let (r,g,b) = Utils.numToColor ShapeWidgets.wColorSlider i in

      let fill =
        "rgb" ++ Utils.parens (String.join "," (List.map toString [r,g,b]))
      in
      flip Svg.rect [] <|
        [ LangSvg.attr "fill" fill
        , LangSvg.attr "x" (toString (x+i)) , LangSvg.attr "y" (toString (y - yOff))
        , LangSvg.attr "width" "1" , LangSvg.attr "height" (toString h)
        ]) [0 .. w]
  in
  [ Svg.g
      [onMouseDownAndStop (toggleSelected [typeAndNodeIdAndFeature])]
      (gradient () ++ [box])
  , ball
  ]


-- Stuff for Color Opacity Zones -----------------------------------------------

wOpacityBox = ShapeWidgets.wOpacitySlider

-- TODO could abstract the zoneColor, zoneOpacity, and zoneStrokeWidth sliders

zoneOpacity zoneName shapeFeature model id shape x y maybeOpacity =
  let pred z = isPrimaryZone z || isRotateZone z in
  let shapeSelected = Set.member id model.selectedShapes in
  let featureSelected =
    Set.member (ShapeWidgets.selectedTypeShapeFeature, id, shapeFeature)
               model.selectedFeatures in
  case ( shapeSelected || featureSelected
       , objectZoneIsCurrentlyBeingManipulated model id pred
       , maybeOpacity ) of
    (True, False, Just nt) -> zoneOpacity_ zoneName shapeFeature model id shape x y nt
    _                      -> []

zoneOpacity_
   : Zone -> ShapeFeature -> Model -> NodeId -> ShapeKind
  -> Num -> Num -> NumTr -> List Svg.Svg
zoneOpacity_ zoneName shapeFeature model id shape x y (n, trace) =
  let (w, h, a, stroke, strokeWidth, rBall) =
      (wOpacityBox, 20, 20, "silver", "2", "7") in
  let yOff = a + rotZoneDelta in
  let typeAndNodeIdAndFeature = (ShapeWidgets.selectedTypeShapeFeature, id, shapeFeature) in
  let ball =
    let cx = x + n * wOpacityBox in
    let cy = y - yOff + (h/2) in
    flip Svg.circle [] <|
      [ LangSvg.attr "stroke" "black" , LangSvg.attr "stroke-width" strokeWidth
      , LangSvg.attr "fill" stroke
      , LangSvg.attr "cx" (toString cx) , LangSvg.attr "cy" (toString cy)
      , LangSvg.attr "r"  rBall
      , cursorOfZone zoneName "default"
      ] ++ zoneEvents id shape zoneName
  in
  let box =
    flip Svg.rect [] <|
      [ LangSvg.attr "fill" <|
          if Set.member typeAndNodeIdAndFeature model.selectedFeatures
            then colorPointSelected
            else "white" -- colorPointNotSelected
      , LangSvg.attr "stroke" stroke , LangSvg.attr "stroke-width" strokeWidth
      , LangSvg.attr "x" (toString x) , LangSvg.attr "y" (toString (y - yOff))
      , LangSvg.attr "width" (toString w) , LangSvg.attr "height" (toString h)
      ]
  in
  [ Svg.g
      [onMouseDownAndStop (toggleSelected [typeAndNodeIdAndFeature])]
      ([box])
  , ball
  ]


-- Stuff for Stroke Width Zones ------------------------------------------------

wStrokeWidthBox = ShapeWidgets.wStrokeWidthSlider

maybeStrokeWidthNumAttr : List LangSvg.Attr -> Maybe NumTr
maybeStrokeWidthNumAttr l =
  case Utils.maybeFind "stroke-width" l of
    Just aval -> case aval.av_ of
      LangSvg.ANum n -> Just n
      _              -> Nothing
    _                -> Nothing

zoneStrokeWidth model id shape x y maybeStrokeWidth =
  let pred z = isPrimaryZone z || isRotateZone z in
  let shapeSelected = Set.member id model.selectedShapes in
  let featureSelected =
    Set.member (ShapeWidgets.selectedTypeShapeFeature, id, ShapeWidgets.shapeStrokeWidth)
               model.selectedFeatures in
  case ( shapeSelected || featureSelected
       , objectZoneIsCurrentlyBeingManipulated model id pred
       , maybeStrokeWidth ) of
    (True, False, Just nt) -> zoneStrokeWidth_ model id shape x y nt
    _                      -> []

zoneStrokeWidth_ model id shape x y (n, trace) =
  let (w, h, a, stroke, strokeWidth, rBall) =
      (wStrokeWidthBox, LangSvg.maxStrokeWidthNum, 20, "silver", "2", "7") in
  let yOff = a + rotZoneDelta in
  let typeAndNodeIdAndFeature =
    (ShapeWidgets.selectedTypeShapeFeature, id, ShapeWidgets.shapeStrokeWidth) in
  let box =
    flip Svg.rect [] <|
      [ LangSvg.attr "fill" <|
          if Set.member typeAndNodeIdAndFeature model.selectedFeatures
            then colorPointSelected
            else "white" -- colorPointNotSelected
      , LangSvg.attr "stroke" stroke , LangSvg.attr "stroke-width" strokeWidth
      , LangSvg.attr "x" (toString x) , LangSvg.attr "y" (toString (y - yOff))
      , LangSvg.attr "width" (toString w) , LangSvg.attr "height" (toString h)
      ]
  in
  let ball =
    let cx = x + (n / LangSvg.maxStrokeWidthNum) * wStrokeWidthBox in
    let cy = y - yOff + (h/2) in
    flip Svg.circle [] <|
      [ LangSvg.attr "stroke" "black" , LangSvg.attr "stroke-width" strokeWidth
      , LangSvg.attr "fill" stroke
      , LangSvg.attr "cx" (toString cx) , LangSvg.attr "cy" (toString cy)
      , LangSvg.attr "r"  rBall
      , cursorOfZone "StrokeWidthBall" "default"
      ] ++ zoneEvents id shape "StrokeWidthBall"
  in
  let triangle =
    let (x0,y0) = (x                   , y - yOff + h/2 ) in
    let (x1,y1) = (x + wStrokeWidthBox , y - yOff       ) in
    let (x2,y2) = (x + wStrokeWidthBox , y - yOff + h   ) in
    svgPath <|
       [ LangSvg.attr "fill" "darkgray"
       , LangSvg.attr "d"
           ("M " ++ toString x0 ++ " " ++ toString y0 ++
           " L " ++ toString x1 ++ " " ++ toString y1 ++
           " L " ++ toString x2 ++ " " ++ toString y2 ++ " Z")
       ]
  in
  [ Svg.g
      [onMouseDownAndStop (toggleSelected [typeAndNodeIdAndFeature])]
      [box, triangle]
  , ball
  ]


-- Stuff for Delete Zones ------------------------------------------------------

zoneDelete id shape x y transform =
  let b = False in
  if b then zoneDelete_ id shape x y transform else []

zoneDelete_ id shape x y transform =
  let (w, h, stroke, strokeWidth) =
      (20, 20, "silver", "2") in
  let evt =
    let foo old =
      { old | slate = Utils.mapSnd (Dict.insert id LangSvg.dummySvgNode) old.slate }
    in
    onMouseDown (UpdateModel foo) in
  let lines =
    let f x1 y1 x2 y2 =
      flip Svg.line [] <|
        [ LangSvg.attr "stroke" "darkred", LangSvg.attr "strokeWidth" strokeWidth
        , LangSvg.attr "x1" (toString x1) , LangSvg.attr "y1" (toString y1)
        , LangSvg.attr "x2" (toString x2) , LangSvg.attr "y2" (toString y2)
        , evt
        ] ++ transform
      in
     [ f x y (x + w) (y + h) , f x (y + h) (x + w) y ] in
  let box =
    flip Svg.rect [] <|
      [ LangSvg.attr "fill" "white"
      , LangSvg.attr "stroke" stroke , LangSvg.attr "strokeWidth" strokeWidth
      , LangSvg.attr "x" (toString x) , LangSvg.attr "y" (toString y)
      , LangSvg.attr "width" (toString w) , LangSvg.attr "height" (toString h)
      , evt
      ] ++ transform
  in
  [box] ++ lines


--------------------------------------------------------------------------------
-- Selection Zones

-- http://www.colorpicker.com/

colorPointSelected      = "#38F552" -- "rgba(0,128,0,1.0)"
colorPointNotSelected   = "#F5B038" -- "orange"
colorLineSelected       = "#B4FADB" -- "blue"
colorLineNotSelected    = "#FAB4D3" -- "red"

hairStrokeWidth         = "5" -- pointZoneStyles.radius - 1

type alias NodeIdAndAttrName     = (LangSvg.NodeId, String)
type alias NodeIdAndTwoAttrNames = (LangSvg.NodeId, String, String)

type alias NodeIdAndFeature      = (LangSvg.NodeId, ShapeWidgets.ShapeFeature)


toggleSelected nodeIdAndFeatures =
  UpdateModel <| toggleSelectedLambda nodeIdAndFeatures

toggleSelectedLambda nodeIdAndFeatures =
  \model ->
    -- If only some of the features were selected, we want to select all of
    -- them, not toggle individually.
    let deselect = List.all (flip Set.member model.selectedFeatures) nodeIdAndFeatures in
    let updateSet nodeIdAndFeature acc =
      if deselect
        then Set.remove nodeIdAndFeature acc
        else Set.insert nodeIdAndFeature acc
    in
    { model | selectedFeatures = List.foldl updateSet model.selectedFeatures nodeIdAndFeatures }

maybeZoneSelectCrossDot sideLength model thisCrosshair x y =
  if sideLength < minLengthForMiddleZones then []
  else zoneSelectCrossDot model thisCrosshair x y

zoneSelectCrossDot : Model -> (Int, ShapeKind, PointFeature)
                  -> number -> number' -> List Svg.Svg
zoneSelectCrossDot model (id, kind, pointFeature) x y =
  let xFeatureName = ShapeWidgets.unparseFeatureNum (Just kind) (X pointFeature) in
  let yFeatureName = ShapeWidgets.unparseFeatureNum (Just kind) (Y pointFeature) in
  let thisCrosshair = (id, xFeatureName, yFeatureName) in

  let len = 20 in
  let color typeAndNodeIdAndFeatures =
    if List.all (flip Set.member model.selectedFeatures) typeAndNodeIdAndFeatures
    then colorPointSelected
    else colorPointNotSelected
  in
  let
    xFeature = (ShapeWidgets.selectedTypeShapeFeature, id, xFeatureName)
    yFeature = (ShapeWidgets.selectedTypeShapeFeature, id, yFeatureName)
    (xColor, yColor) = (color [xFeature], color [yFeature])
  in
  let (backDisc, frontDisc) =
    let r =
      if Set.member thisCrosshair model.hoveredCrosshairs
        then toString len
        else "0"
    in
    let backDisc =
      svgCircle <|
        [ LangSvg.attr "r" r
        , LangSvg.attr "cx" (toString x) , LangSvg.attr "cy" (toString y)
        , LangSvg.attr "fill" "rgba(255,255,255,1.0)"
        ]
    in
    let frontDisc =
      svgCircle <|
        [ LangSvg.attr "r" r
        , LangSvg.attr "cx" (toString x) , LangSvg.attr "cy" (toString y)
        , LangSvg.attr "fill" "none"
        , LangSvg.attr "stroke" "black"
        , LangSvg.attr "stroke-width" pointZoneStyles.strokeWidth
        ]
    in
    (backDisc, frontDisc)
  in
  let xyDot =
    svgCircle <|
      [ LangSvg.attr "cx" (toString x) , LangSvg.attr "cy" (toString y)
      , LangSvg.attr "fill" <| -- "darkgray"
          if Set.member id model.selectedShapes
            then pointZoneStylesFillSelected model id
            else pointZoneStyles.fill.shown
      , LangSvg.attr "stroke" pointZoneStyles.stroke
      , LangSvg.attr "stroke-width" pointZoneStyles.strokeWidth
      , LangSvg.attr "r" <|
          if not (objectIsCurrentlyBeingManipulated model id)
             && (Set.member id model.selectedShapes ||
                 Set.member id model.hoveredShapes ||
                 Set.member thisCrosshair model.hoveredCrosshairs)
          then pointZoneStyles.radius
          else "0"
      , onMouseDown <| UpdateModel <| \model ->
          if Set.member thisCrosshair model.hoveredCrosshairs
            then toggleSelectedLambda [xFeature, yFeature] model
            else { model | hoveredCrosshairs = Set.insert thisCrosshair model.hoveredCrosshairs }
      ]
  in
  let yLine =
    svgLine [
        LangSvg.attr "stroke" yColor
      , LangSvg.attr "stroke-width" <|
          if Set.member thisCrosshair model.hoveredCrosshairs ||
             Set.member yFeature model.selectedFeatures
          then hairStrokeWidth
          else "0"
      , LangSvg.attr "x1" (toString (x-len)) , LangSvg.attr "y1" (toString y)
      , LangSvg.attr "x2" (toString (x+len)) , LangSvg.attr "y2" (toString y)
      , onMouseDown (toggleSelected [yFeature])
      ]
  in
  let xLine =
    svgLine [
        LangSvg.attr "stroke" xColor
      , LangSvg.attr "stroke-width" <|
          if Set.member thisCrosshair model.hoveredCrosshairs ||
             Set.member xFeature model.selectedFeatures
          then hairStrokeWidth
          else "0"
      , LangSvg.attr "y1" (toString (y-len)) , LangSvg.attr "x1" (toString x)
      , LangSvg.attr "y2" (toString (y+len)) , LangSvg.attr "x2" (toString x)
      , onMouseDown (toggleSelected [xFeature])
      ]
  in
  -- using nested group for onMouseLeave handler
  Utils.singleton <| Svg.g
    [onMouseLeave (removeHoveredCrosshair thisCrosshair)]
    [backDisc, xLine, yLine, frontDisc, xyDot]

maybeZoneSelectLine sideLength model nodeId kind featureNum pt1 pt2 =
  if sideLength < minLengthForMiddleZones then []
  else zoneSelectLine model nodeId kind featureNum pt1 pt2

zoneSelectLine model nodeId kind featureNum pt1 pt2 =
  let typeAndNodeIdAndFeature =
    ( ShapeWidgets.selectedTypeShapeFeature
    , nodeId
    , ShapeWidgets.unparseFeatureNum (Just kind) featureNum ) in
  case model.mouseMode of
    MouseDragZone (Left _) _ -> []
    _ ->
     if Set.member nodeId model.hoveredShapes ||
        Set.member typeAndNodeIdAndFeature model.selectedFeatures
     then zoneSelectLine_ model typeAndNodeIdAndFeature pt1 pt2
     else []

zoneSelectLine_ model typeAndNodeIdAndFeature (x1,y1) (x2,y2) =
  let color =
    if Set.member typeAndNodeIdAndFeature model.selectedFeatures
    then colorLineSelected
    else colorLineNotSelected
  in
  let line =
    svgLine [
        LangSvg.attr "stroke" color
      , LangSvg.attr "stroke-width" hairStrokeWidth
      , LangSvg.attr "x1" (toString x1) , LangSvg.attr "y1" (toString y1)
      , LangSvg.attr "x2" (toString x2) , LangSvg.attr "y2" (toString y2)
      , onMouseDown (toggleSelected [typeAndNodeIdAndFeature])
      ]
  in
  [line]

boxySelectZones model id kind boxyNums =

  let drawPoint maybeThreshold feature x y =
    case maybeThreshold of
      Just thresh -> maybeZoneSelectCrossDot thresh model (id, kind, feature) x y
      Nothing     -> zoneSelectCrossDot model (id, kind, feature) x y in

  let drawLine threshold feature pt1 pt2 =
    maybeZoneSelectLine threshold model id kind feature pt1 pt2 in

  let {left, top, right, bot, cx, cy, width, height} = boxyNums in

  let distanceZone f =
    case f of
      DistanceFeature Width   -> drawLine height (D Width) (left,cy) (right,cy)
      DistanceFeature Height  -> drawLine width (D Height) (cx,top) (cx,bot)

      DistanceFeature Radius  -> drawLine width (D Radius) (cx,cy) (right,cy)
      DistanceFeature RadiusX -> drawLine height (D RadiusX) (cx,cy) (right,cy)
      DistanceFeature RadiusY -> drawLine width (D RadiusY) (cx,top) (cx,cy)

      _ -> [] in

  let pointZone f =
    case f of
      PointFeature TopLeft  -> drawPoint Nothing TopLeft left top
      PointFeature TopRight -> drawPoint Nothing TopRight right top
      PointFeature BotLeft  -> drawPoint Nothing BotLeft left bot
      PointFeature BotRight -> drawPoint Nothing BotRight right bot

      PointFeature TopEdge   -> drawPoint (Just width) TopEdge cx top
      PointFeature BotEdge   -> drawPoint (Just width) BotEdge cx bot
      PointFeature LeftEdge  -> drawPoint (Just height) LeftEdge left cy
      PointFeature RightEdge -> drawPoint (Just height) RightEdge right cy
      PointFeature Center    -> drawPoint (Just (min width height)) Center cx cy

      _ -> [] in

  let features = Utils.find "boxySelectZones" ShapeWidgets.simpleKindFeatures kind in
  List.concatMap distanceZone features ++ List.concatMap pointZone features
    -- draw distance zones below point zones


--------------------------------------------------------------------------------
-- Select Blob Zones

{-

zoneBlobStrokeWidth  = 8
zoneBlobPadding      = 10
roundBounds          = True

zoneBlobEdges model blobId nodeId lineEndpoints transparency =
  let stroke =
    if Dict.member blobId model.selectedBlobs
      then "rgba(3,192,60," ++ transparency ++ ")" -- then "#03C03C"
      else "rgba(255,255,0," ++ transparency ++ ")" in
  let edge (pt1,pt2) =
    svgLine
       [ LangSvg.attr "stroke" stroke
       , LangSvg.attr "stroke-width" (toString zoneBlobStrokeWidth)
       , LangSvg.attr "fill" "rgba(0,0,0,0)"
       , cursorStyle "pointer"
       , onMouseDown (toggleSelectedBlob blobId nodeId)
       , attrNum "x1" (fst pt1), attrNum "y1" (snd pt1)
       , attrNum "x2" (fst pt2), attrNum "y2" (snd pt2)
       ]
  in
  List.map edge lineEndpoints

zoneBlobBox model blobId nodeId (a,b,c,d) =
  -- TODO
  if True then []
  else
    let (left, top, right, bot) = (fst a, fst b, fst c, fst d) in
    let (x1,y1) = (left  - zoneBlobPadding, top - zoneBlobPadding) in
    let (x2,y2) = (right + zoneBlobPadding, bot + zoneBlobPadding) in
    let fourCorners = [(x1,y1), (x2,y1), (x2,y2), (x1,y2)] in
    let lineEndpoints = Utils.adjacentPairs True fourCorners in
    zoneBlobEdges model blobId nodeId lineEndpoints "1.0"

zoneBlobLine model blobId nodeId (x1,_) (x2,_) (y1,_) (y2,_) =
  -- TODO
  if True then []
  else
    let pct = 0.25 in
    let (width, height) = (x2 - x1, y2 - y1) in
    let (dx, dy) = (pct * width, pct * height) in
    let lineEndpoints = [ ((x1 + dx, y1 + dy), (x2 - dx, y2 - dy)) ] in
    zoneBlobEdges model blobId nodeId lineEndpoints "0.7"

toggleSelectedBlob blobId nodeId =
  UpdateModel <| \model ->
    { model | selectedBlobs = Utils.toggleDict (blobId, nodeId) model.selectedBlobs }

-}


--------------------------------------------------------------------------------

-- TODO significantly refactor point selection zones, by using
-- ShapeWidgets.featuresOfShape, BoxyFeatureEquations, eval FeatureEquation, etc.

makeZones : Model -> String -> LangSvg.NodeId -> List LangSvg.Attr -> List Svg.Svg
makeZones model shape id l =
  case shape of
    "line"     -> makeZonesLine model id l
    "rect"     -> makeZonesRectOrBox model id shape l
    "BOX"      -> makeZonesRectOrBox model id shape l
    "circle"   -> makeZonesCircle model id l
    "ellipse"  -> makeZonesEllipseOrOval model id shape l
    "OVAL"     -> makeZonesEllipseOrOval model id shape l
    "polygon"  -> makeZonesPoly model shape id l
    "polyline" -> makeZonesPoly model shape id l
    "path"     -> makeZonesPath model shape id l
    -- "g"        -> makeZonesGroup model id l
    _          -> []

makeZonesLine model id l =
  let transform = maybeTransformAttr l in
  let (x1,y1,x2,y2,cx,cy) = ShapeWidgets.evaluateLineFeatures id l in
  let (pt1,pt2) = ((x1,y1), (x2,y2)) in
  let bounds =
    let (xMin,xMax) = minMax x1 x2 in
    let (yMin,yMax) = minMax y1 y2 in
    (xMin, yMin, xMax, yMax) in
  let zLine =
    let enter = [ onMouseEnter (addHoveredShape id) ] in
    zoneLine2 model id "line" "Edge" pt1 pt2 (transform ++ enter)
  in
  let zonesSelect =
    List.concat
       [ maybeZoneSelectCrossDot (distance pt1 pt2) model (id, "line", Center) cx cy
       , zoneSelectCrossDot model (id, "line", Point 1) x1 y1
       , zoneSelectCrossDot model (id, "line", Point 2) x2 y2 ]
  in
  let primaryWidgets =
    boundingBoxZones model id bounds <|
      [zLine] ++
      zonesSelect ++
      zonePoints2 model id "line" transform [pt1, pt2]
  in
  let extraWidgets =
    let c = halfwayBetween pt1 pt2 in
    let r = (distance pt1 pt2 / 2) - rotZoneDelta in
    zoneRotate model id "line" (cx, cy) r (maybeTransformCmds l) ++
    zonesStroke model id "line" x2 y2 l
  in
  primaryWidgets :: extraWidgets

makeZonesRectOrBox model id shape l =
  let boxyNums = ShapeWidgets.evaluateBoxyNums id shape l in
  let {left, top, right, bot, cx, cy, width, height} = boxyNums in
  let bounds = (left, top, right, bot) in
  let transform = maybeTransformAttr l in
  let zoneInterior =
    draggableZone Svg.rect False model id shape "Interior" <|
      [ attrNum "x" left , attrNum "y" top
      , attrNum "width" width , attrNum "height" height
      , onMouseEnter (addHoveredShape id)
      ] ++ transform
  in
  let zonesSelect = boxySelectZones model id shape boxyNums in
  let primaryWidgets =
    boundingBoxZones model id bounds <|
      [zoneInterior] ++
      zonesSelect ++
      eightCardinalZones model id shape transform bounds
  in
  let extraWidgets =
    let r = rotZoneDelta + (height/2) in
    zoneRotate model id shape (cx,cy) r (maybeTransformCmds l) ++
    zonesFillAndStroke model id shape left top l
  in
  primaryWidgets :: extraWidgets

makeZonesCircle model id l =
  let boxyNums = ShapeWidgets.evaluateBoxyNums id "circle" l in
  let {left, top, right, bot, cx, cy, r} = boxyNums in
  let bounds = (left, top, right, bot) in
  let transform = maybeTransformAttr l in
  let zoneInterior =
    draggableZone Svg.circle False model id "circle" "Interior" <|
      [ attrNum "cx" cx, attrNum "cy" cy, attrNum "r" r
      , onMouseEnter (addHoveredShape id)
      ] ++ transform
  in
  let zonesSelect = boxySelectZones model id "circle" boxyNums in
  let primaryWidgets =
     boundingBoxZones model id bounds <|
       [zoneInterior] ++
       zonesSelect ++
       eightCardinalZones model id "circle" transform bounds
  in
  let extraWidgets =
    zoneRotate model id "circle" (cx,cy) (r + rotZoneDelta) (maybeTransformCmds l) ++
    zonesFillAndStroke model id "circle" (cx - r) (cy - r) l
  in
  primaryWidgets :: extraWidgets

makeZonesEllipseOrOval model id shape l =
  let boxyNums = ShapeWidgets.evaluateBoxyNums id shape l in
  let {left, top, right, bot, width, height, cx, cy, rx, ry} = boxyNums in
  let bounds = (left, top, right, bot) in
  let transform = maybeTransformAttr l in
  let zoneInterior =
    draggableZone Svg.ellipse False model id shape "Interior" <|
      [ attrNum "cx" cx, attrNum "cy" cy, attrNum "rx" rx, attrNum "ry" ry
      , onMouseEnter (addHoveredShape id)
      ] ++ transform
  in
  let zonesSelect = boxySelectZones model id shape boxyNums in
  let primaryWidgets =
     boundingBoxZones model id bounds <|
       [zoneInterior] ++
       zonesSelect ++
       eightCardinalZones model id shape transform bounds
  in
  let extraWidgets =
    zoneRotate model id shape (cx,cy) (ry + rotZoneDelta) (maybeTransformCmds l) ++
    zonesFillAndStroke model id shape (cx - rx) (cy - ry) l
  in
  primaryWidgets :: extraWidgets

makeZonesPoly model shape id l =
  let _ = Utils.assert "makeZonesPoly" (shape == "polygon" || shape == "polyline") in
  let transform = maybeTransformAttr l in
  let pts = LangSvg.getPolyPoints l in
  let zPts = zonePoints model id shape transform pts in
  let zLines =
    let pairs = Utils.adjacentPairs (shape == "polygon") pts in
    let f (i,(pti,ptj)) = zoneLine model id shape ("Edge" ++ toString i) pti ptj transform in
    Utils.mapi f pairs in
  let zInterior =
    draggableZone Svg.polygon False model id shape "Interior" <|
      [ LangSvg.compileAttr "points" (LangSvg.aPoints pts)
      , onMouseEnter (addHoveredShape id)
      ] ++ transform
  in
{-
  let zInterior =
    if shape == "polygon" || (shape == "polyline" && firstEqLast pts)
    then [ zoneBorder Svg.polygon model id shape "Interior" False transform <|
             [ LangSvg.compileAttr "points" (LangSvg.aPoints pts)
             , onMouseEnter (addHoveredShape id)
             ]
         ]
    else []
  in
-}
  let zRot = zoneRotatePolyOrPath model id "polygon" pts l in
  let zFillAndStroke =
    case pts of
      (((x0,_),(y0,_))::_) ->
        zonesFillAndStroke model id shape x0 y0 l
      _ ->
        Debug.crash "makeZonesPoly" in
  let zSelect =
    let midptCrossDot ((i1, ((xi1,_),(yi1,_))), (i2, ((xi2,_),(yi2,_)))) =
      let (xAttr1, yAttr1) = ("x" ++ toString i1, "y" ++ toString i1) in
      let (xAttr2, yAttr2) = ("x" ++ toString i2, "y" ++ toString i2) in
      zoneSelectCrossDot model (id, shape, Midpoint i1) (xi1/2+xi2/2) (yi1/2+yi2/2)
    in
    let ptCrossDot (i, ((xi,_),(yi,_))) =
      let (xAttr, yAttr) = ("x" ++ toString i, "y" ++ toString i) in
      zoneSelectCrossDot model (id, shape, Point i) xi yi
    in
    let midptCrossDots =
      let ptsI = Utils.mapi identity pts in
      let ptsIPairs = Utils.selfZipCircConsecPairs ptsI in
      List.concatMap midptCrossDot ptsIPairs
    in
    let crossDots = List.concat <| Utils.mapi ptCrossDot pts in
    midptCrossDots ++ crossDots
  in
  let primaryWidgets =
    let (x1,x2,y1,y2) = Draw.boundingBoxOfPoints_ (List.map (\(x,y) -> (fst x, fst y)) pts) in
    boundingBoxZones model id (x1,y1,x2,y2) <|
      [zInterior] ++ zLines ++ zSelect ++ zPts
  in
  primaryWidgets :: zRot ++ zFillAndStroke

firstEqLast xs = Utils.head_ xs == Utils.head_ (List.reverse xs)

makeZonesPath : Model -> String -> Int -> List LangSvg.Attr -> List Svg.Svg
makeZonesPath model shape id nodeAttrs =
  let _ = Utils.assert "makeZonesPoly" (shape == "path") in
  let transform = maybeTransformAttr nodeAttrs in
  let cmds = fst <| LangSvg.toPath <| Utils.find_ nodeAttrs "d" in
  let (+++) (mi,pt) acc = case mi of Nothing -> acc
                                     _       -> (mi,pt) :: acc in
  let listOfMaybeIndexWithPt =
    List.foldr (\c acc -> case c of
      LangSvg.CmdZ   s              -> acc
      LangSvg.CmdMLT s pt           -> pt +++ acc
      LangSvg.CmdHV  s n            -> acc
      LangSvg.CmdC   s pt1 pt2 pt3  -> pt1 +++ (pt2 +++ (pt3 +++ acc))
      LangSvg.CmdSQ  s pt1 pt2      -> pt1 +++ (pt2 +++ acc)
      LangSvg.CmdA   s a b c d e pt -> pt +++ acc) [] cmds
  in
  let pts = List.map snd listOfMaybeIndexWithPt in
  let dots = zonePoints model id shape transform pts in
  let zRot = zoneRotatePolyOrPath model id "path" pts nodeAttrs in
  let zFillAndStroke =
    case pts of
      (((x0,_),(y0,_))::_) ->
        zonesFillAndStroke model id shape x0 y0 nodeAttrs
      _ ->
        Debug.crash "makeZonesPath"
  in
  let zSelect =
    let ptCrossDot (maybeIndex, ((xi,_),(yi,_))) =
      let i = Utils.fromJust maybeIndex in
      let (xAttr, yAttr) = ("x" ++ toString i, "y" ++ toString i) in
      zoneSelectCrossDot model (id, shape, Point i) xi yi
    in
    let crossDots = List.concatMap ptCrossDot listOfMaybeIndexWithPt in
    crossDots
  in
  let zInterior =
    draggableZone Svg.path False model id shape "Interior" <|
      [ LangSvg.compileAttr "d" (Utils.find_ nodeAttrs "d")
      , onMouseEnter (addHoveredShape id)
      ] ++ transform
  in
  -- TODO add "Edge" zones
  let primaryWidgets =
    let (x1,x2,y1,y2) = Draw.boundingBoxOfPoints_ (List.map (\(x,y) -> (fst x, fst y)) pts) in
    boundingBoxZones model id (x1,y1,x2,y2) <|
      [zInterior] ++
      zSelect ++
      dots
  in
  primaryWidgets :: zRot ++ zFillAndStroke

{-
makeZonesGroup model nodeId l =
  case (maybeFindBounds l, maybeFindBlobId l) of
    (Just bounds, Just blobId) -> [] -- TODO zoneBlobBox model blobId nodeId bounds
    _                          -> []
-}


--------------------------------------------------------------------------------
-- User Interface

strTitle = " sketch-n-sketch " ++ params.strVersion

colorDebug_ c1 c2 =
  if params.debugLayout
    then GE.color c1
    else GE.color c2

colorDebug c1 = colorDebug_ c1 interfaceColor

codeToShow model =
  case model.previewCode of
     Just string -> string
     Nothing     -> model.code

basicCodeBox : Int -> Int -> Model -> GE.Element
basicCodeBox w h model =
  basicCodeBox_ w h (codeToShow model)

basicCodeBox_ w h content =
  let innerPadding = 4
  in
    Html.toElement w h <|
      Html.textarea
        [ Attr.id "editor"
        , Attr.spellcheck False
        , Attr.style
            [ ("font-family", params.mainSection.codebox.font)
            , ("font-size", params.mainSection.codebox.fontSize)
            , ("border", params.mainSection.codebox.border)
            , ("whiteSpace", "pre")
            , ("height", "100%")
            , ("width", "100%")
            , ("resize", "none")
            , ("overflow", "auto")
            -- Horizontal Scrollbars in Chrome
            , ("word-wrap", "normal")
            , ("background-color", "whitesmoke")
            , ("padding", toString innerPadding ++ "px")
            -- Makes the 100% for width/height work as intended
            , ("box-sizing", "border-box")
            ]
        , Attr.value content
        ]
        []

-- Replaces the canvas if we are displaying an error
-- Is mostly a copy of the basic code box in the not manipulable mode
errorBox : Int -> Int -> String -> GE.Element
errorBox w h errormsg =
  Html.toElement w h <|
    Html.textarea
      [ Attr.spellcheck False
      , Attr.readonly True
      , Attr.style
        [ ("font-family", params.mainSection.codebox.font)
        , ("font-size", params.mainSection.codebox.fontSize)
        , ("border", params.mainSection.codebox.border)
        , ("whiteSpace", "pre")
        , ("height", "100%")
        , ("width", "100%")
        , ("resize", "none")
        , ("overflow", "auto")
        -- Horizontal Scrollbars in Chrome
        , ("word-wrap", "normal")
        , ("background-color", "whitesmoke")
        , ("padding", "4px")
        -- Makes the 100% for width/height work as intended
        , ("box-sizing", "border-box")
        ]
      , Attr.value <| "💥 " ++ errormsg
      ]
      []

canvas : Int -> Int -> Model -> GE.Element
canvas w h model =
  case model.mode of
    Print svgCode -> basicCodeBox_ w h svgCode
    _             -> canvas_ w h model

canvas_ w h model =
  let addZones = case model.mode of
    AdHoc  -> True
    Live _ -> model.tool == Cursor
    _      -> False
  in
  let mainCanvas_ = buildSvg (model, addZones) model.slate in
  let mainCanvas =
    case Draw.drawNewShape model of
      []       -> mkSvg addZones mainCanvas_
      drawings -> mkSvg addZones (Svg.g [] (mainCanvas_ :: drawings))
  in
  let makeWidgetsAndZones () =
    let widgets = buildSvgWidgets w h model in
    let svg = mkSvg addZones (Svg.g [] [mainCanvas, widgets]) in
    Html.toElement w h svg
  in
  case (model.mode, model.showGhosts) of
    (Live _, True ) -> makeWidgetsAndZones ()
    (SyncSelect possibleChanges, _) ->
      let possibleChangeStyle = [ ("width",  toString (w//3 - 32))
                                , ("height", toString (h//3 - 32))
                                , ("margin", "10px")
                                , ("background", "white")
                                , ("border", "solid 2px black")
                                , ("cursor", "pointer")
                                , ("text-align", "center")
                                ]
      in
      let
        animatePossibleChange (exp, val, slate, code) =
          let decimalPart a = a - (toFloat <| truncate a) in
          let nToRand n = -- Semi-random function mapping integers to [0.0, 1.0)
            let f = toFloat n in
            decimalPart ((1.0 + f*f*f*f) * e)
          in
          let animateNumber i x time =
            let baseSpeed = 0.4 in
            let frequency = baseSpeed * (0.25 + nToRand i) in
            let theta = time * frequency * 2.0 * pi in
            x * (1 + 0.2 * sin(theta))
          in
          let locIdsAndNumbers = LangTools.unfrozenLocIdsAndNumbers exp in
          let subst = Dict.fromList (Utils.mapi (\(i, (locId, x)) -> (locId, animateNumber i x model.syncSelectTime)) locIdsAndNumbers) in
          -- let _ = Debug.log (toString subst) subst in
          -- let _ = Debug.log (toString model.runAnimation) model.runAnimation in
          let newExp = applyLocSubst subst exp in
          let newVal =
            case Eval.run newExp of
              Ok (newVal, _) -> newVal
              Err s          -> val
          in
          case LangSvg.resolveToIndexedTree model.slideNumber model.movieNumber model.movieTime newVal of
            Ok slateToDraw -> (slateToDraw, (exp, val, slate, code))
            Err s          -> (slate,       (exp, val, slate, code))
      in
      let possibleChangeToSvg (slateToDraw, (exp, val, slate, code)) =
          let model' = model in
          Svg.svg [ Svg.Attributes.viewBox (String.join " " (List.map toString [0, 0, w, h]))
                  , Attr.style possibleChangeStyle
                  , Events.onClick events.address (SelectOption (exp, val, slate, code))
                  , Events.onMouseOver events.address (PreviewCode (Just code))
                  , Events.onMouseOut events.address (PreviewCode Nothing)
                  ]
                  [ buildSvg (model', False) slateToDraw ]
      in
      let cancelButton =
        Html.button [ Attr.style (possibleChangeStyle ++ [("font-size", "25px")])
                    , Events.onClick events.address CancelSync
                    ]
                    [Html.text "Cancel"]
      in
      GE.color (Color.grayscale 0.1)
        <| Html.toElement w h
        <| Html.div [ Attr.style [("overflow", "auto"), ("width", toString w), ("height", toString h)]
                    ]
        <| (List.map possibleChangeToSvg (List.map animatePossibleChange possibleChanges)) ++ [cancelButton]
    _ ->
      Html.toElement w h (mkSvg addZones mainCanvas)

mkSvg hilite svg =
  Svg.svg
     [ onMouseDown MouseClickCanvas
     , Attr.style [ ("width", "100%") , ("height", "100%")
                  , ("border", params.mainSection.canvas.border)
                  ] ]
     [ svg ]

flowRight : Int -> Int -> List (Float, Int -> Int -> GE.Element) -> GE.Element
flowRight w h l =
  let delta = 6 in
  let sep = GE.spacer delta h in
  let n = toFloat (List.length l) in
  let availableWidth = toFloat w - (n-1) * delta in
  let elts = List.map (\(pct, f) -> f (round (pct * availableWidth)) h) l in
  GE.flow GE.right (List.intersperse sep elts)

twoButtons w h b1 b2 = flowRight w h [(1/2, b1), (1/2, b2)]

threeButtons w h b1 b2 b3 = flowRight w h [(1/3, b1), (1/3, b2), (1/3, b3)]

widgetsExampleNavigation w h model =
  [ twoButtons w h (codeButton model) (canvasButton model)
  , dropdownExamples model w h
  , runButton model w h
{-
  , twoButtons w h (saveButton model) (saveAsButton model)
-}
  , loadButton model w h
  ]

widgetsUndoRedo w h model =
  [ twoButtons w h (undoButton model) (redoButton model)
  , cleanButton model w h
  ]

widgetsSlideNavigation w h model =
  [ gapWidget w h
  , twoButtons w h (previousSlideButton model) (nextSlideButton model)
  , twoButtons w h (previousMovieButton model) (nextMovieButton model)
  , slideNumber model w h
  ]

{-
widgetsTools w h model =
  [ twoButtons w h
      (toolModeButton Cursors model)
      (toolModeButton Shapes model)
  ]
  ++ widgetsCursorsOrShapes w h model

widgetsCursorsOrShapes w h model =
  let gap = gapWidget w h in
  case model.toolMode of
    -- for now. but better to remove the wrappers from middleWidgets.
    -- Cursors -> gap :: widgetsCursors w h model
    Cursors -> widgetsCursors w h model
    Shapes  -> gap :: widgetsShapes w h model
-}

threeVersions w h b1 b2 b3 =
  flowRight w h [(1/6, b1), (2/3, b2), (1/6, b3)]

showRawShapeTools = True

widgetsTools w h model =
  let noFeatures = Set.isEmpty model.selectedFeatures in
  let noBlobs = Dict.isEmpty model.selectedBlobs in
  let relateButton = simpleEventButton_ noFeatures in
  let groupButton = simpleEventButton_ (noBlobs || not noFeatures) in
  let groupButtonSelectedFeaturesOkay = simpleEventButton_ noBlobs in

  [ toolButton model Cursor w h ]

  ++

  (

  if False then
     [ flowRight w h
          [ (1/5, toolButton model (Rect Raw))
          , (1/5, toolButton model (Oval Raw))
          , (1/5, toolButton model (Poly Raw))
          , (2/5, toolButton model (Path Raw))
          ]
     ]

  else if showRawShapeTools then -- v0.5.2

    [ twoButtons w h
        (toolButton model (Line Raw))
        (toolButton model Text)
    ]
    ++
    List.map (\tool ->
      flowRight w h
        [ (0.70, toolButton model (tool Raw))
        , (0.30, toolButton model (tool Stretchy))
        ]
    ) [Rect, Oval, Poly, Path]
    ++
    [ flowRight w h
        [ (1/4, toolButton model Lambda)
        , (3/4, dropdownLambdaTool model)
        ]
    ]

  else -- v0.5.1

  [ twoButtons w h
      (toolButton model (Line Raw))
      (toolButton model (Rect Stretchy))
  , twoButtons w h
      (toolButton model (Oval Stretchy))
      (toolButton model (Path Stretchy))
  , flowRight w h
       [ (1/2, toolButton model (Poly Stretchy))
       , (1/2, toolButton model Text)
       ]
  , flowRight w h
       [ (1/4, toolButton model Lambda)
       , (3/4, dropdownLambdaTool model)
       ]
  ]

  ) ++

  [ gapWidget w h
{-
  , relateButton DigHole "Dig Hole" w h
  , relateButton MakeEqual "Make Equal" w h
-}
  , twoButtons w h
      (relateButton DigHole "Dig")
      (relateButton MakeEqual "A = B")
{-
  , gapWidget w h
-}
  , twoButtons w h
      (groupButton DuplicateBlobs "Dupe")
      (groupButton MergeBlobs "Merge")
  , twoButtons w h
      (groupButtonSelectedFeaturesOkay GroupBlobs "Group")
      (groupButton AbstractBlobs "Abs")
  , groupButton (ReplicateBlob HorizontalRepeat) "Repeat Right" w h
  , groupButton (ReplicateBlob LinearRepeat) "Repeat To" w h
  , groupButton (ReplicateBlob RadialRepeat) "Repeat Around" w h
  ]

middleWidgets row1 row2 w h wWrap hWrap model =

  let exampleNavigation = widgetsExampleNavigation w h model in
  let undoRedo = widgetsUndoRedo w h model in
  let tools = widgetsTools w h model in
  let slideNavigation = widgetsSlideNavigation w h model in

  let l1  = if row1 then exampleNavigation ++ undoRedo else [] in
  let l2_ = if row2 then tools else [] in

  let l2 =
    if row1 && row2
      then gapWidget w h :: l2_  -- vertical   (row1 == row2 == True)
      else l2_ in                -- horizontal (row1 XOR row2)

  List.map (GE.container wWrap hWrap GE.middle) <|
    case (model.mode, unwrapVList model.inputVal) of
      (SyncSelect _, _) -> []
      (Print _, _) -> l1
      (_, Just [VConst (slideCount, _), _]) ->
        l1 ++
        (if row1 then slideNavigation else []) ++
        l2
      _ -> l1 ++ l2

      -- modeButton and syncButton...

gapWidget w h = GE.spacer w h

{-
syncButton_ w h model =
  case (model.mode, model.showZones == showZonesSelect) of
    (AdHoc, False) -> [syncButton w h]
    (Live _, True) -> [relateButton w h]
    _              -> []
-}
{-
  case model.mode of
    AdHoc -> [syncButton w h]
    _     -> []
-}

wBtn = params.mainSection.widgets.wBtn
hBtn = params.mainSection.widgets.hBtn

wBtnWide = params.mainSection.widgets.wBtnWide

buttonAttrs w h =
  Attr.style
    [ ("width", dimToPix w)
    , ("height", dimToPix h)
    , ("font-family", params.mainSection.widgets.font)
    , ("font-size", params.mainSection.widgets.fontSize)
    ]

gutterForResizing orient w h =
  let s = if orient == Vertical then "ew-resize" else "ns-resize" in
  colorDebug Color.darkBlue <|
    Html.toElement w h <|
      Html.div
          [ Events.onMouseDown events.address StartResizingMid
          , Attr.style
              [ ("width", dimToPix w) , ("height", dimToPix h)
              , ("cursor", s) ]
          ]
          [ ]

-- Makes a div appropriate for the Ace code editor to be inserted into
-- Flashing of the code editor is caused because of the 'Element' abstraction
-- torching the interior of the fancyCodeBox portion of the screen and necessitates a
-- re-embedding of the editor on the Ace side of things, the delay of which
-- (needs to be sent through a port and such) makes it flash.
fancyCodeBox : Int -> Int -> GE.Element
fancyCodeBox w h = Html.toElement w h <|
    Html.Lazy.lazy (\a -> Html.div [ Attr.id "editor"
             , Attr.style
                 [ ("width", "100%") -- The toElement makes a wrapping Div that
                                     -- has the appropriate w/h
                 , ("height", "100%")
                 , ("pointer-events", "auto")
                 , ("z-index", "1")
                 ]
             ] []) True -- No need to rerender on size changes

mainSectionVertical : Int -> Int -> Model -> GE.Element
mainSectionVertical w h model =
  let
    wGut    = params.mainSection.vertical.wGut
    wMiddle = wBtn
    wCode_  = (w - wMiddle - wGut - wGut) // 2
{-
    wCode   = wCode_ + model.midOffsetX
    wCanvas = wCode_ - model.midOffsetX
-}
    wCode   = if model.hideCode then 0
              else if model.hideCanvas then (w - wMiddle - wGut - wGut)
              else wCode_ + model.midOffsetX
    wCanvas = w - wMiddle - wGut - wGut - wCode
    hCanvas = h - hZInfo
    hZInfo  = params.mainSection.canvas.hZoneInfo
    hWidget = params.mainSection.widgets.hBtn
                + params.mainSection.vertical.hExtra
    wExtra  = params.mainSection.horizontal.wExtra
  in

  let codeSection = if model.basicCodeBox
                       then basicCodeBox wCode h model
                       else fancyCodeBox wCode h in

  let canvasSection = case model.errorBox of
    Nothing ->
      GE.size wCanvas h <|
        GE.flow GE.down
          [ canvas wCanvas hCanvas model
          , GE.flow GE.left
              [ colorDebug Color.red <|
                  GE.container wBtn (hZInfo+1) GE.middle <|
                  outputButton model wBtn hBtn
              , colorDebug Color.orange <| GE.spacer wExtra (hZInfo+1)
              , colorDebug Color.green <|
                  GE.container wBtnWide (hZInfo+1) GE.middle <|
                  ghostsButton model wBtnWide hBtn
              , caption model (wCanvas+1-(wBtn+wExtra+wBtnWide)) (hZInfo+1) -- NOTE: +1 is a band-aid
              ]
          ]
    Just errormsg -> errorBox wCanvas h errormsg
  in

  let gutter = gutterForResizing model.orient wGut h in

  let middleSection =
    colorDebug Color.lightBlue <|
      GE.size wMiddle h <|
        GE.flow GE.down <|
          middleWidgets True True wBtn hBtn wMiddle hWidget model in
  GE.flow GE.right <|
    [ codeSection, gutter, middleSection, gutter, canvasSection ]

mainSectionHorizontal : Int -> Int -> Model -> GE.Element
mainSectionHorizontal w h model =
  let
    wGut    = params.mainSection.vertical.wGut
    hGut    = params.mainSection.horizontal.hGut
    wTools  = wBtn + wGut
    wRest   = w - wTools
    hCode_  = (h - hGut) // 2
    hCode   = hCode_ + model.midOffsetY
    hCanvas = hCode_ - model.midOffsetY - hZInfo
    hZInfo  = params.mainSection.canvas.hZoneInfo
    hWidget = params.mainSection.widgets.hBtn
                + params.mainSection.vertical.hExtra
    wExtra  = params.mainSection.horizontal.wExtra
  in

  let codeSection = if model.basicCodeBox
                       then basicCodeBox wRest hCode model
                       else fancyCodeBox wRest hCode in

  let canvasSection = case model.errorBox of
    Nothing ->
        GE.size wRest (hCanvas + hZInfo) <|
          GE.flow GE.down
            [ canvas wRest hCanvas model
            , GE.flow GE.left
                [ colorDebug Color.red <|
                    GE.container wBtn (hZInfo+1) GE.middle <|
                    outputButton model wBtn hBtn
                , colorDebug Color.orange <| GE.spacer wExtra (hZInfo+1)
                , colorDebug Color.green <|
                    GE.container wBtnWide (hZInfo+1) GE.middle <|
                    ghostsButton model wBtnWide hBtn
                , caption model (wRest-(wBtn+wExtra+wBtnWide)) (hZInfo+1) -- NOTE: +1 is a band-aid
                ]
            ]
    Just errormsg -> errorBox wRest (hCanvas + hZInfo) errormsg
  in

  let hGutter = gutterForResizing model.orient wRest hGut in
  let vGutter = colorDebug Color.darkBlue <| GE.spacer wGut h in

  -- let (middleSection1, middleSection2) =
  --   let foo row1 row2 =
  --     colorDebug Color.lightBlue <|
  --       GE.size w hMiddle <|
  --         GE.flow GE.right <|
  --           middleWidgets row1 row2 wBtn hBtn wWidget hMiddle model
  --   in
  --   (foo True False, foo False True) in
  let mainTools =
    colorDebug Color.lightBlue <|
      GE.size wBtn h <|
        GE.flow GE.down <|
          middleWidgets True True wBtn hBtn wBtn hWidget model
  in
  let codeAndOutput =
    GE.flow GE.down <|
      [ codeSection
      , hGutter
      , canvasSection
      ]
  in
  GE.flow GE.right <|
    [ mainTools, vGutter, codeAndOutput ]


simpleButton_
   : Signal.Address a -> ButtonKind -> a -> Bool -> a -> String
  -> Int -> Int -> GE.Element
simpleButton_ addy btnKind defaultMsg disabled msg text w h =
  if disabled then
      GI.customButton (Signal.message addy defaultMsg)
        (makeButton (btnKind, Disabled) w h text)
        (makeButton (btnKind, Disabled) w h text)
        (makeButton (btnKind, Disabled) w h text)
  else
      GI.customButton (Signal.message addy msg)
        (makeButton (btnKind, Raised) w h text)
        (makeButton (btnKind, Highlighted) w h text)
        (makeButton (btnKind, Depressed) w h text)

simpleEventButton_ = simpleButton_ events.address Regular Noop
simpleTaskButton_  = simpleButton_ taskMailbox.address Regular (Task.succeed ())

simpleButton = simpleEventButton_ False
simpleTaskButton = simpleTaskButton_ False

-- displayKey s = " " ++ Utils.parens s
displayKey s = " " ++ s

runButton model w h =
  let disabled = model.mode == AdHoc in
  simpleEventButton_ disabled WaitRun "Run Code" w h

outputButton model w h =
  let disabled = model.mode == AdHoc in
  let cap =
     case model.mode of
       Print _ -> "[Out] SVG"
       _       -> "[Out] Canvas"
  in
  simpleEventButton_ disabled ToggleOutput cap w h

ghostsButton model w h =
  let cap =
     case model.showGhosts of
       True  -> "[Ghosts] Shown"
       False -> "[Ghosts] Hidden"
  in
  let foo old =
    let showGhosts' = not old.showGhosts in
    let mode' =
      case old.mode of
        Print _ -> Print (LangSvg.printSvg showGhosts' old.slate)
        _       -> old.mode
    in
    { old | showGhosts = showGhosts', mode = mode' }
  in
  simpleEventButton_ False (UpdateModel foo) cap w h

luckyButton model =
  let foo old =
    let so = old.syncOptions in
    let so' = { so | feelingLucky = Sync.toggleHeuristicMode so.feelingLucky } in
    case old.mode of
      Live _ ->
        case mkLive_ so' old.slideNumber old.movieNumber old.movieTime old.inputExp of
          Ok m' -> { old | syncOptions = so', mode = m' }
          Err s -> { old | syncOptions = so', errorBox = Just s }
      _ -> { old | syncOptions = so' }
  in
  -- let yesno = if model.syncOptions.feelingLucky then "Yes" else "No" in
  -- simpleButton (UpdateModel foo) "Lucky" "Lucky" ("[Lucky?] " ++ yesno)
  let yesno =
    let hm = model.syncOptions.feelingLucky in
    if hm == Sync.heuristicsNone then "None"
    else if hm == Sync.heuristicsFair then "Fair"
    else "Biased"
  in
  simpleButton (UpdateModel foo) ("[Heuristics] " ++ yesno)

{-
frozenButton model =
  let cap = if model.syncOptions.thawedByDefault then "[Default] n?" else "[Default] n!" in
  simpleButton ToggleThawed "ToggleThawed " "Toggle ?/!" cap
-}

toolButton : Model -> Tool -> Int -> Int -> GE.Element
toolButton model tool w h =
  let capStretchy s = if showRawShapeTools then "BB" else s in
  let capSticky = Utils.uniPlusMinus in -- Utils.uniDelta in
  let capRaw = "(Raw)" in
  let cap = case tool of
    Cursor        -> "Cursor"
    Line Raw      -> "Line"
    Rect Raw      -> "Rect"
    Rect Stretchy -> capStretchy "Box"
    Oval Raw      -> "Ellipse"
    Oval Stretchy -> capStretchy "Oval"
    Poly Raw      -> "Polygon"
    Poly Stretchy -> capStretchy "Polygon"
    Poly Sticky   -> capSticky
    Path Raw      -> "Path"
    Path Stretchy -> capStretchy "Path"
    Path Sticky   -> capSticky
    Text          -> "Text"
    HelperLine    -> "(Rule)"
    HelperDot     -> "(Dot)"
    Lambda        -> Utils.uniLambda
    _             -> Debug.crash ("toolButton: " ++ toString tool)
  in
  let btnKind = if model.tool == tool then Selected else Unselected in
  -- TODO temporarily disabling a couple tools
  let (btnKind, disabled) =
    case tool of
      Path Sticky -> (Regular, True)
      _           -> (btnKind, False)
  in
  simpleButton_ events.address btnKind Noop disabled
    (UpdateModel (\m -> { m | tool = tool })) cap w h

saveButton : Model -> Int -> Int -> GE.Element
saveButton model w h =
    let cap = "Save" in
    let disabled = List.any ((==) model.exName << Utils.fst3) Examples.list in
    simpleEventButton_ disabled (InterfaceModel.WaitSave model.exName) cap w h
      -- dn dn Utils.uniSave w h

saveAsButton : Model -> Int -> Int -> GE.Element
saveAsButton model w h =
    let cap = "Clone" in
    simpleTaskButton (saveStateLocally model.exName True model) cap w h
      -- dn dn (Utils.uniCamera) w h

loadButton : Model -> Int -> Int -> GE.Element
loadButton model w h =
  let cap = "Revert" in
  simpleTaskButton (loadLocalState model model.exName) cap w h
    -- "Reload" "Reload" Utils.uniReload w h

undoButton : Model -> Int -> Int -> GE.Element
undoButton model =
  let past = fst model.history in
  simpleEventButton_ (List.length past <= 1) Undo "Undo" -- Utils.uniUndo

redoButton : Model -> Int -> Int -> GE.Element
redoButton model =
  let future = snd model.history in
  simpleEventButton_ (List.length future == 0) Redo "Redo" -- Utils.uniRedo

previousSlideButton : Model -> Int -> Int -> GE.Element
previousSlideButton model =
  simpleEventButton_ (model.slideNumber == 1 && model.movieNumber == 1) PreviousSlide "◀◀"

nextSlideButton : Model -> Int -> Int -> GE.Element
nextSlideButton model =
  simpleEventButton_ (model.slideNumber == model.slideCount && model.movieNumber == model.movieCount) NextSlide "▶▶"

previousMovieButton : Model -> Int -> Int -> GE.Element
previousMovieButton model =
  simpleEventButton_ (model.slideNumber == 1 && model.movieNumber == 1) PreviousMovie "◀"

nextMovieButton : Model -> Int -> Int -> GE.Element
nextMovieButton model =
  simpleEventButton_ (model.slideNumber == model.slideCount && model.movieNumber == model.movieCount) NextMovie "▶"

slideNumber : Model -> Int -> Int -> GE.Element
slideNumber model w h =
  let slideNumberElement = GE.centered << T.color Color.white << (T.typeface ["sans-serif"]) << T.fromString in
  GE.container w h GE.middle <|
    slideNumberElement ("Slide " ++ toString model.slideNumber ++ "/" ++ toString model.slideCount)

dropdownExamples : Model -> Int -> Int -> GE.Element
dropdownExamples model w h =
  let
    choices = case model.mode of
      AdHoc -> [(model.exName, Signal.send events.address Noop)]
      _ ->
        let foo (name,_,thunk) = (name, Signal.send events.address (SelectExample name thunk))
            bar saveName = (saveName, loadLocalState model saveName)
            blank = ("", Task.succeed ())
            localsaves = case model.localSaves of
                [] -> []
                l  ->
                  List.concat
                    [ [ ("Local Saves:", Task.succeed ())
                      , blank
                      ]
                    , List.map bar l
                    , [ blank ]
                    ]
        in List.concat
            [ localsaves
            , [ ("Builtin Examples:", Task.succeed ())
              , blank
              ]
            , (List.map foo Examples.list)
            , [ blank
              , ("*Clear Local Saves*", clearLocalSaves)
              ]
            ]
    options = List.map (\(name,task) ->
        if name == model.exName then
              Html.option
                [ Attr.value name
                , Attr.selected True
                ]
                [ Html.text name ]
        else
              Html.option
                [ Attr.value name
                ]
                [ Html.text name ]) choices
    findTask name choices = case choices of
        (n,t) :: rest -> if n == name
                           then t
                           else findTask name rest
        [] -> Debug.crash "Dropdown example does not have associated task"
  in Html.toElement 120 24 <| Html.select
        [ Attr.style
          [ ("pointer-events", "auto")
          , ("border", "0 solid")
          , ("display", "block")
          , ("width", "120px")
          , ("height", "24px")
          , ("font-family", params.mainSection.widgets.font)
          , ("font-size", "1em")
          ]
        , Events.on "change" Events.targetValue
                (\selected -> Signal.message taskMailbox.address <|
                                findTask selected choices)
        ] options

{-
modeButton model =
  if model.mode == AdHoc
  then simpleEventButton_ True Noop "SwitchMode" "SwitchMode" "[Mode] Ad Hoc"
  else simpleEventButton_ (model.newShapeKind /= Nothing)
         (SwitchMode AdHoc) "SwitchMode" "SwitchMode" "[Mode] Live"
-}

cleanButton model =
  let disabled = case model.mode of Live _ -> False
                                    _      -> True in
  simpleEventButton_ disabled WaitClean "Clean Up"

orientationButton w h model =
    let text = "[Orientation] " ++ toString model.orient
    in
      simpleButton SwitchOrient text w h

basicBoxButton w h model =
    let (text, evt) = case model.basicCodeBox of
          True  -> ("[Code Box] Basic", ToggleBasicCodeBox)
          False -> ("[Code Box] Fancy", WaitCodeBox)
    in
       simpleButton evt text w h

codeButton model w h =
  let (cap, btnKind) = case model.hideCode of
    True  -> ("Code", Unselected)
    False -> ("Code", Selected)
  in
  let foo model = { model | hideCode = not model.hideCode } in
  simpleButton_ events.address btnKind Noop
    model.hideCanvas (UpdateModel foo) cap w h

canvasButton model w h =
  let (cap, btnKind) = case model.hideCanvas of
    True  -> ("Canvas", Unselected)
    False -> ("Canvas", Selected)
  in
  let foo model = { model | hideCanvas = not model.hideCanvas } in
  simpleButton_ events.address btnKind Noop
    model.hideCode (UpdateModel foo) cap w h

strLambdaTool lambdaTool =
  let strExp = String.trim << unparse in
  case lambdaTool of
    LambdaBounds e -> "bounds. " ++ strExp e ++ " bounds"
    LambdaAnchor e -> "anchor. " ++ strExp e ++ " anchor"

dropdownLambdaTool : Model -> Int -> Int -> GE.Element
dropdownLambdaTool model w h =
  let options =
    let (selectedIdx, exps) = model.lambdaTools in
    Utils.mapi (\(i,lambdaTool) ->
      let s = strLambdaTool lambdaTool in
      Html.option
         [ Attr.value s, Attr.selected (i == selectedIdx) ]
         [ Html.text s ]
      ) exps
  in
  let handler selected =
    Signal.message events.address <| UpdateModel <| \model ->
      let (_, exps) = model.lambdaTools in
      let indexedStrings = Utils.mapi (\(i,lt) -> (i, strLambdaTool lt)) exps in
      let newSelectedIdx =
        case Utils.findFirst ((==) selected << snd) indexedStrings of
          Just (i, _) -> i
          Nothing     -> Debug.crash "dropdownLambdaTools"
      in
      { model | tool = Lambda, lambdaTools = (newSelectedIdx, exps) }
  in
  let attrs =
     -- refactor these attributes, and dropdownExamples
     [ Attr.style
        [ ("pointer-events", "auto")
        , ("border", "0 solid")
        , ("display", "block")
        , ("width", "80px")
        , ("height", "24px")
        , ("font-family", params.mainSection.widgets.font)
        , ("font-size", "1em")
        ]
     , Events.on "change" Events.targetValue handler
     ]
  in
  Html.toElement 80 24 (Html.select attrs options)


--------------------------------------------------------------------------------
-- Zone Caption and Highlights

caption : Model -> Int -> Int -> GE.Element
caption model w h =
  let eStr = GE.leftAligned << T.color Color.white << T.monospace << T.fromString in
  let tStr col = T.height 16 << T.color col << T.monospace << T.fromString in
  let tSpace = T.height 5 << T.color Color.white << T.monospace << T.fromString <| "\n" in
  colorDebug Color.orange <|
    GE.container w h GE.topLeft <|
      case (model.caption, model.mode, model.mouseMode) of

        (Just (Hovering zoneKey), Live info, MouseNothing) ->
          let (line1, line2, cap) =
            case Sync.hoverInfo zoneKey info of
              (line1, Nothing) ->
                (line1, "", T.bold <| tStr Color.red " (INACTIVE)")
              (line1, Just line2) ->
                (line1, line2, T.bold <| tStr Color.green " (ACTIVE)")
          in
          GE.leftAligned <| T.concat
             [ tSpace -- slop
             , tStr Color.white (" " ++ line1)
             , cap
             , tStr Color.white ("\n " ++ line2)
             ]

        (Just (LangError err), _, _) ->
          eStr err
        _ ->
          GE.empty

turnOnCaptionAndHighlights zoneKey =
  UpdateModel <| \m ->
    let codeBoxInfo = m.codeBoxInfo in
    let hi = liveInfoToHighlights zoneKey m in
    { m | caption = Just (Hovering zoneKey)
        , codeBoxInfo = { codeBoxInfo | highlights = hi } }

turnOffCaptionAndHighlights =
  UpdateModel <| \m ->
    let codeBoxInfo = m.codeBoxInfo in
    { m | caption = Nothing
        , codeBoxInfo = { codeBoxInfo | highlights = [] } }

--------------------------------------------------------------------------------

-- The pop-up save dialog box
-- TODO clean this up, is needlessly bulky
saveElement : Model -> Int -> Int -> GE.Element
saveElement model w h = case model.mode of
  SaveDialog x ->
      -- Note that dimBox must not be a parent of the pickBox, as
      -- opacity of a parent clobbers that of all its children
      let dimBox = GE.color Color.black
                      <| GE.opacity 0.5
                      <| GE.spacer w h
          pickBox = GE.container w h GE.middle
                      <| GE.color interfaceColor
                      <| GE.container 400 200 GE.middle
                      <| GE.flow GE.down
                           [ GE.flow GE.right
                              [ GE.spacer 42 18
                              , GE.centered <|
                                  T.style titleStyle
                                  (T.fromString "Save Work to Browser")
                              ]
                           , GE.spacer 160 10
                           , GE.flow GE.right
                              [ Html.toElement 200 40
                                  <| Html.input
                                      [ Attr.type' "text"
                                      , Attr.style
                                          [ ("height", "32px")
                                          , ("width", "192px")
                                          , ("padding", "4px")
                                          , ("border-width", "0px")
                                          , ("pointer-events", "auto")
                                          , ("box-shadow", "inset 0 0 10px 3px lightgray")
                                          ]
                                      , Attr.value model.fieldContents.value
                                      , Attr.placeholder
                                            model.fieldContents.hint
                                      , Attr.autofocus True
                                      , Events.on "input" Events.targetValue
                                          (\cont -> Signal.message events.address
                                            <| UpdateFieldContents
                                                { value = cont
                                                , hint =
                                                    model.fieldContents.hint
                                                }
                                          )
                                      ]
                                      []
                              , GE.spacer 10 40
                              , simpleTaskButton
                                  ( checkAndSave model.fieldContents.value
                                                 model
                                  )
                                  "Create Save" 100 40
                              ]
                           , GE.spacer 160 10
                           , GE.flow GE.right
                              [ GE.spacer 47 50
                              , GE.centered <|
                                  T.height 12 <|
                                  T.color Color.white <|
                                  (T.fromString <|
                                  "Note: This will overwrite saves with\n"
                                  ++ "the same name. You must choose a\n"
                                  ++ "name different than a built-in example.")
                              ]
                           , GE.spacer 160 10
                           , GE.flow GE.right
                               [ GE.spacer 112 30
                               , simpleButton
                                  (RemoveDialog False "")
                                  "Cancel" 75 30
                               ]
                           ]
      in GE.flow GE.outward [ dimBox, pickBox ]
  _ -> GE.empty


view : (Int, Int) -> Model -> GE.Element
view (w,h) model =
  let
    wAll = w - (2 * wGut) - 1
    wGut = params.wGut
    hTop = params.topSection.h
    hBot = params.botSection.h
    hMid = h - hTop - hBot - 1
    hTot = hTop + hMid + hBot
  in

  let topSection =
    let
      title = (\e -> GE.container (GE.widthOf e) hTop GE.middle e) <|
                GE.leftAligned <| T.style titleStyle (T.fromString strTitle)

      wLogo = params.topSection.wLogo
      logo  = GE.image wLogo wLogo (imgPath "light_logo.svg")

      wBtnO = params.topSection.wBtnO
      hBtnO = params.topSection.hBtnO
      wJunk = params.topSection.wJunk
      wSpcB = params.mainSection.horizontal.wExtra

      -- wSep  = GE.spacer (wAll - (wLogo + 2 * wBtnO + wJunk + wSpcB)) 1
      wSep  = GE.spacer (wAll - (wLogo + 2 * wBtnO + wJunk + wSpcB)) 1
      btnO  = (\e -> GE.container (GE.widthOf e) hTop GE.middle e) <|
                orientationButton wBtnO hBtnO model

      {- not displaying Codebox button for now
      spcB  = GE.spacer wSpcB hTop
      btnB  = (\e -> GE.container (GE.widthOf e) hTop GE.middle e) <|
                basicBoxButton wBtnO hBtnO model
      -}

      spcH  = GE.spacer wSpcB hTop
      btnH  = (\e -> GE.container (GE.widthOf e) hTop GE.middle e) <|
                luckyButton model wBtnO hBtnO
    in
      GE.size wAll hTop <|
        GE.flow GE.right
          [ GE.container wLogo hTop GE.middle logo
          , GE.container (wAll - wLogo) hTop GE.middle <|
              -- GE.flow GE.right [ title, wSep, btnB, spcB, btnO ]
              GE.flow GE.right [ title, wSep, btnH, spcH, btnO ]
          ]
  in

  let midSection =
    GE.size wAll hMid <|
      case model.orient of
        Vertical   -> mainSectionVertical wAll hMid model
        Horizontal -> mainSectionHorizontal wAll hMid model in

  let botSection = GE.spacer wAll hBot in
  let sideGutter = colorDebug Color.black <| GE.spacer wGut hTot in

  let basicUI =
    GE.flow GE.right
       [ sideGutter
       , GE.flow GE.down
           [ colorDebug Color.lightYellow <| topSection
           , midSection
           , colorDebug Color.lightYellow <| botSection
           ]
       , sideGutter
       ]
  in

  -- Runs a task at startup by making the whole window hoverable briefly, which
  -- fires the task to the taskMailbox basically right away (the user's mouse is
  -- presumably over the window). Note that it is important to add the event
  -- handler to a dummy object that is removed, as adding it to the whole body
  -- results in nothing being clickable after the load is successful.
  case (model.startup, model.mode) of
    (True, _) ->
      let foo _ =
        Signal.message taskMailbox.address <|
          -- Insert more tasks to run at startup here
          getLocalSaves `andThen` \_ ->

          ---
          Signal.send
            events.address
            (UpdateModel (\m -> { m | startup = False}))
      in
      GE.flow GE.inward
        [ GI.hoverable foo <| GE.spacer w h
        , basicUI
        ]
    (False, SaveDialog m) ->
      GE.flow GE.inward
        [ saveElement model w h
        , basicUI
        ]
    _ ->
      basicUI

-- TODO: add onMouseUp DeselectObject event to all GE.Elements...

------------------------------------------------------------------------------
