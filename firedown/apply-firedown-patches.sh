#!/usr/bin/env bash
#
# apply-firedown-patches.sh
#
# Applies Firedown's modifications to a vanilla FFmpeg source tree.
# Invoked from ffmpeg-android-maker.sh after FFmpeg source is downloaded
# and before any per-ABI builds run.
#
# Usage:
#   ./apply-firedown-patches.sh <path-to-ffmpeg-source-dir>
#
# Idempotent — running twice on the same tree is safe. Each edit is checked
# independently so partial states from prior failed runs are recoverable.

set -euo pipefail

FFMPEG_DIR="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIREDOWN_DIR="$SCRIPT_DIR"

if [[ -z "$FFMPEG_DIR" ]]; then
    echo "ERROR: missing FFmpeg source directory argument" >&2
    echo "Usage: $0 <path-to-ffmpeg-source-dir>" >&2
    exit 1
fi

if [[ ! -d "$FFMPEG_DIR" ]] || [[ ! -f "$FFMPEG_DIR/configure" ]]; then
    echo "ERROR: $FFMPEG_DIR does not look like an FFmpeg source tree" >&2
    exit 1
fi

echo "[firedown] Applying patches to: $FFMPEG_DIR"

# ----------------------------------------------------------------------
# Step 1: File replacements (http.c → OkHttp JNI backend)
# ----------------------------------------------------------------------

REPLACEMENTS_DIR="$FIREDOWN_DIR/replacements"

if [[ -d "$REPLACEMENTS_DIR" ]]; then
    echo "[firedown] Copying file replacements..."

    if [[ -f "$REPLACEMENTS_DIR/libavformat/http.c" ]]; then
        echo "  - libavformat/http.c (OkHttp JNI backend)"
        cp "$REPLACEMENTS_DIR/libavformat/http.c" "$FFMPEG_DIR/libavformat/http.c"
    fi

    # New files, not replacements: the DASH demuxer's XML tree, parsed in
    # Java (FFmpegXml) instead of libxml2. Wired in by Step 3e.
    echo "  - libavformat/fdxml.{c,h} (DASH manifest XML via JNI)"
    cp "$REPLACEMENTS_DIR/libavformat/fdxml.c" "$FFMPEG_DIR/libavformat/fdxml.c"
    cp "$REPLACEMENTS_DIR/libavformat/fdxml.h" "$FFMPEG_DIR/libavformat/fdxml.h"
fi

# ----------------------------------------------------------------------
# Step 2: configure — patch protocol declarations
# ----------------------------------------------------------------------
# Two independent edits, matching the working Firedown build:
#
#  (a) DELETE the line  https_protocol_select="tls_protocol"
#      Decouples https_protocol from tls_protocol so https builds without
#      a TLS backend. Our replacement http.c handles HTTPS at the OkHttp
#      layer in Java.
#
#  (b) ADD the line  http_protocol_deps="jni"
#      Marks http_protocol as JNI-dependent (matches what the replacement
#      http.c actually uses). Inserted just before the
#      "# external library protocols" comment.
#
# Each edit is checked independently — if a prior run did (a) but failed
# before (b), re-running this script will complete (b).

echo "[firedown] Patching configure..."

python3 - "$FFMPEG_DIR/configure" <<'PYEOF'
import sys

path = sys.argv[1]
with open(path) as f:
    text = f.read()

orig = text
changes = []

# (a) Delete https_protocol_select="tls_protocol", replace with marker.
old_a = 'https_protocol_select="tls_protocol"'
marker_a = '# FIREDOWN-PATCH-A: https_protocol_select removed (was tls_protocol)'
if marker_a in text:
    pass  # already done
elif old_a in text:
    text = text.replace(old_a, marker_a, 1)
    changes.append('(a) deleted https_protocol_select line')
else:
    print('ERROR: anchor for edit (a) not found: ' + old_a, file=sys.stderr)
    print('       Upstream FFmpeg may have changed; update this script.', file=sys.stderr)
    sys.exit(2)

# (b) Inject http_protocol_deps="jni" before "# external library protocols".
inject_b = 'http_protocol_deps="jni"'
anchor_b = '# external library protocols'
if inject_b in text:
    pass  # already done
elif anchor_b in text:
    text = text.replace(anchor_b, inject_b + '\n\n' + anchor_b, 1)
    changes.append('(b) inserted http_protocol_deps="jni"')
