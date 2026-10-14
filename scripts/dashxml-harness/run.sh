#!/bin/sh
# Differential test of the DASH demuxer's XML layer: libxml2 against fdxml.
#
# The fork replaces libxml2 in libavformat/dashdec.c with fdxml
# (firedown/replacements/libavformat/fdxml.{c,h}): libxml2's names, backed by
# ONE JNI call per manifest into the app's FFmpegXml.parse(). This runs
# dashdec.c's REAL parse_manifest() on every manifest of a corpus, built two
# ways, and diffs everything it extracted (URLs, init sections, segment lists,
# timelines, MPD/Period timing, metadata):
#   - REFERENCE: vanilla dashdec.c + libxml2 (the version scripts/libxml2
#     pins), as upstream FFmpeg builds it;
#   - FDXML: dashdec.c as the REAL firedown/apply-firedown-patches.sh leaves
#     it (run on a copy of the tree) + fdxml.c, with the tree coming from the
#     REAL FFmpegXml.java (copied from the app repo) in a JVM: the same bytes
#     through the same Java, a process boundary in place of JNI.
# Checks:
#   - every manifest identical, except those in expected-diffs.txt, which
#     must differ with the fdxml build refusing them;
#   - every hand-written corpus case that is not a fail_* parses in the
#     reference build (so "identical" never means "both failed");
#   - no ASan/UBSan report in either build, and no leak in the fdxml build
#     beyond what the reference leaks for the same manifest (upstream dashdec
#     leaks a little; fdxml must add nothing);
#   - fdxml.c compiles warning-free with and without CONFIG_JNI (the JNI half
#     cannot run here, so it is at least compiled against the JDK's jni.h);
#   - teeth: four planted bugs, three in fdxml.c and one in FFmpegXml.java,
#     must each be caught.
#
#   sh scripts/dashxml-harness/run.sh
#
# Corpus: corpus/*.mpd (hand-written, one behaviour each; fail_* must be
# refused by both builds), gen-corpus.py (a 2.8 MB segment list, nesting at
# and past the 256-level limit) and, unless DASHXML_EXTERNAL=0, the DASH test
# manifests of ExoPlayer (androidx/media), Shaka Player and dash.js,
# sparse-cloned once into the cache (delete their cache dirs to refresh).
#
# Needs: a C compiler with ASan/UBSan (gcc or clang; CC to choose), make,
# git, curl, python3, a JDK, autoconf/automake/libtool and zlib headers (for
# the reference libxml2), and network the first time. FFmpeg's source and
# host build, libxml2, kxml2 and the external corpora are cached under
# $FIREDOWN_HARNESS_CACHE/dashxml (default ~/.cache/firedown-harness). The
# app repo is $FIREDOWN (default: a firedown checkout beside this repo).
#
# Known limit: Android's KXmlParser is libcore's fork of kxml2; this runs
# upstream kxml2 2.3.0 from Maven Central, so a parser difference between the
# two is only visible on a device.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
APP=${FIREDOWN:-$ROOT/../firedown}
FFMPEGXML="$APP/app/src/main/java/com/solarized/firedown/ffmpegutils/FFmpegXml.java"
CACHE=${FIREDOWN_HARNESS_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/firedown-harness}/dashxml
CC=${CC:-cc}
JOBS=$(nproc 2>/dev/null || echo 4)
OUT=$(mktemp -d)
trap 'rm -rf "${OUT:?}"' EXIT
mkdir -p "$CACHE"

if [ ! -f "$FFMPEGXML" ]; then
  echo "FFmpegXml.java not found at $FFMPEGXML (set FIREDOWN to the app repo)" >&2
  exit 1
fi
FFV=$(sed -n 's/^SOURCE_VALUE=//p' "$ROOT/scripts/parse-arguments.sh")
XMLV=$(sed -n 's/^XML_VERSION=//p' "$ROOT/scripts/libxml2/download.sh")
echo "dashxml: FFmpeg $FFV, reference libxml2 $XMLV, app at $APP"

# --- dependencies (cached) ---------------------------------------------------

