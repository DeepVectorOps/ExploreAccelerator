module Main (main) where

import Claims
import Prune
import Record
import Control.Monad (unless)
import Data.List (partition)
import Data.String.Conversions (cs)
import Data.Text (Text)
import Data.Time (getCurrentTime)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import GHC.IO.Encoding (setLocaleEncoding, utf8)
import System.Directory (doesDirectoryExist)
import System.Environment (getArgs)
import System.Exit (ExitCode (..), exitWith)
import System.IO (stderr)

usage :: Text
usage =
  T.unlines
    [ "usage: expacc check NAME... [--print-all | --print-true | --print-false | --minimal-output]"
    , "       shown claims print command: and output: lines"
    , "       --minimal-output prints only the totals, plus FALSE id and command of each false claim"
    , "       expacc lint NAME..."
    , "       expacc record NAME --id ID --text TEXT [--doc D] [--commit C] [--depends DEP]... -- CMD"
    , "       expacc record-append NAME --id ID --text TEXT -- CMD"
    , "       expacc record-fix NAME ID"
    , "       expacc prune [--dry-run] [--delete-if-older DUR] [--delete-if-inaccurate RATIO] [--delete-if-missing-claim]"
    , "CMD is a bash string, run with bash -c; pipes and redirects work. Quote it as one argument."
    , "NAME is a slug (other, or other#id for one claim), resolved in $EXPACC_DIR/claims"
    , "(default ./live-docs/explore/claims). record runs CMD and stores its output as the"
    , "expected output; record creates the file, record-append adds a claim to it,"
    , "record-fix re-runs a claim and rewrites its expected output."
    , "prune deletes docs (and their claims) that are older than DUR (7d, 1h, 30m, 45s) AND"
    , "have a true-claim ratio below RATIO, or that have no claims file."
    , "--delete-if-older also filters --delete-if-missing-claim when both are given."
    , "--dry-run lists the files that would be removed and deletes nothing."
    , "Each deleted doc prints the reasons and the files removed."
    , "A low true-claim ratio is reported as T/N claims true, below RATIO (true/total, not inaccurate/total)."
    ]

data Flags = Flags
  { fId :: Maybe Text
  , fText :: Maybe Text
  , fHeader :: Header
  }

parseFlags :: [Text] -> Either Text Flags
parseFlags = go (Flags Nothing Nothing emptyHeader)
  where
    go f [] = Right f
    go f ("--id" : v : r) = go f {fId = Just v} r
    go f ("--text" : v : r) = go f {fText = Just v} r
    go f ("--doc" : v : r) = go f {fHeader = (fHeader f) {hDoc = Just v}} r
    go f ("--commit" : v : r) = go f {fHeader = (fHeader f) {hCommit = Just v}} r
    go f ("--depends" : v : r) = case parseDepRef v of
      Left e -> Left e
      Right d -> go f {fHeader = (fHeader f) {hDepends = hDepends (fHeader f) <> [d]}} r
    go _ (x : _) = Left ("unknown or incomplete option: " <> x)

newClaim :: Flags -> [Text] -> Either Text NewClaim
newClaim f cmd = case (fId f, fText f) of
  (Just i, Just t) -> Right (NewClaim i t (cmdOf cmd))
  _ -> Left "--id and --text are required"

-- | One argument is a raw bash string; several are an argv, quoted into one.
cmdOf :: [Text] -> Text
cmdOf [c] = c
cmdOf argv = quoteArgv argv

parsePruneOpts :: [Text] -> Either Text PruneOpts
parsePruneOpts = go (PruneOpts Nothing Nothing False False)
  where
    go o [] = Right o
    go o ("--dry-run" : r) = go o {poDryRun = True} r
    go o ("--delete-if-older" : v : r) = parseDuration v >>= \d -> go o {poOlder = Just d} r
    go o ("--delete-if-inaccurate" : v : r) = parseRatio v >>= \x -> go o {poInaccurate = Just x} r
    go o ("--delete-if-missing-claim" : r) = go o {poMissing = True} r
    go _ (x : _) = Left ("unknown or incomplete option: " <> x)

