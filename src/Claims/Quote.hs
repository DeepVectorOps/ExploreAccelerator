module Claims.Quote (quoteArgv) where

import Data.Char (isAlphaNum)
import Data.Text (Text)
import qualified Data.Text as T

-- | One bash word per argument, so an argv runs as it would unshelled.
quoteArgv :: [Text] -> Text
quoteArgv = T.unwords . map quote
  where
    quote w
      | not (T.null w) && T.all plain w = w
      | otherwise = "'" <> T.replace "'" "'\\''" w <> "'"
    plain c = isAlphaNum c || c `elem` ("-_./=:,@%+" :: String)
