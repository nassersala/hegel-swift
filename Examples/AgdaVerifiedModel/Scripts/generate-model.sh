#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
EXAMPLE_DIR=$(dirname "$SCRIPT_DIR")
BUILD_DIR="$EXAMPLE_DIR/.build/agda"
FIXTURE_DIR="$EXAMPLE_DIR/Tests/AgdaVerifiedModelTests/Fixtures"

mkdir -p "$BUILD_DIR"
mkdir -p "$FIXTURE_DIR"
cd "$EXAMPLE_DIR"

agda --include-path=Agda Agda/DoorModel.agda
agda --compile --include-path=Agda --compile-dir="$BUILD_DIR" Agda/ExportDoorModel.agda
"$BUILD_DIR/ExportDoorModel"

echo "generated Tests/AgdaVerifiedModelTests/Fixtures/door-model.json"
