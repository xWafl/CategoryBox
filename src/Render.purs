module CategoryBox.Render where

import Prelude

import CategoryBox.Data.Main (composeMorphisms, createFunctor, createMorphism, emptyCategory)
import CategoryBox.Data.Types (Category, Object(..), World)
import CategoryBox.Foreign.ForeignAction (ForeignAction(..))
import CategoryBox.Foreign.Render (Context2d, GeomMouseEventHandler, GeomWheelEventHandler, GeometryCache, createForeignMorphism, createForeignObject, emptyGeometryCache, getContext, handleMouseDown, handleMouseMove, handleMouseUp, handleScroll, renderCanvas, startDragging, startMorphism, stopDragging)
import CategoryBox.Helpers.CantorPairing (invertCantorPairing)
import Concur.Core (Widget)
import Concur.Core.Props (filterProp)
import Concur.React (HTML)
import Concur.React.DOM as D
import Concur.React.Props (ReactProps, onMouseDown, onMouseMove, onMouseUp, onWheel)
import Concur.React.Props as P
import Concur.React.Run (runWidgetInDom)
import Control.Alt ((<|>))
import Control.Apply (lift4)
import Data.Argonaut (decodeJson, encodeJson, parseJson)
import Data.Argonaut.Core (stringify)
import Data.Array (elemIndex, length, mapWithIndex, singleton, snoc, updateAt, (!!), (:))
import Data.Bifunctor (bimap)
import Data.Bitraversable (bisequence)
import Data.Either (hush)
import Data.Maybe (Maybe(..), fromMaybe, maybe)
import Data.Traversable (sequence)
import Data.Tuple (Tuple(..), snd, uncurry)
import Effect (Effect)
import Effect.Class (liftEffect)
import Effect.Console (log)
import Effect.Unsafe (unsafePerformEffect)
import React.Ref (NativeNode, Ref)
import React.Ref as Ref
import React.SyntheticEvent (SyntheticKeyboardEvent, SyntheticMouseEvent, SyntheticWheelEvent)
import Unsafe.Coerce (unsafeCoerce)
import Web.HTML (window)
import Web.HTML.Location (reload)
import Web.HTML.Window (innerHeight, innerWidth, localStorage, location)
import Web.Storage.Storage (clear, getItem, setItem)

-- | Ways we can update the GeometryState.
data UpdateAction
  = UpdateCreateObject Int Int String
  | UpdateCreateMorphism Int Int String
  | UpdateCreateCategory String
  | UpdateComposeMorphisms Int Int String
  | UpdateCreateFunctor Int Int String Boolean
  | NoUpdate

-- | State that contains all the geometry caches.
type GeometryState =
  { context :: Maybe Context2d
  , geometryCaches :: Array GeometryCache
  , mainGeometryCache :: GeometryCache
  , currentCategory :: Int
  }

-- | Actions that the user can execute via the DOM.
data Action = 
  Render
  | HandleMouseEvent GeomMouseEventHandler SyntheticMouseEvent
  | HandleWheelEvent GeomWheelEventHandler SyntheticWheelEvent
  | AddCategoryPress String
  | SwitchCategoryTo Int
  | ClearStorageData

-- | Tuple of World and GeometryState, wrapped in something and used after handling a typescript event.
data HandleActionOutput
  = NewState (Tuple World GeometryState)
  | RaiseComponent (Widget HTML (Tuple World GeometryState))
  | ReplaceCategory (Tuple World GeometryState)
  | NoActionOutput

storeUniverse :: World -> GeometryState -> Effect Unit
storeUniverse world state = do
  w <- window
  s <- localStorage w
  setItem "universe" (stringify $ encodeJson { world, state }) s

getLocalStorageUniverse :: Effect (Tuple World GeometryState)
getLocalStorageUniverse = bisequence $ Tuple world state
  where
    stored :: Effect (Maybe String)
    stored = do
      w <- window
      s <- localStorage w
      getItem "universe" s
    parsed :: Effect (Maybe { world :: World, state :: GeometryState })
    parsed = stored <#> (_ >>= hush <<< (parseJson >=> decodeJson))
    world :: Effect World
    world = maybe defaultWorld (_.world) <$> parsed
    state :: Effect GeometryState
    state = maybe defaultState (_.state) <$> parsed
    functorCategory :: GeometryCache
    functorCategory = createForeignObject (unsafePerformEffect emptyGeometryCache) 0 0 "Category 1"
    defaultWorld :: World
    defaultWorld = { categories: []
                   , functorCategory: emptyCategory { objects = [ Object "Category 1" ] }
                   , functors: []
                   , name: "My world" 
                   }
    defaultState :: GeometryState
    defaultState = { context: Nothing
                   , geometryCaches: [unsafePerformEffect emptyGeometryCache]
                   , mainGeometryCache: functorCategory
                   , currentCategory: 0 
                   }

