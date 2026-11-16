{-# LANGUAGE OverloadedStrings #-}

-- | Local explorer for live-docs trees. Binds 127.0.0.1:3090 only.
module Main (main) where

import Claims
import Control.Concurrent.MVar (MVar, newMVar, withMVar)
import Control.Exception (IOException, finally, try)
import Control.Monad (forM)
import Data.Aeson (eitherDecode, object, (.:), (.=))
import Data.Aeson.Types (Parser, parseEither, parseMaybe)
import qualified Data.Aeson as A
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LBS
import Data.List (isPrefixOf, isSuffixOf, sort)
import Data.String.Conversions (cs)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import LiveDocs.Config
import Lucid
import Network.HTTP.Types.Status (status400)
import Network.Wai.Handler.Warp (defaultSettings, setHost, setPort)
import System.Directory
  ( canonicalizePath
  , doesDirectoryExist
  , doesFileExist
  , getCurrentDirectory
  , getFileSize
  , listDirectory
  , pathIsSymbolicLink
  , setCurrentDirectory
  )
import System.FilePath (isAbsolute, splitDirectories, takeDirectory, (</>))
import Web.Scotty

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
    Right v -> case parseEither (A.withObject "scan" (.: "roots")) v of
      Left e -> bad (cs e)
      Right roots -> liftIO (scanRoots roots) >>= json
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
    Right v -> case parseEither (A.withObject "check" (\o -> (,) <$> o .: "root" <*> o .: "name")) v of
      Left e -> bad (cs e)
      Right (root :: Text, name :: Text) -> case validAbsolute (cs root) of
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
    Right v -> case parseLifetimeReq v of
      Left e -> bad e
      Right (root, secs) -> case validAbsolute (cs root) of
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

jsonBody :: ActionM (Either Text A.Value)
jsonBody = do
  bs <- body
  pure $ case eitherDecode bs of
    Left _ -> Left "invalid JSON"
    Right v -> Right v

bad :: Text -> ActionM ()
bad msg = do
  status status400
  json (object ["error" .= msg])

withProjectCwd :: MVar () -> FilePath -> IO a -> IO a
withProjectCwd lock dir act = withMVar lock $ \_ -> do
  old <- getCurrentDirectory
  setCurrentDirectory dir
  act `finally` setCurrentDirectory old

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
  here <- liveAt root
  kids <- listKids root
  one <- concat <$> forM kids liveAt
  two <- concat <$> forM kids (\k -> listKids k >>= fmap concat . mapM liveAt)
  pure (here ++ one ++ two)
  where
    liveAt parent = do
      let p = parent </> "live-docs"
      ok <- doesDirectoryExist p
      pure [p | ok]

scanRoots :: [Text] -> IO A.Value
scanRoots roots = do
  projects <- fmap concat $ forM roots $ \r -> do
    let path = cs r
    case validAbsolute path of
      Left e -> pure [missing r e]
      Right absPath -> do
        exists <- doesDirectoryExist absPath
        if not exists
          then pure [missing r "missing or not a directory"]
          else findLiveDocs absPath >>= mapM projectHit
  pure $ object ["defaultLifetimeSeconds" .= defaultExploreLifetime, "projects" .= projects]

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
  let total = sum [b | (_, b, _) <- files]
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
      , "lifetimeSeconds" .= secs
      , "lifetimeSet" .= set
      , "lifetimeError" .= lifeErr
      , "files" .= [object ["rel" .= rel, "bytes" .= b, "markdown" .= md] | (rel, b, md) <- files]
      , "claims" .= claims
      ]

walkFiles :: FilePath -> FilePath -> IO [(Text, Integer, Bool)]
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
                pure [(cs r, sz, ".md" `isSuffixOf` n)]
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

-- | Absolute path with no empty, "." or ".." segment. Does not canonicalize.
validAbsolute :: FilePath -> Either Text FilePath
validAbsolute p
  | not (isAbsolute p) = Left "path is not absolute"
  | any (`elem` [".", "..", ""]) (splitDirectories p) = Left "path must not contain . or .."
  | otherwise = Right p

readLiveFile :: FilePath -> FilePath -> IO (Either Text BS.ByteString)
readLiveFile root rel = case validAbsolute root of
  Left e -> pure (Left e)
  Right rootPath
    | badRel rel -> pure (Left "relative path is not allowed")
    | otherwise -> readLiveFile' rootPath rel

