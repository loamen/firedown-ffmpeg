#!/usr/bin/env bash

case $ANDROID_ABI in
  x86)
    # Disabling assembler optimizations, because they have text relocations
    EXTRA_BUILD_CONFIGURATION_FLAGS="$EXTRA_BUILD_CONFIGURATION_FLAGS --disable-asm"
    ;;
  x86_64)
    EXTRA_BUILD_CONFIGURATION_FLAGS="$EXTRA_BUILD_CONFIGURATION_FLAGS --x86asmexe=${NASM_EXECUTABLE}"
    ;;
esac

if [ "$FFMPEG_GPL_ENABLED" = true ] ; then
    EXTRA_BUILD_CONFIGURATION_FLAGS="$EXTRA_BUILD_CONFIGURATION_FLAGS --enable-gpl"
fi

# Preparing flags for enabling requested libraries
ADDITIONAL_COMPONENTS=
for LIBARY_NAME in ${FFMPEG_EXTERNAL_LIBRARIES[@]}
do
  ADDITIONAL_COMPONENTS+=" --enable-$LIBARY_NAME"
done

# Referencing dependencies without pkgconfig
DEP_CFLAGS="-I${BUILD_DIR_EXTERNAL}/${ANDROID_ABI}/include"
DEP_LD_FLAGS="-L${BUILD_DIR_EXTERNAL}/${ANDROID_ABI}/lib $FFMPEG_EXTRA_LD_FLAGS"

# Android 15 with 16 kb page size support
# https://developer.android.com/guide/practices/page-sizes#compile-r27
EXTRA_LDFLAGS="-Wl,-z,max-page-size=16384 $DEP_LD_FLAGS"

# === Firedown configuration ===
# - --enable-jni: required by replacement libavformat/http.c (OkHttp bridge)
# - --disable-protocol=...: trim unused/unwanted network protocols
# - --enable-protocol=http,https: only protocols we need (handled by OkHttp via JNI)
# - --disable-muxer=hls,dash,hds: Firedown is a downloader, doesn't write streams
# - --disable-encoders / --enable-encoder=aac: only AAC encoder for re-muxing
# - --disable-outdevs / --disable-indevs: no input/output devices on Android
# - --disable-ffprobe / --disable-ffmpeg / --disable-doc: skip CLI tools and docs

./configure \
  --prefix=${BUILD_DIR_FFMPEG}/${ANDROID_ABI} \
  --enable-cross-compile \
  --disable-openssl \
  --disable-gnutls \
  --disable-mbedtls \
  --enable-jni \
  --disable-protocol=httpproxy,rtmp,rtmpe,rtmps,rtmpt,rtmpte,rtmpts,tls,ffrtmp,ffrtmpcrypt,ffrtmphttp,rtsp,rtp,srtp,ftp,ipns_gateway,gopher,ipfs_gateway,mmsh,mmst \
  --enable-protocol=http,https \
  --disable-muxer=hls,dash,hds \
  --disable-encoders \
  --enable-encoder=aac \
  --enable-encoder=gif \
  --enable-muxer=gif \
  --enable-filter=palettegen \
  --enable-filter=paletteuse \
  --enable-filter=split \
  --enable-filter=fps \
  --enable-filter=scale \
  --disable-outdevs \
  --disable-indevs \
  --target-os=android \
  --arch=${TARGET_TRIPLE_MACHINE_ARCH} \
  --sysroot=${SYSROOT_PATH} \
  --cc=${FAM_CC} \
  --cxx=${FAM_CXX} \
  --ld=${FAM_LD} \
  --ar=${FAM_AR} \
  --as=${FAM_CC} \
  --nm=${FAM_NM} \
  --ranlib=${FAM_RANLIB} \
  --strip=${FAM_STRIP} \
  --extra-cflags="-O3 -fPIC $DEP_CFLAGS" \
  --extra-ldflags="$EXTRA_LDFLAGS" \
  --enable-shared \
  --disable-static \
  --disable-vulkan \
  --disable-ffprobe \
  --disable-ffmpeg \
  --disable-doc \
  --pkg-config=${PKG_CONFIG_EXECUTABLE} \
  ${EXTRA_BUILD_CONFIGURATION_FLAGS} \
  $ADDITIONAL_COMPONENTS || exit 1

${MAKE_EXECUTABLE} clean
${MAKE_EXECUTABLE} -j${HOST_NPROC}
${MAKE_EXECUTABLE} install
