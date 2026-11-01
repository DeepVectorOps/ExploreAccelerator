module Main (main) where

import qualified Test.ClaimsTest as ClaimsTest
import Test.Hspec (hspec)

main :: IO ()
main = hspec ClaimsTest.spec
