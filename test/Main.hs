module Main (main) where

import qualified Test.ClaimsTest as ClaimsTest
import qualified Test.LiveDocsConfigTest as LiveDocsConfigTest
import qualified Test.PruneTest as PruneTest
import Test.Hspec (hspec)

main :: IO ()
main = hspec (ClaimsTest.spec >> PruneTest.spec >> LiveDocsConfigTest.spec)