# FFmpeg source + host static libs. The dash demuxer is NOT in the libs: the
# driver compiles dashdec.c itself, once per variant.
FFSRC="$CACHE/ffmpeg-$FFV/src"
FFBUILD="$CACHE/ffmpeg-$FFV/build"
if [ ! -f "$FFSRC/.harness-ready" ]; then
  rm -rf "$FFSRC"
  git -c advice.detachedHead=false clone -q --depth 1 --branch "n$FFV" https://github.com/FFmpeg/FFmpeg "$FFSRC"
  # Host only: let https exist without a TLS backend, so avio_find_protocol_name()
  # knows https:// URLs as the Android build (OkHttp) does. dashdec's BaseURL
  # resolution asks it (ishttp). configure.vanilla is what the patch step uses.
  cp "$FFSRC/configure" "$FFSRC/configure.vanilla"
  sed 's/^https_protocol_select="tls_protocol"$//' "$FFSRC/configure.vanilla" > "$FFSRC/configure"
  touch "$FFSRC/.harness-ready"
fi
if [ ! -f "$FFBUILD/.harness-ready" ]; then
  echo "dashxml: building FFmpeg $FFV for the host (once)"
  rm -rf "$FFBUILD"
  mkdir -p "$FFBUILD"
  if ! (cd "$FFBUILD" && "$FFSRC/configure" --cc="$CC" --disable-everything --disable-programs \
          --disable-doc --enable-static --disable-shared --enable-demuxer=mov \
          --enable-protocol=file,http,https --disable-autodetect --disable-x86asm \
          --disable-debug > configure.log 2>&1 \
        && make -j"$JOBS" libavformat/libavformat.a libavcodec/libavcodec.a \
          libavutil/libavutil.a > make.log 2>&1); then
    echo "FFmpeg host build failed; logs in $FFBUILD" >&2
    exit 1
  fi
  touch "$FFBUILD/.harness-ready"
fi

# The reference libxml2, configured as scripts/libxml2/build.sh does (minus
# the cross-compile). GNOME's GitLab first, its GitHub mirror if unreachable.
XMLDIR="$CACHE/libxml2-$XMLV"
if [ ! -f "$XMLDIR/inst/.harness-ready" ]; then
  echo "dashxml: building libxml2 $XMLV for the host (once)"
  rm -rf "$XMLDIR"
  mkdir -p "$XMLDIR/build"
  git -c advice.detachedHead=false clone -q --depth 1 --branch "v$XMLV" https://gitlab.gnome.org/GNOME/libxml2.git "$XMLDIR/src" 2>/dev/null \
    || git -c advice.detachedHead=false clone -q --depth 1 --branch "v$XMLV" https://github.com/GNOME/libxml2 "$XMLDIR/src"
  if ! ( (cd "$XMLDIR/src" && NOCONFIGURE=1 ./autogen.sh) > "$XMLDIR/build.log" 2>&1 \
        && cd "$XMLDIR/build" && "$XMLDIR/src/configure" --prefix="$XMLDIR/inst" CC="$CC" \
          --disable-shared --enable-static --with-zlib --with-pic --without-python \
          --without-debug --without-lzma >> "$XMLDIR/build.log" 2>&1 \
        && make -j"$JOBS" >> "$XMLDIR/build.log" 2>&1 && make install >> "$XMLDIR/build.log" 2>&1); then
    echo "libxml2 build failed; log in $XMLDIR/build.log" >&2
    exit 1
  fi
  touch "$XMLDIR/inst/.harness-ready"
fi

# kxml2 from Maven Central, checked against a PINNED sha1 (Maven's own .sha1
# for 2.3.0); retried, as Central rate-limits bursts with a 429.
KXML="$CACHE/kxml2-2.3.0.jar"
KXML_SHA1=ccbc77a5fd907ef863c29f3596c6f54ffa4e9442
if [ ! -f "$KXML" ]; then
  n=0
  until curl -fsS -o "$KXML.part" https://repo1.maven.org/maven2/net/sf/kxml/kxml2/2.3.0/kxml2-2.3.0.jar; do
    n=$((n + 1)); [ $n -ge 5 ] && { echo "kxml2 download failed" >&2; exit 1; }
    sleep $((n * 3))
  done
  got=$(sha1sum "$KXML.part" | cut -c1-40)
  if [ "$got" != "$KXML_SHA1" ]; then
    echo "sha1 mismatch for kxml2: $got, expected $KXML_SHA1" >&2
    rm -f "$KXML.part"
    exit 1
  fi
  mv "$KXML.part" "$KXML"
fi

# --- the fdxml tree, made by the REAL patch script ---------------------------
# Only the files apply-firedown-patches.sh needs, from vanilla sources.

