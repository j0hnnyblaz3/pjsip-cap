cmake_minimum_required(VERSION 3.22)
project(pjsip_jni C)

# Determine architecture-specific lib suffix
if(ANDROID_ABI STREQUAL "arm64-v8a")
    set(PJ_ARCH "aarch64-unknown-linux-android")
elseif(ANDROID_ABI STREQUAL "armeabi-v7a")
    set(PJ_ARCH "armv7-unknown-linux-android")
elseif(ANDROID_ABI STREQUAL "x86_64")
    set(PJ_ARCH "x86_64-pc-linux-android")
else()
    message(FATAL_ERROR "Unsupported ABI: ${ANDROID_ABI}")
endif()

set(PJSIP_ROOT "${CMAKE_SOURCE_DIR}/../../../libs")
set(PJSIP_LIB_DIR "${PJSIP_ROOT}/${ANDROID_ABI}/lib")

# Header search paths
include_directories(${PJSIP_ROOT})

# Collect all PJSIP static libraries (order matters for linker)
set(PJSIP_LIBS
    pjsua-${PJ_ARCH}
    pjsip-ua-${PJ_ARCH}
    pjsip-simple-${PJ_ARCH}
    pjsip-${PJ_ARCH}
    pjmedia-codec-${PJ_ARCH}
    pjmedia-${PJ_ARCH}
    pjmedia-audiodev-${PJ_ARCH}
    pjmedia-videodev-${PJ_ARCH}
    pjnath-${PJ_ARCH}
    pjlib-util-${PJ_ARCH}
    pjsdp-${PJ_ARCH}
    pjsua2-${PJ_ARCH}
    resample-${PJ_ARCH}
    srtp-${PJ_ARCH}
    gsmcodec-${PJ_ARCH}
    speex-${PJ_ARCH}
    ilbccodec-${PJ_ARCH}
    g7221codec-${PJ_ARCH}
    webrtc-${PJ_ARCH}
    pj-${PJ_ARCH}
    opus
    ssl
    crypto
)

# Import each static library
foreach(lib ${PJSIP_LIBS})
    add_library(${lib} STATIC IMPORTED)
    set_target_properties(${lib} PROPERTIES IMPORTED_LOCATION "${PJSIP_LIB_DIR}/lib${lib}.a")
endforeach()

# Build the JNI shared library
add_library(pjsip_jni SHARED pjsip_jni.c)

# Link everything together
target_link_libraries(pjsip_jni
    # Wrap PJSIP libs in a group so the linker resolves circular deps
    -Wl,--start-group
    ${PJSIP_LIBS}
    -Wl,--end-group
    # Android system libraries
    OpenSLES
    log
    android
)
