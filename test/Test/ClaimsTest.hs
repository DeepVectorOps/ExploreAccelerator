module Test.ClaimsTest (spec) where

import Claims
import Record
import Control.Concurrent (forkIO, newEmptyMVar, putMVar, takeMVar)
import Control.Exception (IOException, SomeException, bracket, catch, finally, try)
import System.Timeout (timeout)
import Data.Aeson (encode, object, (.=))
import Data.Either (isLeft)
import Data.List (isInfixOf)
import Data.String.Conversions (cs)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.Directory
  ( createDirectory, createDirectoryIfMissing, getTemporaryDirectory, removeDirectoryRecursive )
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.FilePath ((</>))
import System.Posix.Process (getProcessID)
import Test.Hspec

-- | Fresh temp dir per test.
withTmp :: (FilePath -> IO a) -> IO a
withTmp act = do
  tmp <- getTemporaryDirectory
  pid <- getProcessID
  let mk i = do
        let d = tmp </> ("claims-test-" <> show pid <> "-" <> show (i :: Int))
        ok <- (createDirectory d >> pure True) `catch` \(_ :: IOException) -> pure False
        if ok then pure d else mk (i + 1)
  bracket (mk 0) removeDirectoryRecursive act

claimLine :: Text -> Text -> [Text] -> Maybe [Text] -> Text
claimLine i t cmd ex =
  cs . encode $ object $
    ["id" .= i, "text" .= t, "cmd" .= cmd] <> maybe [] (\e -> ["expect" .= e]) ex

-- | Claim whose cmd is a raw bash string.
bashLine :: Text -> Text -> Maybe [Text] -> Text
bashLine i cmd ex =
  cs . encode $ object $
    ["id" .= i, "text" .= i, "cmd" .= cmd] <> maybe [] (\e -> ["expect" .= e]) ex

headerLine :: [Text] -> Text
headerLine ds = cs (encode (object ["depends" .= ds]))

writeClaims :: FilePath -> Text -> [Text] -> IO ()
writeClaims dir name ls = do
  createDirectoryIfMissing True (dir </> "claims")
  TIO.writeFile (dir </> "claims" </> cs name <> ".claims.jsonl") (T.unlines ls)

-- | Claim running rg for "needle" in a file.
rgClaim :: Text -> FilePath -> Maybe [Text] -> Text
rgClaim i f = claimLine i ("claim " <> i) ["rg", "-n", "needle", cs f]

verdicts :: [ClaimResult] -> [(Text, Verdict)]
verdicts rs = [(i, v) | ClaimResult {resId = ClaimId i, resVerdict = v} <- rs]

ids :: [ClaimResult] -> [(Text, Text)]
ids rs = [(n, i) | ClaimResult {resFile = ClaimsName n, resId = ClaimId i} <- rs]

