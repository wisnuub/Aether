#!/bin/bash
# Build Aether's native Plants vs. Zombies runtime for Apple Silicon.
#
#   NativePorts/PvZ/build-macos.sh <output-dir>
#
# Produces a self-contained folder:
#   pvz-native                 arm64 executable
#   libs/                      bundled SDL2 / libopenmpt / libpng / libjpeg
#   libsteam_api.dylib         Valve's Steam API redistributable (downloaded, not committed)
#   make-compat-overrides.py   text-override generator for Steam 1.2.0.1096 data
#   LICENSE, COPYING           LGPL-3.0 terms (must ship with the runtime)
#
# Requirements (Homebrew): cmake ninja sdl2 libopenmpt libpng jpeg-turbo dylibbundler
# Exit code 0 with a warning when requirements are missing, so Aether still builds.

set -euo pipefail
PORT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="${1:?usage: build-macos.sh <output-dir>}"
BUILD_DIR="${AETHER_NATIVE_BUILD_DIR:-$PORT_DIR/build}"
CACHE_DIR="${HOME}/Library/Caches/Aether/steamworks"
STEAMWORKS_CRATE_VERSION="0.13.0"   # bundles Steamworks SDK 1.62 redistributables

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

for tool in cmake ninja dylibbundler; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "warning: native PvZ runtime skipped: '$tool' not found (brew install cmake ninja sdl2 libopenmpt libpng jpeg-turbo dylibbundler)"
        exit 0
    fi
done

# 1. Compile (incremental).
cmake -G Ninja -S "$PORT_DIR" -B "$BUILD_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
    -DAETHER_STEAM=ON >/dev/null
cmake --build "$BUILD_DIR"

# 2. Steam API redistributable (cached).
STEAM_LIB="$CACHE_DIR/libsteam_api.dylib"
if [ ! -f "$STEAM_LIB" ]; then
    mkdir -p "$CACHE_DIR"
    TMP="$(mktemp -d)"
    curl -fsSL -A "aether-build" -o "$TMP/sys.crate" \
        "https://crates.io/api/v1/crates/steamworks-sys/$STEAMWORKS_CRATE_VERSION/download"
    tar -xzf "$TMP/sys.crate" -C "$TMP" \
        "steamworks-sys-$STEAMWORKS_CRATE_VERSION/lib/steam/redistributable_bin/osx/libsteam_api.dylib"
    cp "$TMP/steamworks-sys-$STEAMWORKS_CRATE_VERSION/lib/steam/redistributable_bin/osx/libsteam_api.dylib" "$STEAM_LIB"
    rm -rf "$TMP"
fi

# 3. Assemble the output folder only when something changed.
STAMP="$OUT_DIR/.build-stamp"
NEWEST="$(stat -f %m "$BUILD_DIR/pvz-native")"
if [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$NEWEST" ] && [ -x "$OUT_DIR/pvz-native" ]; then
    echo "native PvZ runtime up to date"
    exit 0
fi

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR/libs"
cp "$BUILD_DIR/pvz-native" "$OUT_DIR/"
dylibbundler -of -cd -b -x "$OUT_DIR/pvz-native" -d "$OUT_DIR/libs" -p "@executable_path/libs/" >/dev/null
# Homebrew's SDL2 is sdl2-compat, which dlopens SDL3 from @loader_path at runtime.
SDL3_LIB="$(brew --prefix sdl3 2>/dev/null)/lib/libSDL3.0.dylib"
if otool -L "$OUT_DIR/libs/libSDL2-2.0.0.dylib" >/dev/null 2>&1 && strings "$OUT_DIR/libs/libSDL2-2.0.0.dylib" | grep -q "libSDL3.dylib"; then
    cp "$SDL3_LIB" "$OUT_DIR/libs/libSDL3.dylib"
    chmod u+w "$OUT_DIR/libs/libSDL3.dylib"
    install_name_tool -id "@loader_path/libSDL3.dylib" "$OUT_DIR/libs/libSDL3.dylib" 2>/dev/null
fi
cp "$STEAM_LIB" "$OUT_DIR/"
cp "$PORT_DIR/scripts/make-compat-overrides.py" "$PORT_DIR/LICENSE" "$PORT_DIR/COPYING" "$OUT_DIR/"

# dylibbundler rewrote load commands; re-sign everything ad hoc (required on arm64).
find "$OUT_DIR" \( -name "*.dylib" -o -name "pvz-native" \) -type f -exec codesign -f -s - {} \; 2>/dev/null
echo "$NEWEST" > "$STAMP"
echo "native PvZ runtime built into $OUT_DIR"
