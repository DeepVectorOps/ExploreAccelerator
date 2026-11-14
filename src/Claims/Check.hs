-- | Reading claims files from the explore dir and replaying their claims.
module Claims.Check
  ( resolveExploreDir
  , checkClaims
  , lintFile
  , compareOutput
  ) where

import Claims.File
import Claims.Name
import Claims.Result
import Claims.RgGroup
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
      Right out -> pure (compareOutput (claimCmd c) ex out, Just (claimCmd c), Just out)

-- | Verdict for a command's expected and actual stdout lines. For @rg -n@
-- output (every line parses as rg's format) the lines are grouped into
-- blocks, so moved lines are 'Shifted' and a change diffs block-wise.
compareOutput :: Text -> [Text] -> [Text] -> Verdict
compareOutput cmd e a
  | e == a = VTrue
  | sort e == sort a = VFalse (Reordered e a)
  | Just be <- grouped e
  , Just ba <- grouped a =
      let moved = [(blockHeader x, blockHeader y, bStart y - bStart x) | (x, y) <- zip be ba, bStart x /= bStart y]
          -- offsets are only meaningful when blocks pair up one to one
          movedAlso
            | length be == length ba = [m | (m, (x, y)) <- zip moved' (zip be ba), bFile x == bFile y, isMove m]
            | otherwise = []
            where
              moved' = [(blockHeader x, blockHeader y, bStart y - bStart x) | (x, y) <- zip be ba]
              isMove (_, _, d) = d /= 0
       in if map content be == map content ba && not (null moved)
            then VFalse (Shifted moved)
            else VFalse (RgMismatch movedAlso (renderBlocks be) (renderBlocks ba))
  | otherwise = VFalse (Mismatch e a)
  where
    grouped ls
      | mentionsRgLineNumbers cmd = groupRg <$> parseRgOutput ls
      | otherwise = Nothing
    content b = (bFile b, bBody b)

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
