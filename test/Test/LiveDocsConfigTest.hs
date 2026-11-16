module Test.LiveDocsConfigTest (spec) where

import Control.Exception (IOException, bracket, catch)
import Data.Aeson (eitherDecodeStrict, encode, object, (.=))
import qualified Data.Aeson as A
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LBS
import Data.Either (isLeft)
import LiveDocs.Config
import System.Directory (createDirectory, doesFileExist, getTemporaryDirectory, removeDirectoryRecursive)
import System.FilePath ((</>))
import System.Posix.Process (getProcessID)
import Test.Hspec

withTmp :: (FilePath -> IO a) -> IO a
withTmp act = do
  tmp <- getTemporaryDirectory
  pid <- getProcessID
  let mk i = do
        let d = tmp </> ("livedocs-config-test-" <> show pid <> "-" <> show (i :: Int))
        ok <- (createDirectory d >> pure True) `catch` \(_ :: IOException) -> pure False
        if ok then pure d else mk (i + 1)
  bracket (mk 0) removeDirectoryRecursive act

spec :: Spec
spec = describe "live-docs config" $ do
  it "missing file is Right Nothing" $ withTmp $ \d ->
    readExploreLifetime d `shouldReturn` Right Nothing
  it "reads a digit string" $ withTmp $ \d -> do
    BS.writeFile (d </> ".live-docs-config.json") "{\"explore-lifetime\": \"432000\"}\n"
    readExploreLifetime d `shouldReturn` Right (Just 432000)
  it "reads a JSON number" $ withTmp $ \d -> do
    BS.writeFile (d </> ".live-docs-config.json") "{\"explore-lifetime\": 432000}\n"
    readExploreLifetime d `shouldReturn` Right (Just 432000)
  it "missing key is Right Nothing" $ withTmp $ \d -> do
    BS.writeFile (d </> ".live-docs-config.json") "{\"other\": 1}\n"
    readExploreLifetime d `shouldReturn` Right Nothing
  it "rejects zero, negative, and a non-numeric string" $ withTmp $ \d -> do
    let path = d </> ".live-docs-config.json"
    BS.writeFile path "{\"explore-lifetime\": 0}\n"
    readExploreLifetime d >>= (`shouldSatisfy` isLeft)
    BS.writeFile path "{\"explore-lifetime\": -1}\n"
    readExploreLifetime d >>= (`shouldSatisfy` isLeft)
    BS.writeFile path "{\"explore-lifetime\": \"nope\"}\n"
    readExploreLifetime d >>= (`shouldSatisfy` isLeft)
  it "converts days" $ do
    daysToSeconds 1 `shouldBe` Right 86400
    daysToSeconds 0 `shouldSatisfy` isLeft
  it "writes a JSON string and keeps other keys" $ withTmp $ \d -> do
    writeExploreLifetime d 86400 `shouldReturn` Right ()
    bs <- BS.readFile (d </> ".live-docs-config.json")
    case eitherDecodeStrict bs of
      Right (A.Object o) -> KM.lookup "explore-lifetime" o `shouldBe` Just (A.String "86400")
      other -> expectationFailure (show other)
    readExploreLifetime d `shouldReturn` Right (Just 86400)
    BS.writeFile (d </> ".live-docs-config.json") (LBS.toStrict (encode (object ["explore-lifetime" .= ("1" :: String), "other" .= True])) <> "\n")
    writeExploreLifetime d 86400 `shouldReturn` Right ()
    bs2 <- BS.readFile (d </> ".live-docs-config.json")
    case eitherDecodeStrict bs2 of
      Right (A.Object o) -> do
        KM.lookup "explore-lifetime" o `shouldBe` Just (A.String "86400")
        KM.lookup "other" o `shouldBe` Just (A.Bool True)
      other -> expectationFailure (show other)
  it "write of 0 does not create a file" $ withTmp $ \d -> do
    writeExploreLifetime d 0 >>= (`shouldSatisfy` isLeft)
    doesFileExist (d </> ".live-docs-config.json") `shouldReturn` False
