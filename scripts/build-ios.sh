#!/bin/bash
#
# Build PJSIP + OpenSSL + Opus for iOS from source.
# Produces an XCFramework at ios/Frameworks/PjsipSDK.xcframework
#
# Usage:
#   ./scripts/build-ios.sh          # full build
#   ./scripts/build-ios.sh clean    # remove all build artifacts
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$PROJECT_ROOT/build/ios"

# Versions
PJSIP_VERSION="2.16"
OPENSSL_VERSION="3.4.1"
OPUS_VERSION="1.5.2"

# Minimum iOS version
MIN_IOS="15.0"

# Architectures to build
DEVICE_ARCH="arm64"
SIM_ARCHS="arm64 x86_64"

# Output
FRAMEWORK_DIR="$PROJECT_ROOT/ios/Frameworks"

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
    rm -rf "$FRAMEWORK_DIR/PjsipSDK.xcframework"
    log "Clean complete."
    exit 0
fi

mkdir -p "$BUILD_DIR/src" "$BUILD_DIR/output" "$BUILD_DIR/work"

# ===================================================================
# Helpers
# ===================================================================

get_sdk_path() {
    local platform="$1"
    xcrun --sdk "$platform" --show-sdk-path
}

get_cc() {
    xcrun --sdk "$1" -f clang
}

# ===================================================================
# 1. Build OpenSSL
# ===================================================================

build_openssl() {
    local arch="$1"
    local platform="$2"  # iphoneos or iphonesimulator
    local prefix="$BUILD_DIR/output/openssl-${platform}-${arch}"

    if [ -f "$prefix/lib/libssl.a" ]; then
        log "OpenSSL ($platform/$arch) already built, skipping."
        return
    fi

    log "Building OpenSSL $OPENSSL_VERSION for $platform/$arch..."

    local src_dir="$BUILD_DIR/src/openssl-$OPENSSL_VERSION"
    if [ ! -d "$src_dir" ]; then
        log "Downloading OpenSSL $OPENSSL_VERSION..."
        curl -sL "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz" \
            -o "$BUILD_DIR/src/openssl.tar.gz"
        tar xzf "$BUILD_DIR/src/openssl.tar.gz" -C "$BUILD_DIR/src/"
    fi

    # Work in a copy to allow parallel builds
    local work_dir="$BUILD_DIR/work/openssl-${platform}-${arch}"
    rm -rf "$work_dir"
    cp -a "$src_dir" "$work_dir"
    cd "$work_dir"

    local sdk_path
    sdk_path=$(get_sdk_path "$platform")

    local target
    local min_ver_flag
    if [ "$platform" = "iphoneos" ]; then
        target="ios64-xcrun"
        min_ver_flag="-miphoneos-version-min=$MIN_IOS"
    else
        target="iossimulator-xcrun"
        min_ver_flag="-mios-simulator-version-min=$MIN_IOS"
    fi

    ./Configure "$target" \
        no-shared \
        no-tests \
        no-ui-console \
        no-async \
        no-engine \
        no-comp \
        --prefix="$prefix" \
        "$min_ver_flag" \
        "-arch $arch" \
        -isysroot "$sdk_path" \
        2>&1 | tail -5

    make -j"$(sysctl -n hw.ncpu)" 2>&1 | tail -3
    make install_sw 2>&1 | tail -3

    cd "$PROJECT_ROOT"
    log "OpenSSL ($platform/$arch) done."
}

# ===================================================================
# 2. Build Opus
# ===================================================================

