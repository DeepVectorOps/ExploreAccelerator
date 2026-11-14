{-# LANGUAGE DerivingStrategies #-}

-- | Grouping of ripgrep line-numbered output (@rg -n@) into blocks, so a
-- claim whose lines only moved can be told apart from one whose lines changed.
--
-- This is a heuristic: it applies only when the command looks like @rg -n@
-- and every output line parses as rg's format. Anything else falls back to
-- the plain line diff.
module Claims.RgGroup
  ( Block (..)
  , RgLine (..)
  , mentionsRgLineNumbers
  , parseRgOutput
  , groupRg
  , blockHeader
  , renderBlocks
  ) where

import Data.Char (isDigit, isSpace)
import Data.List (sortOn)
import qualified Data.Map.Strict as Map
import Data.Maybe (mapMaybe)
import Data.Ord (Down (..))
import Data.Text (Text)
import qualified Data.Text as T
import Text.Read (readMaybe)

-- | One parsed output line. 'rlFile' is 'Nothing' for single-file output
-- (@N:text@ / @N-text@).
data RgLine = RgLine
  { rlFile :: Maybe Text
  , rlNum :: Int
  , rlText :: Text
  }
  deriving stock (Eq, Show)

-- | Consecutive lines of one file with consecutive numbers.
data Block = Block
  { bFile :: Maybe Text
  , bStart :: Int
  , bEnd :: Int
  , bBody :: [Text]
  }
  deriving stock (Eq, Show)

-- | The command runs @rg@ with line numbers: an @rg@ word plus @-n@,
-- @--line-number@, or a short-flag cluster containing @n@ (@-nA5@, @-in@).
mentionsRgLineNumbers :: Text -> Bool
mentionsRgLineNumbers cmd = any isRg ws && any isN ws
  where
    ws = T.split (\c -> isSpace c || c `elem` ("|;&()`'\"" :: String)) cmd
    isRg w = w == "rg" || "/rg" `T.isSuffixOf` w
    isN w =
      w == "--line-number"
        || ( "-" `T.isPrefixOf` w
               && not ("--" `T.isPrefixOf` w)
               && T.length w > 1
               && T.all (\c -> isDigit c || c `elem` ['a' .. 'z'] || c `elem` ['A' .. 'Z']) (T.drop 1 w)
               && T.any (== 'n') (T.takeWhile (not . isDigit) (T.drop 1 w))
           )

-- | Parses every line, or gives 'Nothing' if any line is not rg output.
-- @--@ separators are dropped (blocks are split by line numbers anyway).
parseRgOutput :: [Text] -> Maybe [RgLine]
parseRgOutput ls =
  firstJust [multi True, single, multi False]
  where
    body = filter (/= "--") ls
    firstJust = foldr (\m acc -> maybe acc Just m) Nothing
    single = traverse singleLine body
    multi strict = do
      cands <- traverse (nonEmpty . multiCands) body
      let freq = Map.fromListWith (+) [(p, 1 :: Int) | cs <- cands, p <- dedup (map fst' cs)]
          score (p, _, _) = Map.findWithDefault 0 p freq
          -- The path most lines agree on wins. Paths sharing that count are
          -- prefixes of one another: prefer one without @:@ or whitespace
          -- (text after the real path can hold @:12:@ or @ -5- @), then the
          -- longest (the real path can hold @-1-@, as in @a-1-b.md@).
          key c@(p, _, _) = (Down (score c), T.any (== ':') p, T.any isSpace p, Down (T.length p))
          pick cs = case sortOn key cs of
            best : _ -> best
            [] -> error "unreachable"
          chosen = map pick cands
      if strict && not (all (plausible . fst') chosen)
        then Nothing
        else Just [RgLine (Just p) n t | (p, n, t) <- chosen]
    fst' (p, _, _) = p
    nonEmpty xs = if null xs then Nothing else Just xs
    dedup = Map.keys . Map.fromList . map (,())
    plausible p = (T.any (== '/') p || T.any (== '.') p) && not (startsNumColon p)
    startsNumColon p =
      let (d, r) = T.span isDigit p in not (T.null d) && ":" `T.isPrefixOf` r

-- | @N:text@ or @N-text@.
singleLine :: Text -> Maybe RgLine
singleLine l = do
  let (d, r) = T.span isDigit l
  n <- readMaybe (T.unpack d)
  (sep, t) <- T.uncons r
  if sep == ':' || sep == '-' then Just (RgLine Nothing n t) else Nothing

-- | Every split @path SEP N SEP text@ with SEP the same @:@ or @-@ on both
-- sides, leftmost first.
multiCands :: Text -> [(Text, Int, Text)]
multiCands l = mapMaybe at [i | (i, c) <- zip [0 ..] (T.unpack l), i > 0, c == ':' || c == '-']
  where
    at i = do
      let (p, rest) = T.splitAt i l
      (sep, r) <- T.uncons rest
      let (d, r') = T.span isDigit r
      n <- readMaybe (T.unpack d)
      (sep', t) <- T.uncons r'
      if sep' == sep then Just (p, n, t) else Nothing

-- | Lines of the same file with consecutive numbers form one block.
groupRg :: [RgLine] -> [Block]
groupRg = reverse . map finish . foldl step []
  where
    step (b : bs) (RgLine f n t)
      | bFile b == f && n == bEnd b + 1 = b {bEnd = n, bBody = t : bBody b} : bs
    step bs (RgLine f n t) = Block f n n [t] : bs
    finish b = b {bBody = reverse (bBody b)}

-- | @path:36-41@ / @path:36@, or @lines 36-41@ / @line 36@ for one file.
blockHeader :: Block -> Text
blockHeader Block {..} = case bFile of
  Just p -> p <> ":" <> range
  Nothing -> (if bStart == bEnd then "line " else "lines ") <> range
  where
    range
      | bStart == bEnd = tshow bStart
      | otherwise = tshow bStart <> "-" <> tshow bEnd
    tshow = T.pack . show

-- | Header line, then the body lines indented by two spaces.
renderBlocks :: [Block] -> [Text]
renderBlocks = concatMap (\b -> blockHeader b : map ("  " <>) (bBody b))
