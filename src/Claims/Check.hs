-- | Reading claims files from the explore dir and replaying their claims.
module Claims.Check
  ( resolveExploreDir
  , checkClaims
  , lintFile
  ) where

import Claims.File
import Claims.Name
import Claims.Result
import Claims.Run (runCmd)
import Control.Monad (forM_, unless, when)
import Data.Bifunctor (first)
import qualified Data.ByteString as BS
import Data.IORef
import Data.List (isSuffixOf, sort)
import Data.Maybe (fromMaybe)
import qualified Data.Set as Set
import Data.String.Conversions (cs)
import Data.Text (Text)
import qualified Data.Text as T
import System.Directory (doesDirectoryExist, doesFileExist, listDirectory)
import System.Environment (lookupEnv)
import System.FilePath (takeFileName, (</>))

resolveExploreDir :: IO FilePath
resolveExploreDir = fromMaybe "./live-docs/explore" <$> lookupEnv "EXPACC_DIR"

-- | Verdict, the command if it was run, and its stdout if the run finished.
verdictFor :: Claim -> IO (Verdict, Maybe Text, Maybe [Text])
verdictFor c = case claimExpect c of
  Nothing -> pure (VFalse NotRecorded, Nothing, Nothing)
  Just ex ->
    runCmd (claimCmd c) >>= \case
      Left r -> pure (VFalse r, Just (claimCmd c), Nothing)
      Right out -> pure (compareLines ex out, Just (claimCmd c), Just out)
  where
    compareLines e a
      | e == a = VTrue
      | sort e == sort a = VFalse (Reordered e a)
      | otherwise = VFalse (Mismatch e a)

-- | Reads @$EXPACC_DIR/claims/NAME.claims.jsonl@. NAME is a slug; there is
-- no doc-header lookup and no path acceptance.
readClaimsFile :: FilePath -> ClaimsName -> IO (Either Reason ClaimsFile)
readClaimsFile dir name = do
  let path = claimsPath dir name
  doesFileExist path >>= \case
    True -> first (BadFile . cs) . parseClaimsFile path . cs <$> BS.readFile path
    False -> Left . MissingDep <$> notFound dir name

-- | Claims files in @claims/@, sorted.
listClaimsFiles :: FilePath -> IO [FilePath]
listClaimsFiles dir = do
  let cdir = claimsDir dir
  doesDirectoryExist cdir >>= \case
    False -> pure []
    True -> map (cdir </>) . sort . filter (".claims.jsonl" `isSuffixOf`) <$> listDirectory cdir

notFound :: FilePath -> ClaimsName -> IO Text
notFound dir name = do
  have <- map (T.dropEnd (T.length ".claims.jsonl") . cs . takeFileName) <$> listClaimsFiles dir
  let avail
        | null have = "none"
        | otherwise = T.intercalate ", " (take 10 have) <> (if length have > 10 then ", ..." else "")
  pure ("no such claims file " <> cs (claimsPath dir name) <> " (claims files in " <> cs (claimsDir dir) <> ": " <> avail <> ")")

data Env = Env
  { envDir :: FilePath
  , envClaims :: IORef (Set.Set (ClaimsName, ClaimId))
  , envFiles :: IORef (Set.Set ClaimsName)
  , envOut :: IORef [ClaimResult]
  }

-- | Checks the named files and, transitively, their dependencies.
checkClaims :: FilePath -> [ClaimsName] -> IO [ClaimResult]
checkClaims dir names = do
  env <- Env dir <$> newIORef mempty <*> newIORef mempty <*> newIORef []
  forM_ names $ visit env Target Nothing
  reverse <$> readIORef (envOut env)

visit :: Env -> Origin -> Maybe ClaimId -> ClaimsName -> IO ()
visit env origin only name =
  readClaimsFile (envDir env) name >>= \case
    Left r -> emit (ClaimId (maybe "*" (\(ClaimId i) -> i) only)) "" (VFalse r) Nothing Nothing
    Right cf -> do
      let picked = [c | c <- cfClaims cf, maybe True (== claimId c) only]
      when (null picked) $ forM_ only $ \i -> emit i "" (VFalse (MissingDep "no such claim")) Nothing Nothing
      forM_ picked $ \c -> once (envClaims env) (name, claimId c) $
        verdictFor c >>= \(v, cmd, out) -> emit (claimId c) (claimText c) v cmd out
      once (envFiles env) name $ do
        forM_ (cfProblems cf) $ \p -> emit (ClaimId "lint") "" (VFalse (Lint p)) Nothing Nothing
        forM_ (hDepends (cfHeader cf)) $ \case
          WholeFile n -> visit env Dependency Nothing n
          OneClaim n i -> visit env Dependency (Just i) n
  where
    emit i t v cmd out = modifyIORef (envOut env) (ClaimResult name i t origin v cmd out :)
    once ref k act = do
      seen <- readIORef ref
      unless (k `Set.member` seen) $ modifyIORef ref (Set.insert k) >> act

-- | Lint problems of one claims file, without running any command.
lintFile :: FilePath -> ClaimsName -> IO [Text]
lintFile dir name =
  readClaimsFile dir name >>= \case
    Left (MissingDep t) -> pure [t]
    Left (BadFile t) -> pure [t]
    Left _ -> pure []
    Right cf -> pure (cfProblems cf)
