{-# LANGUAGE DerivingStrategies #-}

-- | Verdicts of a check, and how they are shown.
module Claims.Result
  ( Origin (..)
  , Reason (..)
  , MovedLine (..)
  , Verdict (..)
  , ClaimResult (..)
  , PrintMode (..)
  , allTrue
  , renderResults
  , renderShifted
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
  | -- | rg -n or sed -n output that holds the same lines, only at other
    -- line numbers: one row per output line.
    Shifted [MovedLine]
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

-- | One output line of a 'Shifted' claim: its file (none for single-file
-- rg output), expected and actual line number, and text.
data MovedLine = MovedLine
  { mlFile :: Maybe Text
  , mlOld :: Int
  , mlNew :: Int
  , mlText :: Text
  }
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
renderResults mode rs = T.unlines (intercalate [""] ([summary] : map render (filter shown rs) <> [[summary]]))
  where
    shown r = case (mode, resVerdict r) of
      (PrintAll, _) -> True
      (PrintTrue, VTrue) -> True
      (PrintFalse, VFalse _) -> True
      (PrintMinimal, VFalse _) -> True
      _ -> False
    summary =
      (if allTrue rs then "OK: " else "FAILED: ")
        <> tshow (count isTrue) <> " true, " <> tshow (count isFalse) <> " false"
        <> (if count isDrifted > 0 then ", " <> tshow (count isDrifted) <> " drifted" else "")
    count p = length (filter (p . resVerdict) rs)
    isTrue = (== VTrue)
    isDrifted = \case VFalse (Shifted _) -> True; _ -> False
    isFalse v = not (isTrue v || isDrifted v)
    render r =
      let ClaimsName n = resFile r
          ClaimId i = resId r
          label = n <> "#" <> i <> (if resOrigin r == Dependency then " (dep)" else "")
          traced = commandLines (resCmd r) <> outputLines (resOut r)
       in case (mode, resVerdict r) of
            (PrintMinimal, VFalse (Shifted _)) -> ("DRIFTED " <> label) : commandLines (resCmd r)
            (PrintMinimal, VFalse _) -> ("FALSE " <> label) : commandLines (resCmd r)
            (_, VTrue) -> ("TRUE  " <> label <> "  " <> resText r) : traced
            (_, VFalse (Shifted moved)) ->
              ("DRIFTED " <> label <> "  -- same lines, line numbers moved " <> offsets moved <> " (expacc fix-line-shift " <> n <> " to update)")
                : ("claim: " <> resText r)
                : commandLines (resCmd r)
                <> movedLines moved
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
      Shifted moved -> "same lines, line numbers moved " <> offsets moved
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
      RgMismatch e a -> "diff (command output was transformed: rg lines grouped into path:START-END blocks):" : renderDiff e a
      Shifted moved -> movedLines moved
      Reordered e a -> map (("    - " <>)) e <> map (("    + " <>)) a
      _ -> []

-- | @shifted LABEL  by +3@, then one row per moved output line.
renderShifted :: Text -> [MovedLine] -> [Text]
renderShifted label moved = ("shifted " <> label <> "  " <> offsets moved) : movedLines moved

-- | A note that the output is shown transformed, then aligned rows of
-- @path  OLD -> NEW  text@; a line that did not move shows only its number.
movedLines :: [MovedLine] -> [Text]
movedLines moved = "output (command output was transformed: one row per line, old -> new line number):" : map row moved
  where
    row m = "    " <> file m <> nums m <> "  " <> mlText m
    file m = maybe "" (\f -> padR wf f <> "  ") (mlFile m)
    nums m
      | mlOld m == mlNew m = padL (wo + 4 + wn) (tshow (mlNew m))
      | otherwise = padL wo (tshow (mlOld m)) <> " -> " <> padR wn (tshow (mlNew m))
    wf = maximum (0 : [T.length f | Just f <- map mlFile moved])
    wo = maximum (0 : map (T.length . tshow . mlOld) moved)
    wn = maximum (0 : map (T.length . tshow . mlNew) moved)
    padR w t = t <> T.replicate (w - T.length t) " "
    padL w t = T.replicate (w - T.length t) " " <> t

-- | @by +3@ when every moved line moved alike, else @(+3, -2)@.
offsets :: [MovedLine] -> Text
offsets moved = case nubOrd [mlNew m - mlOld m | m <- moved, mlNew m /= mlOld m] of
  [d] -> "by " <> signed d
  ds -> "(" <> T.intercalate ", " (map signed ds) <> ")"
  where
    signed d = (if d > 0 then "+" else "") <> tshow d

tshow :: Show a => a -> Text
tshow = cs . show

-- | Diff rows with two unchanged lines of context around each change.
renderDiff :: [Text] -> [Text] -> [Text]
renderDiff e a = intercalate ["      ..."] (map hunk (getContextDiff (Just 2) e a))
  where
    hunk = concatMap $ \case
      Both ls _ -> map (row "      ") ls
      First ls -> map (row "    - ") ls
      Second ls -> map (row "    + ") ls
    row prefix (Numbered _ t) = prefix <> t
