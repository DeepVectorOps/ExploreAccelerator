{-# LANGUAGE DerivingStrategies #-}

-- | Replayable "claims" written by explore agents: a statement, a
-- command and its expected output. A claim holds while replaying the command
-- yields exactly the same output.
module Claims
  ( ClaimId (..)
  , ClaimsName (..)
  , Claim (..)
  , ClaimsFile (..)
  , DepRef (..)
  , Header (..)
  , emptyHeader
  , Origin (..)
  , Reason (..)
  , Verdict (..)
  , ClaimResult (..)
  , PrintMode (..)
  , resolveExploreDir
  , parseClaimsName
  , parseDepRef
  , claimsPath
  , parseClaimsFile
  , checkClaims
  , renderResults
  , allTrue
  , lintFile
  , runCmd
  , claimsDir
  , renderDiff
  ) where

import Control.Exception (IOException, try)
import Control.Monad (filterM, forM_, unless, when)
import Data.Aeson
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import Data.Aeson.Types (parseEither)
import Data.Bifunctor (first)
import qualified Data.ByteString as BS
import Data.IORef
import Data.Algorithm.Diff (PolyDiff (..))
import Data.Algorithm.DiffContext (Numbered (..), getContextDiff)
import Data.List (intercalate, isSuffixOf, sort)
import Data.Maybe (fromMaybe, listToMaybe)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.String.Conversions (cs)
import Data.Text (Text)
import qualified Data.Text as T
import System.Directory (doesDirectoryExist, doesFileExist, listDirectory)
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..))
import System.FilePath (takeFileName, (</>))
import System.Process (proc, readCreateProcessWithExitCode)

newtype ClaimId = ClaimId Text
  deriving newtype (Eq, Ord, Show, FromJSON, ToJSON)

newtype ClaimsName = ClaimsName Text
  deriving newtype (Eq, Ord, Show)

data Claim = Claim
  { claimId :: ClaimId
  , claimText :: Text
  , claimCmd :: [Text]
  , claimExpect :: Maybe [Text]
  }
  deriving stock (Eq, Show)

instance FromJSON Claim where
  parseJSON = withObject "Claim" $ \o ->
    Claim <$> o .: "id" <*> o .: "text" <*> o .: "cmd" <*> o .:? "expect"

claimPairs :: KeyValue e kv => Claim -> [kv]
claimPairs Claim {..} =
  ["id" .= claimId, "text" .= claimText, "cmd" .= claimCmd] <> ["expect" .= e | Just e <- [claimExpect]]

instance ToJSON Claim where
  toJSON = object . claimPairs
  toEncoding = pairs . mconcat . claimPairs

data DepRef = WholeFile ClaimsName | OneClaim ClaimsName ClaimId
  deriving stock (Eq, Show)

instance FromJSON DepRef where
  parseJSON = withText "DepRef" (pure . parseDepRef)

instance ToJSON DepRef where
  toJSON = \case
    WholeFile (ClaimsName n) -> String n
    OneClaim (ClaimsName n) (ClaimId i) -> String (n <> "#" <> i)

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

data Origin = Target | Dependency
  deriving stock (Eq, Show)

data Reason
  = Mismatch [Text] [Text]
  | Reordered [Text] [Text]
  | NotRecorded
  | Rejected Text
  | ExecFailed Text
  | MissingDep Text
  | BadFile Text
  | Lint Text
  deriving stock (Eq, Show)

data Verdict = VTrue | VFalse Reason
  deriving stock (Eq, Show)

data ClaimResult = ClaimResult
  { resFile :: ClaimsName
  , resId :: ClaimId
  , resText :: Text
  , resOrigin :: Origin
  , resVerdict :: Verdict
  }
  deriving stock (Eq, Show)

data PrintMode = PrintAll | PrintTrue | PrintFalse
  deriving stock (Eq, Show)

resolveExploreDir :: IO FilePath
resolveExploreDir = fromMaybe "./live-docs/explore" <$> lookupEnv "EXPACC_DIR"

