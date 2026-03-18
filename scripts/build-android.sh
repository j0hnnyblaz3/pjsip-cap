#!/bin/bash
#
# Build PJSIP + OpenSSL + Opus for Android from source.
# Produces static libs in android/src/main/jniLibs/<abi>/
#
# Usage:
#   ./scripts/build-android.sh          # full build
#   ./scripts/build-android.sh clean    # remove all build artifacts
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$PROJECT_ROOT/build/android"

# Versions
PJSIP_VERSION="2.16"
OPENSSL_VERSION="3.4.1"
OPUS_VERSION="1.5.2"

# Android settings
MIN_API=24
TARGET_ABIS="arm64-v8a armeabi-v7a x86_64"

# Output — PJSIP .so files go here for Gradle to pick up
JNILIBS_DIR="$PROJECT_ROOT/android/src/main/jniLibs"

# --- Detect NDK ---
if [ -z "${ANDROID_NDK_ROOT:-}" ]; then
    # Try common locations
    for candidate in \
        "/opt/homebrew/share/android-commandlinetools/ndk/27.2.12479018" \
        "$HOME/Library/Android/sdk/ndk/27.2.12479018" \
        "$HOME/Library/Android/sdk/ndk/"*; do
        if [ -d "$candidate/toolchains/llvm" ]; then
            ANDROID_NDK_ROOT="$candidate"
            break
        fi
    done
fi

if [ -z "${ANDROID_NDK_ROOT:-}" ] || [ ! -d "$ANDROID_NDK_ROOT" ]; then
    echo "ERROR: ANDROID_NDK_ROOT not set and NDK not found." >&2
    echo "Install with: sdkmanager 'ndk;27.2.12479018'" >&2
    exit 1
fi

export ANDROID_NDK_ROOT

# Detect host tag
case "$(uname -s)-$(uname -m)" in
    Darwin-arm64) HOST_TAG="darwin-x86_64" ;;  # NDK uses x86_64 even on Apple Silicon
    Darwin-x86_64) HOST_TAG="darwin-x86_64" ;;
    Linux-x86_64) HOST_TAG="linux-x86_64" ;;
    *) echo "Unsupported host" >&2; exit 1 ;;
esac

TOOLCHAIN="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/$HOST_TAG"

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

log()   { echo -e "${GREEN}[BUILD]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# --- Clean ---
if [ "${1:-}" = "clean" ]; then
    log "Cleaning build artifacts..."
    rm -rf "$BUILD_DIR"
    rm -rf "$JNILIBS_DIR"
    log "Clean complete."
    exit 0
fi

mkdir -p "$BUILD_DIR/src" "$BUILD_DIR/output" "$BUILD_DIR/work"

# ===================================================================
# Helpers: map ABI to build targets
# ===================================================================

abi_to_openssl_target() {
    case "$1" in
        arm64-v8a)   echo "android-arm64" ;;
        armeabi-v7a) echo "android-arm" ;;
        x86_64)      echo "android-x86_64" ;;
    esac
}

abi_to_triple() {
    case "$1" in
        arm64-v8a)   echo "aarch64-linux-android" ;;
        armeabi-v7a) echo "armv7a-linux-androideabi" ;;
        x86_64)      echo "x86_64-linux-android" ;;
    esac
}

abi_to_clang_triple() {
    # Clang triple includes API level
    case "$1" in
        arm64-v8a)   echo "aarch64-linux-android${MIN_API}" ;;
        armeabi-v7a) echo "armv7a-linux-androideabi${MIN_API}" ;;
        x86_64)      echo "x86_64-linux-android${MIN_API}" ;;
    esac
}

abi_to_configure_host() {
    case "$1" in
        arm64-v8a)   echo "aarch64-linux-android" ;;
        armeabi-v7a) echo "arm-linux-androideabi" ;;
        x86_64)      echo "x86_64-linux-android" ;;
    esac
}

abi_to_pjsip_target() {
    case "$1" in
        arm64-v8a)   echo "arm64-v8a" ;;
        armeabi-v7a) echo "armeabi-v7a" ;;
        x86_64)      echo "x86_64" ;;
    esac
}

# ===================================================================
# 1. Build OpenSSL
# ===================================================================

