{-# LANGUAGE OverloadedStrings #-}

-- | Writing claims: the command is run here and its output becomes @expect@,
-- so agents never copy output by hand.
module Record
  ( Header (..)
  , NewClaim (..)
  , recordNew
  , recordAppend
  , recordFix
  ) where

import Claims
import Control.Monad (unless)
import Data.Aeson (ToJSON, Value (..), eitherDecodeStrict, encode)
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as BS
import Data.Maybe (catMaybes)
import Data.String.Conversions (cs)
import Data.Text (Text)
import qualified Data.Text as T
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath (takeDirectory)

data Header = Header
  { hDoc :: Maybe Text
  , hCommit :: Maybe Text
  , hDepends :: [Text]
  }

data NewClaim = NewClaim
  { ncId :: Text
  , ncText :: Text
  , ncCmd :: [Text]
  }

json :: ToJSON a => a -> Text
json = cs . encode

-- | A JSON object with its keys in the given order, which 'encode' of an
-- object would not keep.
obj :: [(Text, Text)] -> Text
obj kvs = "{" <> T.intercalate "," [json k <> ":" <> v | (k, v) <- kvs] <> "}"

headerLine :: Header -> Maybe Text
headerLine h
  | null fields = Nothing
  | otherwise = Just (obj fields)
  where
    fields =
      catMaybes
        [ ("doc",) . json <$> hDoc h
        , ("commit",) . json <$> hCommit h
        , if null (hDepends h) then Nothing else Just ("depends", json (hDepends h))
        ]

claimLine :: Claim -> Text
claimLine c =
  obj $
    [ ("id", json (claimId c))
    , ("text", json (claimText c))
    , ("cmd", json (claimCmd c))
    ]
      <> [("expect", json e) | Just e <- [claimExpect c]]

-- | Runs the command; its stdout lines become the claim's @expect@.
recorded :: NewClaim -> IO (Either Text Claim)
recorded nc =
  runCmd (ncCmd nc) >>= \case
    Left (Rejected t) -> pure (Left t)
    Left (ExecFailed t) -> pure (Left ("command failed, nothing recorded: " <> t))
    Left _ -> pure (Left "command failed, nothing recorded")
    Right out -> pure (Right (Claim (ClaimId (ncId nc)) (ncText nc) (ncCmd nc) (Just out)))

report :: Text -> ClaimsName -> Claim -> Text
report verb (ClaimsName n) c =
  T.unlines $
    (verb <> " " <> n <> "#" <> i <> " (" <> T.pack (show (length out)) <> " lines)")
      : map ("    " <>) out
  where
    ClaimId i = claimId c
    out = maybe [] id (claimExpect c)

-- | Creates the claims file, with a header when any header field is given.
recordNew :: FilePath -> ClaimsName -> Header -> NewClaim -> IO (Either Text Text)
recordNew dir name hdr nc = do
  let path = claimsPath dir name
  exists <- doesFileExist path
  if exists
    then pure (Left ("claims file exists: " <> cs path <> ". Use record-append to add a claim."))
    else
      recorded nc >>= \case
        Left e -> pure (Left e)
        Right c -> do
          createDirectoryIfMissing True (takeDirectory path)
          BS.writeFile path (cs (T.unlines (catMaybes [headerLine hdr] <> [claimLine c])))
          pure (Right (report "recorded" name c))

-- | Appends one claim to an existing claims file.
recordAppend :: FilePath -> ClaimsName -> NewClaim -> IO (Either Text Text)
recordAppend dir name nc = do
  let path = claimsPath dir name
  exists <- doesFileExist path
  if not exists
    then pure (Left ("no claims file " <> cs path <> ". Use record to create it."))
    else do
      raw <- BS.readFile path
      case parseClaimsFile path (cs raw) of
        Left e -> pure (Left (cs e))
        Right cf
          | ClaimId (ncId nc) `elem` map claimId (cfClaims cf) ->
              pure (Left ("claim id exists: " <> ncId nc <> ". Use record-fix to refresh it."))
          | otherwise ->
              recorded nc >>= \case
                Left e -> pure (Left e)
                Right c -> do
                  let sep = if BS.null raw || BS.last raw == 10 then "" else "\n"
                  BS.appendFile path (cs (sep <> claimLine c <> "\n"))
                  pure (Right (report "recorded" name c))

-- | Re-runs the command of an existing claim and rewrites its @expect@. All
-- other lines of the file are kept as they are.
recordFix :: FilePath -> ClaimsName -> Text -> IO (Either Text Text)
recordFix dir name cid = do
  let path = claimsPath dir name
  exists <- doesFileExist path
  if not exists
    then pure (Left ("no claims file " <> cs path))
    else do
      raw <- cs <$> BS.readFile path
      case parseClaimsFile path raw of
        Left e -> pure (Left (cs e))
        Right cf -> case [c | c <- cfClaims cf, claimId c == ClaimId cid] of
          [] -> pure (Left ("no claim " <> cid <> " in " <> cs path))
          old : _ ->
            recorded (NewClaim cid (claimText old) (claimCmd old)) >>= \case
              Left e -> pure (Left e)
              Right new -> do
                let fixed = old {claimExpect = claimExpect new}
                    swap l
                      | isClaimLine l = claimLine fixed
                      | otherwise = l
                    isClaimLine l = case eitherDecodeStrict (cs l) of
                      Right (Object o) -> KM.lookup "id" o == Just (String cid) && not (KM.member "depends" o)
                      _ -> False
                    old' = maybe [] id (claimExpect old)
                    new' = maybe [] id (claimExpect new)
                unless (old' == new') $
                  BS.writeFile path (cs (T.unlines (map swap (T.lines raw))))
                pure . Right $
                  if old' == new'
                    then "unchanged " <> name' <> "#" <> cid <> "\n"
                    else T.unlines (("fixed " <> name' <> "#" <> cid) : renderDiff old' new')
  where
    ClaimsName name' = name