PATCHED="$OUT/patched"
mkdir -p "$PATCHED/libavformat"
cp "$FFSRC/configure.vanilla" "$PATCHED/configure"
cp "$FFSRC/libavformat/dashdec.c" "$FFSRC/libavformat/hls.c" "$FFSRC/libavformat/Makefile" \
   "$PATCHED/libavformat/"
if ! bash "$ROOT/firedown/apply-firedown-patches.sh" "$PATCHED" > "$OUT/apply.log" 2>&1; then
  cat "$OUT/apply.log" >&2
  echo "apply-firedown-patches.sh failed on vanilla FFmpeg $FFV" >&2
  exit 1
fi

# --- build -------------------------------------------------------------------

CHECKS=0
FAILED=0
pass() { CHECKS=$((CHECKS + 1)); }
fail() { CHECKS=$((CHECKS + 1)); FAILED=$((FAILED + 1)); echo "FAIL $*"; }

mkdir -p "$OUT/java" "$OUT/classes"
cp "$FFMPEGXML" "$OUT/java/"
javac -nowarn -d "$OUT/classes" -cp "$KXML" "$OUT/java/FFmpegXml.java" $(find "$HERE/java" -name '*.java')

CFL="-std=c17 -DHAVE_AV_CONFIG_H -D_ISOC11_SOURCE -D_FILE_OFFSET_BITS=64 -D_LARGEFILE_SOURCE"
CFL="$CFL -D_POSIX_C_SOURCE=200809 -D_XOPEN_SOURCE=700 -D_GNU_SOURCE -pthread -O1 -g"
CFL="$CFL -fno-omit-frame-pointer -fsanitize=address,undefined -fno-sanitize-recover=undefined"
INC="-I$FFBUILD -I$FFSRC/libavformat -I$FFSRC"
LIBS="$FFBUILD/libavformat/libavformat.a $FFBUILD/libavcodec/libavcodec.a $FFBUILD/libavutil/libavutil.a -lm -lpthread"

# fdxml.c itself: warning-free, both halves. CONFIG_JNI comes from a config.h
# wrapper; the JNI half is compiled against the JDK's jni.h.
JDK=$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")
WARN="-std=c17 -DHAVE_AV_CONFIG_H -Wall -Wextra -Wno-unused-parameter -Wno-sign-compare"
WARN="$WARN -Wmissing-prototypes -Wstrict-prototypes -Wdeclaration-after-statement -Werror -fsyntax-only"
for jni in 0 1; do
  mkdir -p "$OUT/cfg$jni"
  printf '#include "%s/config.h"\n#undef CONFIG_JNI\n#define CONFIG_JNI %s\n' "$FFBUILD" "$jni" \
    > "$OUT/cfg$jni/config.h"
  if $CC $WARN -I"$OUT/cfg$jni" $INC -I"$JDK/include" -I"$JDK/include/linux" \
       "$PATCHED/libavformat/fdxml.c" 2> "$OUT/warn$jni.log"; then
    pass
  else
    cat "$OUT/warn$jni.log"
    fail "fdxml.c does not compile warning-free with CONFIG_JNI=$jni"
  fi
done

# Upstream sources build with warnings this harness does not own: -w.
$CC $CFL -w $INC -c "$FFSRC/libavformat/dash.c" -o "$OUT/dash.o"
$CC $CFL -w $INC -I"$XMLDIR/inst/include/libxml2" "$HERE/dash_dump.c" "$OUT/dash.o" \
    -o "$OUT/dump_libxml2" "$XMLDIR/inst/lib/libxml2.a" -lz $LIBS
build_fdxml() {
  # $1 = directory holding dashdec.c + fdxml.{c,h}, $2 = output binary
  $CC $CFL -w -DFDXML_VARIANT -I"$1" $INC "$HERE/dash_dump.c" "$1/fdxml.c" "$OUT/dash.o" -o "$2" $LIBS
}
build_fdxml "$PATCHED/libavformat" "$OUT/dump_fdxml"

# --- corpus --------------------------------------------------------------------