-- | Accepts @foo@, @foo.claims.jsonl@ or @foo.md@.
parseClaimsName :: Text -> ClaimsName
parseClaimsName t = ClaimsName $ fromMaybe t (listToMaybe [b | s <- [".claims.jsonl", ".md"], Just b <- [T.stripSuffix s t]])

claimsPath :: FilePath -> ClaimsName -> FilePath
claimsPath dir (ClaimsName n) = claimsDir dir </> cs n <> ".claims.jsonl"

claimsDir :: FilePath -> FilePath
claimsDir dir = dir </> "claims"

parseDepRef :: Text -> DepRef
parseDepRef t = case T.breakOn "#" t of
  (n, "") -> WholeFile (parseClaimsName n)
  (n, i) -> OneClaim (parseClaimsName n) (ClaimId (T.drop 1 i))

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
    <> [ "claim " <> i <> ": cmd is run without a shell, but contains " <> t
       | Claim {claimId = ClaimId i, claimCmd = cmd} <- claims
       , t <- take 1 [t | t <- cmd, t `elem` shellTokens] <> take 1 [h | h : _ <- [cmd], h `elem` shells]
       ]
  where
    counts = Map.toList (Map.fromListWith (+) [(claimId c, 1) | c <- claims])
    shellTokens = ["|", "||", "&&", ";", ">", ">>", "<", "2>&1", "2>/dev/null"]
    shells = ["sh", "bash", "zsh"]

parseClaimsFile :: FilePath -> Text -> Either String ClaimsFile
parseClaimsFile path txt = do
  ls <- parseLines path txt
  pure
    ClaimsFile
      { cfHeader = fromMaybe emptyHeader (listToMaybe [h | LHeader h _ <- ls])
      , cfClaims = [c | LClaim c <- ls]
      , cfProblems = problemsOf (concat [u | LHeader _ u <- ls]) [c | LClaim c <- ls]
      }

splitCmd :: [Text] -> Either Text (String, [String])
splitCmd = \case
  [] -> Left "empty command"
  c : args -> Right (cs c, cs <$> args)

-- | Raw stdout lines. Exit 1 (no matches) is fine; exit >= 2 or exec failure is not.
runCmd :: [Text] -> IO (Either Reason [Text])
runCmd argv = case splitCmd argv of
  Left why -> pure (Left (Rejected why))
  Right (c, args) ->
    try (readCreateProcessWithExitCode (proc c args) "") >>= \case
      Left e -> pure (Left (ExecFailed (cs (show (e :: IOException)))))
      Right (ExitFailure n, _, err) | n >= 2 -> pure (Left (ExecFailed (T.strip (cs err))))
      Right (_, out, _) -> pure (Right (T.lines (cs out)))

verdictFor :: Claim -> IO Verdict
verdictFor c = case claimExpect c of
  Nothing -> pure (VFalse NotRecorded)
  Just ex ->
    either VFalse (compareLines ex) <$> runCmd (claimCmd c)
  where
    compareLines e a
      | e == a = VTrue
      | sort e == sort a = VFalse (Reordered e a)
      | otherwise = VFalse (Mismatch e a)

-- | Reads @claims/NAME.claims.jsonl@. When there is none, falls back to the
-- file whose @doc@ header is @NAME.md@.
readClaimsFile :: FilePath -> ClaimsName -> IO (Either Reason ClaimsFile)
readClaimsFile dir name@(ClaimsName n) = do
  direct <- doesFileExist (claimsPath dir name)
  if direct
    then load (claimsPath dir name)
    else findByDoc dir (n <> ".md") >>= maybe (Left . MissingDep <$> notFound dir name) load
  where
    load path = first (BadFile . cs) . parseClaimsFile path . cs <$> BS.readFile path

-- | Claims files in @claims/@, sorted.
listClaimsFiles :: FilePath -> IO [FilePath]
listClaimsFiles dir = do
  let cdir = claimsDir dir
  doesDirectoryExist cdir >>= \case
    False -> pure []
    True -> map (cdir </>) . sort . filter (".claims.jsonl" `isSuffixOf`) <$> listDirectory cdir