readLiveFile' :: FilePath -> FilePath -> IO (Either Text BS.ByteString)
readLiveFile' root rel = do
  let live = root </> "live-docs"
  known <- doesDirectoryExist live
  if not known
    then pure (Left "unknown project root")
    else do
      canonLive <- tryIO (canonicalizePath live)
      canonFile <- tryIO (canonicalizePath (live </> rel))
      case (canonLive, canonFile) of
        (Left _, _) -> pure (Left "live-docs path is not readable")
        (_, Left _) -> pure (Left "file is not readable")
        (Right cl, Right cf) -> do
          isFile <- doesFileExist cf
          let under = (addSlash cl) `isPrefixOf` cf
          if not isFile || not under
            then pure (Left "path is outside live-docs")
            else Right <$> BS.readFile cf

addSlash :: FilePath -> FilePath
addSlash p
  | "/" `isSuffixOf` p = p
  | otherwise = p <> "/"

badRel :: FilePath -> Bool
badRel rel =
  null rel || isAbsolute rel || any (`elem` ["..", ".", ""]) (splitDirectories rel)

tryIO :: IO a -> IO (Either IOException a)
tryIO = try

parseLifetimeReq :: A.Value -> Either Text (Text, Integer)
parseLifetimeReq (A.Object o) = do
  root <- note "missing root" (KM.lookup "root" o >>= parseMaybe A.parseJSON)
  amountV <- note "missing amount" (KM.lookup "amount" o)
  unit <- note "missing unit" (KM.lookup "unit" o >>= parseMaybe A.parseJSON)
  n <- case parseEither (A.parseJSON :: A.Value -> Parser Integer) amountV of
    Right i -> Right i
    Left _ -> Left "amount must be an integer"
  secs <- case (unit :: Text) of
    "seconds"
      | n <= 0 -> Left "seconds must be > 0"
      | otherwise -> Right n
    "days" -> daysToSeconds n
    _ -> Left "unit must be seconds or days"
  if T.null root then Left "missing root" else pure (root, secs)
  where
    note e = maybe (Left e) Right
parseLifetimeReq _ = Left "body must be an object"

page :: Html ()
page = doctypehtml_ $ do
  head_ $ do
    meta_ [charset_ "utf-8"]
    meta_ [name_ "viewport", content_ "width=device-width, initial-scale=1"]
    title_ "Live docs"
    script_ [src_ "https://unpkg.com/@phosphor-icons/web"] ("" :: Text)
    script_ [src_ "https://unpkg.com/marked/marked.min.js"] ("" :: Text)
    style_ css
  body_ $ do
    h1_ $ do
      i_ [class_ "ph ph-books", title_ "live docs"] ""
      "Live docs"
    section_ [class_ "roots"] $ do
      p_ [class_ "hint"] "Saved in this browser only. Each path is a project, or a folder of projects. The page looks for live-docs up to two levels down."
      div_ [class_ "row"] $ do
        input_ [id_ "root-input", type_ "text", placeholder_ "/absolute/path"]
        button_ [id_ "add-root", type_ "button"] "Add"
      ul_ [id_ "root-list"] ""
    div_ [id_ "projects"] ""
    script_ pageJs

css :: Text
css =
  T.concat
    [ "body{margin:0;padding:1.25rem 1.5rem 2rem;font-family:system-ui,sans-serif;"
    , "background:#12141a;color:#e7e9ee;line-height:1.4}"
    , "h1{display:flex;align-items:center;gap:.5rem;font-weight:560;font-size:1.45rem;margin:0 0 .75rem}"
    , ".ph{font-size:1.5rem;color:#9eb7ff}"
    , ".hint{color:#a7adba;font-size:.9rem;margin:.2rem 0 .6rem;max-width:52rem}"
    , ".row{display:flex;gap:.4rem;align-items:center;flex-wrap:wrap}"
    , "input,select,button{font:inherit;background:#1c2030;color:#e7e9ee;border:1px solid #34384a;border-radius:6px;padding:.3rem .5rem}"
    , "button{cursor:pointer}"
    , "#root-input{min-width:22rem;flex:1}"
    , "ul{list-style:none;padding:0;margin:.4rem 0}"
    , ".card{border:1px solid #2c3142;border-radius:10px;padding:.8rem 1rem;margin:.8rem 0;background:#181b24}"
    , "h2{font-size:1.05rem;font-weight:560;margin:.1rem 0 .3rem}"
    , ".meta{color:#b7beca;font-size:.9rem;margin:.15rem 0}"
    , "pre{white-space:pre-wrap;background:#0e1016;padding:.6rem;border-radius:8px;overflow:auto;max-height:22rem}"
    , ".md{max-width:48rem}"
    , ".err{color:#ffb4b4}"
    ]