-- | Update the World and the GeometryState.
updateStateCache :: World -> GeometryState -> UpdateAction -> Tuple World GeometryState
updateStateCache world geom action = case action of
  UpdateCreateObject posX posY name ->
    Tuple (updateWorldCategory (category { objects = snoc category.objects (Object name) }) world )
    $ updateGeometryState (createForeignObject geometryCache posX posY name) geom
  UpdateCreateMorphism idx1 idx2 name ->
    Tuple (updateWorldCategory (category { morphisms = category.morphisms <> (fromMaybe [] $ sequence $ singleton newMorphism) } ) world) 
    $ updateGeometryState (createForeignMorphism geometryCache idx1 idx2 name) geom
    where
      obj1 = category.objects !! idx1
      obj2 = category.objects !! idx2
      newMorphism = createMorphism <$> obj1 <*> obj2 <*> Just name
  UpdateCreateFunctor idx1 idx2 name contravariant ->
    Tuple world { functors = fromMaybe world.functors (snoc world.functors <$> newFunctor) }
    $ geom { mainGeometryCache = uncurry (createForeignObject geom.mainGeometryCache) (invertCantorPairing $ length world.functors) name }
    where
      cat1 = world.categories !! idx1
      cat2 = world.categories !! idx2
      newFunctor = join $ lift4 createFunctor cat1 cat2 (Just name) (Just contravariant)
  UpdateCreateCategory name -> Tuple newWorld newState
    where
      newWorld = world { categories = snoc world.categories $ emptyCategory { name = name } }
      newState = geom { geometryCaches = snoc geom.geometryCaches $ unsafePerformEffect emptyGeometryCache
                      , currentCategory = length world.categories
                      , mainGeometryCache = uncurry (createForeignObject geom.mainGeometryCache) (bimap (mul 100) (mul 100) $ invertCantorPairing $ length $ (_.objects) $ world.functorCategory) ("id " <> name)
                      }
  UpdateComposeMorphisms idx1 idx2 name ->
    Tuple (updateWorldCategory (category { morphisms = category.morphisms <> (fromMaybe [] $ sequence $ singleton composedMorphism) }) world) 
    $ updateGeometryState (fromMaybe geometryCache $ createForeignMorphism geometryCache <$> composedIdx1 <*> composedIdx2 <*> Just name) geom
    where
      mor1 = category.morphisms !! idx1
      mor2 = category.morphisms !! idx2
      composedMorphism = join $ composeMorphisms <$> mor1 <*> mor2
      composedIdx1 = join $ composedMorphism <#> \f -> elemIndex f.from category.objects
      composedIdx2 = join $ composedMorphism <#> \f -> elemIndex f.to category.objects
  NoUpdate -> Tuple world geom
  where
    category :: Category
    category = getCurrentCategory world geom

    geometryCache :: GeometryCache
    geometryCache = getCurrentCache geom

    updateGeometryState :: GeometryCache -> GeometryState -> GeometryState
    updateGeometryState cache state = state { geometryCaches = fromMaybe state.geometryCaches (updateAt (state.currentCategory - 1) cache state.geometryCaches) }

    updateWorldCategory :: Category -> World -> World
    updateWorldCategory cat w = if geom.currentCategory == 0 then world { functorCategory = cat } else world { categories = fromMaybe world.categories $ updateAt (geom.currentCategory - 1) cat w.categories }

