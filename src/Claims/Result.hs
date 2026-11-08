{-# LANGUAGE DerivingStrategies #-}

-- | Verdicts of a check, and how they are shown.
module Claims.Result
  ( Origin (..)
  , Reason (..)
  , Verdict (..)
  , ClaimResult (..)
  , PrintMode (..)
  , allTrue
  , renderResults
  , renderDiff
  ) where

import Claims.Name
import Data.Algorithm.Diff (PolyDiff (..))
import Data.Algorithm.DiffContext (Numbered (..), getContextDiff)
import Data.List (intercalate)
import Data.String.Conversions (cs)
import Data.Text (Text)
import qualified Data.Text as T

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
  , resCmd :: Maybe Text
  , resOut :: Maybe [Text]
  }
  deriving stock (Eq, Show)

data PrintMode = PrintAll | PrintTrue | PrintFalse
  deriving stock (Eq, Show)

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
          traced = commandLines (resCmd r) <> outputLines (resOut r)
       in case resVerdict r of
            VTrue -> ("TRUE  " <> label <> "  " <> resText r) : traced
            VFalse why ->
              ("FALSE " <> label <> "  " <> resText r <> "  -- " <> reasonText (resOrigin r) why)
                : traced
                <> diffLines why
    commandLines = \case
      Nothing -> []
      Just cmd -> case T.lines cmd of
        [] -> ["command:"]
        ls -> map ("command: " <>) ls
    outputLines = \case
      Nothing -> []
      Just [] -> ["output:"]
      Just ls -> map ("output: " <>) ls
    reasonText origin = \case
      Mismatch {} -> "output differs"
      Reordered {} -> "same lines, different order (sort the output, e.g. rg --sort path)"
      NotRecorded -> "no expect recorded"
      Rejected t -> "rejected: " <> t
      ExecFailed t -> "exec failed: " <> t
      MissingDep t ->
        (if origin == Dependency then "missing dependency: " else "") <> t
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
