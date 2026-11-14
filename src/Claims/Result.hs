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
import Data.Containers.ListUtils (nubOrd)
import Data.List (intercalate)
import Data.String.Conversions (cs)
import Data.Text (Text)
import qualified Data.Text as T

data Origin = Target | Dependency
  deriving stock (Eq, Show)

data Reason
  = Mismatch [Text] [Text]
  | Reordered [Text] [Text]
  | -- | rg -n output whose blocks hold the same lines, only at other line
    -- numbers: (expected header, actual header, offset) per moved block.
    Shifted [(Text, Text, Int)]
  | -- | rg -n output that changed: expected and actual grouped into blocks
    -- (see "Claims.RgGroup"), so the diff shows headers and changed lines.
    RgMismatch [Text] [Text]
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

data PrintMode = PrintAll | PrintTrue | PrintFalse | PrintMinimal
  deriving stock (Eq, Show)

allTrue :: [ClaimResult] -> Bool
allTrue = all ((== VTrue) . resVerdict)

renderResults :: PrintMode -> [ClaimResult] -> Text
renderResults mode rs = T.unlines (intercalate [""] (map render (filter shown rs) <> [[summary]]))
  where
    shown r = case (mode, resVerdict r) of
      (PrintAll, _) -> True
      (PrintTrue, VTrue) -> True
      (PrintFalse, VFalse _) -> True
      (PrintMinimal, VFalse _) -> True
      _ -> False
    summary = (if allTrue rs then "OK: " else "FAILED: ") <> cs (show (count True) <> " true, " <> show (count False) <> " false")
    count b = length [() | r <- rs, (resVerdict r == VTrue) == b]
    render r =
      let ClaimsName n = resFile r
          ClaimId i = resId r
          label = n <> "#" <> i <> (if resOrigin r == Dependency then " (dep)" else "")
          traced = commandLines (resCmd r) <> outputLines (resOut r)
       in case (mode, resVerdict r) of
            (PrintMinimal, VFalse _) -> ("FALSE " <> label) : commandLines (resCmd r)
            (_, VTrue) -> ("TRUE  " <> label <> "  " <> resText r) : traced
            (_, VFalse why) ->
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
      RgMismatch {} -> "output differs"
      Shifted moved -> "same lines, line numbers moved " <> offsets moved <> " (record-fix to update)"
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
      RgMismatch e a -> renderDiff e a
      Shifted moved -> concat [["    - " <> o, "    + " <> n] | (o, n, _) <- moved]
      Reordered e a -> map (("    - " <>)) e <> map (("    + " <>)) a
      _ -> []

-- | @by +3@ when every block moved alike, else @(+3, -2)@.
offsets :: [(Text, Text, Int)] -> Text
offsets moved = case nubOrd [d | (_, _, d) <- moved] of
  [d] -> "by " <> signed d
  ds -> "(" <> T.intercalate ", " (map signed ds) <> ")"
  where
    signed d = (if d > 0 then "+" else "") <> cs (show d)

-- | Diff rows with two unchanged lines of context around each change.
renderDiff :: [Text] -> [Text] -> [Text]
renderDiff e a = intercalate ["      ..."] (map hunk (getContextDiff (Just 2) e a))
  where
    hunk = concatMap $ \case
      Both ls _ -> map (row "      ") ls
      First ls -> map (row "    - ") ls
      Second ls -> map (row "    + ") ls
    row prefix (Numbered _ t) = prefix <> t
