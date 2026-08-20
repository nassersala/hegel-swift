#!/bin/bash
# Builds Vendor/CHegel.xcframework from a hegel-rust checkout.
#
# Each slice is a dynamic CHegel.framework wrapping libhegel (built from
# hegel-c at the pinned tag) plus hegel.h and a module map, so the Swift
# package needs no systemLibrary target, no -L/-rpath flags, and no
# install-name surgery: `swift build` links the framework and SPM/Xcode
# embed it wherever it's consumed.
#
# Usage:
#   Scripts/build-xcframework.sh --hegel-rust <checkout> [--slices macos,ios,ios-sim]
#
# The checkout is a clone of https://github.com/hegeldev/hegel-rust at the
# tag this binding pins (TAG below); the script refuses to build from
# anything else. It may also be given as HEGEL_RUST in the environment.
#
# iOS slices need a rustup-managed toolchain with the aarch64-apple-ios /
# aarch64-apple-ios-sim std targets installed:
#   rustup target add aarch64-apple-ios aarch64-apple-ios-sim
set -euo pipefail

TAG="v0.32.5"
MACOS_MIN="14.0"
IOS_MIN="17.0"

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HEGEL_RUST="${HEGEL_RUST:-}"
SLICES="macos"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --hegel-rust) HEGEL_RUST="$2"; shift 2 ;;
        --slices) SLICES="$2"; shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

# --- Verify the source checkout is exactly the pinned release -------------

if [[ -z "$HEGEL_RUST" ]]; then
    echo "error: no hegel-rust checkout given" >&2
    echo "usage: $0 --hegel-rust <checkout> [--slices macos,ios,ios-sim]" >&2
    echo "hint: git clone --branch $TAG --depth 1 https://github.com/hegeldev/hegel-rust" >&2
    exit 2
fi

DESCRIBED=$(git -C "$HEGEL_RUST" describe --tags --exact-match 2>/dev/null || true)
if [[ "$DESCRIBED" != "$TAG" ]]; then
    echo "error: $HEGEL_RUST is at '${DESCRIBED:-<no tag>}', need $TAG" >&2
    echo "hint: git clone --branch $TAG --depth 1 https://github.com/hegeldev/hegel-rust" >&2
    exit 1
fi
HEADER="$HEGEL_RUST/hegel-c/include/hegel.h"
[[ -f "$HEADER" ]] || { echo "error: $HEADER not found" >&2; exit 1; }

BUILD_DIR="$REPO_DIR/.build/xcframework"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# --- One framework per slice ----------------------------------------------

write_modulemap() {
    cat > "$1" <<'EOF'
framework module CHegel {
    umbrella header "hegel.h"
    export *
}
EOF
}

write_info_plist() {  # $1 = path, $2 = platform key, $3 = min-version key/value
    cat > "$1" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>dev.hegel.CHegel</string>
    <key>CFBundleName</key><string>CHegel</string>
    <key>CFBundleExecutable</key><string>CHegel</string>
    <key>CFBundlePackageType</key><string>FMWK</string>
    <key>CFBundleShortVersionString</key><string>${TAG#v}</string>
    <key>CFBundleVersion</key><string>${TAG#v}</string>
    <key>CFBundleSupportedPlatforms</key><array><string>$2</string></array>
    $3
</dict>
</plist>
EOF
}

build_slice() {  # $1 = slice name
    local slice="$1" triple env_prefix="" dylib fw
    case "$slice" in
        macos)   triple="aarch64-apple-darwin"; env_prefix="MACOSX_DEPLOYMENT_TARGET=$MACOS_MIN" ;;
        ios)     triple="aarch64-apple-ios"; env_prefix="IPHONEOS_DEPLOYMENT_TARGET=$IOS_MIN" ;;
        ios-sim) triple="aarch64-apple-ios-sim"; env_prefix="IPHONEOS_DEPLOYMENT_TARGET=$IOS_MIN" ;;
        *) echo "unknown slice: $slice" >&2; exit 2 ;;
    esac

    echo "== building $slice ($triple)"
    (cd "$HEGEL_RUST" && env $env_prefix \
        cargo build --release -p hegeltest-c --target "$triple")
    dylib="$HEGEL_RUST/target/$triple/release/libhegel_c.dylib"

    fw="$BUILD_DIR/$slice/CHegel.framework"
    if [[ "$slice" == "macos" ]]; then
        # Versioned (deep) bundle layout, required on macOS.
        mkdir -p "$fw/Versions/A/Headers" "$fw/Versions/A/Modules" "$fw/Versions/A/Resources"
        cp "$dylib" "$fw/Versions/A/CHegel"
        cp "$HEADER" "$fw/Versions/A/Headers/hegel.h"
        write_modulemap "$fw/Versions/A/Modules/module.modulemap"
        write_info_plist "$fw/Versions/A/Resources/Info.plist" "MacOSX" \
            "<key>LSMinimumSystemVersion</key><string>$MACOS_MIN</string>"
        ln -s A "$fw/Versions/Current"
        ln -s Versions/Current/CHegel "$fw/CHegel"
        ln -s Versions/Current/Headers "$fw/Headers"
        ln -s Versions/Current/Modules "$fw/Modules"
        ln -s Versions/Current/Resources "$fw/Resources"
        install_name_tool -id "@rpath/CHegel.framework/Versions/A/CHegel" "$fw/Versions/A/CHegel"
    else
        # Shallow bundle layout, required on iOS.
        mkdir -p "$fw/Headers" "$fw/Modules"
        cp "$dylib" "$fw/CHegel"
        cp "$HEADER" "$fw/Headers/hegel.h"
        write_modulemap "$fw/Modules/module.modulemap"
        write_info_plist "$fw/Info.plist" \
            "$([[ "$slice" == ios ]] && echo iPhoneOS || echo iPhoneSimulator)" \
            "<key>MinimumOSVersion</key><string>$IOS_MIN</string>"
        install_name_tool -id "@rpath/CHegel.framework/CHegel" "$fw/CHegel"
    fi
    codesign --force --sign - "$fw"
}

FRAMEWORK_ARGS=()
IFS=',' read -ra SLICE_LIST <<< "$SLICES"
for slice in "${SLICE_LIST[@]}"; do
    build_slice "$slice"
    FRAMEWORK_ARGS+=(-framework "$BUILD_DIR/$slice/CHegel.framework")
done

# --- Assemble ---------------------------------------------------------------

OUT="$REPO_DIR/Vendor/CHegel.xcframework"
rm -rf "$OUT"
xcodebuild -create-xcframework "${FRAMEWORK_ARGS[@]}" -output "$OUT"
echo "== wrote $OUT"
find "$OUT" -name CHegel -type f | while read -r bin; do
    shasum -a 256 "$bin"
done