else:
    print('ERROR: anchor for edit (b) not found: ' + anchor_b, file=sys.stderr)
    sys.exit(2)

if text != orig:
    with open(path, 'w') as f:
        f.write(text)
    for c in changes:
        print('[firedown] ' + c)
else:
    print('[firedown] configure already fully patched')
PYEOF

# Independent post-patch verification
if ! grep -q '# FIREDOWN-PATCH-A' "$FFMPEG_DIR/configure"; then
    echo "ERROR: edit (a) verification failed (https_protocol_select not removed)" >&2
    exit 3
fi
if ! grep -q '^http_protocol_deps="jni"$' "$FFMPEG_DIR/configure"; then
    echo "ERROR: edit (b) verification failed (http_protocol_deps=jni not present)" >&2
    exit 3
fi

chmod +x "$FFMPEG_DIR/configure"

# ----------------------------------------------------------------------
# Step 3: hls.c — remove keepalive code paths
# ----------------------------------------------------------------------

HLS_FILE="$FFMPEG_DIR/libavformat/hls.c"
HLS_PATCH="$FIREDOWN_DIR/patches/0002-hls-c-remove-keepalive-branches.patch"

if [[ ! -f "$HLS_FILE" ]]; then
    echo "ERROR: $HLS_FILE not found" >&2
    exit 4
fi

if grep -q "FIREDOWN-HLS-PATCHED" "$HLS_FILE"; then
    echo "[firedown] hls.c already patched, skipping"
elif [[ -f "$HLS_PATCH" ]] && head -1 "$HLS_PATCH" | grep -q '^From '; then
    echo "[firedown] Applying hls.c patch..."
    if ! patch -p1 --forward --reject-file=- -d "$FFMPEG_DIR" < "$HLS_PATCH"; then
        echo "ERROR: hls.c patch failed to apply" >&2
        echo "       FFmpeg source may have changed; regenerate the patch with:" >&2
        echo "       ./firedown/scripts/generate-hls-patch.sh $FFMPEG_DIR" >&2
        exit 5
    fi
else
    echo "WARNING: $HLS_PATCH is missing or a placeholder" >&2
    echo "         Generate it with: ./firedown/scripts/generate-hls-patch.sh $FFMPEG_DIR" >&2
    echo "         Continuing without hls.c patch — connection keepalive still active." >&2
fi

# ----------------------------------------------------------------------
# Step 3b: hls.c — cache and reuse single-use AES keys (Niconico domand)
# ----------------------------------------------------------------------
# Applied as a separate patch (its own FIREDOWN-HLS-KEYCACHE marker) so it is
# idempotent independently of the keepalive patch above. Its hunks live well
# away from the keepalive hunks (read_key + the include block, vs. open_url),
# so applying after Step 3 just lands at an offset — patch handles that.

KEYCACHE_PATCH="$FIREDOWN_DIR/patches/0004-hls-c-single-use-key-cache.patch"

if grep -q "FIREDOWN-HLS-KEYCACHE" "$HLS_FILE"; then
    echo "[firedown] hls.c key cache already applied, skipping"
elif [[ -f "$KEYCACHE_PATCH" ]] && head -1 "$KEYCACHE_PATCH" | grep -q '^From '; then
    echo "[firedown] Applying hls.c single-use key cache patch..."
    if ! patch -p1 --forward --reject-file=- -d "$FFMPEG_DIR" < "$KEYCACHE_PATCH"; then
        echo "ERROR: hls.c key cache patch failed to apply" >&2
        echo "       FFmpeg source may have changed; regenerate the patch with:" >&2
        echo "       ./firedown/scripts/generate-keycache-patch.sh $FFMPEG_DIR" >&2
        exit 6
    fi
else
    echo "WARNING: $KEYCACHE_PATCH is missing or a placeholder" >&2
    echo "         Generate it with: ./firedown/scripts/generate-keycache-patch.sh $FFMPEG_DIR" >&2
    echo "         Continuing without the key cache — single-use AES keys (Niconico" >&2
    echo "         domand) will hang on the second open." >&2
fi

# Step 3c: hls.c — bail out after consecutive segment open failures
# ----------------------------------------------------------------------
# Separate patch (its own FIREDOWN-HLS-SEGFAIL marker) so it is idempotent
# independently of the patches above. Its hunks (struct playlist field +
# read_data_continuous) are distinct from the keepalive (open_url) and key
# cache (read_key) hunks, so applying after Steps 3/3b just lands at an offset.