-- | Handles events passed to us from the typescript side.
handleForeignAction :: World -> GeometryState -> ForeignAction -> HandleActionOutput
handleForeignAction world geom action = case action of
  -- | Use updateStateCache to update the state.
  CreateObject posX posY name -> NewState $ updateStateCache world geom (UpdateCreateObject posX posY name)
  CreateMorphism idx1 idx2 name -> NewState $ updateStateCache world geom (UpdateCreateMorphism idx1 idx2 name)
  ComposeMorphisms idx1 idx2 name -> NewState $ updateStateCache world geom (UpdateCreateMorphism idx1 idx2 name)
  -- | Start morphsims or dragging
  StartMorphism idx -> NewState $ Tuple world $ updateGeometryState (startMorphism geometryCache idx) geom
  StartDragging idx -> NewState $ Tuple world $ updateGeometryState (startDragging geometryCache idx) geom
  StopDragging -> NewState $ Tuple world $ updateGeometryState (stopDragging geometryCache) geom
  -- | Pass a component back to the user for further input.
  GetObjectName posX posY -> RaiseComponent $ modalInputComponent "What is the name of this object?" "Object name" <#> handleReceivedName world geom
    where
      handleReceivedName :: World -> GeometryState -> Maybe String -> Tuple World GeometryState
      handleReceivedName c g rawName = case rawName of
        (Just name) -> updateStateCache c g $ UpdateCreateObject posX posY name
        (Nothing) -> Tuple c g
  GetMorphismName idx1 idx2 -> RaiseComponent $ modalInputComponent "What is the name of this morphism?" "Morphism name" <#> handleReceivedName world geom
    where
      handleReceivedName :: World -> GeometryState -> Maybe String -> Tuple World GeometryState
      handleReceivedName c g rawName = case rawName of
        (Just name) -> updateStateCache c g $ UpdateCreateMorphism idx1 idx2 name
        (Nothing) -> Tuple c g
  GetCompositionName idx1 idx2 -> RaiseComponent $ modalInputComponent "What is the name of this composed morphism?" "Morphism name" <#> handleReceivedName world geom
    where
      handleReceivedName :: World -> GeometryState -> Maybe String -> Tuple World GeometryState
      handleReceivedName c g rawName = case rawName of
        (Just name) -> updateStateCache c g $ UpdateComposeMorphisms idx1 idx2 name
        (Nothing) -> Tuple c g
  NoAction -> NewState $ Tuple world geom
  where
    category = getCurrentCategory world geom
    geometryCache = getCurrentCache geom

    updateGeometryState :: GeometryCache -> GeometryState -> GeometryState
    updateGeometryState cache state = state { geometryCaches = fromMaybe state.geometryCaches (updateAt (state.currentCategory - 1) cache state.geometryCaches) }

