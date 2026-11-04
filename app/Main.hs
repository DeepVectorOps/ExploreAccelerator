module Main (main) where

import Claims
import Record
import Data.List (partition)
import Data.String.Conversions (cs)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import GHC.IO.Encoding (setLocaleEncoding, utf8)
import System.Environment (getArgs)
import System.Exit (ExitCode (..), exitWith)
import System.IO (stderr)

usage :: Text
usage =
  T.unlines
    [ "usage: expacc check NAME... [--print-all | --print-true | --print-false]"
    , "       expacc lint NAME..."
    , "       expacc record NAME --id ID --text TEXT [--doc D] [--commit C] [--depends DEP]... -- CMD"
    , "       expacc record-append NAME --id ID --text TEXT -- CMD"
    , "       expacc record-fix NAME ID"
    , "CMD is a bash string, run with bash -c; pipes and redirects work. Quote it as one argument."
    , "NAME is a slug (other, or other#id for one claim), resolved in $EXPACC_DIR/claims"
    , "(default ./live-docs/explore/claims). record runs CMD and stores its output as the"
    , "expected output; record creates the file, record-append adds a claim to it,"
    , "record-fix re-runs a claim and rewrites its expected output."
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

finish :: Either Text Text -> IO ()
finish = \case
  Right out -> TIO.putStr out
  Left err -> TIO.hPutStrLn stderr ("expacc: " <> err) >> exitWith (ExitFailure 1)

printFlags :: [(Text, PrintMode)]
printFlags = [("--print-all", PrintAll), ("--print-true", PrintTrue), ("--print-false", PrintFalse)]

-- | A bad name is a usage error (exit 2), not a failed check.
requireNames :: [Text] -> IO [ClaimsName]
requireNames ns = case traverse parseClaimsName ns of
  Left e -> TIO.hPutStrLn stderr ("expacc: " <> e) >> exitWith (ExitFailure 2)
  Right xs -> pure xs

main :: IO ()
main = do
  setLocaleEncoding utf8
  args <- map cs <$> getArgs
  dir <- resolveExploreDir
  case args of
    "check" : rest
      | (flags, names@(_ : _)) <- partition ("--" `T.isPrefixOf`) rest
      , Just modes <- mapM (`lookup` printFlags) flags -> do
          parsed <- requireNames names
          results <- checkClaims dir parsed
          TIO.putStr (renderResults (last (PrintFalse : modes)) results)
          exitWith (if allTrue results then ExitSuccess else ExitFailure 1)
    "lint" : names@(_ : _) -> do
      parsed <- requireNames names
      problems <- concat <$> mapM (\n -> map (\p -> let ClaimsName t = n in t <> ": " <> p) <$> lintFile dir n) parsed
      TIO.putStr (T.unlines (if null problems then ["OK: no problems"] else problems))
      exitWith (if null problems then ExitSuccess else ExitFailure 1)
    cmd : name : rest
      | cmd `elem` ["record", "record-append"]
      , (flagArgs, "--" : argv@(_ : _)) <- break (== "--") rest ->
          case parseFlags flagArgs >>= \f -> (f,) <$> newClaim f argv of
            Left err -> TIO.hPutStrLn stderr err >> exitWith (ExitFailure 2)
            Right (f, nc) -> case parseClaimsName name of
              Left e -> TIO.hPutStrLn stderr ("expacc: " <> e) >> exitWith (ExitFailure 2)
              Right n
                | cmd == "record" -> recordNew dir n (fHeader f) nc >>= finish
                | otherwise -> recordAppend dir n nc >>= finish
    ["record-fix", name, cid] -> case parseClaimsName name of
      Left e -> TIO.hPutStrLn stderr ("expacc: " <> e) >> exitWith (ExitFailure 2)
      Right n -> recordFix dir n cid >>= finish
    ["--help"] -> TIO.putStr usage
    [] -> TIO.putStr usage
    _ -> TIO.hPutStrLn stderr usage >> exitWith (ExitFailure 2)
