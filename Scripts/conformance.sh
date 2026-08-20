#!/bin/bash
# Layer-2 differential conformance: hegel-swift, hegel-go, and dialectic
# must interpret the same seed into the same choice sequence. All three
# harnesses in Conformance/ run the same draw program (identical arguments
# to identical libhegel calls, seed 42, derandomized, database off) against
# the SAME engine binary — the vendored CHegel framework dylib, which
# hegel-go loads via HEGEL_LIBHEGEL_PATH and dialectic links directly (all
# three pin libhegel 0.32.5). The transcripts must match byte for byte.
#
# Requires a Go toolchain (brew install go), cmake, and a checkout of
# dialectic (default ~/src/dialectic, override with DIALECTIC_DIR).
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LIBHEGEL="$REPO_DIR/Vendor/CHegel.xcframework/macos-arm64/CHegel.framework/Versions/A/CHegel"
DIALECTIC_DIR="${DIALECTIC_DIR:-$HOME/src/dialectic}"
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

# The dialectic column needs a local checkout (not present in CI): skip
# with a notice rather than fail when it is missing.
HAVE_DIALECTIC=0
if [ -d "$DIALECTIC_DIR" ] && command -v cmake > /dev/null; then
    HAVE_DIALECTIC=1
    echo "== dialectic transcript"
    cmake -S "$DIALECTIC_DIR" -B "$OUT/dialectic-build" \
        -DCMAKE_BUILD_TYPE=Release \
        -DDIALECTIC_LIBHEGEL_LIBRARY="$LIBHEGEL" \
        -DDIALECTIC_BUILD_TESTS=OFF -DDIALECTIC_BUILD_EXAMPLES=OFF > /dev/null
    cmake --build "$OUT/dialectic-build" > /dev/null
    clang -std=c99 -Wall -Wextra -I "$DIALECTIC_DIR/include" \
        "$REPO_DIR/Conformance/transcript-dialectic/main.c" \
        "$OUT/dialectic-build/libdialectic.a" "$LIBHEGEL" \
        -Wl,-rpath,"$REPO_DIR/Vendor/CHegel.xcframework/macos-arm64" \
        -o "$OUT/transcript-dialectic"
    "$OUT/transcript-dialectic" 2>/dev/null | grep '^case ' > "$OUT/dialectic.txt"
else
    echo "== dialectic transcript: no checkout at $DIALECTIC_DIR (or no cmake); skipping"
fi

echo "== comparing $(wc -l < "$OUT/swift.txt" | tr -d ' ') cases"
status=0
if ! diff -u "$OUT/go.txt" "$OUT/swift.txt"; then
    echo "FAIL: hegel-swift and hegel-go disagree on the choice sequence" >&2
    status=1
fi
if [ "$HAVE_DIALECTIC" -eq 1 ] && ! diff -u "$OUT/go.txt" "$OUT/dialectic.txt"; then
    echo "FAIL: dialectic and hegel-go disagree on the choice sequence" >&2
    status=1
fi
if [ "$status" -eq 0 ]; then
    echo "OK: draw transcripts are identical"
fi
exit "$status"
