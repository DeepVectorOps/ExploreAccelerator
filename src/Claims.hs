-- | Replayable "claims" written by explore agents: a statement, a bash
-- command and its expected output. A claim holds while replaying the command
-- yields exactly the same output.
module Claims
  ( module Claims.Name
  , module Claims.Quote
  , module Claims.File
  , module Claims.Result
  , module Claims.Run
  , module Claims.Check
  ) where

import Claims.Check
import Claims.File
import Claims.Name
import Claims.Quote
import Claims.Result
import Claims.Run
