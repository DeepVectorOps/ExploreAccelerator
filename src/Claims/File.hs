{-# LANGUAGE DerivingStrategies #-}

-- | The claims file format: an optional header line, then one claim per line.
module Claims.File
  ( Claim (..)
  , Header (..)
  , emptyHeader
  , ClaimsFile (..)
  , parseClaimsFile
  ) where

import Claims.Name
import Claims.Quote (quoteArgv)
import Data.Aeson
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import Data.Aeson.Types (parseEither)
import Data.Bifunctor (first)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, listToMaybe)
import Data.String.Conversions (cs)
import Data.Text (Text)
import qualified Data.Text as T

data Claim = Claim
  { claimId :: ClaimId
  , claimText :: Text
  , claimCmd :: Text
  , claimExpect :: Maybe [Text]
  }
  deriving stock (Eq, Show)

instance FromJSON Claim where
  parseJSON = withObject "Claim" $ \o ->
    Claim <$> o .: "id" <*> o .: "text" <*> (o .: "cmd" >>= cmdText) <*> o .:? "expect"
    where
      -- Older files hold an argv array; it becomes one quoted bash string.
      cmdText = \case
        String t -> pure t
        v -> quoteArgv <$> parseJSON v

claimPairs :: KeyValue e kv => Claim -> [kv]
claimPairs Claim {..} =
  ["id" .= claimId, "text" .= claimText, "cmd" .= claimCmd] <> ["expect" .= e | Just e <- [claimExpect]]

instance ToJSON Claim where
  toJSON = object . claimPairs
  toEncoding = pairs . mconcat . claimPairs

-- | The optional first line of a claims file.
data Header = Header
  { hDoc :: Maybe Text
  , hCommit :: Maybe Text
  , hDepends :: [DepRef]
  }
  deriving stock (Eq, Show)

emptyHeader :: Header
emptyHeader = Header Nothing Nothing []

headerKeys :: [Key]
headerKeys = ["depends", "doc", "commit"]

instance FromJSON Header where
  parseJSON = withObject "Header" $ \o ->
    Header <$> o .:? "doc" <*> o .:? "commit" <*> o .:? "depends" .!= []

headerPairs :: KeyValue e kv => Header -> [kv]
headerPairs Header {..} =
  ["doc" .= d | Just d <- [hDoc]] <> ["commit" .= c | Just c <- [hCommit]] <> ["depends" .= hDepends | not (null hDepends)]

instance ToJSON Header where
  toJSON = object . headerPairs
  toEncoding = pairs . mconcat . headerPairs

data ClaimsFile = ClaimsFile
  { cfHeader :: Header
  , cfClaims :: [Claim]
  , cfProblems :: [Text]
  }
  deriving stock (Eq, Show)

-- | A header with its unknown keys, or a claim.
data Line = LHeader Header [Text] | LClaim Claim

-- | Non-blank lines; only the first may be a header object with any of
-- @depends@, @doc@ and @commit@.
parseLines :: FilePath -> Text -> Either String [Line]
parseLines path = go True . zip [1 ..] . T.lines
  where
    go _ [] = Right []
    go isFirst ((n, l) : rest)
      | T.null (T.strip l) = go isFirst rest
      | otherwise = do
          v <- first (err n) (eitherDecodeStrict (cs l))
          line <- first (err n) $ case v of
            Object o
              | isFirst, any (`KM.member` o) headerKeys ->
                  (`LHeader` [Key.toText k | k <- KM.keys o, k `notElem` headerKeys]) <$> parseEither parseJSON v
            _ -> LClaim <$> parseEither parseJSON v
          (line :) <$> go False rest
    err n e = path <> ":" <> show (n :: Int) <> ": " <> e

-- | Mistakes that would otherwise be silently ignored or confusing.
problemsOf :: [Text] -> [Claim] -> [Text]
problemsOf unknownKeys claims =
  ["unknown header key: " <> k | k <- unknownKeys]
    <> ["duplicate claim id: " <> i | (ClaimId i, n) <- counts, n > (1 :: Int)]
  where
    counts = Map.toList (Map.fromListWith (+) [(claimId c, 1) | c <- claims])

parseClaimsFile :: FilePath -> Text -> Either String ClaimsFile
parseClaimsFile path txt = do
  ls <- parseLines path txt
  pure
    ClaimsFile
      { cfHeader = fromMaybe emptyHeader (listToMaybe [h | LHeader h _ <- ls])
      , cfClaims = [c | LClaim c <- ls]
      , cfProblems = problemsOf (concat [u | LHeader _ u <- ls]) [c | LClaim c <- ls]
      }