SEGFAIL_PATCH="$FIREDOWN_DIR/patches/0005-hls-c-bail-on-consecutive-segment-failures.patch"

if grep -q "FIREDOWN-HLS-SEGFAIL" "$HLS_FILE"; then
    echo "[firedown] hls.c segment-failure bail already applied, skipping"
elif [[ -f "$SEGFAIL_PATCH" ]] && head -1 "$SEGFAIL_PATCH" | grep -q '^From '; then
    echo "[firedown] Applying hls.c consecutive-segment-failure bail patch..."
    if ! patch -p1 --forward --reject-file=- -d "$FFMPEG_DIR" < "$SEGFAIL_PATCH"; then
        echo "ERROR: hls.c segment-failure patch failed to apply" >&2
        echo "       FFmpeg source may have changed; regenerate the patch with:" >&2
        echo "       ./firedown/scripts/generate-segfail-patch.sh $FFMPEG_DIR" >&2
        exit 7
    fi
else
    echo "WARNING: $SEGFAIL_PATCH is missing or a placeholder" >&2
    echo "         Generate it with: ./firedown/scripts/generate-segfail-patch.sh $FFMPEG_DIR" >&2
    echo "         Continuing without it — a stream whose every segment fails (e.g." >&2
    echo "         a live HLS whose fragments all 403) will probe/download forever." >&2
fi

# ----------------------------------------------------------------------
# Step 3d: dashdec.c — drop xmlCleanupParser() after each manifest parse
# ----------------------------------------------------------------------
# Separate patch (its own FIREDOWN-DASH-XMLCLEANUP marker), a different file
# from the hls.c patches above, so it is idempotent on its own. Removes the
# libxml2 process-exit teardown that dashdec.c ran after EVERY manifest parse:
# it destroys libxml2's static global mutexes, so a second DASH manifest parse
# on another thread of the same process (capture-probe pool, downloader, a
# live refresh_manifest) locked a destroyed mutex and bionic aborted the app
# ("pthread_mutex_lock called on a destroyed mutex", 1.1.91 tombstone).

DASH_FILE="$FFMPEG_DIR/libavformat/dashdec.c"
XMLCLEANUP_PATCH="$FIREDOWN_DIR/patches/0006-dashdec-c-drop-xmlCleanupParser.patch"

if [[ ! -f "$DASH_FILE" ]]; then
    echo "ERROR: $DASH_FILE not found" >&2
    exit 8
fi

if grep -q "FIREDOWN-DASH-XMLCLEANUP" "$DASH_FILE"; then
    echo "[firedown] dashdec.c xmlCleanupParser removal already applied, skipping"
elif [[ -f "$XMLCLEANUP_PATCH" ]] && head -1 "$XMLCLEANUP_PATCH" | grep -q '^From '; then
    echo "[firedown] Applying dashdec.c xmlCleanupParser removal patch..."
    if ! patch -p1 --forward --reject-file=- -d "$FFMPEG_DIR" < "$XMLCLEANUP_PATCH"; then
        echo "ERROR: dashdec.c xmlCleanupParser patch failed to apply" >&2
        echo "       FFmpeg source may have changed; regenerate the patch with:" >&2
        echo "       ./firedown/scripts/generate-xmlcleanup-patch.sh $FFMPEG_DIR" >&2
        exit 9
    fi
else
    echo "WARNING: $XMLCLEANUP_PATCH is missing or a placeholder" >&2
    echo "         Generate it with: ./firedown/scripts/generate-xmlcleanup-patch.sh $FFMPEG_DIR" >&2
    echo "         Continuing without it — two DASH manifests parsed concurrently in one" >&2
    echo "         process can abort it (destroyed libxml2 mutex)." >&2
fi

# Independent post-patch verification: the call must be gone, not merely marked.
if grep -q 'xmlCleanupParser();' "$DASH_FILE"; then
    echo "ERROR: dashdec.c still calls xmlCleanupParser() after patching" >&2
    exit 9
fi