build_opus() {
    local arch="$1"
    local platform="$2"
    local prefix="$BUILD_DIR/output/opus-${platform}-${arch}"

    if [ -f "$prefix/lib/libopus.a" ]; then
        log "Opus ($platform/$arch) already built, skipping."
        return
    fi

    log "Building Opus $OPUS_VERSION for $platform/$arch..."

    local src_dir="$BUILD_DIR/src/opus-$OPUS_VERSION"
    if [ ! -d "$src_dir" ]; then
        log "Downloading Opus $OPUS_VERSION..."
        curl -sL "https://downloads.xiph.org/releases/opus/opus-$OPUS_VERSION.tar.gz" \
            -o "$BUILD_DIR/src/opus.tar.gz"
        tar xzf "$BUILD_DIR/src/opus.tar.gz" -C "$BUILD_DIR/src/"
    fi

    local work_dir="$BUILD_DIR/work/opus-${platform}-${arch}"
    rm -rf "$work_dir"
    cp -a "$src_dir" "$work_dir"
    cd "$work_dir"

    local sdk_path
    sdk_path=$(get_sdk_path "$platform")
    local cc
    cc=$(get_cc "$platform")

    local host
    if [ "$arch" = "arm64" ]; then
        host="aarch64-apple-darwin"
    else
        host="x86_64-apple-darwin"
    fi

    local extra_cflags=""
    if [ "$platform" = "iphonesimulator" ]; then
        extra_cflags="-mios-simulator-version-min=$MIN_IOS"
    else
        extra_cflags="-miphoneos-version-min=$MIN_IOS"
    fi

    CC="$cc" \
    CFLAGS="-arch $arch -isysroot $sdk_path -O2 $extra_cflags" \
    LDFLAGS="-arch $arch -isysroot $sdk_path" \
    ./configure \
        --host="$host" \
        --prefix="$prefix" \
        --enable-static \
        --disable-shared \
        --disable-doc \
        --disable-extra-programs \
        2>&1 | tail -5

    make -j"$(sysctl -n hw.ncpu)" 2>&1 | tail -3
    make install 2>&1 | tail -3

    cd "$PROJECT_ROOT"
    log "Opus ($platform/$arch) done."
}

# ===================================================================
# 3. Build PJSIP
# ===================================================================

build_pjsip() {
    local arch="$1"
    local platform="$2"
    local prefix="$BUILD_DIR/output/pjsip-${platform}-${arch}"

    if [ -f "$prefix/lib/libpjsua.a" ]; then
        log "PJSIP ($platform/$arch) already built, skipping."
        return
    fi

    log "Building PJSIP $PJSIP_VERSION for $platform/$arch..."

    local src_dir="$BUILD_DIR/src/pjproject-$PJSIP_VERSION"
    if [ ! -d "$src_dir" ]; then
        log "Downloading PJSIP $PJSIP_VERSION..."
        curl -sL "https://github.com/pjsip/pjproject/archive/refs/tags/$PJSIP_VERSION.tar.gz" \
            -o "$BUILD_DIR/src/pjsip.tar.gz"
        tar xzf "$BUILD_DIR/src/pjsip.tar.gz" -C "$BUILD_DIR/src/"
    fi

    local work_dir="$BUILD_DIR/work/pjsip-${platform}-${arch}"
    rm -rf "$work_dir"
    cp -a "$src_dir" "$work_dir"
    cd "$work_dir"

    local ssl_prefix="$BUILD_DIR/output/openssl-${platform}-${arch}"
    local opus_prefix="$BUILD_DIR/output/opus-${platform}-${arch}"

    # Write config_site.h
    cat > pjlib/include/pj/config_site.h <<'PJCFG'
#define PJ_CONFIG_IPHONE 1
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

/* WebSocket transport for FreeSWITCH WSS */
#define PJ_WEBSOCK_MAX_FRAME_LEN 65536

#include <pj/config_site_sample.h>
PJCFG

    local sdk_path
    sdk_path=$(get_sdk_path "$platform")

    local saved_min_ios="$MIN_IOS"

    if [ "$platform" = "iphonesimulator" ]; then
        export DEVPATH="/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer"
        export ARCH="-arch $arch"
        export MIN_IOS="-mios-simulator-version-min=$saved_min_ios"
        export CFLAGS="-O2 -arch $arch -isysroot $sdk_path -mios-simulator-version-min=$saved_min_ios"
        export LDFLAGS="-arch $arch -isysroot $sdk_path -mios-simulator-version-min=$saved_min_ios"
    else
        unset DEVPATH 2>/dev/null || true
        export ARCH="-arch $arch"
        export MIN_IOS="-miphoneos-version-min=$saved_min_ios"
        export CFLAGS="-O2 -arch $arch -isysroot $sdk_path -miphoneos-version-min=$saved_min_ios"
        export LDFLAGS="-arch $arch -isysroot $sdk_path -miphoneos-version-min=$saved_min_ios"
    fi

    ./configure-iphone \
        --prefix="$prefix" \
        --with-ssl="$ssl_prefix" \
        --with-opus="$opus_prefix" \
        --disable-video \
        --disable-openh264 \
        --disable-libvpx \
        --disable-ffmpeg \
        --disable-v4l2 \
        2>&1 | tail -10

    make dep 2>&1 | tail -3
    # Build libraries only (skip samples/tests which fail to link for simulator)
    make -j"$(sysctl -n hw.ncpu)" lib 2>&1 | tail -5
    make install 2>&1 | tail -5

    # The install target may not copy everything, manually copy libs
    mkdir -p "$prefix/lib" "$prefix/include"

    # Collect all .a files from PJSIP build
    find . -name "*.a" -not -path "*/third_party/*" | while read -r lib; do
        cp "$lib" "$prefix/lib/" 2>/dev/null || true
    done

    # Also grab third_party built libs (resample, srtp, etc.)
    find ./third_party -name "*.a" | while read -r lib; do
        cp "$lib" "$prefix/lib/" 2>/dev/null || true
    done

    # Copy headers
    for dir in pjsip pjlib pjlib-util pjmedia pjnath; do
        if [ -d "$dir/include" ]; then
            cp -a "$dir/include/"* "$prefix/include/" 2>/dev/null || true
        fi
    done

    cd "$PROJECT_ROOT"

    unset ARCH CFLAGS LDFLAGS DEVPATH 2>/dev/null || true
    MIN_IOS="$saved_min_ios"
    log "PJSIP ($platform/$arch) done."
}

