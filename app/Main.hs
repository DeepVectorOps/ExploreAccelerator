{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Claims
import Record
import Data.List (partition)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import GHC.IO.Encoding (setLocaleEncoding, utf8)
import System.Environment (getArgs)
import System.Exit (ExitCode (..), exitWith)
import System.IO (hPutStrLn, stderr)

usage :: Text
usage =
  T.unlines
    [ "usage: expacc check NAME... [--print-all | --print-true | --print-false]"
    , "       expacc lint NAME..."
    , "       expacc record NAME --id ID --text TEXT [--doc D] [--commit C] [--depends DEP]... -- CMD ARG..."
    , "       expacc record-append NAME --id ID --text TEXT -- CMD ARG..."
    , "       expacc record-fix NAME ID"
    , "NAME is foo, foo.claims.jsonl or foo.md, resolved in $EXPACC_DIR/claims"
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
parseFlags = go (Flags Nothing Nothing (Header Nothing Nothing []))
  where
    go f [] = Right f
    go f ("--id" : v : r) = go f {fId = Just v} r
    go f ("--text" : v : r) = go f {fText = Just v} r
    go f ("--doc" : v : r) = go f {fHeader = (fHeader f) {hDoc = Just v}} r
    go f ("--commit" : v : r) = go f {fHeader = (fHeader f) {hCommit = Just v}} r
    go f ("--depends" : v : r) = go f {fHeader = (fHeader f) {hDepends = hDepends (fHeader f) <> [v]}} r
    go _ (x : _) = Left ("unknown or incomplete option: " <> x)

newClaim :: Flags -> [Text] -> Either Text NewClaim
newClaim f cmd = case (fId f, fText f) of
  (Just i, Just t) -> Right (NewClaim i t cmd)
  _ -> Left "--id and --text are required"

finish :: Either Text Text -> IO ()
finish = \case
  Right out -> TIO.putStr out
  Left err -> TIO.hPutStrLn stderr ("expacc: " <> err) >> exitWith (ExitFailure 1)

printFlags :: [(Text, PrintMode)]
printFlags = [("--print-all", PrintAll), ("--print-true", PrintTrue), ("--print-false", PrintFalse)]

main :: IO ()
main = do
  setLocaleEncoding utf8
  args <- map T.pack <$> getArgs
  dir <- resolveExploreDir
  case args of
    "check" : rest
      | (flags, names@(_ : _)) <- partition ("--" `T.isPrefixOf`) rest
      , Just modes <- mapM (`lookup` printFlags) flags -> do
          results <- checkClaims dir (parseClaimsName <$> names)
          TIO.putStr (renderResults (last (PrintFalse : modes)) results)
          exitWith (if allTrue results then ExitSuccess else ExitFailure 1)
    "lint" : names@(_ : _) -> do
      problems <- concat <$> mapM (\n -> map (\p -> n <> ": " <> p) <$> lintFile dir (parseClaimsName n)) names
      TIO.putStr (T.unlines (if null problems then ["OK: no problems"] else problems))
      exitWith (if null problems then ExitSuccess else ExitFailure 1)
    cmd : name : rest
      | cmd `elem` ["record", "record-append"]
      , (flagArgs, "--" : argv@(_ : _)) <- break (== "--") rest ->
          case parseFlags flagArgs >>= \f -> (f,) <$> newClaim f argv of
            Left err -> hPutStrLn stderr (T.unpack err) >> exitWith (ExitFailure 2)
            Right (f, nc)
              | cmd == "record" -> recordNew dir (parseClaimsName name) (fHeader f) nc >>= finish
              | otherwise -> recordAppend dir (parseClaimsName name) nc >>= finish
    ["record-fix", name, cid] -> recordFix dir (parseClaimsName name) cid >>= finish
    ["--help"] -> TIO.putStr usage
    [] -> TIO.putStr usage
    _ -> hPutStrLn stderr (T.unpack usage) >> exitWith (ExitFailure 2)
