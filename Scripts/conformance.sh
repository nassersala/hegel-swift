#!/bin/bash
# Layer-2 differential conformance: hegel-swift and hegel-go must interpret
# the same seed into the same choice sequence. Both harnesses in
# Conformance/ run the same draw program (identical arguments to identical
# libhegel calls, seed 42, derandomized, database off) against the SAME
# engine binary — the vendored CHegel framework dylib, which hegel-go loads
# via HEGEL_LIBHEGEL_PATH (hegel-go pins libhegel 0.32.5, same as this
# binding). The transcripts must match byte for byte.
#
# Requires a Go toolchain (brew install go).
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LIBHEGEL="$REPO_DIR/Vendor/CHegel.xcframework/macos-arm64/CHegel.framework/Versions/A/CHegel"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

echo "== swift transcript"
(cd "$REPO_DIR/Conformance/transcript-swift" && swift run -c release 2>/dev/null) \
    | grep '^case ' > "$OUT/swift.txt"

echo "== go transcript"
(cd "$REPO_DIR/Conformance/transcript-go" \
    && go build -o "$OUT/transcript-go" . \
    && HEGEL_LIBHEGEL_PATH="$LIBHEGEL" "$OUT/transcript-go" 2>/dev/null) \
    | grep '^case ' > "$OUT/go.txt"

echo "== comparing $(wc -l < "$OUT/swift.txt" | tr -d ' ') cases"
if diff -u "$OUT/go.txt" "$OUT/swift.txt"; then
    echo "OK: draw transcripts are identical"
else
    echo "FAIL: hegel-swift and hegel-go disagree on the choice sequence" >&2
    exit 1
fi