pageJs :: Text
pageJs =
  T.unlines
    [ "const KEY = 'live-docs-explorer-roots';"
    , "const load = () => { try { const v = JSON.parse(localStorage.getItem(KEY) || '[]'); return Array.isArray(v) ? v.filter(x => typeof x === 'string' && x) : []; } catch (e) { return []; } };"
    , "const save = xs => localStorage.setItem(KEY, JSON.stringify(xs));"
    , "let roots = load();"
    , "const $ = id => document.getElementById(id);"
    , "function human(n) {"
    , "  const u = ['B','KB','MB','GB','TB'];"
    , "  let i = 0, x = Number(n) || 0;"
    , "  while (x >= 1024 && i < u.length - 1) { x /= 1024; i++; }"
    , "  return (i === 0 ? String(Math.round(x)) : x.toFixed(1)) + ' ' + u[i];"
    , "}"
    , "function daysLabel(sec) {"
    , "  const d = sec / 86400;"
    , "  return Number.isInteger(d) ? String(d) : d.toFixed(2);"
    , "}"
    , "function renderRoots() {"
    , "  const ul = $('root-list');"
    , "  ul.replaceChildren();"
    , "  roots.forEach((p, i) => {"
    , "    const li = document.createElement('li');"
    , "    li.className = 'row';"
    , "    const span = document.createElement('span');"
    , "    span.textContent = p;"
    , "    const b = document.createElement('button');"
    , "    b.type = 'button';"
    , "    b.textContent = 'Remove';"
    , "    b.addEventListener('click', () => { roots = roots.filter((_, j) => j !== i); save(roots); renderRoots(); scan(); });"
    , "    li.append(span, b);"
    , "    ul.append(li);"
    , "  });"
    , "}"
    , "async function scan() {"
    , "  const box = $('projects');"
    , "  box.textContent = 'Scanning…';"
    , "  const res = await fetch('/api/scan', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({roots})});"
    , "  const data = await res.json();"
    , "  box.replaceChildren();"
    , "  const def = data.defaultLifetimeSeconds;"
    , "  (data.projects || []).forEach(p => box.append(card(p, def)));"
    , "}"
    , "function card(p, def) {"
    , "  const el = document.createElement('article');"
    , "  el.className = 'card';"
    , "  if (!p.found) {"
    , "    const h = document.createElement('h2');"
    , "    h.textContent = p.root || '(root)';"
    , "    const e = document.createElement('p');"
    , "    e.className = 'err';"
    , "    e.textContent = p.error || 'not found';"
    , "    el.append(h, e);"
    , "    return el;"
    , "  }"
    , "  const h = document.createElement('h2');"
    , "  h.textContent = p.root;"
    , "  const path = document.createElement('p');"
    , "  path.className = 'meta';"
    , "  path.textContent = p.liveDocs;"
    , "  const counts = document.createElement('p');"
    , "  counts.className = 'meta';"
    , "  counts.textContent = p.fileCount + ' files, ' + human(p.totalBytes);"
    , "  el.append(h, path, counts, lifetimeControl(p, def), fileList(p), claimList(p));"
    , "  const view = document.createElement('div');"
    , "  const result = document.createElement('pre');"
    , "  result.hidden = true;"
    , "  el.append(view, result);"
    , "  el._view = view;"
    , "  el._result = result;"
    , "  return el;"
    , "}"
    , "function lifetimeControl(p, def) {"
    , "  const wrap = document.createElement('div');"
    , "  wrap.className = 'row';"
    , "  const label = document.createElement('span');"
    , "  label.className = 'meta';"
    , "  if (typeof p.lifetimeError === 'string' && p.lifetimeError) {"
    , "    label.textContent = p.lifetimeError;"
    , "    label.className = 'err';"
    , "  } else if (!p.lifetimeSet) {"
    , "    label.textContent = 'Not set. Script default ' + def + ' seconds (' + daysLabel(def) + ' days).';"
    , "  } else {"
    , "    label.textContent = p.lifetimeSeconds + ' seconds (' + daysLabel(p.lifetimeSeconds) + ' days).';"
    , "  }"
    , "  const num = document.createElement('input');"
    , "  num.type = 'number';"
    , "  num.min = '1';"
    , "  num.value = p.lifetimeSet ? String(p.lifetimeSeconds) : String(def);"
    , "  const sel = document.createElement('select');"
    , "  ['seconds','days'].forEach(u => {"
    , "    const o = document.createElement('option');"
    , "    o.value = u; o.textContent = u; sel.append(o);"
    , "  });"
    , "  sel.addEventListener('change', () => {"
    , "    const raw = num.value.trim();"
    , "    const n = Number(raw);"
    , "    const whole = raw !== '' && Number.isFinite(n) && Number.isInteger(n) && n > 0;"
    , "    if (sel.value === 'days') {"
    , "      if (whole && n % 86400 === 0) { num.value = String(n / 86400); label.className = 'meta'; }"
    , "      else { num.value = ''; label.textContent = 'Not a whole number of days.'; label.className = 'err'; }"
    , "    } else if (whole) {"
    , "      num.value = String(n * 86400);"
    , "      label.className = 'meta';"
    , "    } else {"
    , "      num.value = '';"
    , "    }"
    , "  });"
    , "  const saveBtn = document.createElement('button');"
    , "  saveBtn.type = 'button';"
    , "  saveBtn.textContent = 'Save';"
    , "  saveBtn.addEventListener('click', async () => {"
    , "    const raw = num.value.trim();"
    , "    const amount = Number(raw);"
    , "    if (raw === '' || !Number.isFinite(amount) || !Number.isInteger(amount) || amount <= 0) {"
    , "      label.textContent = 'Enter a positive whole number.';"
    , "      label.className = 'err';"
    , "      return;"
    , "    }"
    , "    const res = await fetch('/api/lifetime', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({root: p.root, amount, unit: sel.value})});"
    , "    const data = await res.json();"
    , "    if (!res.ok) { label.textContent = data.error || 'save failed'; label.className = 'err'; return; }"
    , "    scan();"
    , "  });"
    , "  wrap.append(label, num, sel, saveBtn);"
    , "  return wrap;"
    , "}"
    , "function fileList(p) {"
    , "  const ul = document.createElement('ul');"
    , "  ul.className = 'files';"
    , "  (p.files || []).forEach(f => {"
    , "    const li = document.createElement('li');"
    , "    const b = document.createElement('button');"
    , "    b.type = 'button';"
    , "    b.textContent = f.rel + ' (' + human(f.bytes) + ')';"
    , "    b.addEventListener('click', () => openFile(p, f, b.closest('article')));"
    , "    li.append(b);"
    , "    ul.append(li);"
    , "  });"
    , "  return ul;"
    , "}"
    , "async function openFile(p, f, card) {"
    , "  const view = card._view;"
    , "  view.replaceChildren();"
    , "  const res = await fetch('/api/file?root=' + encodeURIComponent(p.root) + '&rel=' + encodeURIComponent(f.rel));"
    , "  if (!res.ok) {"
    , "    const data = await res.json();"
    , "    const e = document.createElement('p');"
    , "    e.className = 'err';"
    , "    e.textContent = data.error || 'read failed';"
    , "    view.append(e);"
    , "    return;"
    , "  }"
    , "  const text = await res.text();"
    , "  if (f.markdown && window.marked && typeof marked.parse === 'function') {"
    , "    const d = document.createElement('div');"
    , "    d.className = 'md';"
    , "    d.innerHTML = marked.parse(text);"
    , "    view.append(d);"
    , "  } else {"
    , "    const pre = document.createElement('pre');"
    , "    pre.textContent = text;"
    , "    view.append(pre);"
    , "  }"
    , "}"
    , "function claimList(p) {"
    , "  const ul = document.createElement('ul');"
    , "  ul.className = 'claims';"
    , "  (p.claims || []).forEach(c => {"
    , "    const li = document.createElement('li');"
    , "    const run = document.createElement('button');"
    , "    run.type = 'button';"
    , "    run.textContent = 'Run';"
    , "    run.addEventListener('click', () => runCheck(p, c.name, run.closest('article')));"
    , "    const name = document.createElement('strong');"
    , "    name.textContent = ' ' + c.name;"
    , "    li.append(run, name);"
    , "    const sub = document.createElement('ul');"
    , "    (c.claims || []).forEach(cl => {"
    , "      const sli = document.createElement('li');"
    , "      const rb = document.createElement('button');"
    , "      rb.type = 'button';"
    , "      rb.textContent = 'Run';"
    , "      rb.addEventListener('click', () => runCheck(p, c.name + '#' + cl.id, rb.closest('article')));"
    , "      const t = document.createElement('span');"
    , "      t.textContent = ' ' + cl.id + ' ' + (cl.text || '');"
    , "      sli.append(rb, t);"
    , "      sub.append(sli);"
    , "    });"
    , "    li.append(sub);"
    , "    ul.append(li);"
    , "  });"
    , "  return ul;"
    , "}"
    , "async function runCheck(p, name, card) {"
    , "  const pre = card._result;"
    , "  pre.hidden = false;"
    , "  pre.textContent = 'Running…';"
    , "  const res = await fetch('/api/check', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({root: p.root, name})});"
    , "  const data = await res.json();"
    , "  pre.textContent = data.text || data.error || '';"
    , "}"
    , "$('add-root').addEventListener('click', () => {"
    , "  const v = $('root-input').value.trim();"
    , "  if (!v || roots.includes(v)) return;"
    , "  roots.push(v);"
    , "  save(roots);"
    , "  $('root-input').value = '';"
    , "  renderRoots();"
    , "  scan();"
    , "});"
    , "renderRoots();"
    , "scan();"
    ]
