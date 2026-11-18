{-# LANGUAGE DerivingStrategies #-}

-- | Line ranges printed with @sed -n 'A,Bp' FILE@, so a claim whose lines
-- only moved in the file can be told apart from one whose lines changed.
--
-- This is a heuristic: it applies only when the whole command is that one
-- @sed@ call. Anything else (pipes, more flags, several files) is not parsed.
module Claims.SedRange
  ( SedRange (..)
  , parseSedRange
  , shiftedRange
  , sedShift
  ) where

import Claims.Result (MovedLine (..))
import Control.Applicative ((<|>))
import Control.Exception (IOException, catch)
import Control.Monad (guard)
import qualified Data.ByteString as BS
import Data.Char (isAlphaNum, isDigit)
import Data.List (isPrefixOf, tails)
import Data.Maybe (fromMaybe)
import Data.String.Conversions (cs)
import Data.Text (Text)
import qualified Data.Text as T
import Text.Read (readMaybe)

-- | 'srScript' is the address as written (@36,41p@ or @36p@), without quotes.
data SedRange = SedRange
  { srStart :: Int
  , srEnd :: Int
  , srScript :: Text
  , srFile :: Text
  }
  deriving stock (Eq, Show)

-- | @sed -n 'A,Bp' FILE@ or @sed -n 'Ap' FILE@, quotes optional.
parseSedRange :: Text -> Maybe SedRange
parseSedRange cmd = case T.words cmd of
  ["sed", "-n", s, f] -> do
    let script = unquote s
        file = unquote f
    guard (not (T.null file) && T.all plain file)
    (a, b) <- case T.splitOn "," <$> T.stripSuffix "p" script of
      Just [x] -> (\n -> (n, n)) <$> num x
      Just [x, y] -> (,) <$> num x <*> num y
      _ -> Nothing
    guard (a >= 1 && a <= b)
    Just (SedRange a b script file)
  _ -> Nothing
  where
    num t = guard (not (T.null t) && T.all isDigit t) >> readMaybe (T.unpack t)
    unquote t = fromMaybe t (quoted "'" t <|> quoted "\"" t)
    quoted q t = T.stripPrefix q t >>= T.stripSuffix q
    plain c = isAlphaNum c || c `elem` ("/._-+" :: String)

-- | The expected lines sit, unchanged, at exactly one other place in the
-- file: one row per line and the command with the new range.
shiftedRange :: Text -> [Text] -> [Text] -> Maybe ([MovedLine], Text)
shiftedRange cmd expect fileLines = do
  sr <- parseSedRange cmd
  guard (not (null expect))
  start <- case [i | (i, rest) <- zip [1 ..] (tails fileLines), expect `isPrefixOf` rest] of
    [i] | i /= srStart sr -> Just i
    _ -> Nothing
  let end = start + length expect - 1
      script
        | T.any (== ',') (srScript sr) = tshow start <> "," <> tshow end <> "p"
        | otherwise = tshow start <> "p"
      -- The script is the first place its text can occur: @sed -n@ holds no digit.
      (before, after) = T.breakOn (srScript sr) cmd
  Just
    ( [MovedLine (Just (srFile sr)) (srStart sr + k) (start + k) t | (k, t) <- zip [0 ..] expect]
    , before <> script <> T.drop (T.length (srScript sr)) after
    )
  where
    tshow = T.pack . show

-- | 'shiftedRange' against the file as it is now, read from the current directory.
sedShift :: Text -> [Text] -> IO (Maybe ([MovedLine], Text))
sedShift cmd expect = case parseSedRange cmd of
  Nothing -> pure Nothing
  Just sr -> do
    ls <- (T.lines . cs <$> BS.readFile (cs (srFile sr))) `catch` \(_ :: IOException) -> pure []
    pure (shiftedRange cmd expect ls)
