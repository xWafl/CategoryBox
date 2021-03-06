module CategoryBox.Data.Types where

import Data.Argonaut (class DecodeJson, class EncodeJson, decodeJson, fromString, jsonEmptyObject, (:=), (~>))
import Data.Argonaut.Decode.Combinators ((.:))
import Prelude (class Eq, class Show, bind, pure, ($), (&&), (<$>), (<<<), (<>), (==))

import Data.Argonaut.Decode.Decoders (decodeString)
import Data.Newtype (class Newtype, unwrap)

-- | Newtype for an Object with a string denoting the name
newtype Object = Object String

derive instance eqObject :: Eq Object

derive instance newtypeObject :: Newtype Object _

instance showObject :: Show Object where
  show (Object a) = a

instance encodeObjectJson :: EncodeJson Object where
  encodeJson = fromString <<< unwrap

instance decodeObjectJson :: DecodeJson Object where
  decodeJson a = Object <$> decodeString a

-- | Newtype for morphisms leading from an object to an object as well as having a name
type Morphism = 
  { from :: Object
  , to :: Object
  , name :: String
  }

-- | Record for a Category including objects and morphisms
type Category =
  { objects :: Array Object
  , morphisms :: Array Morphism
  , name :: String
  }

-- | Record for a world including categories and functors
type World =
  { categories :: Array Category
  , functorCategory :: Category
  , functors :: Array CFunctor
  , name :: String
  }

-- | Newtype for a functor leading from a category to a category, as well as a name and a boolean where true means contravariance.
newtype CFunctor = CFunctor
  { from :: Category
  , to :: Category
  , name :: String
  , contravariant :: Boolean
  }

derive instance newtypeFunctor :: Newtype CFunctor _

instance eqFunctor :: Eq CFunctor where
  eq (CFunctor f) (CFunctor g) = f.from == g.from && f.to == g.to && f.contravariant == g.contravariant

instance showFunctor :: Show CFunctor where
  show (CFunctor f) = f.name <> ": " <> f.from.name <> " -> " <> f.to.name

instance encodeJsonCFunctor :: EncodeJson CFunctor where
  encodeJson func = 
    "from" := unwrapped.from
    ~> "to" := unwrapped.to
    ~> "name" := unwrapped.name
    ~> "contravariant" := unwrapped.contravariant
    ~> jsonEmptyObject
    where
      unwrapped :: _
      unwrapped = unwrap func

instance decodeJsonCFunctor :: DecodeJson CFunctor where
  decodeJson json = do
    x <- decodeJson json
    from <- x .: "from"
    to <- x .: "to"
    name <- x .: "name"
    contravariant <- x .: "contravariant"
    pure $ CFunctor { from: from, to: to, name: name, contravariant: contravariant }