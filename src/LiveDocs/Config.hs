-- | explore-lifetime in live-docs/.live-docs-config.json.
module LiveDocs.Config
  ( defaultExploreLifetime
  , secondsPerDay
  , daysToSeconds
  , readExploreLifetime
  , writeExploreLifetime
  ) where

import Data.Aeson
import Data.Aeson.Types (Parser, parseEither)
import qualified Data.Aeson.KeyMap as KM
import Data.Bifunctor (first)
import qualified Data.ByteString as BS
import Data.Char (isDigit)
import Data.String.Conversions (cs)
import Data.Text (Text)
import qualified Data.Text as T
import System.Directory (doesFileExist)
import System.FilePath ((</>))

-- | Default lifetime: 5 days, in seconds. Shown when the file is missing.
-- Never written unless the user saves a value.
defaultExploreLifetime :: Integer
defaultExploreLifetime = 432000

secondsPerDay :: Integer
secondsPerDay = 86400

daysToSeconds :: Integer -> Either Text Integer
daysToSeconds n
  | n <= 0 = Left "days must be > 0"
  | otherwise = Right (n * secondsPerDay)

configPath :: FilePath -> FilePath
configPath dir = dir </> ".live-docs-config.json"

-- | @dir@ is the live-docs directory, not the config file.
-- Missing file or missing key is 'Right' 'Nothing'. A present key is a JSON
-- string of digits or a JSON number, and must be an integer > 0.
readExploreLifetime :: FilePath -> IO (Either Text (Maybe Integer))
readExploreLifetime dir = do
  let path = configPath dir
  exists <- doesFileExist path
  if not exists
    then pure (Right Nothing)
    else do
      bs <- BS.readFile path
      case eitherDecodeStrict bs of
        Left _ -> pure (Left "invalid JSON")
        Right (Object o) -> pure (lookupLifetime o)
        Right _ -> pure (Left "config is not a JSON object")

lookupLifetime :: Object -> Either Text (Maybe Integer)
lookupLifetime o = case KM.lookup "explore-lifetime" o of
  Nothing -> Right Nothing
  Just v -> Just <$> parseLifetime v

parseLifetime :: Value -> Either Text Integer
parseLifetime (String t)
  | not (T.null t) && T.all isDigit t = positive (read (T.unpack t))
  | otherwise = Left "explore-lifetime must be a string of digits or a number"
parseLifetime v = case parseEither (parseJSON :: Value -> Parser Integer) v of
  Right n -> positive n
  Left _ -> Left "explore-lifetime must be a string of digits or a number"

positive :: Integer -> Either Text Integer
positive n
  | n <= 0 = Left "explore-lifetime must be > 0"
  | otherwise = Right n

-- | Rejects @n <= 0@ and does not write. Stores the value as a JSON string of
-- decimal seconds. Other top-level keys are kept. A non-object file is left
-- untouched.
writeExploreLifetime :: FilePath -> Integer -> IO (Either Text ())
writeExploreLifetime dir n
  | n <= 0 = pure (Left "explore-lifetime must be > 0")
  | otherwise = do
      let path = configPath dir
      exists <- doesFileExist path
      loaded <-
        if not exists
          then pure (Right KM.empty)
          else do
            bs <- BS.readFile path
            pure $ case eitherDecodeStrict bs of
              Left _ -> Left "invalid JSON"
              Right (Object o) -> Right o
              Right _ -> Left "config is not a JSON object"
      case loaded of
        Left e -> pure (Left e)
        Right o -> do
          let o' = KM.insert "explore-lifetime" (String (cs (show n))) o
          BS.writeFile path (cs (encode (Object o')) <> "\n")
          pure (Right ())
