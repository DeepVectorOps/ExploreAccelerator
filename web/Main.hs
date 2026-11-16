{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

-- | Local explorer for live-docs trees. Binds 127.0.0.1:3090 only.
module Main (main) where

import Control.Concurrent.MVar (MVar, newMVar, withMVar)
import Control.Exception (finally)
import Data.Aeson (eitherDecode, object, (.:), (.=))
import Data.Aeson.Types (Parser, parseEither)
import qualified Data.Aeson as A
import qualified Data.Aeson.KeyMap as KM
import Data.ByteString (ByteString)
import qualified Data.ByteString.Lazy as LBS
import Data.FileEmbed (embedFile)
import Data.String.Conversions (cs)
import Data.Text (Text)
import qualified Data.Text as T
import LiveDocs.Config (daysToSeconds, writeExploreLifetime)
import Lucid
import Network.HTTP.Types.Status (status400)
import Network.Wai.Handler.Warp (defaultSettings, setHost, setPort)
import Scan (readLiveFile, scanRoots, validAbsolute)
import System.Directory (doesDirectoryExist, getCurrentDirectory, setCurrentDirectory)
import System.FilePath ((</>))
import Web.Scotty
import Claims (allTrue, checkRef, parseDepRef, renderResults, PrintMode (..))

appCss :: ByteString
appCss = $(embedFile "web/static/app.css")

appJs :: ByteString
appJs = $(embedFile "web/static/app.js")

main :: IO ()
main = do
  lock <- newMVar ()
  let settings = setHost "127.0.0.1" (setPort 3090 defaultSettings)
  scottyOpts (Options 0 settings) (routes lock)

routes :: MVar () -> ScottyM ()
routes lock = do
  get "/" $ html $ renderText page
  post "/api/scan" $ jsonBody >>= \case
    Left e -> bad e
    Right (ScanReq roots) -> liftIO (scanRoots roots) >>= json
  get "/api/file" $ do
    root <- queryParam "root" :: ActionM Text
    rel <- queryParam "rel" :: ActionM Text
    got <- liftIO (readLiveFile (cs root) (cs rel))
    case got of
      Left e -> bad e
      Right bs -> do
        setHeader "Content-Type" "text/plain; charset=utf-8"
        raw (LBS.fromStrict bs)
  post "/api/check" $ jsonBody >>= \case
    Left e -> bad e
    Right (CheckReq root name) -> case validAbsolute (cs root) of
      Left e -> bad e
      Right rootPath -> case parseDepRef name of
        Left e -> bad e
        Right ref -> do
          let explore = rootPath </> "live-docs" </> "explore"
          exists <- liftIO (doesDirectoryExist explore)
          if not exists
            then bad "explore directory is missing"
            else do
              rs <- liftIO (withProjectCwd lock rootPath (checkRef explore ref))
              json (object ["ok" .= allTrue rs, "text" .= renderResults PrintAll rs])
  post "/api/lifetime" $ jsonBody >>= \case
    Left e -> bad e
    Right req -> case lifetimeSeconds req of
      Left e -> bad e
      Right secs -> case validAbsolute (cs (lifeRoot req)) of
        Left e -> bad e
        Right rootPath -> do
          let live = rootPath </> "live-docs"
          known <- liftIO (doesDirectoryExist live)
          if not known
            then bad "unknown project root"
            else do
              wrote <- liftIO (writeExploreLifetime live secs)
              case wrote of
                Left e -> bad e
                Right () -> json (object ["lifetimeSeconds" .= secs])

jsonBody :: A.FromJSON a => ActionM (Either Text a)
jsonBody = do
  bs <- body
  pure $ case eitherDecode bs of
    Left _ -> Left "invalid JSON"
    Right v -> case parseEither A.parseJSON v of
      Left e -> Left (presentParseError e)
      Right a -> Right a

-- | Lifetime parsers 'fail' with the texts the page already shows. Aeson's
-- 'parseEither' prefixes those. Other parse errors stay as Aeson's text,
-- which is what scan and check already returned.
presentParseError :: String -> Text
presentParseError e =
  case T.stripPrefix "Error in $: " (cs e) of
    Just rest | rest `elem` lifetimeErrors -> rest
    _ -> cs e

lifetimeErrors :: [Text]
lifetimeErrors =
  [ "missing root"
  , "missing amount"
  , "missing unit"
  , "amount must be an integer"
  , "seconds must be > 0"
  , "unit must be seconds or days"
  , "body must be an object"
  , "days must be > 0"
  ]

bad :: Text -> ActionM ()
bad msg = do
  status status400
  json (object ["error" .= msg])

withProjectCwd :: MVar () -> FilePath -> IO a -> IO a
withProjectCwd lock dir act = withMVar lock $ \_ -> do
  old <- getCurrentDirectory
  setCurrentDirectory dir
  act `finally` setCurrentDirectory old

newtype ScanReq = ScanReq [Text]

instance A.FromJSON ScanReq where
  parseJSON = A.withObject "scan" $ \o -> ScanReq <$> o .: "roots"

data CheckReq = CheckReq Text Text

instance A.FromJSON CheckReq where
  parseJSON = A.withObject "check" $ \o -> CheckReq <$> o .: "root" <*> o .: "name"

data Unit = Seconds | Days

instance A.FromJSON Unit where
  parseJSON (A.String "seconds") = pure Seconds
  parseJSON (A.String "days") = pure Days
  parseJSON (A.String _) = fail "unit must be seconds or days"
  parseJSON _ = fail "missing unit"

data LifetimeReq = LifetimeReq
  { lifeRoot :: Text
  , lifeAmount :: Integer
  , lifeUnit :: Unit
  }

instance A.FromJSON LifetimeReq where
  parseJSON (A.Object o) = do
    root <- case KM.lookup "root" o of
      Nothing -> fail "missing root"
      Just v -> case parseEither A.parseJSON v of
        Right t -> pure t
        Left _ -> fail "missing root"
    amount <- case KM.lookup "amount" o of
      Nothing -> fail "missing amount"
      Just v -> case parseEither (A.parseJSON :: A.Value -> Parser Integer) v of
        Right i -> pure i
        Left _ -> fail "amount must be an integer"
    unit <- case KM.lookup "unit" o of
      Nothing -> fail "missing unit"
      Just v -> A.parseJSON v
    pure (LifetimeReq root amount unit)
  parseJSON _ = fail "body must be an object"

lifetimeSeconds :: LifetimeReq -> Either Text Integer
lifetimeSeconds LifetimeReq{lifeRoot, lifeAmount, lifeUnit} = do
  secs <- case lifeUnit of
    Seconds
      | lifeAmount <= 0 -> Left "seconds must be > 0"
      | otherwise -> Right lifeAmount
    Days -> daysToSeconds lifeAmount
  if T.null lifeRoot then Left "missing root" else Right secs

page :: Html ()
page = doctypehtml_ $ do
  head_ $ do
    meta_ [charset_ "utf-8"]
    meta_ [name_ "viewport", content_ "width=device-width, initial-scale=1"]
    title_ "Live docs"
    script_ [src_ "https://unpkg.com/marked/marked.min.js"] ("" :: Text)
    style_ (cs appCss :: Text)
  body_ $ do
    h1_ "Live docs"
    section_ [class_ "roots"] $ do
      p_ [class_ "hint"] "Saved in this browser only. Each path is a project, or a folder of projects. The page looks for live-docs up to two levels down."
      div_ [class_ "row"] $ do
        input_ [id_ "root-input", type_ "text", placeholder_ "/absolute/path"]
        button_ [id_ "add-root", type_ "button"] "Add"
      ul_ [id_ "root-list"] ""
    div_ [id_ "projects"] ""
    script_ (cs appJs :: Text)
