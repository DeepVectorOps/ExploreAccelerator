{-# LANGUAGE DerivingStrategies #-}

-- | Deleting stale explore docs. Selection is pure ('decide'); the IO side
-- only gathers each doc's age and claim score and removes the files.
module Prune
  ( PruneOpts (..)
  , Why (..)
  , Doc (..)
  , parseDuration
  , parseRatio
  , needsCheck
  , decide
  , renderWhy
  , listDocs
  , scoreOf
  , deleteDoc
  ) where

import Claims.Name
import Claims.Result
import Control.Monad (filterM, when)
import Data.Char (isDigit)
import Data.List (isSuffixOf, sort)
import Data.Maybe (catMaybes, isJust)
import Data.String.Conversions (cs)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (NominalDiffTime, UTCTime, diffUTCTime)
import System.Directory (doesFileExist, getModificationTime, listDirectory, removeFile)
import System.FilePath (dropExtension, (</>))
import Text.Read (readMaybe)

data PruneOpts = PruneOpts
  { poOlder :: Maybe NominalDiffTime
  , poInaccurate :: Maybe Double
  , poMissing :: Bool
  }
  deriving stock (Eq, Show)

data Why = Older | Inaccurate Int Int | MissingClaims
  deriving stock (Eq, Show)

data Doc = Doc
  { docSlug :: Text
  , docAge :: NominalDiffTime
  , docHasClaims :: Bool
  }
  deriving stock (Eq, Show)

-- | @7d@, @1h@, @30m@, @45s@: digits then exactly one unit.
parseDuration :: Text -> Either Text NominalDiffTime
parseDuration t = case T.unsnoc t of
  Just (n, u)
    | not (T.null n), T.all isDigit n, Just secs <- lookup u units -> Right (fromInteger (read (cs n) * secs))
  _ -> Left ("bad duration " <> t <> " (expected e.g. 7d, 1h, 30m, 45s)")
  where
    units = [('d', 86400), ('h', 3600), ('m', 60), ('s', 1)]

parseRatio :: Text -> Either Text Double
parseRatio t = case readMaybe (cs (if "." `T.isPrefixOf` t then "0" <> t else t)) of
  Just r | r >= 0, r <= 1 -> Right r
  _ -> Left ("bad ratio " <> t <> " (expected a number in [0,1])")

olderOk :: PruneOpts -> Doc -> Maybe Bool
olderOk o d = (docAge d >) <$> poOlder o

-- | Whether the slow claim replay is needed: only for docs with claims that
-- already pass the age filter.
needsCheck :: PruneOpts -> Doc -> Bool
needsCheck o d = docHasClaims d && isJust (poInaccurate o) && olderOk o d /= Just False

-- | Reasons to delete (empty keeps the doc). The score is (true, total)
-- claims, present when 'needsCheck' held. Older and inaccurate are ANDed;
-- missing claims is a separate rule.
decide :: PruneOpts -> Doc -> Maybe (Int, Int) -> [Why]
decide o d score
  | not (docHasClaims d) = [MissingClaims | poMissing o]
  | null rules || not (all fst rules) = []
  | otherwise = map snd rules
  where
    rules = catMaybes [(,Older) <$> olderOk o d, inaccurate <$> poInaccurate o]
    inaccurate r = case score of
      Just (t, n) -> (if n == 0 then r > 0 else fromIntegral t / fromIntegral n < r, Inaccurate t n)
      Nothing -> (False, Inaccurate 0 0)

renderWhy :: Why -> Text
renderWhy = \case
  Older -> "older"
  Inaccurate t n -> "inaccurate " <> cs (show t) <> "/" <> cs (show n)
  MissingClaims -> "missing claims"

-- | Docs directly in the explore dir, sorted by slug.
listDocs :: FilePath -> UTCTime -> IO [Doc]
listDocs dir now = do
  mds <- filterM (doesFileExist . (dir </>)) . sort . filter (".md" `isSuffixOf`) =<< listDirectory dir
  mapM doc mds
  where
    doc f = do
      let slug = cs (dropExtension f)
      age <- diffUTCTime now <$> getModificationTime (dir </> f)
      Doc slug age <$> doesFileExist (claimsPath dir (ClaimsName slug))

-- | (true, total) over the file's own claims; dependency and lint rows don't count.
scoreOf :: [ClaimResult] -> (Int, Int)
scoreOf rs = (length (filter ((== VTrue) . resVerdict) own), length own)
  where
    own = [r | r <- rs, resOrigin r == Target, not (isLint (resVerdict r))]
    isLint = \case
      VFalse (Lint _) -> True
      _ -> False

deleteDoc :: FilePath -> Doc -> IO ()
deleteDoc dir d = do
  removeFile (dir </> cs (docSlug d) <> ".md")
  when (docHasClaims d) $ do
    let claims = claimsPath dir (ClaimsName (docSlug d))
    removeFile claims
    lockExists <- doesFileExist (claims <> ".lock")
    when lockExists $ removeFile (claims <> ".lock")
