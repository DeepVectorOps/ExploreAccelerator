{-# LANGUAGE OverloadedStrings #-}

module Scan
  ( scanRoots
  , readLiveFile
  , validAbsolute
  ) where

import Claims
import Control.Exception (IOException, displayException, try)
import Control.Monad (foldM, forM)
import Data.Aeson (object, (.=))
import qualified Data.Aeson as A
import qualified Data.ByteString as BS
import Data.List (isPrefixOf, isSuffixOf, nub, sort)
import Data.String.Conversions (cs)
import Data.Text (Text)
import qualified Data.Text.IO as TIO
import Data.Time (UTCTime, defaultTimeLocale, formatTime)
import LiveDocs.Config
import System.Directory
  ( canonicalizePath
  , doesDirectoryExist
  , doesFileExist
  , getFileSize
  , getModificationTime
  , listDirectory
  , pathIsSymbolicLink
  )
import System.FilePath (isAbsolute, splitDirectories, takeDirectory, takeFileName, (</>))

scanRoots :: [Text] -> IO A.Value
scanRoots roots = do
  (projects, _) <- foldM step ([], []) roots
  pure $ object ["defaultLifetimeSeconds" .= defaultExploreLifetime, "projects" .= projects]
  where
    step (acc, seen) rootText = do
      (cards, seen') <- scanOne rootText seen
      pure (acc ++ cards, seen')

-- | Invalid and missing roots become the not-found card before any walk.
-- A thrown scan of one root becomes that same card and does not fail the others.
-- The same live-docs path is hit once; the first search root wins.
scanOne :: Text -> [FilePath] -> IO ([A.Value], [FilePath])
scanOne rootText seen = case validAbsolute (cs rootText) of
  Left e -> pure ([missing rootText e], seen)
  Right absPath -> do
    exists <- doesDirectoryExist absPath
    if not exists
      then pure ([missing rootText "missing or not a directory"], seen)
      else do
        got <- try (findLiveDocs absPath) :: IO (Either IOException [FilePath])
        case got of
          Left ex -> pure ([missing rootText (cs (displayException ex))], seen)
          Right lives -> do
            let fresh = filter (`notElem` seen) lives
            built <- try (mapM projectHit fresh) :: IO (Either IOException [A.Value])
            case built of
              Left ex -> pure ([missing rootText (cs (displayException ex))], seen)
              Right cards -> pure (cards, seen ++ fresh)

missing :: Text -> Text -> A.Value
missing root err =
  object
    [ "root" .= root
    , "found" .= False
    , "error" .= err
    , "files" .= ([] :: [A.Value])
    , "claims" .= ([] :: [A.Value])
    ]

projectHit :: FilePath -> IO A.Value
projectHit live = do
  files <- walkFiles live ""
  let total = sum [b | (_, b, _, _) <- files]
      newest = case [t | (_, _, _, t) <- files] of
        [] -> Nothing
        ts -> Just (fmtTime (maximum ts))
  life <- readExploreLifetime live
  claims <- readClaims (live </> "explore")
  let (set, secs, lifeErr) = case life of
        Right (Just n) -> (True, Just n, Nothing :: Maybe Text)
        Right Nothing -> (False, Nothing, Nothing)
        Left e -> (False, Nothing, Just e)
  pure $
    object
      [ "root" .= takeDirectory live
      , "liveDocs" .= live
      , "found" .= True
      , "fileCount" .= length files
      , "totalBytes" .= total
      , "modified" .= newest
      , "lifetimeSeconds" .= secs
      , "lifetimeSet" .= set
      , "lifetimeError" .= lifeErr
      , "files" .= [object ["rel" .= rel, "bytes" .= b, "markdown" .= md, "modified" .= fmtTime t] | (rel, b, md, t) <- files]
      , "claims" .= claims
      ]

skipChild :: String -> Bool
skipChild name =
  "." `isPrefixOf` name || name `elem` ["result", "node_modules", "dist", "dist-newstyle", ".git", "live-docs"]

-- | Real child directories. Symlinks are skipped. A found live-docs tree is
-- not descended into.
listKids :: FilePath -> IO [FilePath]
listKids dir = do
  names <- listDirectory dir
  fmap concat $ forM (sort names) $ \n ->
    if skipChild n
      then pure []
      else do
        let p = dir </> n
        link <- pathIsSymbolicLink p
        if link
          then pure []
          else do
            isDir <- doesDirectoryExist p
            pure [p | isDir]

findLiveDocs :: FilePath -> IO [FilePath]
findLiveDocs root = do
  self <- selfLive root
  here <- liveAt root
  kids <- listKids root
  one <- concat <$> forM kids liveAt
  two <- concat <$> forM kids (\k -> listKids k >>= fmap concat . mapM liveAt)
  canon <- mapM canonicalizePath (self ++ here ++ one ++ two)
  pure (nub canon)
  where
    liveAt parent = do
      let p = parent </> "live-docs"
      ok <- doesDirectoryExist p
      pure [p | ok]
    -- The added path may already be the live-docs tree, not a parent of one.
    selfLive p
      | takeFileName p == "live-docs" = do
          ok <- doesDirectoryExist p
          pure [p | ok]
      | otherwise = pure []

fmtTime :: UTCTime -> Text
fmtTime = cs . formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ"

walkFiles :: FilePath -> FilePath -> IO [(Text, Integer, Bool, UTCTime)]
walkFiles dir rel = do
  names <- listDirectory dir
  rows <- fmap concat $ forM names $ \n -> do
    let p = dir </> n
        r = if null rel then n else rel </> n
    link <- pathIsSymbolicLink p
    if link
      then pure []
      else do
        isDir <- doesDirectoryExist p
        if isDir
          then walkFiles p r
          else do
            isFile <- doesFileExist p
            if not isFile
              then pure []
              else do
                sz <- getFileSize p
                mt <- getModificationTime p
                pure [(cs r, sz, ".md" `isSuffixOf` n, mt)]
  pure (sort rows)

readClaims :: FilePath -> IO [A.Value]
readClaims explore = do
  names <- listClaimsNames explore
  forM names $ \name@(ClaimsName n) -> do
    let path = claimsPath explore name
    txt <- TIO.readFile path
    let claims = case parseClaimsFile path txt of
          Left _ -> []
          Right cf ->
            [ object ["id" .= i, "text" .= claimText c]
            | c <- cfClaims cf
            , let ClaimId i = claimId c
            ]
    pure (object ["name" .= n, "claims" .= claims])

-- | Reject ".", "..", and empty segments. Shared by absolute roots and relative files.
badSegment :: FilePath -> Bool
badSegment s = s == "." || s == ".." || null s

hasBadSegment :: FilePath -> Bool
hasBadSegment p = any badSegment (splitDirectories p)

-- | Absolute path with no empty, "." or ".." segment. Does not canonicalize.
validAbsolute :: FilePath -> Either Text FilePath
validAbsolute p
  | not (isAbsolute p) = Left "path is not absolute"
  | hasBadSegment p = Left "path must not contain . or .."
  | otherwise = Right p

badRel :: FilePath -> Bool
badRel rel = null rel || isAbsolute rel || hasBadSegment rel

readLiveFile :: FilePath -> FilePath -> IO (Either Text BS.ByteString)
readLiveFile root rel = case validAbsolute root of
  Left e -> pure (Left e)
  Right rootPath
    | badRel rel -> pure (Left "relative path is not allowed")
    | otherwise -> do
        let live = rootPath </> "live-docs"
        known <- doesDirectoryExist live
        if not known
          then pure (Left "unknown project root")
          else do
            canonLive <- try (canonicalizePath live) :: IO (Either IOException FilePath)
            canonFile <- try (canonicalizePath (live </> rel)) :: IO (Either IOException FilePath)
            case (canonLive, canonFile) of
              (Left _, _) -> pure (Left "live-docs path is not readable")
              (_, Left _) -> pure (Left "file is not readable")
              (Right cl, Right cf) -> do
                isFile <- doesFileExist cf
                let under = addSlash cl `isPrefixOf` cf
                if not isFile || not under
                  then pure (Left "path is outside live-docs")
                  else Right <$> BS.readFile cf

addSlash :: FilePath -> FilePath
addSlash p
  | "/" `isSuffixOf` p = p
  | otherwise = p <> "/"