spec :: Spec
spec = describe "expacc replayable explore claims" $ do
  describe "parseClaimsName" $ do
    it "accepts a slug and rejects a path or a suffix" $ do
      parseClaimsName "foo" `shouldBe` Right (ClaimsName "foo")
      parseClaimsName "foo-bar_1" `shouldBe` Right (ClaimsName "foo-bar_1")
      parseDepRef "other" `shouldBe` Right (WholeFile (ClaimsName "other"))
      parseDepRef "other#id" `shouldBe` Right (OneClaim (ClaimsName "other") (ClaimId "id"))
      parseClaimsName "foo.claims.jsonl" `shouldSatisfy` isLeft
      parseClaimsName "foo.md" `shouldSatisfy` isLeft
      parseClaimsName "live-docs/explore/claims/foo" `shouldSatisfy` isLeft
      parseDepRef "live-docs/explore/claims/foo.claims.jsonl" `shouldSatisfy` isLeft
      parseDepRef "other#" `shouldSatisfy` isLeft

  describe "parseClaimsFile" $ do
    let c1 = claimLine "c1" "one" ["ls"] (Just ["x"])
        c2 = claimLine "c2" "two" ["ls"] Nothing
    it "parses header and claims" $
      case parseClaimsFile "f" (T.unlines [headerLine ["other", "o2#id", "o3"], c1, c2]) of
        Right cf -> do
          hDepends (cfHeader cf) `shouldBe`
            [WholeFile (ClaimsName "other"), OneClaim (ClaimsName "o2") (ClaimId "id"), WholeFile (ClaimsName "o3")]
          map claimId (cfClaims cf) `shouldBe` [ClaimId "c1", ClaimId "c2"]
          map claimExpect (cfClaims cf) `shouldBe` [Just ["x"], Nothing]
        Left e -> expectationFailure e
    it "parses doc and commit from the header, with or without depends" $ do
      let h = cs . encode . object
      fmap cfHeader
        (parseClaimsFile "f" (T.unlines [h ["doc" .= ("e.md" :: Text), "commit" .= ("abc" :: Text)], c1]))
        `shouldBe` Right (Header (Just "e.md") (Just "abc") [])
      fmap (\cf -> (cfHeader cf, length (cfClaims cf)))
        (parseClaimsFile "f" (T.unlines [h ["depends" .= ["x" :: Text], "commit" .= ("abc" :: Text)], c1]))
        `shouldBe` Right (Header Nothing (Just "abc") [WholeFile (ClaimsName "x")], 1)
    it "parses without header" $
      fmap (\cf -> (cfHeader cf, length (cfClaims cf))) (parseClaimsFile "f" (T.unlines [c1]))
        `shouldBe` Right (emptyHeader, 1)
    it "rejects a depends object after the first line" $
      case parseClaimsFile "f" (T.unlines [c1, headerLine ["x"]]) of
        Left e -> e `shouldSatisfy` ("f:2:" `isInfixOf`)
        Right _ -> expectationFailure "expected parse error"
    it "skips blank lines but counts them in line numbers" $ do
      fmap (length . cfClaims) (parseClaimsFile "f" (T.unlines ["", c1, "   ", c2])) `shouldBe` Right 2
      case parseClaimsFile "some.claims.jsonl" (T.unlines ["", c1, "", "not json"]) of
        Left e -> e `shouldSatisfy` ("some.claims.jsonl:4:" `isInfixOf`)
        Right _ -> expectationFailure "expected parse error"

  describe "checkClaims" $ do
    let withData body act = withTmp $ \d -> do
          let f = d </> "data.txt"
          TIO.writeFile f body
          act d f
        run d ls = writeClaims d "t" ls >> checkClaims d [ClaimsName "t"]
    it "true claim" $ withData "needle one\nhay\nneedle two\n" $ \d f -> do
      rs <- run d [rgClaim "a" f (Just ["1:needle one", "3:needle two"])]
      verdicts rs `shouldBe` [("a", VTrue)]
      case rs of
        [ClaimResult {resCmd = Just cmd, resOut = Just out}] -> do
          cmd `shouldSatisfy` T.isInfixOf "rg"
          out `shouldBe` ["1:needle one", "3:needle two"]
        other -> expectationFailure (show other)
    it "line-number drift in rg -n output is Shifted" $ withData "needle one\nhay\n" $ \d f -> do
      rs <- run d [rgClaim "a" f (Just ["99:needle one"])]
      verdicts rs `shouldBe` [("a", VFalse (Shifted [("line 99", "line 1", -98)]))]
    it "line-number drift without rg -n is a Mismatch" $ withData "needle one\nhay\n" $ \d f -> do
      rs <- run d [bashLine "a" ("grep -n needle " <> cs f) (Just ["99:needle one"])]
      verdicts rs `shouldBe` [("a", VFalse (Mismatch ["99:needle one"] ["1:needle one"]))]
    it "content change in rg -n output diffs the grouped blocks" $ withData "needle one\nneedle new\n" $ \d f -> do
      rs <- run d [rgClaim "a" f (Just ["1:needle one", "2:needle old"])]
      verdicts rs `shouldBe`
        [("a", VFalse (RgMismatch ["lines 1-2", "  needle one", "  needle old"] ["lines 1-2", "  needle one", "  needle new"]))]
    it "rg -n piped into wc -l keeps the plain diff" $ withData "needle one\nneedle two\n" $ \d f -> do
      rs <- run d [bashLine "a" ("rg -n needle " <> cs f <> " | wc -l") (Just ["3"])]
      verdicts rs `shouldBe` [("a", VFalse (Mismatch ["3"] ["2"]))]
    it "shifted context block across files with -A and -- separators" $ withTmp $ \d -> do
      createDirectoryIfMissing True (d </> "src")
      TIO.writeFile (d </> "src" </> "a.hs") "x\nx\nx\nloginFunction = 1\nctx1\nctx2\n"
      TIO.writeFile (d </> "src" </> "b.hs") "loginFunction = 2\nb1\n"
      let cmd = "cd " <> cs d <> " && rg --sort path -n -A2 loginFunction src"
          ex = ["src/a.hs:1:loginFunction = 1", "src/a.hs-2-ctx1", "src/a.hs-3-ctx2", "--", "src/b.hs:1:loginFunction = 2", "src/b.hs-2-b1"]
      rs <- run d [bashLine "a" cmd (Just ex)]
      verdicts rs `shouldBe` [("a", VFalse (Shifted [("src/a.hs:1-3", "src/a.hs:4-6", 3)]))]
      let txt = renderResults PrintFalse rs
      txt `shouldSatisfy` T.isInfixOf "same lines, line numbers moved by +3 (fix-line-shift to update)"
      txt `shouldSatisfy` T.isInfixOf "    - src/a.hs:1-3\n    + src/a.hs:4-6\n"
      txt `shouldSatisfy` (not . T.isInfixOf "    - src/b.hs")
    it "shift plus one changed line shows only the header and that line" $ withTmp $ \d -> do
      createDirectoryIfMissing True (d </> "src")
      TIO.writeFile (d </> "src" </> "a.hs") "x\nx\nloginFunction = 1\nl2\nl3 changed\nl4\nl5\n"
      let cmd = "cd " <> cs d <> " && rg --sort path -nA4 loginFunction src"
          ex = ["src/a.hs:1:loginFunction = 1", "src/a.hs-2-l2", "src/a.hs-3-l3", "src/a.hs-4-l4", "src/a.hs-5-l5"]
      rs <- run d [bashLine "a" cmd (Just ex)]
      let txt = renderResults PrintFalse rs
      txt `shouldSatisfy` T.isInfixOf "-- output differs"
      txt `shouldSatisfy` T.isInfixOf "    - src/a.hs:1-5\n    + src/a.hs:3-7\n        loginFunction = 1\n        l2\n    -   l3\n    +   l3 changed\n"
      length (filter ("    - " `T.isPrefixOf`) (T.lines txt)) `shouldBe` 2
    it "a different total offset per block lists each offset" $ do
      let v = compareOutput "rg -n x src"
            ["src/a.hs:1:x", "src/b.hs:10:x"] ["src/a.hs:3:x", "src/b.hs:5:x"]
      v `shouldBe` VFalse (Shifted [("src/a.hs:1", "src/a.hs:3", 2), ("src/b.hs:10", "src/b.hs:5", -5)])
      renderResults PrintFalse [ClaimResult (ClaimsName "f") (ClaimId "x") "t" Target v Nothing Nothing]
        `shouldSatisfy` T.isInfixOf "line numbers moved (+2, -5)"
    it "one rg line whose text holds :N: or -N- splits at the real path" $ do
      fmap groupRg (parseRgOutput ["src/a.hs:9:x:12:y"]) `shouldBe` Just [Block (Just "src/a.hs") 9 9 ["x:12:y"]]
      fmap groupRg (parseRgOutput ["src/a.hs-4-ctx -5- here"]) `shouldBe` Just [Block (Just "src/a.hs") 4 4 ["ctx -5- here"]]
    it "same lines in another order is Reordered" $ withData "needle one\nneedle two\n" $ \d f -> do
      rs <- run d [rgClaim "a" f (Just ["2:needle two", "1:needle one"])]
      verdicts rs `shouldBe`
        [("a", VFalse (Reordered ["2:needle two", "1:needle one"] ["1:needle one", "2:needle two"]))]
    it "missing expect is NotRecorded" $ withData "needle\n" $ \d f -> do
      rs <- run d [rgClaim "a" f Nothing]
      verdicts rs `shouldBe` [("a", VFalse NotRecorded)]
      case rs of
        [ClaimResult {resCmd = Nothing, resOut = Nothing}] -> pure ()
        other -> expectationFailure (show other)
    it "rejects an empty command" $ withData "needle\n" $ \d _ -> do
      rs <- run d [claimLine "empty" "t" [] (Just [])]
      verdicts rs `shouldBe` [("empty", VFalse (Rejected "empty command"))]
    it "no-match with expect [] is true" $ withData "hay\n" $ \d f -> do
      rs <- run d [rgClaim "a" f (Just [])]
      verdicts rs `shouldBe` [("a", VTrue)]
      case rs of
        [ClaimResult {resOut = Just []}] -> pure ()
        other -> expectationFailure (show other)
    it "rg on a nonexistent file is ExecFailed" $ withData "x\n" $ \d f -> do
      rs <- run d [rgClaim "a" (f <> ".nope") (Just [])]
      case verdicts rs of
        [(_, VFalse (ExecFailed _))] -> pure ()
        other -> expectationFailure (show other)
    it "wc -l works" $ withData "a\nb\nc\n" $ \d f -> do
      rs <- run d [claimLine "w" "t" ["wc", "-l", cs f] (Just ["3 " <> cs f])]
      verdicts rs `shouldBe` [("w", VTrue)]
    it "cmd is a raw bash string: pipes work" $ withData "needle\nhay\nneedle\n" $ \d f -> do
      rs <- run d [bashLine "p" ("rg needle " <> cs f <> " | wc -l") (Just ["2"])]
      verdicts rs `shouldBe` [("p", VTrue)]
    it "an argv-array cmd from an older file still runs, quoted" $ withData "a b\n" $ \d f -> do
      rs <- run d [claimLine "q" "t" ["rg", "-n", "a b", cs f] (Just ["1:a b"])]
      verdicts rs `shouldBe` [("q", VTrue)]
    it "unparseable file yields BadFile" $ withTmp $ \d -> do
      writeClaims d "t" ["not json"]
      rs <- checkClaims d [ClaimsName "t"]
      case verdicts rs of
        [(_, VFalse (BadFile _))] -> pure ()
        other -> expectationFailure (show other)

  describe "depends" $ do
    let withData act = withTmp $ \d -> do
          let f = d </> "data.txt"
          TIO.writeFile f "needle\n"
          act d f
        good i f = rgClaim i f (Just ["1:needle"])
        origins rs = [(i, o) | ClaimResult {resId = ClaimId i, resOrigin = o} <- rs]
    it "whole-file dep pulls all claims as Dependency" $ withData $ \d f -> do
      writeClaims d "a" [headerLine ["b"], good "a1" f]
      writeClaims d "b" [good "b1" f, good "b2" f]
      rs <- checkClaims d [ClaimsName "a"]
      origins rs `shouldBe` [("a1", Target), ("b1", Dependency), ("b2", Dependency)]
      allTrue rs `shouldBe` True
    it "#id dep pulls only that claim" $ withData $ \d f -> do
      writeClaims d "a" [headerLine ["b#b2"], good "a1" f]
      writeClaims d "b" [good "b1" f, good "b2" f]
      rs <- checkClaims d [ClaimsName "a"]
      origins rs `shouldBe` [("a1", Target), ("b2", Dependency)]
    it "missing dep file is MissingDep" $ withData $ \d f -> do
      writeClaims d "a" [headerLine ["nope"], good "a1" f]
      rs <- checkClaims d [ClaimsName "a"]
      case verdicts rs of
        [("a1", VTrue), (_, VFalse (MissingDep _))] -> pure ()
        other -> expectationFailure (show other)
    it "missing #id is MissingDep" $ withData $ \d f -> do
      writeClaims d "a" [headerLine ["b#zzz"], good "a1" f]
      writeClaims d "b" [good "b1" f]
      rs <- checkClaims d [ClaimsName "a"]
      case verdicts rs of
        [("a1", VTrue), ("zzz", VFalse (MissingDep _))] -> pure ()
        other -> expectationFailure (show other)
    it "cycle a->b->a terminates, each claim once" $ withData $ \d f -> do
      writeClaims d "a" [headerLine ["b"], good "a1" f]
      writeClaims d "b" [headerLine ["a"], good "b1" f]
      rs <- checkClaims d [ClaimsName "a"]
      ids rs `shouldBe` [("a", "a1"), ("b", "b1")]
    it "file as target and dep is evaluated once" $ withData $ \d f -> do
      writeClaims d "a" [headerLine ["b"], good "a1" f]
      writeClaims d "b" [good "b1" f]
      rs <- checkClaims d [ClaimsName "a", ClaimsName "b"]
      ids rs `shouldBe` [("a", "a1"), ("b", "b1")]
      origins rs `shouldBe` [("a1", Target), ("b1", Dependency)]

  describe "claims lookup" $ do
    let withData act = withTmp $ \d -> do
          let f = d </> "data.txt"
          TIO.writeFile f "needle\n"
          act d f
        good i f = rgClaim i f (Just ["1:needle"])
        header = cs . encode . object
    it "a path in depends is a bad file, not a missing file" $ withTmp $ \d -> do
      writeClaims d "a" [headerLine ["live-docs/explore/claims/b.claims.jsonl"]]
      rs <- checkClaims d [ClaimsName "a"]
      case verdicts rs of
        [(_, VFalse (BadFile m))] -> m `shouldSatisfy` T.isInfixOf "claims name must be a slug"
        other -> expectationFailure (show other)
    it "resolves a slug only, not a doc header" $ withData $ \d f -> do
      writeClaims d "my-note" [header ["doc" .= ("my-note.md" :: Text)], good "a1" f]
      rs <- checkClaims d [ClaimsName "my-note"]
      verdicts rs `shouldBe` [("a1", VTrue)]
    it "does not read claims files outside claims/" $ withData $ \d f -> do
      TIO.writeFile (d </> "flat.claims.jsonl") (T.unlines [good "a" f])
      rs <- checkClaims d [ClaimsName "flat"]
      case verdicts rs of
        [(_, VFalse (MissingDep _))] -> pure ()
        other -> expectationFailure (show other)
    it "a missing file lists the claims files that exist" $ withData $ \d f -> do
      writeClaims d "have" [good "a" f]
      rs <- checkClaims d [ClaimsName "nope"]
      case verdicts rs of
        [(_, VFalse (MissingDep m))] -> do
          m `shouldSatisfy` T.isInfixOf "claims/nope.claims.jsonl"
          m `shouldSatisfy` T.isInfixOf "have"
        other -> expectationFailure (show other)

  describe "lint" $ do
    let withData act = withTmp $ \d -> do
          let f = d </> "data.txt"
          TIO.writeFile f "needle\n"
          act d f
        good i f = rgClaim i f (Just ["1:needle"])
        header = cs . encode . object
    it "check reports unknown header keys, and duplicate ids as FALSE" $ withData $ \d f -> do
      writeClaims d "t"
        [ header ["doc" .= ("t.md" :: Text), "note" .= ("x" :: Text)]
        , good "a" f
        , good "a" f
        ]
      rs <- checkClaims d [ClaimsName "t"]
      [m | ClaimResult {resVerdict = VFalse (Lint m)} <- rs] `shouldBe`
        [ "unknown header key: note"
        , "duplicate claim id: a"
        ]
    it "lintFile finds the same problems without running commands" $ withData $ \d f -> do
      writeClaims d "t" [good "a" f, good "a" f]
      lintFile d (ClaimsName "t") `shouldReturn` ["duplicate claim id: a"]
    it "a clean file has no problems" $ withData $ \d f -> do
      writeClaims d "t" [good "a" f]
      lintFile d (ClaimsName "t") `shouldReturn` []

  describe "record" $ do
    let nc i f = NewClaim i ("claim " <> i) (quoteArgv ["rg", "-n", "needle", cs f])
        withData act = withTmp $ \d -> do
          let f = d </> "data.txt"
          TIO.writeFile f "needle one\nhay\nneedle two\n"
          act d f
    it "record stores the command output as expect and the claim then checks TRUE" $ withData $ \d f -> do
      Right msg <- recordNew d (ClaimsName "r") emptyHeader (nc "a" f)
      msg `shouldSatisfy` T.isInfixOf "(2 lines)"
      msg `shouldSatisfy` T.isInfixOf "1:needle one"
      rs <- checkClaims d [ClaimsName "r"]
      verdicts rs `shouldBe` [("a", VTrue)]
    it "record runs a piped bash string and stores its output" $ withData $ \d f -> do
      Right msg <- recordNew d (ClaimsName "r") emptyHeader (NewClaim "p" "p" ("rg needle " <> cs f <> " | wc -l"))
      msg `shouldSatisfy` T.isInfixOf "(1 lines)"
      rs <- checkClaims d [ClaimsName "r"]
      verdicts rs `shouldBe` [("p", VTrue)]
    it "record writes the header, and refuses to overwrite an existing file" $ withData $ \d f -> do
      Right _ <- recordNew d (ClaimsName "r") (Header (Just "r.md") (Just "abc") [WholeFile (ClaimsName "dep")]) (nc "a" f)
      Right cf <- parseClaimsFile "r" <$> TIO.readFile (d </> "claims" </> "r.claims.jsonl")
      cfHeader cf `shouldBe` Header (Just "r.md") (Just "abc") [WholeFile (ClaimsName "dep")]
      Left e <- recordNew d (ClaimsName "r") emptyHeader (nc "b" f)
      e `shouldSatisfy` T.isInfixOf "record-append"
    it "record does not write anything when the command fails" $ withData $ \d f -> do
      Left e <- recordNew d (ClaimsName "r") emptyHeader (nc "a" (f <> ".nope"))
      e `shouldSatisfy` T.isInfixOf "nothing recorded"
      recordAppend d (ClaimsName "r") (nc "a" f) >>= (`shouldSatisfy` either (const True) (const False))
    it "record-append adds a claim and rejects a duplicate id" $ withData $ \d f -> do
      Right _ <- recordNew d (ClaimsName "r") emptyHeader (nc "a" f)
      Right _ <- recordAppend d (ClaimsName "r") (nc "b" f)
      Left e <- recordAppend d (ClaimsName "r") (nc "b" f)
      e `shouldSatisfy` T.isInfixOf "record-fix"
      rs <- checkClaims d [ClaimsName "r"]
      verdicts rs `shouldBe` [("a", VTrue), ("b", VTrue)]
    it "parallel record-append keeps both claims" $ withTmp $ \d -> do
      Right _ <- recordNew d (ClaimsName "r") emptyHeader (NewClaim "base" "claim base" "echo base")
      v1 <- newEmptyMVar
      v2 <- newEmptyMVar
      let go v nc = forkIO $ do
            r <- try (recordAppend d (ClaimsName "r") nc)
            putMVar v (r :: Either SomeException (Either Text Text))
      _ <- go v1 (NewClaim "one" "claim one" "sleep 1; echo one")
      _ <- go v2 (NewClaim "two" "claim two" "sleep 1; echo two")
      m <- timeout (15 * 1000000) $ (,) <$> takeMVar v1 <*> takeMVar v2
      case m of
        Nothing -> expectationFailure "timed out waiting for parallel record-append"
        Just (r1, r2) -> do
          case (r1, r2) of
            (Right (Right _), Right (Right _)) -> pure ()
            other -> expectationFailure ("parallel record-append results: " <> show other)
          Right cf <- parseClaimsFile "r" <$> TIO.readFile (d </> "claims" </> "r.claims.jsonl")
          let got = map claimId (cfClaims cf)
          got `shouldSatisfy` (ClaimId "one" `elem`)
          got `shouldSatisfy` (ClaimId "two" `elem`)
    it "record-fix rewrites only that claim's expect and shows the diff" $ withData $ \d f -> do
      Right _ <- recordNew d (ClaimsName "r") (Header (Just "r.md") Nothing []) (nc "a" f)
      Right _ <- recordAppend d (ClaimsName "r") (nc "b" f)
      TIO.writeFile f "needle one\nhay\nneedle changed\n"
      Right msg <- recordFix d (ClaimsName "r") "b"
      msg `shouldSatisfy` T.isInfixOf "    - 3:needle two"
      msg `shouldSatisfy` T.isInfixOf "    + 3:needle changed"
      rs <- checkClaims d [ClaimsName "r"]
      verdicts rs `shouldBe` [("a", VFalse (RgMismatch ["line 1", "  needle one", "line 3", "  needle two"] ["line 1", "  needle one", "line 3", "  needle changed"])), ("b", VTrue)]
      recordFix d (ClaimsName "r") "b" >>= (`shouldSatisfy` either (const False) (T.isPrefixOf "unchanged"))
    it "record-fix on an unknown id fails" $ withData $ \d f -> do
      Right _ <- recordNew d (ClaimsName "r") emptyHeader (nc "a" f)
      recordFix d (ClaimsName "r") "zzz" >>= (`shouldSatisfy` either (T.isInfixOf "no claim zzz") (const False))

  describe "fix-line-shift" $ do
    let withData act = withTmp $ \d -> do
          let f = d </> "data.txt"
          TIO.writeFile f "top\nneedle one\nhay\nneedle two\n"
          act d f
        sedLine i range f = bashLine i ("sed -n '" <> range <> "' " <> cs f)
        stored d = do
          Right cf <- parseClaimsFile "s" <$> TIO.readFile (d </> "claims" </> "s.claims.jsonl")
          pure [(claimCmd c, claimExpect c) | c <- cfClaims cf]
        fix dry d = fixLineShifts dry d (WholeFile (ClaimsName "s"))
    it "a sed -n range whose lines moved is Shifted" $ withData $ \d f -> do
      writeClaims d "s" [sedLine "a" "1,2p" f (Just ["needle one", "hay"])]
      rs <- checkClaims d [ClaimsName "s"]
      verdicts rs `shouldBe` [("a", VFalse (Shifted [(cs f <> ":1-2", cs f <> ":2-3", 1)]))]
    it "sed -n lines that are gone, or found twice, are a Mismatch" $ withData $ \d f -> do
      TIO.writeFile f "x\ndup\ndup\n"
      writeClaims d "s" [sedLine "gone" "1p" f (Just ["needle one"]), sedLine "twice" "1p" f (Just ["dup"])]
      rs <- checkClaims d [ClaimsName "s"]
      verdicts rs `shouldBe` [("gone", VFalse (Mismatch ["needle one"] ["x"])), ("twice", VFalse (Mismatch ["dup"] ["x"]))]
    it "parses only a whole sed -n range command" $ do
      parseSedRange "sed -n '3,9p' src/a.hs" `shouldBe` Just (SedRange 3 9 "3,9p" "src/a.hs")
      parseSedRange "sed -n 3p \"src/a.hs\"" `shouldBe` Just (SedRange 3 3 "3p" "src/a.hs")
      parseSedRange "sed -n '3,9p' src/a.hs | wc -l" `shouldBe` Nothing
      parseSedRange "sed -n '/x/p' src/a.hs" `shouldBe` Nothing
    it "moves shifted rg and sed claims and leaves the rest alone" $ withData $ \d f -> do
      let rgCmd = "rg -n needle " <> cs f
          changed = bashLine "changed" rgCmd (Just ["2:needle one", "4:needle old"])
      writeClaims d "s"
        [ bashLine "rg" rgCmd (Just ["1:needle one", "3:needle two"])
        , sedLine "sed" "1,2p" f (Just ["needle one", "hay"])
        , sedLine "one" "3p" f (Just ["needle two"])
        , changed
        , bashLine "ok" ("wc -l < " <> cs f) (Just ["4"])
        ]
      before <- stored d
      Right dry <- fix True d
      length (sfShifted dry) `shouldBe` 3
      stored d `shouldReturn` before
      Right done <- fix False d
      (sfTrue done, sfFalse done) `shouldBe` (1, 1)
      sfShifted done `shouldBe` sfShifted dry
      head (sfShifted done) `shouldBe` ["shifted s#rg  by +1", "    - line 1", "    + line 2", "    - line 3", "    + line 4"]
      after <- stored d
      take 3 after
        `shouldBe` [ (rgCmd, Just ["2:needle one", "4:needle two"])
                   , ("sed -n '2,3p' " <> cs f, Just ["needle one", "hay"])
                   , ("sed -n '4p' " <> cs f, Just ["needle two"])
                   ]
      drop 3 after `shouldBe` drop 3 before
      rs <- checkClaims d [ClaimsName "s"]
      [i | (i, VTrue) <- verdicts rs] `shouldBe` ["rg", "sed", "one", "ok"]
    it "takes one claim by id and fails on an unknown one" $ withData $ \d f -> do
      writeClaims d "s" [sedLine "a" "1,2p" f (Just ["needle one", "hay"]), sedLine "b" "3p" f (Just ["needle two"])]
      Right one <- fixLineShifts False d (OneClaim (ClaimsName "s") (ClaimId "b"))
      length (sfShifted one) `shouldBe` 1
      map fst <$> stored d `shouldReturn` ["sed -n '1,2p' " <> cs f, "sed -n '4p' " <> cs f]
      fixLineShifts False d (OneClaim (ClaimsName "s") (ClaimId "zzz"))
        >>= (`shouldSatisfy` either (T.isInfixOf "no claim zzz") (const False))

  describe "renderResults" $ do
    let t = ClaimResult (ClaimsName "f") (ClaimId "t1") "good" Target VTrue Nothing Nothing
        d = ClaimResult (ClaimsName "g") (ClaimId "d1") "dep bad" Dependency
              (VFalse (Mismatch ["gone"] ["new"])) Nothing Nothing
        rs = [t, d]
        out m = renderResults m rs
    it "PrintMinimal shows only false ids, their commands, and the totals" $ do
      let bad = d {resCmd = Just "rg -n needle src"}
          txt = renderResults PrintMinimal [t, bad]
      txt `shouldSatisfy` (not . T.isInfixOf "TRUE")
      txt `shouldSatisfy` (not . T.isInfixOf "output:")
      txt `shouldSatisfy` (not . T.isInfixOf "gone")
      txt `shouldSatisfy` T.isInfixOf "FALSE g#d1 (dep)\ncommand: rg -n needle src\n"
      txt `shouldSatisfy` T.isInfixOf "FAILED: 1 true, 1 false"
      renderResults PrintMinimal [t] `shouldBe` "OK: 1 true, 0 false\n"
    it "PrintFalse hides TRUE rows" $ do
      out PrintFalse `shouldSatisfy` (not . T.isInfixOf "TRUE")
      out PrintFalse `shouldSatisfy` T.isInfixOf "FALSE g#d1 (dep)"
    it "PrintTrue hides FALSE rows" $ do
      out PrintTrue `shouldSatisfy` T.isInfixOf "TRUE  f#t1"
      out PrintTrue `shouldSatisfy` (not . T.isInfixOf "FALSE")
    it "PrintAll shows both, with summary" $ do
      out PrintAll `shouldSatisfy` T.isInfixOf "TRUE"
      out PrintAll `shouldSatisfy` T.isInfixOf "FALSE"
      out PrintAll `shouldSatisfy` T.isInfixOf "1 true, 1 false"
      out PrintFalse `shouldSatisfy` T.isInfixOf "1 true, 1 false"
    it "ends with OK or FAILED" $ do
      out PrintAll `shouldSatisfy` T.isInfixOf "FAILED: 1 true, 1 false"
      renderResults PrintAll [t] `shouldSatisfy` T.isInfixOf "OK: 1 true, 0 false"
    it "diff keeps two lines of context and drops the rest" $ do
      let ls = ["l" <> cs (show i) | i <- [1 .. 10 :: Int]]
          r = ClaimResult (ClaimsName "f") (ClaimId "x") "t" Target
                (VFalse (Mismatch ls (take 9 ls <> ["new"]))) Nothing Nothing
          txt = renderResults PrintFalse [r]
      txt `shouldSatisfy` T.isInfixOf "      l8\n      l9\n    - l10\n    + new"
      txt `shouldSatisfy` (not . T.isInfixOf "l1\n")
    it "renders diff lines under a mismatch" $ do
      out PrintAll `shouldSatisfy` T.isInfixOf "    - gone"
      out PrintAll `shouldSatisfy` T.isInfixOf "    + new"
    it "TRUE rows of Target have no (dep) marker" $
      out PrintTrue `shouldSatisfy` (not . T.isInfixOf "(dep)")
    it "prefixes missing dependency only when the miss is a dep" $ do
      let miss o = ClaimResult (ClaimsName "f") (ClaimId "*") "" o (VFalse (MissingDep "no such claims file x")) Nothing Nothing
      renderResults PrintFalse [miss Target] `shouldSatisfy` (not . T.isInfixOf "missing dependency:")
      renderResults PrintFalse [miss Dependency] `shouldSatisfy` T.isInfixOf "missing dependency: no such claims file"
    it "prints command and output lines for a shown claim" $ do
      let r = ClaimResult (ClaimsName "f") (ClaimId "t1") "good" Target VTrue (Just "echo hi") (Just ["hi", "there"])
          txt = renderResults PrintTrue [r]
      txt `shouldSatisfy` T.isInfixOf "command: echo hi\noutput: hi\noutput: there\n"
    it "marks a run that printed nothing" $ do
      let r = ClaimResult (ClaimsName "f") (ClaimId "t1") "good" Target VTrue (Just "true") (Just [])
      renderResults PrintTrue [r] `shouldSatisfy` T.isInfixOf "command: true\noutput:\n"
    it "omits command and output when the claim did not run" $ do
      let r = ClaimResult (ClaimsName "f") (ClaimId "*") "" Target (VFalse (MissingDep "x")) Nothing Nothing
          txt = renderResults PrintFalse [r]
      txt `shouldSatisfy` (not . T.isInfixOf "command:")
      txt `shouldSatisfy` (not . T.isInfixOf "output:")

  describe "rg -n grouping" $ do
    it "detects rg with a line-number flag" $ do
      mapM_ ((`shouldBe` True) . mentionsRgLineNumbers)
        ["rg -n x src", "rg --sort path --line-number x", "rg -nA5 x", "rg -in x", "cd d && rg -C2 -n x | head"]
      mapM_ ((`shouldBe` False) . mentionsRgLineNumbers)
        ["rg x src", "grep -n x src", "rg -A5 x", "rg --no-line-number x", "rgx -n y"]
    it "parses paths with dashes and digits" $ do
      let ls = ["2024-notes-v2/a-1-b.md:3:hit", "2024-notes-v2/a-1-b.md-4-ctx -5- here", "--", "2024-notes-v2/a-1-b.md:9:x:12:y"]
      fmap groupRg (parseRgOutput ls) `shouldBe` Just
        [ Block (Just "2024-notes-v2/a-1-b.md") 3 4 ["hit", "ctx -5- here"]
        , Block (Just "2024-notes-v2/a-1-b.md") 9 9 ["x:12:y"]
        ]
    it "parses the single-file N:text / N-text form" $ do
      let ls = ["12:foo.bar:3:x", "13-ctx-1-y", "--", "20:z"]
      fmap groupRg (parseRgOutput ls) `shouldBe` Just
        [Block Nothing 12 13 ["foo.bar:3:x", "ctx-1-y"], Block Nothing 20 20 ["z"]]
      fmap (renderBlocks . groupRg) (parseRgOutput ls) `shouldBe`
        Just ["lines 12-13", "  foo.bar:3:x", "  ctx-1-y", "line 20", "  z"]
    it "rejects output with a line that is not rg format" $
      parseRgOutput ["src/a.hs:1:x", "total 3"] `shouldBe` Nothing
    it "falls back to the plain diff when a line does not parse" $
      compareOutput "rg -n x src" ["src/a.hs:1:x", "note"] ["src/a.hs:2:x", "note"]
        `shouldBe` VFalse (Mismatch ["src/a.hs:1:x", "note"] ["src/a.hs:2:x", "note"])
    it "a file rename is not a shift" $
      compareOutput "rg -n x src" ["src/a.hs:1:x"] ["src/b.hs:1:x"]
        `shouldBe` VFalse (RgMismatch ["src/a.hs:1", "  x"] ["src/b.hs:1", "  x"])

  describe "resolveExploreDir" $
    it "honours EXPACC_DIR and falls back to default" $ do
      old <- lookupEnv "EXPACC_DIR"
      let restore = maybe (unsetEnv "EXPACC_DIR") (setEnv "EXPACC_DIR") old
      (do setEnv "EXPACC_DIR" "/some/dir"
          resolveExploreDir >>= (`shouldBe` "/some/dir")
          unsetEnv "EXPACC_DIR"
          resolveExploreDir >>= (`shouldBe` "./live-docs/explore")) `finally` restore
