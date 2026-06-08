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

echo "[firedown] Done."