build_openssl() {
    local abi="$1"
    local prefix="$BUILD_DIR/output/openssl-${abi}"

    if [ -f "$prefix/lib/libssl.a" ]; then
        log "OpenSSL ($abi) already built, skipping."
        return
    fi

    log "Building OpenSSL $OPENSSL_VERSION for $abi..."

    local src_dir="$BUILD_DIR/src/openssl-$OPENSSL_VERSION"
    if [ ! -d "$src_dir" ]; then
        log "Downloading OpenSSL $OPENSSL_VERSION..."
        curl -sL "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz" \
            -o "$BUILD_DIR/src/openssl.tar.gz"
        tar xzf "$BUILD_DIR/src/openssl.tar.gz" -C "$BUILD_DIR/src/"
    fi

    local work_dir="$BUILD_DIR/work/openssl-${abi}"
    rm -rf "$work_dir"
    cp -a "$src_dir" "$work_dir"
    cd "$work_dir"

    local target
    target=$(abi_to_openssl_target "$abi")

    export PATH="$TOOLCHAIN/bin:$PATH"
    export ANDROID_NDK_HOME="$ANDROID_NDK_ROOT"

    ./Configure "$target" \
        no-shared \
        no-tests \
        no-ui-console \
        no-async \
        no-engine \
        no-comp \
        -D__ANDROID_API__=$MIN_API \
        --prefix="$prefix" \
        2>&1 | tail -5

    make -j"$(sysctl -n hw.ncpu)" 2>&1 | tail -3
    make install_sw 2>&1 | tail -3

    cd "$PROJECT_ROOT"
    log "OpenSSL ($abi) done."
}

# ===================================================================
# 2. Build Opus
# ===================================================================

build_opus() {
    local abi="$1"
    local prefix="$BUILD_DIR/output/opus-${abi}"

    if [ -f "$prefix/lib/libopus.a" ]; then
        log "Opus ($abi) already built, skipping."
        return
    fi

    log "Building Opus $OPUS_VERSION for $abi..."

    local src_dir="$BUILD_DIR/src/opus-$OPUS_VERSION"
    if [ ! -d "$src_dir" ]; then
        log "Downloading Opus $OPUS_VERSION..."
        curl -sL "https://downloads.xiph.org/releases/opus/opus-$OPUS_VERSION.tar.gz" \
            -o "$BUILD_DIR/src/opus.tar.gz"
        tar xzf "$BUILD_DIR/src/opus.tar.gz" -C "$BUILD_DIR/src/"
    fi

    local work_dir="$BUILD_DIR/work/opus-${abi}"
    rm -rf "$work_dir"
    cp -a "$src_dir" "$work_dir"
    cd "$work_dir"

    local clang_triple
    clang_triple=$(abi_to_clang_triple "$abi")
    local host
    host=$(abi_to_configure_host "$abi")

    export PATH="$TOOLCHAIN/bin:$PATH"
    export CC="${TOOLCHAIN}/bin/${clang_triple}-clang"
    export CXX="${TOOLCHAIN}/bin/${clang_triple}-clang++"
    export AR="${TOOLCHAIN}/bin/llvm-ar"
    export RANLIB="${TOOLCHAIN}/bin/llvm-ranlib"
    export STRIP="${TOOLCHAIN}/bin/llvm-strip"

    ./configure \
        --host="$host" \
        --prefix="$prefix" \
        --enable-static \
        --disable-shared \
        --disable-doc \
        --disable-extra-programs \
        --with-sysroot="$TOOLCHAIN/sysroot" \
        CFLAGS="-O2" \
        2>&1 | tail -5

    make -j"$(sysctl -n hw.ncpu)" 2>&1 | tail -3
    make install 2>&1 | tail -3

    unset CC CXX AR RANLIB STRIP
    cd "$PROJECT_ROOT"
    log "Opus ($abi) done."
}

# ===================================================================
# 3. Build PJSIP
# ===================================================================

build_pjsip() {
    local abi="$1"
    local prefix="$BUILD_DIR/output/pjsip-${abi}"

    if [ -f "$prefix/lib/libpjsua2.a" ]; then
        log "PJSIP ($abi) already built, skipping."
        return
    fi

    log "Building PJSIP $PJSIP_VERSION for $abi..."

    local src_dir="$BUILD_DIR/src/pjproject-$PJSIP_VERSION"
    if [ ! -d "$src_dir" ]; then
        log "Downloading PJSIP $PJSIP_VERSION..."
        curl -sL "https://github.com/pjsip/pjproject/archive/refs/tags/$PJSIP_VERSION.tar.gz" \
            -o "$BUILD_DIR/src/pjsip.tar.gz"
        tar xzf "$BUILD_DIR/src/pjsip.tar.gz" -C "$BUILD_DIR/src/"
    fi

    local work_dir="$BUILD_DIR/work/pjsip-${abi}"
    rm -rf "$work_dir"
    cp -a "$src_dir" "$work_dir"
    cd "$work_dir"

    local ssl_prefix="$BUILD_DIR/output/openssl-${abi}"
    local opus_prefix="$BUILD_DIR/output/opus-${abi}"

    # Write config_site.h
    cat > pjlib/include/pj/config_site.h <<'PJCFG'
#define PJ_CONFIG_ANDROID 1
#define PJ_HAS_SSL_SOCK 1
#define PJMEDIA_HAS_OPUS_CODEC 1

/* Audio-only: disable video */
#define PJMEDIA_HAS_VIDEO 0
#define PJMEDIA_HAS_OPENH264_CODEC 0
#define PJMEDIA_HAS_VPX_CODEC 0

/* Codec config */
#define PJMEDIA_HAS_G711_CODEC 1
#define PJMEDIA_HAS_GSM_CODEC 1
#define PJMEDIA_HAS_ILBC_CODEC 1
#define PJMEDIA_HAS_SPEEX_CODEC 1

#include <pj/config_site_sample.h>
PJCFG

    export TARGET_ABI="$abi"
    export APP_PLATFORM="$MIN_API"
    export ANDROID_NDK_ROOT

    ./configure-android \
        --prefix="$prefix" \
        --with-ssl="$ssl_prefix" \
        --with-opus="$opus_prefix" \
        --disable-video \
        --disable-openh264 \
        --disable-ffmpeg \
        --disable-v4l2 \
        2>&1 | tail -10

    make dep 2>&1 | tail -3
    # Build libraries only (skip samples/tests)
    make -j"$(sysctl -n hw.ncpu)" lib 2>&1 | tail -5
    make install 2>&1 | tail -5

    # Manually collect all .a files
    mkdir -p "$prefix/lib" "$prefix/include"

    find . -name "*.a" -not -path "*/output/*" | while read -r lib; do
        cp "$lib" "$prefix/lib/" 2>/dev/null || true
    done

    # Copy headers
    for dir in pjsip pjlib pjlib-util pjmedia pjnath; do
        if [ -d "$dir/include" ]; then
            cp -a "$dir/include/"* "$prefix/include/" 2>/dev/null || true
        fi
    done

    unset TARGET_ABI APP_PLATFORM
    cd "$PROJECT_ROOT"
    log "PJSIP ($abi) done."
}

