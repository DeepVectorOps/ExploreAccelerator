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
  , driftedLines
  , renderLineMap
  , movedLinesJsonl
  , renderDiff
  ) where

import Claims.Name
import Data.Aeson (encode, object, (.=))
import Data.Algorithm.Diff (PolyDiff (..))
import Data.Aeson (encode, object, (.=))
import Data.Algorithm.DiffContext (Numbered (..), getContextDiff)
import Data.Containers.ListUtils (nubOrd)
import Data.List (groupBy, intercalate, sortOn)
import qualified Data.Map.Strict as Map
import Data.Function (on)
import Data.String.Conversions (cs)
import Data.Maybe (fromMaybe)
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

-- | One output line of a 'Shifted' claim: its file ('Nothing' only when rg
-- printed no path and the command names no single file), expected and
-- actual line number, and text.
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
renderResults mode rs = T.unlines (intercalate [""] ([summary] : map render (filter shown rs) <> lineMap <> [[summary]]))
  where
    lineMap
      | mode == PrintMinimal || null (driftedLines rs) = []
      | otherwise = [renderLineMap (driftedLines rs)]
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
movedLines moved = "output (command output was transformed: one row per line, path  old -> new line number):" : map row moved
  where
    row m = "    " <> padR wf (fileOf m) <> "  " <> nums m <> "  " <> mlText m
    nums m
      | mlOld m == mlNew m = padL (wo + 4 + wn) (tshow (mlNew m))
      | otherwise = padL wo (tshow (mlOld m)) <> " -> " <> padR wn (tshow (mlNew m))
    wf = maximum (0 : map (T.length . fileOf) moved)
    wo = maximum (0 : map (T.length . tshow . mlOld) moved)
    wn = maximum (0 : map (T.length . tshow . mlNew) moved)

-- | The path, or a marker when the command did not name one file.
fileOf :: MovedLine -> Text
fileOf = fromMaybe unknownFile . mlFile

unknownFile :: Text
unknownFile = "(file unknown: rg printed no path and the command names no single file)"

padR, padL :: Int -> Text -> Text
padR w t = t <> T.replicate (w - T.length t) " "
padL w t = T.replicate (w - T.length t) " " <> t

-- | Every drifted claim as @file#id@ and its moved lines.
driftedLines :: [ClaimResult] -> [(Text, [MovedLine])]
driftedLines rs = [(claimLabel r, moved) | r@ClaimResult {resVerdict = VFalse (Shifted moved)} <- rs]
  where
    claimLabel r = let ClaimsName n = resFile r; ClaimId i = resId r in n <> "#" <> i

-- | All moved lines of all claims merged per file and sorted by old line:
-- the offset ranges, then one row per old -> new pair with the claims that
-- saw it. Two claims that disagree on an old line are marked CONFLICT.
renderLineMap :: [(Text, [MovedLine])] -> [Text]
renderLineMap claims =
  "line map (every line of the drifted claims above, merged per file; old -> new):"
    : concatMap file (Map.toList byFile)
    <> [ "Only the lines listed are known. A cited line that is not listed may have moved by"
       , "another offset or changed: find it again (rg -n 'its text' PATH), never interpolate"
       , "between listed lines or extend an offset range past its listed ends."
       ]
  where
    byFile = Map.fromListWith (\new old -> Map.unionWith (<>) old new) [(fileOf m, Map.singleton (mlOld m, mlNew m) [c]) | (c, ms) <- claims, m <- ms]
    file (f, pairs) =
      let rows = [(o, n, nubOrd cs') | ((o, n), cs') <- Map.toList pairs]
          news = Map.fromListWith (<>) [(o, [n]) | (o, n, _) <- rows]
          conflict o = maybe False ((> 1) . length) (Map.lookup o news)
          wo = maximum (0 : [T.length (tshow o) | (o, _, _) <- rows])
          wn = maximum (0 : [T.length (tshow n) | (_, n, _) <- rows])
          runs = groupBy ((==) `on` delta) rows
          delta (o, n, _) = n - o
          range r = case (r, last r) of
            ((o, _, _) : _, (o', _, _))
              | o == o' -> "line " <> tshow o <> ": " <> signed (delta (head r))
              | otherwise -> "lines " <> tshow o <> "-" <> tshow o' <> ": " <> signed (delta (head r))
            _ -> ""
          row (o, n, cs') =
            "    " <> padL wo (tshow o) <> " -> " <> padR wn (tshow n) <> "  " <> padL 4 (signed (n - o))
              <> "  " <> T.intercalate ", " cs' <> (if conflict o then "  CONFLICT: claims disagree on this line" else "")
       in ("  " <> f) : ("    offsets (listed lines only): " <> T.intercalate ", " (map range runs)) : map row rows

-- | One JSON object per moved line: @{path, old, new, claim, text}@, path
-- @null@ when unknown.
movedLinesJsonl :: [(Text, [MovedLine])] -> [Text]
movedLinesJsonl claims =
  [ cs (encode (object ["path" .= mlFile m, "old" .= mlOld m, "new" .= mlNew m, "claim" .= c, "text" .= mlText m]))
  | (c, ms) <- claims
  , m <- ms
  ]

-- | @by +3@ when every moved line moved alike, else @(+3, -2)@.
offsets :: [MovedLine] -> Text
offsets moved = case nubOrd [mlNew m - mlOld m | m <- moved, mlNew m /= mlOld m] of
  [d] -> "by " <> signed d
  ds -> "(" <> T.intercalate ", " (map signed ds) <> ")"


signed :: Int -> Text
signed d = (if d >= 0 then "+" else "") <> tshow d

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