localStorageCanvasComponent :: forall a. Widget HTML a
localStorageCanvasComponent = join $ liftEffect $ (storageData <#> uncurry canvasComponent)
  where
    storageData :: Effect (Tuple World GeometryState)
    storageData = getLocalStorageUniverse

-- | Empty canvas component with functor category baked in
defaultCanvasComponent :: forall a. Widget HTML a
defaultCanvasComponent = canvasComponent defaultWorld defaultState
  where
    functorCategory :: GeometryCache
    functorCategory = createForeignObject (unsafePerformEffect emptyGeometryCache) 0 0 "Category 1"
    defaultWorld :: World
    defaultWorld = { categories: []
                   , functorCategory: emptyCategory { objects = [ Object "Category 1" ] }
                   , functors: []
                   , name: "My world" 
                   }
    defaultState :: GeometryState
    defaultState = { context: Nothing
                   , geometryCaches: [unsafePerformEffect emptyGeometryCache]
                   , mainGeometryCache: functorCategory
                   , currentCategory: 0 
                   }

errorComponent :: String -> forall a. Widget HTML a
errorComponent str = D.h1 [] [ D.text str ]

-- | Render `defaultCanvasComponent` on the div with the `app` id.
render :: Effect Unit
render = runWidgetInDom "app" defaultCanvasComponent
    
-- | Run a computation which requires access to a canvas rendering context.
withContext :: forall a. Ref NativeNode -> (Context2d -> Effect a) -> Effect (Maybe a)
withContext ref comp = do
  matchingRef <- liftEffect $ Ref.getCurrentRef ref
  case matchingRef of
    Nothing -> pure Nothing
    Just element -> do
      context <- getContext (unsafeCoerce element)
      sequence $ Just $ comp context

-- | Get current category based off the world and current state.
getCurrentCategory :: World -> GeometryState -> Category
getCurrentCategory world st = if st.currentCategory == 0 then functorCategory else fromMaybe functorCategory ((!!) world.categories (st.currentCategory - 1))
  where
    functorCategory :: Category
    functorCategory = world.functorCategory

-- | Get current geometry cache based off the current state.
getCurrentCache :: GeometryState -> GeometryCache
getCurrentCache state = if state.currentCategory == 0
                        then state.mainGeometryCache
                        else fromMaybe state.mainGeometryCache ((!!) state.geometryCaches (state.currentCategory - 1))

-- | Component that gathers an input from a modal.
modalInputComponent :: String -> String -> Widget HTML (Maybe String)
modalInputComponent question placeholder = do 
  e <- D.div [ P.className "modalInputComponentBackground", Nothing <$ onKeyEscape ]
    [ D.div [ P.className "modalInputComponentBody" ] 
      [ D.h2 [ P.className "modalInputComponentQuestion" ] [ D.text question ]
      , D.input  [ Just <$> P.onKeyEnter, P.placeholder placeholder, P.className "modalInputComponentInput", P._id "modalInputComponentInput" ]
      , D.button [ Nothing <$ P.onClick, P.className "modalInputComponentCancel" ] [ D.text "Close" ]
      ]
    ]
  new <- pure $ P.unsafeTargetValue <$> e
  _ <- liftEffect $ sequence $ P.resetTargetValue "" <$> e
  pure new
    where
      onKeyEscape :: ReactProps SyntheticKeyboardEvent
      onKeyEscape = filterProp isEscapeEvent P.onKeyDown
      isEscapeEvent :: SyntheticKeyboardEvent -> Boolean
      isEscapeEvent e = e'.which == 27 || e'.keyCode == 27
        where
          e' = unsafeCoerce e

canvasComponent :: forall a. World -> GeometryState -> Widget HTML a
canvasComponent world st = do
  canvasRef <- liftEffect Ref.createNodeRef

  -- | Create HTML of the component, as well as gather any events.
  event <- D.div 
    [ P._id $ "canvasDiv" ]
    $ [ D.button [(AddCategoryPress $ ("Category " <> (show $ length world.categories + 1))) <$ P.onClick, P.className "categoryButton"] [D.text "Add category"]
      , D.div
          [P._id "categoryButtons"]
          (D.button [SwitchCategoryTo 0 <$ P.onClick, P.className "categoryButton"] [D.text "Functor category"] :
          mapWithIndex (\idx _ -> D.button [SwitchCategoryTo (idx + 1) <$ P.onClick, P.className "categoryButton"] [D.text $ "Category " <> (show $ idx + 1)]) world.categories)
      , D.button [ClearStorageData <$ P.onClick, P.className "categoryButton"] [D.text "Clear storage"]
      , D.canvas
        [ P.width $ unsafePerformEffect $ (window >>= innerWidth) <#> (flip sub 100 >>> show)
        , P.height $ unsafePerformEffect $ (window >>= innerHeight) <#> (flip sub 6 >>> show)
        , P._id $ "leCanvas"
        , P.ref (Ref.fromRef canvasRef)
        , onMouseDown <#> \event -> HandleMouseEvent handleMouseDown event
        , onMouseMove <#> \event -> HandleMouseEvent handleMouseMove event
        , onMouseUp <#> \event -> HandleMouseEvent handleMouseUp event
        , onWheel <#> \event -> HandleWheelEvent handleScroll event
        ] []
      ]

  -- | Get the new state after handling any DOM actions.
  newState <- liftEffect $ handleAction st event canvasRef

  -- | Render the next version of the component.
  fromMaybe (canvasComponent world st) $ newState <#> \passedState -> case passedState of
    (NewState state) -> (liftEffect $ uncurry storeUniverse state) *> (uncurry canvasComponent state)
    (RaiseComponent component) -> canvasComponent world st <|> component >>= \state -> uncurry canvasComponent state
    (ReplaceCategory new) -> uncurry canvasComponent new
    (NoActionOutput) -> canvasComponent world st

  where

  category :: Category
  category = getCurrentCategory world st

  -- | Handle action passed to us via the DOM.
  handleAction :: GeometryState -> Action -> Ref NativeNode -> Effect (Maybe HandleActionOutput)
  handleAction state action ref = case action of
    Render -> do
      _ <- withContext ref \ctx -> renderCanvas ctx geometryCache
      pure $ Just $ NoActionOutput
    HandleMouseEvent handler event ->
      (\val -> handleForeignAction world state <$> val) <$> (withContext ref (\ctx -> handler ctx event geometryCache))
      <* (handleAction state Render ref)
    HandleWheelEvent handler event ->
      (\val -> handleForeignAction world state <$> val) <$> (withContext ref (\ctx -> handler ctx event geometryCache))
      <* (handleAction state Render ref)
    AddCategoryPress name -> 
      (pure $ Just $ ReplaceCategory newState)
      <* (handleAction (snd newState) Render ref)
      where
        newState = updateStateCache world st $ UpdateCreateCategory name
    SwitchCategoryTo newIdx -> (pure $ Just $ ReplaceCategory $ Tuple world $ getNewState newIdx) <* (handleAction (getNewState newIdx) Render ref)
      where
        getNewState :: Int -> GeometryState
        getNewState newInt = (\x -> st { currentCategory = if x > length world.categories then st.currentCategory else if x < 1 then 0 else x }) newInt
    ClearStorageData -> do
      w <- window
      s <- localStorage w
      clear s
      l <- location w
      reload l
      pure Nothing
    where
      geometryCache = getCurrentCache state