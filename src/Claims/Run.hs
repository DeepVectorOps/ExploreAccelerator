module Claims.Run (runCmd) where

import Claims.Result (Reason (..))
import Control.Exception (IOException, try)
import Data.String.Conversions (cs)
import Data.Text (Text)
import qualified Data.Text as T
import System.Exit (ExitCode (..))
import System.Process (proc, readCreateProcessWithExitCode)

-- | Raw stdout lines of @bash -c cmd@. Exit 1 (no matches) is fine; exit >= 2 or exec failure is not.
runCmd :: Text -> IO (Either Reason [Text])
runCmd cmd
  | T.null (T.strip cmd) = pure (Left (Rejected "empty command"))
  | otherwise =
      try (readCreateProcessWithExitCode (proc "bash" ["-c", cs cmd]) "") >>= \case
        Left e -> pure (Left (ExecFailed (cs (show (e :: IOException)))))
        Right (ExitFailure n, _, err) | n >= 2 -> pure (Left (ExecFailed (T.strip (cs err))))
        Right (_, out, _) -> pure (Right (T.lines (cs out)))
