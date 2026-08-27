module ExportDoorModel where

-- Filesystem IO is intentionally isolated from the `--safe` proof module.
-- This module only materialises DoorModel.artifact after DoorModel has passed
-- Agda's coverage, termination, and safe-mode checks.

open import Agda.Builtin.IO using (IO)
open import Agda.Builtin.String using (String)
open import Agda.Builtin.Unit using (⊤)
open import DoorModel using (artifact)

postulate writeFile : String → String → IO ⊤

{-# FOREIGN GHC import qualified Data.Text as Text #-}
{-# FOREIGN GHC import qualified Data.Text.IO as TextIO #-}
{-# COMPILE GHC writeFile = \ path contents -> TextIO.writeFile (Text.unpack path) contents #-}

main : IO ⊤
main = writeFile "Tests/AgdaVerifiedModelTests/Fixtures/door-model.json" artifact