python3 "$HERE/gen-corpus.py" "$OUT/gen"
find "$HERE/corpus" "$OUT/gen" -name '*.mpd' > "$OUT/corpus.txt"
EXTERNAL=""
if [ "${DASHXML_EXTERNAL:-1}" != 0 ]; then
  # repo, path inside it
  for spec in "androidx/media libraries/test_data/src/test/assets/media/mpd" \
              "shaka-project/shaka-player test/test/assets" \
              "Dash-Industry-Forum/dash.js test/unit/data"; do
    repo=${spec%% *}
    path=${spec#* }
    dir="$CACHE/corpora/$(echo "$repo" | tr / _)"
    if [ ! -f "$dir/.harness-ready" ]; then
      rm -rf "$dir"
      if git -c advice.detachedHead=false clone -q --depth 1 --filter=blob:none --sparse "https://github.com/$repo" "$dir" 2>/dev/null \
         && git -C "$dir" sparse-checkout set "$path" > /dev/null 2>&1; then
        touch "$dir/.harness-ready"
      else
        echo "dashxml: external corpus $repo unavailable, continuing without it"
        rm -rf "$dir"
        continue
      fi
    fi
    find "$dir/$path" -type f \( -name '*.mpd' -o -path '*/media/mpd/*' \) >> "$OUT/corpus.txt"
    EXTERNAL="$EXTERNAL $repo"
  done
fi
sort -o "$OUT/corpus.txt" "$OUT/corpus.txt"
TOTAL=$(wc -l < "$OUT/corpus.txt" | tr -d ' ')

# --- run -----------------------------------------------------------------------

URL='https://cdn.example.com/vod/show/manifest.mpd?tok=abc'
export FDXML_CP="$OUT/classes:$KXML"
mkdir -p "$OUT/blobs" "$OUT/res"

label() { echo "$1" | sed "s|^$HERE/||; s|^$OUT/||; s|^$CACHE/corpora/||; s|/|_|g"; }
leaked() {
  # allocations ASan's leak summary reports in a stderr file, 0 when none
  sed -n 's/.*leaked in \([0-9]*\) allocation.*/\1/p' "$1" | awk '{s += $1} END {print s + 0}'
}
sanitizer_error() { grep -qE "ERROR: AddressSanitizer|runtime error|FDXML-HARNESS" "$1"; }
is_expected() { grep -q "^$(basename "$1") " "$HERE/expected-diffs.txt"; }

identical=0
while read -r f; do
  n=$(label "$f")
  ASAN_OPTIONS=detect_leaks=1 FDXML_BLOB_DIR="$OUT/blobs" \
    "$OUT/dump_libxml2" "$f" "$URL" > "$OUT/res/$n.ref" 2> "$OUT/res/$n.ref.err" || true
  ASAN_OPTIONS=detect_leaks=1 FDXML_BLOB_DIR="$OUT/blobs" \
    "$OUT/dump_fdxml" "$f" "$URL" > "$OUT/res/$n.fdx" 2> "$OUT/res/$n.fdx.err" || true

  # A complete dump ends with "end": a crash or a lost buffer must never pass
  # as two identical, truncated outputs.
  for v in ref fdx; do
    if [ "$(tail -1 "$OUT/res/$n.$v")" = end ]; then pass; else fail "$n: $v output incomplete"; fi
  done
  if sanitizer_error "$OUT/res/$n.ref.err"; then fail "$n: sanitizer report in the libxml2 build"; else pass; fi
  if sanitizer_error "$OUT/res/$n.fdx.err"; then fail "$n: sanitizer report in the fdxml build"; else pass; fi
  if [ "$(leaked "$OUT/res/$n.fdx.err")" -gt "$(leaked "$OUT/res/$n.ref.err")" ]; then
    fail "$n: fdxml leaks more than libxml2"
  else
    pass
  fi

  case "$f" in
    "$HERE/corpus/"*|"$OUT/gen/"*)
      case "$(basename "$f")" in
        fail_*) ;;
        *) if ! head -1 "$OUT/res/$n.ref" | grep -q '^ret=0 '; then
             fail "$n: the reference build does not parse it (a corpus case must)"
           else
             pass
           fi ;;
      esac ;;
  esac

  if is_expected "$f"; then
    if cmp -s "$OUT/res/$n.ref" "$OUT/res/$n.fdx"; then
      fail "$n: expected to differ (expected-diffs.txt) but identical"
    elif head -1 "$OUT/res/$n.fdx" | grep -q '^ret=0 '; then
      fail "$n: expected fdxml to refuse it, but it parsed"
    else
      pass
    fi
  elif cmp -s "$OUT/res/$n.ref" "$OUT/res/$n.fdx"; then
    identical=$((identical + 1))
    pass
  else
    fail "$n: libxml2 and fdxml disagree"
    diff "$OUT/res/$n.ref" "$OUT/res/$n.fdx" | head -6 | sed 's/^/    /'
  fi