prune :: FilePath -> PruneOpts -> IO ()
prune dir o = do
  docs <- listDocs dir =<< getCurrentTime
  deleted <- fmap concat . mapM pruneOne $ docs
  TIO.putStrLn (cs (show (length deleted)) <> " deleted")
  where
    pruneOne d = do
      score <- if needsCheck o d then Just . scoreOf <$> checkClaims dir [ClaimsName (docSlug d)] else pure Nothing
      case decide o d score of
        [] -> pure []
        whys -> do
          files <- if poDryRun o then filesToDelete dir d else deleteDoc dir d
          let verb = if poDryRun o then "would delete " else "deleted "
          TIO.putStrLn (verb <> docSlug d <> " (" <> T.intercalate ", " (map renderWhy whys) <> ")")
          mapM_ (TIO.putStrLn . ("  " <>) . cs) files
          pure [d]

finish :: Either Text Text -> IO ()
finish = \case
  Right out -> TIO.putStr out
  Left err -> TIO.hPutStrLn stderr ("expacc: " <> err) >> exitWith (ExitFailure 1)

printFlags :: [(Text, PrintMode)]
printFlags = [("--print-all", PrintAll), ("--print-true", PrintTrue), ("--print-false", PrintFalse), ("--minimal-output", PrintMinimal)]

-- | A bad name is a usage error (exit 2), not a failed check.
usageError :: Text -> IO a
usageError e = TIO.hPutStrLn stderr ("expacc: " <> e) >> exitWith (ExitFailure 2)

requireName :: Text -> IO ClaimsName
requireName = either usageError pure . parseClaimsName

-- | A missing explore dir means the command was not run from the repo root
-- (or EXPACC_DIR is wrong), not that the named claims files are absent.
requireExploreDir :: FilePath -> IO ()
requireExploreDir dir = do
  ok <- doesDirectoryExist dir
  unless ok $ TIO.hPutStrLn stderr (missingExploreDir dir) >> exitWith (ExitFailure 1)

missingExploreDir :: FilePath -> Text
missingExploreDir dir
  | dir == "./live-docs/explore" =
      "no live-docs/explore/ dir found check if run from correct place."
  | otherwise =
      "no " <> cs dir <> "/ dir found check if run from correct place."

main :: IO ()
main = do
  setLocaleEncoding utf8
  args <- map cs <$> getArgs
  dir <- resolveExploreDir
  case args of
    "check" : rest
      | (flags, names@(_ : _)) <- partition ("--" `T.isPrefixOf`) rest
      , Just modes <- mapM (`lookup` printFlags) flags -> do
          requireExploreDir dir
          parsed <- traverse requireName names
          results <- checkClaims dir parsed
          TIO.putStr (renderResults (last (PrintFalse : modes)) results)
          exitWith (if allTrue results then ExitSuccess else ExitFailure 1)
    "lint" : names@(_ : _) -> do
      requireExploreDir dir
      parsed <- traverse requireName names
      problems <- concat <$> mapM (\n -> map (\p -> let ClaimsName t = n in t <> ": " <> p) <$> lintFile dir n) parsed
      TIO.putStr (T.unlines (if null problems then ["OK: no problems"] else problems))
      exitWith (if null problems then ExitSuccess else ExitFailure 1)
    cmd : name : rest
      | cmd `elem` ["record", "record-append"]
      , (flagArgs, "--" : argv@(_ : _)) <- break (== "--") rest ->
          case parseFlags flagArgs >>= \f -> (f,) <$> newClaim f argv of
            Left err -> TIO.hPutStrLn stderr err >> exitWith (ExitFailure 2)
            Right (f, nc) -> do
              n <- requireName name
              (if cmd == "record" then recordNew dir n (fHeader f) nc else recordAppend dir n nc) >>= finish
    ["record-fix", name, cid] -> requireName name >>= \n -> recordFix dir n cid >>= finish
    "prune" : flags@(_ : _) -> do
      o <- either usageError pure (parsePruneOpts flags)
      requireExploreDir dir
      prune dir o
    ["--help"] -> TIO.putStr usage
    [] -> TIO.putStr usage
    _ -> TIO.hPutStrLn stderr usage >> exitWith (ExitFailure 2)
