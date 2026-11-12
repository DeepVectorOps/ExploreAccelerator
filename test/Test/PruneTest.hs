module Test.PruneTest (spec) where

import Data.Either (isLeft)
import Prune
import Test.Hspec

doc :: Bool -> Doc
doc = Doc "d" 7200

spec :: Spec
spec = describe "prune" $ do
  describe "parseDuration" $ do
    it "accepts each unit" $
      mapM parseDuration ["7d", "1h", "30m", "45s"] `shouldBe` Right [604800, 3600, 1800, 45]
    it "rejects bad input" $
      mapM_ ((`shouldSatisfy` isLeft) . parseDuration) ["", "d", "7", "7x", "1h30m", "-1h", "1.5h", " 7d"]

  describe "parseRatio" $ do
    it "accepts [0,1]" $ mapM parseRatio ["0", "1", "0.5", ".25"] `shouldBe` Right [0, 1, 0.5, 0.25]
    it "rejects out of range and junk" $
      mapM_ ((`shouldSatisfy` isLeft) . parseRatio) ["1.1", "-0.1", "x", ""]

  describe "decide" $ do
    let older h = PruneOpts (Just (h * 3600)) Nothing False False
        inacc r = PruneOpts Nothing (Just r) False False
        both h r = PruneOpts (Just (h * 3600)) (Just r) False False
    it "older only" $ do
      decide (older 1) (doc True) Nothing `shouldBe` [Older]
      decide (older 3) (doc True) Nothing `shouldBe` []
    it "inaccurate only" $ do
      decide (inacc 0.5) (doc True) (Just (1, 4)) `shouldBe` [Inaccurate 1 4 0.5]
      decide (inacc 0.5) (doc True) (Just (2, 4)) `shouldBe` []
    it "zero claims qualify only when the ratio is positive" $ do
      decide (inacc 0.1) (doc True) (Just (0, 0)) `shouldBe` [Inaccurate 0 0 0.1]
      decide (inacc 0) (doc True) (Just (0, 0)) `shouldBe` []
    it "reports true/total against the cutoff" $
      renderWhy (Inaccurate 3 12 0.5) `shouldBe` "3/12 claims true, below 0.5"
    it "ANDs older and inaccurate" $ do
      decide (both 1 0.5) (doc True) (Just (1, 4)) `shouldBe` [Older, Inaccurate 1 4 0.5]
      decide (both 1 0.5) (doc True) (Just (4, 4)) `shouldBe` []
      decide (both 3 0.5) (doc True) Nothing `shouldBe` []
    it "skips the check for docs too young or without claims" $ do
      needsCheck (both 3 0.5) (doc True) `shouldBe` False
      needsCheck (both 1 0.5) (doc True) `shouldBe` True
      needsCheck (inacc 0.5) (doc False) `shouldBe` False
      needsCheck (older 1) (doc True) `shouldBe` False
    it "ignores docs without claims unless --delete-if-missing-claim" $ do
      decide (both 1 1) (doc False) Nothing `shouldBe` []
      decide (PruneOpts Nothing Nothing True False) (doc False) Nothing `shouldBe` [MissingClaims]
      decide (PruneOpts Nothing Nothing True False) (doc True) Nothing `shouldBe` []
