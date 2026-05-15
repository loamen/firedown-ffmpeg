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
# Adding -ffunction-sections / -fdata-sections + --gc-sections lets the linker
# drop unreferenced functions/data per-symbol, dramatically shrinking the .so files.
EXTRA_CFLAGS="-O2 -fPIC -ffunction-sections -fdata-sections $DEP_CFLAGS"
EXTRA_LDFLAGS="-Wl,-z,max-page-size=16384 -Wl,--gc-sections $DEP_LD_FLAGS"

# === Firedown configuration ===
# - --enable-jni: required by replacement libavformat/http.c (OkHttp bridge)
# - --disable-avdevice: Firedown never loads libavdevice (libpostproc is
#     already off by default in ffmpeg 8.x unless --enable-gpl pulls it in)
# - --disable-hwaccels: desktop hwaccels (CUDA/VAAPI/...) don't apply on Android
# - --disable-debug / --disable-runtime-cpudetect: smaller per-ABI binaries
# - --disable-protocol=... + --enable-protocol=http,https: OkHttp handles the rest via JNI
# - --disable-{decoders,demuxers,muxers,parsers,bsfs,filters,encoders} + targeted re-enables:
#     allow-list approach — only the codecs/containers/parsers/bitstream-filters/filters
#     Firedown actually touches are compiled in. Add a name back here when you hit a
#     stream that needs it.
# - --disable-outdevs / --disable-indevs: no input/output devices on Android
# - --disable-ffprobe / --disable-ffmpeg / --disable-doc: skip CLI tools and docs

./configure \
  --prefix=${BUILD_DIR_FFMPEG}/${ANDROID_ABI} \
  --enable-cross-compile \
  --disable-openssl \
  --disable-gnutls \
  --disable-mbedtls \
  --enable-jni \
  --disable-avdevice \
  --disable-hwaccels \
  --disable-debug \
  --disable-runtime-cpudetect \
  --disable-lzma \
  --disable-iconv \
  --disable-sndio \
  --disable-libxcb \
  --disable-sdl2 \
  --disable-xlib \
  --disable-protocol=httpproxy,rtmp,rtmpe,rtmps,rtmpt,rtmpte,rtmpts,tls,ffrtmp,ffrtmpcrypt,ffrtmphttp,rtsp,rtp,srtp,ftp,ipns_gateway,gopher,ipfs_gateway,mmsh,mmst \
  --enable-protocol=http,https \
  --disable-encoders \
  --enable-encoder=aac \
  --enable-encoder=gif \
  --disable-decoders \
  --enable-decoder=h264,hevc,vp8,vp9,av1,mpeg4,mjpeg,aac,aac_latm,mp3,opus,vorbis,flac,ac3,eac3,pcm_s16le,pcm_s16be,pcm_u8,gif,png,webp,bmp,tiff,apng \
  --disable-demuxers \
  --enable-demuxer=mov,matroska,hls,dash,mpegts,flv,webm_dash_manifest,aac,mp3,ogg,flac,wav,m4v,image2,webp_pipe,heif,ico,apng,gif \
  --disable-muxers \
  --enable-muxer=mp4,mov,ipod,matroska,webm,mpegts,adts,gif,mp3,ogg,flac,wav \
  --disable-parsers \
  --enable-parser=h264,hevc,aac,aac_latm,mpegaudio,opus,vorbis,vp8,vp9,av1,flac,mjpeg,gif \
  --disable-bsfs \
  --enable-bsf=aac_adtstoasc,h264_mp4toannexb,hevc_mp4toannexb,extract_extradata,vp9_superframe \
  --disable-filters \
  --enable-filter=palettegen \
  --enable-filter=paletteuse \
  --enable-filter=split \
  --enable-filter=fps \
  --enable-filter=scale \
  --enable-filter=aformat \
  --enable-filter=asetnsamples \
  --enable-filter=aresample \
  --enable-filter=anull \
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
  --extra-cflags="$EXTRA_CFLAGS" \
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