# ===================================================================
# 4. Create XCFramework
# ===================================================================

create_xcframework() {
    log "Creating XCFramework..."

    local device_dir="$BUILD_DIR/output/pjsip-iphoneos-$DEVICE_ARCH"
    local headers_dir="$device_dir/include"

    local device_merged="$BUILD_DIR/output/merged-device"
    local sim_merged="$BUILD_DIR/output/merged-sim"
    rm -rf "$device_merged" "$sim_merged"
    mkdir -p "$device_merged" "$sim_merged"

    # Device: use only the arch-suffixed .a files to avoid duplicates
    local device_libs=()
    for f in "$device_dir"/lib/*-aarch64-apple-darwin_ios.a; do
        [ -f "$f" ] && device_libs+=("$f")
    done
    # OpenSSL + Opus
    [ -f "$BUILD_DIR/output/openssl-iphoneos-$DEVICE_ARCH/lib/libssl.a" ] && \
        device_libs+=("$BUILD_DIR/output/openssl-iphoneos-$DEVICE_ARCH/lib/libssl.a")
    [ -f "$BUILD_DIR/output/openssl-iphoneos-$DEVICE_ARCH/lib/libcrypto.a" ] && \
        device_libs+=("$BUILD_DIR/output/openssl-iphoneos-$DEVICE_ARCH/lib/libcrypto.a")
    [ -f "$BUILD_DIR/output/opus-iphoneos-$DEVICE_ARCH/lib/libopus.a" ] && \
        device_libs+=("$BUILD_DIR/output/opus-iphoneos-$DEVICE_ARCH/lib/libopus.a")

    log "  Merging ${#device_libs[@]} device libs into $device_merged/libPjsipSDK.a"
    libtool -static -o "$device_merged/libPjsipSDK.a" "${device_libs[@]}" 2>/dev/null

    # Simulator: need to lipo arm64+x86_64 per-lib, then merge
    # First, get canonical lib names from arm64 sim build
    local sim_arm64_dir="$BUILD_DIR/output/pjsip-iphonesimulator-arm64"
    local sim_x86_dir="$BUILD_DIR/output/pjsip-iphonesimulator-x86_64"
    local sim_lipo_dir="$BUILD_DIR/output/lipo-sim"
    rm -rf "$sim_lipo_dir"
    mkdir -p "$sim_lipo_dir"

    # Lipo each PJSIP lib: match by base name stripping the arch suffix
    # arm64 libs: lib*-aarch64-apple-darwin_ios.a
    # x86_64 libs: lib*-x86_64-apple-darwin_ios.a
    for arm64_lib in "$sim_arm64_dir"/lib/*.a; do
        [ -f "$arm64_lib" ] || continue
        local basename
        basename=$(basename "$arm64_lib")
        # Convert arm64 name to x86_64 name
        local x86_name="${basename/aarch64-apple-darwin_ios/x86_64-apple-darwin_ios}"
        local x86_lib="$sim_x86_dir/lib/$x86_name"
        # Output with a generic name
        local out_name="${basename/-aarch64-apple-darwin_ios/}"

        if [ -f "$x86_lib" ]; then
            lipo "$arm64_lib" "$x86_lib" -create -output "$sim_lipo_dir/$out_name" 2>/dev/null
        else
            cp "$arm64_lib" "$sim_lipo_dir/$out_name"
        fi
    done

    # Also lipo OpenSSL
    for lib_name in libssl libcrypto; do
        local arm64_lib="$BUILD_DIR/output/openssl-iphonesimulator-arm64/lib/${lib_name}.a"
        local x86_lib="$BUILD_DIR/output/openssl-iphonesimulator-x86_64/lib/${lib_name}.a"
        if [ -f "$arm64_lib" ] && [ -f "$x86_lib" ]; then
            lipo "$arm64_lib" "$x86_lib" -create -output "$sim_lipo_dir/${lib_name}.a"
        elif [ -f "$arm64_lib" ]; then
            cp "$arm64_lib" "$sim_lipo_dir/${lib_name}.a"
        fi
    done

    # Lipo Opus
    local opus_arm64="$BUILD_DIR/output/opus-iphonesimulator-arm64/lib/libopus.a"
    local opus_x86="$BUILD_DIR/output/opus-iphonesimulator-x86_64/lib/libopus.a"
    if [ -f "$opus_arm64" ] && [ -f "$opus_x86" ]; then
        lipo "$opus_arm64" "$opus_x86" -create -output "$sim_lipo_dir/libopus.a"
    elif [ -f "$opus_arm64" ]; then
        cp "$opus_arm64" "$sim_lipo_dir/libopus.a"
    fi

    # Now merge all sim fat libs into one
    local sim_all_libs=()
    for f in "$sim_lipo_dir"/*.a; do
        [ -f "$f" ] && sim_all_libs+=("$f")
    done
    log "  Merging ${#sim_all_libs[@]} sim libs into $sim_merged/libPjsipSDK.a"
    libtool -static -o "$sim_merged/libPjsipSDK.a" "${sim_all_libs[@]}" 2>/dev/null

    # Create XCFramework
    rm -rf "$FRAMEWORK_DIR/PjsipSDK.xcframework"
    mkdir -p "$FRAMEWORK_DIR"

    xcodebuild -create-xcframework \
        -library "$device_merged/libPjsipSDK.a" \
        -headers "$headers_dir" \
        -library "$sim_merged/libPjsipSDK.a" \
        -headers "$headers_dir" \
        -output "$FRAMEWORK_DIR/PjsipSDK.xcframework"

    log "XCFramework created at $FRAMEWORK_DIR/PjsipSDK.xcframework"
}

# ===================================================================
# Main
# ===================================================================

log "=== Building PJSIP SDK for iOS ==="
log "PJSIP: $PJSIP_VERSION | OpenSSL: $OPENSSL_VERSION | Opus: $OPUS_VERSION"
log "Min iOS: $MIN_IOS | Device: $DEVICE_ARCH | Sim: $SIM_ARCHS"
echo ""

# Step 1: Build dependencies for all architectures
log "--- Step 1: OpenSSL ---"
build_openssl "$DEVICE_ARCH" "iphoneos"
for arch in $SIM_ARCHS; do
    build_openssl "$arch" "iphonesimulator"
done

log "--- Step 2: Opus ---"
build_opus "$DEVICE_ARCH" "iphoneos"
for arch in $SIM_ARCHS; do
    build_opus "$arch" "iphonesimulator"
done

# Step 3: Build PJSIP
log "--- Step 3: PJSIP ---"
build_pjsip "$DEVICE_ARCH" "iphoneos"
for arch in $SIM_ARCHS; do
    build_pjsip "$arch" "iphonesimulator"
done

# Step 4: Package
log "--- Step 4: XCFramework ---"
create_xcframework

echo ""
log "=== Build complete! ==="
log "XCFramework: $FRAMEWORK_DIR/PjsipSDK.xcframework"
log ""
log "Add to your podspec or Package.swift:"
log "  s.vendored_frameworks = 'ios/Frameworks/PjsipSDK.xcframework'"
log "  s.frameworks = 'CallKit', 'PushKit', 'AVFoundation', 'AudioToolbox', 'CFNetwork'"
log "  s.libraries = 'c++'"