# ===================================================================
# 4. Collect outputs for Gradle
# ===================================================================

collect_for_gradle() {
    log "Collecting libraries for Gradle..."

    # For Android with Capacitor, we need the static .a files
    # The Gradle build will link them via CMake or ndk-build
    # For simplicity, we'll create a structure the build.gradle can reference

    local libs_dir="$PROJECT_ROOT/android/libs"
    mkdir -p "$libs_dir"

    for abi in $TARGET_ABIS; do
        local abi_dir="$libs_dir/$abi"
        mkdir -p "$abi_dir/lib" "$abi_dir/include"

        # Copy PJSIP libs
        local pjsip_dir="$BUILD_DIR/output/pjsip-${abi}"
        if [ -d "$pjsip_dir/lib" ]; then
            cp "$pjsip_dir"/lib/*.a "$abi_dir/lib/" 2>/dev/null || true
        fi

        # Copy OpenSSL libs
        local ssl_dir="$BUILD_DIR/output/openssl-${abi}"
        [ -f "$ssl_dir/lib/libssl.a" ] && cp "$ssl_dir/lib/libssl.a" "$abi_dir/lib/"
        [ -f "$ssl_dir/lib/libcrypto.a" ] && cp "$ssl_dir/lib/libcrypto.a" "$abi_dir/lib/"

        # Copy Opus lib
        local opus_dir="$BUILD_DIR/output/opus-${abi}"
        [ -f "$opus_dir/lib/libopus.a" ] && cp "$opus_dir/lib/libopus.a" "$abi_dir/lib/"

        # Copy headers (same for all ABIs, just use the first)
        if [ ! -f "$libs_dir/include-copied" ] && [ -d "$pjsip_dir/include" ]; then
            cp -a "$pjsip_dir/include/"* "$libs_dir/" 2>/dev/null || true
            # Also copy OpenSSL headers
            [ -d "$ssl_dir/include" ] && cp -a "$ssl_dir/include/"* "$libs_dir/" 2>/dev/null || true
            # Opus headers
            [ -d "$opus_dir/include" ] && cp -a "$opus_dir/include/"* "$libs_dir/" 2>/dev/null || true
            touch "$libs_dir/include-copied"
        fi

        local lib_count
        lib_count=$(find "$abi_dir/lib" -name "*.a" | wc -l | tr -d ' ')
        log "  $abi: $lib_count static libs"
    done

    log "Libraries collected in android/libs/"
}

# ===================================================================
# Main
# ===================================================================

log "=== Building PJSIP SDK for Android ==="
log "PJSIP: $PJSIP_VERSION | OpenSSL: $OPENSSL_VERSION | Opus: $OPUS_VERSION"
log "NDK: $ANDROID_NDK_ROOT"
log "Min API: $MIN_API | ABIs: $TARGET_ABIS"
echo ""

# Step 1: Build dependencies for all ABIs
log "--- Step 1: OpenSSL ---"
for abi in $TARGET_ABIS; do
    build_openssl "$abi"
done

log "--- Step 2: Opus ---"
for abi in $TARGET_ABIS; do
    build_opus "$abi"
done

# Step 3: Build PJSIP
log "--- Step 3: PJSIP ---"
for abi in $TARGET_ABIS; do
    build_pjsip "$abi"
done

# Step 4: Collect
log "--- Step 4: Collect for Gradle ---"
collect_for_gradle

echo ""
log "=== Android build complete! ==="
log "Static libs: android/libs/<abi>/lib/*.a"
log "Headers: android/libs/*.h"
