#!/bin/bash
# Layer-2 differential conformance: hegel-swift, hegel-go, hegel-rust and
# dialectic must interpret the same seed into the same choice sequence.
# Every harness in Conformance/ runs the same draw programs (identical
# arguments to identical libhegel calls, seed 42, derandomized, database
# off) against libhegel 0.32.5: the vendored CHegel framework dylib for
# swift, go (loaded via HEGEL_LIBHEGEL_PATH) and dialectic (linked
# directly); the rust column links its own copy of the same engine
# version statically, so it is the reference the engine's own language
# gives. The transcripts of each program must match byte for byte.
#
# Programs: primitives, bigints, text, strings, lists, stateful,
# stateful-reject. A harness that cannot express a program exits 2 and
# its column is skipped for that program.
#
# Requires a Go toolchain (brew install go) and cargo (brew install rust).
# The dialectic column is optional: set DIALECTIC_DIR to a dialectic
# checkout (and have cmake installed) to include it.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LIBHEGEL="$REPO_DIR/Vendor/CHegel.xcframework/macos-arm64/CHegel.framework/Versions/A/CHegel"
DIALECTIC_DIR="${DIALECTIC_DIR:-}"
PROGRAMS="primitives bigints text strings lists stateful stateful-reject"
# Divergences confirmed real and reported upstream, as column:program.
# They print instead of failing the run until the fix lands.
#   go:stateful-reject  hegel-go never calls hegel_state_machine_rule_rejected
#                       (hegeldev/hegel-go#135), so a rejected rule is charged
#                       to its step budget.
KNOWN="go:stateful-reject"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

echo "== building swift"
(cd "$REPO_DIR/Conformance/transcript-swift" && swift build -c release 2>/dev/null)
SWIFT_BIN="$REPO_DIR/Conformance/transcript-swift/.build/release/transcript-swift"

echo "== building go"
(cd "$REPO_DIR/Conformance/transcript-go" && go build -o "$OUT/transcript-go" .)

echo "== building rust"
(cd "$REPO_DIR/Conformance/transcript-rust" && cargo build --release --quiet)
RUST_BIN="$REPO_DIR/Conformance/transcript-rust/target/release/transcript-rust"

# The dialectic column needs a local checkout (not present in CI): skip
# with a notice rather than fail when it is missing.
HAVE_DIALECTIC=0
if [ -n "$DIALECTIC_DIR" ] && [ -d "$DIALECTIC_DIR" ] && command -v cmake > /dev/null; then
    HAVE_DIALECTIC=1
    echo "== building dialectic"
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
else
    echo "== dialectic: set DIALECTIC_DIR to a dialectic checkout to include it; skipping"
fi

# transcript <column> <program>: writes $OUT/<program>.<column>.txt, or
# returns 2 when the column cannot express the program.
transcript() {
    local column="$1" program="$2" file="$OUT/$2.$1.txt" status=0
    case "$column" in
        swift) "$SWIFT_BIN" "$program" > "$file.raw" 2>/dev/null || status=$? ;;
        go) HEGEL_LIBHEGEL_PATH="$LIBHEGEL" "$OUT/transcript-go" "$program" > "$file.raw" 2>/dev/null || status=$? ;;
        rust) "$RUST_BIN" "$program" > "$file.raw" 2>/dev/null || status=$? ;;
        dialectic) "$OUT/transcript-dialectic" "$program" > "$file.raw" 2>/dev/null || status=$? ;;
    esac
    if [ "$status" -eq 2 ]; then return 2; fi
    if [ "$status" -ne 0 ]; then
        echo "FAIL: $column $program exited $status" >&2
        return 1
    fi
    grep -E '^(case|step)( |$)' "$file.raw" > "$file" || true
}

status=0
for program in $PROGRAMS; do
    transcript rust "$program"
    columns="swift go"
    [ "$HAVE_DIALECTIC" -eq 1 ] && columns="$columns dialectic"
    lines="$(wc -l < "$OUT/$program.rust.txt" | tr -d ' ')"
    compared="rust"
    for column in $columns; do
        if transcript "$column" "$program"; then
            if diff -u "$OUT/$program.rust.txt" "$OUT/$program.$column.txt" > "$OUT/$program.$column.diff"; then
                compared="$compared $column"
            elif [[ " $KNOWN " == *" $column:$program "* ]]; then
                echo "== $program: $column disagrees with rust (known, reported upstream; $(wc -l < "$OUT/$program.$column.txt" | tr -d ' ') lines)"
            else
                echo "FAIL: $program: $column disagrees with rust" >&2
                cat "$OUT/$program.$column.diff" >&2
                status=1
            fi
        elif [ $? -eq 2 ]; then
            :
        else
            status=1
        fi
    done
    echo "== $program: $lines lines, identical across: $compared"
done
if [ "$status" -eq 0 ]; then
    echo "OK: draw transcripts are identical"
fi
exit "$status"