findByDoc :: FilePath -> Text -> IO (Maybe FilePath)
findByDoc dir doc = do
  paths <- listClaimsFiles dir
  hits <- filterM (fmap (maybe False ((== Just doc) . hDoc . cfHeader)) . header) paths
  pure (listToMaybe hits)
  where
    header p = either (const Nothing) Just . parseClaimsFile p . cs <$> BS.readFile p

notFound :: FilePath -> ClaimsName -> IO Text
notFound dir name = do
  have <- map (T.dropEnd (T.length ".claims.jsonl") . cs . takeFileName) <$> listClaimsFiles dir
  let avail
        | null have = "none"
        | otherwise = T.intercalate ", " (take 10 have) <> (if length have > 10 then ", ..." else "")
  pure ("no such file " <> cs (claimsPath dir name) <> " (claims files in " <> cs (claimsDir dir) <> ": " <> avail <> ")")

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
    Left r -> emit (ClaimId (maybe "*" (\(ClaimId i) -> i) only)) "" (VFalse r)
    Right cf -> do
      let picked = [c | c <- cfClaims cf, maybe True (== claimId c) only]
      when (null picked) $ forM_ only $ \i -> emit i "" (VFalse (MissingDep "no such claim"))
      forM_ picked $ \c -> once (envClaims env) (name, claimId c) $
        verdictFor c >>= emit (claimId c) (claimText c)
      once (envFiles env) name $ do
       forM_ (cfProblems cf) $ \p -> emit (ClaimId "lint") "" (VFalse (Lint p))
       forM_ (hDepends (cfHeader cf)) $ \case
         WholeFile n -> visit env Dependency Nothing n
         OneClaim n i -> visit env Dependency (Just i) n
  where
    emit i t v = modifyIORef (envOut env) (ClaimResult name i t origin v :)
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

allTrue :: [ClaimResult] -> Bool
allTrue = all ((== VTrue) . resVerdict)

renderResults :: PrintMode -> [ClaimResult] -> Text
renderResults mode rs = T.unlines (concatMap render (filter shown rs) <> [summary])
  where
    shown r = case (mode, resVerdict r) of
      (PrintAll, _) -> True
      (PrintTrue, VTrue) -> True
      (PrintFalse, VFalse _) -> True
      _ -> False
    summary = (if allTrue rs then "OK: " else "FAILED: ") <> cs (show (count True) <> " true, " <> show (count False) <> " false")
    count b = length [() | r <- rs, (resVerdict r == VTrue) == b]
    render r =
      let ClaimsName n = resFile r
          ClaimId i = resId r
          label = n <> "#" <> i <> (if resOrigin r == Dependency then " (dep)" else "")
       in case resVerdict r of
            VTrue -> ["TRUE  " <> label <> "  " <> resText r]
            VFalse why ->
              ("FALSE " <> label <> "  " <> resText r <> "  -- " <> reasonText why)
                : diffLines why
    reasonText = \case
      Mismatch {} -> "output differs"
      Reordered {} -> "same lines, different order (sort the output, e.g. rg --sort path)"
      NotRecorded -> "no expect recorded"
      Rejected t -> "rejected: " <> t
      ExecFailed t -> "exec failed: " <> t
      MissingDep t -> "missing dependency: " <> t
      BadFile t -> t
      Lint t -> "lint: " <> t
    diffLines = \case
      Mismatch e a -> renderDiff e a
      Reordered e a -> map (("    - " <>)) e <> map (("    + " <>)) a
      _ -> []

-- | Diff rows with two unchanged lines of context around each change.
renderDiff :: [Text] -> [Text] -> [Text]
renderDiff e a = intercalate ["      ..."] (map hunk (getContextDiff (Just 2) e a))
  where
    hunk = concatMap $ \case
      Both ls _ -> map (row "      ") ls
      First ls -> map (row "    - ") ls
      Second ls -> map (row "    + ") ls
    row prefix (Numbered _ t) = prefix <> t
