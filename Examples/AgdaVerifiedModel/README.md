# Agda-verified model experiment

This example tests the proposed boundary between formal verification and
property-based testing:

1. `Agda/DoorModel.agda` defines a total two-state door model and is checked
   with Agda's `--safe` mode (no postulates).
2. Agda checks two theorems about that same executable `step` definition:
   opening succeeds only from the unlocked state, and locking always leaves
   the model locked.
3. The separate `Agda/ExportDoorModel.agda` IO module evaluates every
   state/command pair and writes the complete transition table to the Swift
   test fixture. Filesystem FFI never enters the trusted proof module.
4. Hegel treats that generated table as the oracle for a Swift door and
   shrinks a planted conformance bug to one `open` command.

Regenerate the artifact and run the consumer:

```sh
./Scripts/generate-model.sh
swift test
```

Generation requires `agda` and the GHC backend (`ghc`). The checked-in JSON
means consumers of the Swift example need neither tool unless they change the
formal model.

The experiment intentionally has no Agda-to-Swift compiler and no Agda
runtime inside the test. For a finite model, exporting the complete evaluated
table keeps the bridge small and ensures Swift does not hand-translate the
verified transition function.
