-- | Writing claims: the command is run here and its output becomes @expect@,
-- so agents never copy output by hand.
module Record
  ( NewClaim (..)
  , recordNew
  , recordAppend
  , recordFix
  ) where

import Claims
import Control.Monad (unless, when)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Except (ExceptT (..), except, runExceptT, throwE, withExceptT)
import Data.Aeson (encode)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.List (find)
import Data.Maybe (fromMaybe)
import Data.String.Conversions (cs)
import Data.Text (Text)
import qualified Data.Text as T
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath (takeDirectory)

data NewClaim = NewClaim
  { ncId :: Text
  , ncText :: Text
  , ncCmd :: Text
  }

type Rec = ExceptT Text IO

-- | Runs the command; its stdout lines become the claim's @expect@.
recorded :: NewClaim -> Rec Claim
recorded NewClaim {..} =
  Claim (ClaimId ncId) ncText ncCmd . Just <$> withExceptT failed (ExceptT (runCmd ncCmd))
  where
    failed = \case
      Rejected t -> t
      ExecFailed t -> "command failed, nothing recorded: " <> t
      _ -> "command failed, nothing recorded"

-- | The parsed claims file, which must exist; @hint@ is appended to the error otherwise.
load :: Text -> FilePath -> ClaimsName -> Rec ClaimsFile
load hint dir name = do
  let path = claimsPath dir name
  exists <- liftIO (doesFileExist path)
  unless exists $ throwE ("no claims file " <> cs path <> hint)
  withExceptT cs . except . parseClaimsFile path . cs =<< liftIO (BS.readFile path)

-- | Writes the whole file: the header line, if any, then one line per claim.
save :: FilePath -> ClaimsName -> Header -> [Claim] -> Rec ()
save dir name hdr claims = liftIO $ do
  let path = claimsPath dir name
  createDirectoryIfMissing True (takeDirectory path)
  BL.writeFile path (mconcat [l <> "\n" | l <- [encode hdr | hdr /= emptyHeader] <> map encode claims])

expected :: Claim -> [Text]
expected = fromMaybe [] . claimExpect

label :: ClaimsName -> ClaimId -> Text
label (ClaimsName n) (ClaimId i) = n <> "#" <> i

report :: ClaimsName -> Claim -> Text
report name c =
  T.unlines $
    ("recorded " <> label name (claimId c) <> " (" <> cs (show (length (expected c))) <> " lines)")
      : map ("    " <>) (expected c)

-- | Creates the claims file, with a header when any header field is given.
recordNew :: FilePath -> ClaimsName -> Header -> NewClaim -> IO (Either Text Text)
recordNew dir name hdr nc = runExceptT $ do
  let path = claimsPath dir name
  exists <- liftIO (doesFileExist path)
  when exists $ throwE ("claims file exists: " <> cs path <> ". Use record-append to add a claim.")
  c <- recorded nc
  save dir name hdr [c]
  pure (report name c)

-- | Adds one claim to an existing claims file.
recordAppend :: FilePath -> ClaimsName -> NewClaim -> IO (Either Text Text)
recordAppend dir name nc = runExceptT $ do
  cf <- load ". Use record to create it." dir name
  when (ClaimId (ncId nc) `elem` map claimId (cfClaims cf)) $
    throwE ("claim id exists: " <> ncId nc <> ". Use record-fix to refresh it.")
  c <- recorded nc
  save dir name (cfHeader cf) (cfClaims cf <> [c])
  pure (report name c)

-- | Re-runs the command of an existing claim and rewrites its @expect@.
recordFix :: FilePath -> ClaimsName -> Text -> IO (Either Text Text)
recordFix dir name cid = runExceptT $ do
  cf <- load "" dir name
  old <-
    maybe (throwE ("no claim " <> cid <> " in " <> cs (claimsPath dir name))) pure $
      find ((== ClaimId cid) . claimId) (cfClaims cf)
  new <- recorded (NewClaim cid (claimText old) (claimCmd old))
  if expected old /= expected new
    then do
      save dir name (cfHeader cf) [if claimId c == ClaimId cid then new else c | c <- cfClaims cf]
      pure (T.unlines (("fixed " <> label name (ClaimId cid)) : renderDiff (expected old) (expected new)))
    else pure ("unchanged " <> label name (ClaimId cid) <> "\n")