done < "$OUT/corpus.txt"

# --- teeth -----------------------------------------------------------------------
# Each planted bug must make at least one manifest disagree or trip a sanitizer.

catches() {
  # $1 = fdxml binary, $2 = blob dir, $3 = classpath; prints how many manifests caught it
  caught=0
  while read -r f; do
    n=$(label "$f")
    is_expected "$f" && continue
    ASAN_OPTIONS=detect_leaks=0 FDXML_BLOB_DIR="$2" FDXML_CP="$3" \
      "$1" "$f" "$URL" > "$OUT/mut.out" 2> "$OUT/mut.err" || true
    if ! cmp -s "$OUT/res/$n.ref" "$OUT/mut.out" || sanitizer_error "$OUT/mut.err"; then
      caught=$((caught + 1))
    fi
  done < "$OUT/corpus.txt"
  echo "$caught"
}

mutate() {
  # $1 = file, $2 = old text, $3 = new text
  python3 - "$1" "$2" "$3" <<'PY'
import sys
path, old, new = sys.argv[1:]
text = open(path).read()
if old not in text:
    sys.exit('mutation anchor not found: ' + old)
open(path, 'w').write(text.replace(old, new, 1))
PY
}

c_mutant() {
  # $1 = description, $2 = old, $3 = new
  rm -rf "$OUT/mut"
  cp -r "$PATCHED/libavformat" "$OUT/mut"
  if ! mutate "$OUT/mut/fdxml.c" "$2" "$3"; then
    fail "mutant '$1': anchor gone from fdxml.c; update run.sh"
    return
  fi
  build_fdxml "$OUT/mut" "$OUT/dump_mut"
  n=$(catches "$OUT/dump_mut" "$OUT/blobs" "$FDXML_CP")
  if [ "$n" -gt 0 ]; then echo "  mutant caught by $n manifest(s): $1"; pass; else fail "mutant not caught: $1"; fi
}

c_mutant "an empty element's content is NULL, not \"\"" \
  '    out = av_malloc(content_length(node) + 1);' \
  '    if (!content_length(node)) { return NULL; } out = av_malloc(content_length(node) + 1);'
c_mutant "a CDATA section is typed as text" \
  '        node->type = XML_CDATA_SECTION_NODE;' \
  '        node->type = XML_TEXT_NODE;'
c_mutant "xmlGetProp returns the last matching attribute" \
  '            return av_strdup(attr->value);' \
  '            { const xmlAttr *a2; for (a2 = attr->next; a2; a2 = a2->next) { if (!strcmp(a2->name, name)) { return av_strdup(a2->value); } } return av_strdup(attr->value); }'

# FFmpegXml: leave prefixes to the parser (namespace mode), the first
# version's bug: undeclared prefixes (mspr:pro, scte35:, yt:) reject the file.
mkdir -p "$OUT/mutjava/src" "$OUT/mutjava/classes" "$OUT/mutjava/blobs"
cp "$FFMPEGXML" "$OUT/mutjava/src/"
if mutate "$OUT/mutjava/src/FFmpegXml.java" \
     'parser.setFeature(XmlPullParser.FEATURE_PROCESS_NAMESPACES, false);' \
     'parser.setFeature(XmlPullParser.FEATURE_PROCESS_NAMESPACES, true);'; then
  javac -nowarn -d "$OUT/mutjava/classes" -cp "$KXML" "$OUT/mutjava/src/FFmpegXml.java" \
        $(find "$HERE/java" -name '*.java')
  n=$(catches "$OUT/dump_fdxml" "$OUT/mutjava/blobs" "$OUT/mutjava/classes:$KXML")
  if [ "$n" -gt 0 ]; then
    echo "  mutant caught by $n manifest(s): FFmpegXml leaves namespace prefixes to the parser"
    pass
  else
    fail "mutant not caught: FFmpegXml leaves namespace prefixes to the parser"
  fi
else
  fail "mutant anchor gone from FFmpegXml.java; update run.sh"
fi

echo "dashxml: $TOTAL manifests (external:${EXTERNAL:- none}), $identical identical," \
     "$(grep -c '^[^#]' "$HERE/expected-diffs.txt") expected difference(s)"
echo "dashxml: $CHECKS checks, $FAILED failed"
[ "$FAILED" -eq 0 ]
