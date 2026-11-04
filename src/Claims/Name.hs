{-# LANGUAGE DerivingStrategies #-}

-- | Claims names and references. A name is always a slug, never a path.
module Claims.Name
  ( ClaimId (..)
  , ClaimsName (..)
  , DepRef (..)
  , parseClaimsName
  , parseDepRef
  , claimsPath
  , claimsDir
  ) where

import Data.Aeson
import Data.Char (isAlphaNum)
import Data.String.Conversions (cs)
import Data.Text (Text)
import qualified Data.Text as T
import System.FilePath ((</>))

newtype ClaimId = ClaimId Text
  deriving newtype (Eq, Ord, Show, FromJSON, ToJSON)

newtype ClaimsName = ClaimsName Text
  deriving newtype (Eq, Ord, Show)

data DepRef = WholeFile ClaimsName | OneClaim ClaimsName ClaimId
  deriving stock (Eq, Show)

instance FromJSON DepRef where
  parseJSON = withText "DepRef" $ \t -> case parseDepRef t of
    Left e -> fail (cs e)
    Right d -> pure d

instance ToJSON DepRef where
  toJSON = \case
    WholeFile (ClaimsName n) -> String n
    OneClaim (ClaimsName n) (ClaimId i) -> String (n <> "#" <> i)

-- | The only legal claims name: a slug (@other@), not a path and not a
-- suffix. @.claims.jsonl@ and @.md@ are rejected so a doubled path cannot
-- be assembled by accident.
parseClaimsName :: Text -> Either Text ClaimsName
parseClaimsName t
  | isSlug t = Right (ClaimsName t)
  | otherwise = Left (badClaimsName t)

-- | @other@ or @other#id@. Same slug rule on both sides of @#@.
parseDepRef :: Text -> Either Text DepRef
parseDepRef t = case T.breakOn "#" t of
  (n, "") -> WholeFile <$> parseClaimsName n
  (n, rest)
    | Just i <- T.stripPrefix "#" rest, isSlug i ->
        OneClaim <$> parseClaimsName n <*> pure (ClaimId i)
    | otherwise -> Left (badClaimsName t)

claimsPath :: FilePath -> ClaimsName -> FilePath
claimsPath dir (ClaimsName n) = claimsDir dir </> cs n <> ".claims.jsonl"

claimsDir :: FilePath -> FilePath
claimsDir dir = dir </> "claims"

isSlug :: Text -> Bool
isSlug t = case T.uncons t of
  Just (c, rest) -> isAlphaNum c && T.all slugChar rest
  Nothing -> False
  where
    slugChar c = isAlphaNum c || c == '-' || c == '_'

badClaimsName :: Text -> Text
badClaimsName t =
  "claims name must be a slug like other or other#id, not "
    <> t
    <> " (no path, no .claims.jsonl, no .md)"