# ----------------------------------------------------------------------
# Step 3e: dashdec.c — parse manifests in Java (FFmpegXml), not libxml2
# ----------------------------------------------------------------------
# dashdec.c keeps calling libxml2's names; fdxml.h maps them onto a tree that
# libavformat/fdxml.c rebuilds from ONE JNI call per manifest. So dashdec.c
# itself changes in two lines (the include and the parse call), and the
# DASH demuxer depends on JNI instead of libxml2 — build WITHOUT -xml2.
#
# The guard at the end is the part to keep: fdxml.h implements only the
# libxml2 calls dashdec.c makes today. An FFmpeg bump that adds one must fail
# here, not compile against a missing macro or link against a stray libxml2.

FDXML_HEADER="$FFMPEG_DIR/libavformat/fdxml.h"

python3 - "$DASH_FILE" "$FFMPEG_DIR/configure" "$FFMPEG_DIR/libavformat/Makefile" "$FDXML_HEADER" <<'PYEOF'
import re
import sys

dash_path, configure_path, makefile_path, header_path = sys.argv[1:]


def edit(path, old, new, marker, what):
    with open(path) as f:
        text = f.read()
    if marker in text:
        return
    if old not in text:
        print('ERROR: anchor for %s not found in %s: %s' % (what, path, old), file=sys.stderr)
        print('       Upstream FFmpeg may have changed; update this script.', file=sys.stderr)
        sys.exit(10)
    with open(path, 'w') as f:
        f.write(text.replace(old, new, 1))
    print('[firedown] ' + what)


edit(dash_path,
     '#include <libxml/parser.h>',
     '#include "fdxml.h" /* FIREDOWN-DASH-FDXML: XML tree from FFmpegXml (JNI) */',
     'FIREDOWN-DASH-FDXML', 'dashdec.c: include fdxml.h')
edit(dash_path,
     'doc = xmlReadMemory(buf.str, buf.len, c->base_url, NULL, 0);',
     'doc = ff_fdxml_read_memory(s, buf.str, buf.len);',
     'ff_fdxml_read_memory(', 'dashdec.c: parse through ff_fdxml_read_memory')
edit(configure_path,
     'dash_demuxer_deps="libxml2"',
     'dash_demuxer_deps="jni"',
     'dash_demuxer_deps="jni"', 'configure: dash demuxer depends on jni')
edit(makefile_path,
     'OBJS-$(CONFIG_DASH_DEMUXER)              += dash.o dashdec.o\n',
     'OBJS-$(CONFIG_DASH_DEMUXER)              += dash.o dashdec.o fdxml.o\n',
     'dashdec.o fdxml.o', 'Makefile: build fdxml.o with the dash demuxer')

with open(dash_path) as f:
    dash = f.read()
with open(header_path) as f:
    header = f.read()
if 'libxml/' in dash:
    print('ERROR: dashdec.c still includes a libxml2 header', file=sys.stderr)
    sys.exit(10)
provided = set(re.findall(r'^#define\s+(xml\w+|LIBXML_\w+)', header, re.M))
provided |= set(re.findall(r'\b(xml[A-Z]\w*|XML_[A-Z_]+)\b', header))
# Code only: comments (patch 0006's among them) may name libxml2 freely.
code = re.sub(r'/\*.*?\*/', ' ', dash, flags=re.S)
code = re.sub(r'//[^\n]*', ' ', code)
used = set(re.findall(r'\b(xml[A-Z]\w*|XML_[A-Z_]+|LIBXML_\w+)\b', code))
missing = sorted(used - provided)
if missing:
    print('ERROR: dashdec.c uses libxml2 names fdxml.h does not provide: ' + ', '.join(missing), file=sys.stderr)
    print('       Implement them in firedown/replacements/libavformat/fdxml.{c,h}', file=sys.stderr)
    print('       with libxml2 2.13 semantics, and diff dashdec parse results against', file=sys.stderr)
    print('       a libxml2 build before shipping.', file=sys.stderr)
    sys.exit(10)
PYEOF

if ! grep -q 'FIREDOWN-DASH-FDXML' "$DASH_FILE" || ! grep -q 'ff_fdxml_read_memory(' "$DASH_FILE"; then
    echo "ERROR: dashdec.c fdxml edit verification failed" >&2
    exit 10
fi
if ! grep -q '^dash_demuxer_deps="jni"$' "$FFMPEG_DIR/configure"; then
    echo "ERROR: configure dash_demuxer_deps edit verification failed" >&2
    exit 10
fi

echo "[firedown] Done."
