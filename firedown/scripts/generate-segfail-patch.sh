#!/usr/bin/env bash
#
# generate-segfail-patch.sh
#
# One-time helper: given a vanilla FFmpeg source tree, produces a real
# unified-diff patch at
#   firedown/patches/0005-hls-c-bail-on-consecutive-segment-failures.patch
# that applies cleanly with `patch -p1`.
#
# Run this whenever you bump FFmpeg versions in the build, to regenerate the
# patch against the new upstream hls.c.
#
# What the patch does — the "endless probing on an all-403 live stream" fix:
#
#   ffmpeg's HLS reader (read_data_continuous) retries a segment seg_max_retry
#   times, then SKIPS it (cur_seq_no++) and reloads the playlist. But the retry
#   counter is *per segment* (a local reset on every skip), so there is no
#   bound across segments: a playlist whose EVERY segment fails to open —
#   e.g. a live broadcast whose fragments all return 403 (a stale/untransformed
#   token), or any stream the CDN has revoked — skips one fragment, reloads,
#   skips the next, reloads, forever. A live playlist has no #EXT-X-ENDLIST, so
#   there is no EOF to end it, and because the live edge keeps advancing the
#   playlist is never "insufficient", so max_reload / m3u8_hold_counters never
#   trip either. find_stream_info (the capture probe) and the downloader both
#   sit on this loop with no way out short of the AVIO interrupt callback, which
#   only fires on a user cancel. Net effect: the worker thread spins on a dead
#   stream indefinitely.
#
#   Fix: count CONSECUTIVE whole-segment open failures on the playlist, reset
#   the count to 0 on any successful open, and once a run exceeds a small bound
#   propagate the open error (return ret) instead of skipping + reloading. This
#   rides out a handful of genuinely-transient fragment errors on an otherwise
#   good VOD (the count resets the moment one segment opens) while failing fast
#   on a fully-broken stream. It is NOT done in the okhttp protocol layer: each
#   fragment is a separate URLContext, the protocol already returns the 403
#   correctly, and only the demuxer (which owns the skip/reload loop and the
#   per-playlist state) can decide a *run* of failures means "give up" without
#   abusing AVERROR_EXIT (reserved for cancel) or aborting on a single skippable
#   bad segment.
#
# Usage:
#   ./generate-segfail-patch.sh <path-to-vanilla-ffmpeg-source>

set -euo pipefail

FFMPEG_DIR="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIREDOWN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PATCH_OUT="$FIREDOWN_DIR/patches/0005-hls-c-bail-on-consecutive-segment-failures.patch"

if [[ -z "$FFMPEG_DIR" ]] || [[ ! -f "$FFMPEG_DIR/libavformat/hls.c" ]]; then
    echo "Usage: $0 <path-to-vanilla-ffmpeg-source>" >&2
    exit 1
fi

ORIGINAL="$FFMPEG_DIR/libavformat/hls.c"
MODIFIED="$(mktemp)"

# Apply transformations using Python for reliable multi-line block matching.
python3 - "$ORIGINAL" "$MODIFIED" <<'PYEOF'
import sys

src_path, out_path = sys.argv[1], sys.argv[2]
with open(src_path, 'r') as f:
    src = f.read()

# ---------------------------------------------------------------------------
# Transformation 1: add a per-playlist consecutive-failure counter to
# struct playlist. Anchor on the cur_seq_no / last_seq_no pair so we land in
# the segment-sequence bookkeeping block.
# ---------------------------------------------------------------------------
field_anchor = (
    '    int64_t cur_seq_no;\n'
    '    int64_t last_seq_no;\n'
)
field_add = (
    '    int64_t cur_seq_no;\n'
    '    int64_t last_seq_no;\n'
    '    /* FIREDOWN-HLS-SEGFAIL: number of consecutive whole segments that\n'
    '     * failed to open (each after its seg_max_retry retries). Reset to 0 on\n'
    '     * any successful segment open. When a run exceeds\n'
    '     * FIREDOWN_HLS_MAX_CONSECUTIVE_SEG_FAILURES, read_data_continuous\n'
    '     * propagates the open error instead of skipping + reloading forever. */\n'
    '    int firedown_seg_open_failures;\n'
)
if 'firedown_seg_open_failures' in src:
    pass  # already present
elif field_anchor in src:
    src = src.replace(field_anchor, field_add, 1)
else:
    print("ERROR: struct playlist cur_seq_no/last_seq_no anchor not matched", file=sys.stderr)
    sys.exit(2)

# ---------------------------------------------------------------------------
# Transformation 2: define the bound just above read_data_continuous.
# ---------------------------------------------------------------------------
fn_anchor = 'static int read_data_continuous(void *opaque, uint8_t *buf, int buf_size)\n'
define_block = (
    '/* FIREDOWN-HLS-SEGFAIL: give up on a playlist whose segments keep failing\n'
    ' * to open. Vanilla retries each segment seg_max_retry times then skips it,\n'
    ' * but that counter is per-segment, so a stream where EVERY segment fails\n'
    ' * (e.g. a live playlist whose fragments all return 403) skips forever and\n'
    ' * never ends find_stream_info / the read loop. We count consecutive\n'
    ' * whole-segment open failures and, past this bound, propagate the open\n'
    ' * error so the demuxer fails fast instead of probing the entire (endless)\n'
    ' * manifest. Small enough to kill a fully-broken stream in a few segments,\n'
    ' * large enough to ride out a handful of genuinely-transient fragment\n'
    ' * errors on an otherwise-good VOD (the count resets on any open success). */\n'
    '#define FIREDOWN_HLS_MAX_CONSECUTIVE_SEG_FAILURES 10\n'
    '\n'
)
if '#define FIREDOWN_HLS_MAX_CONSECUTIVE_SEG_FAILURES' in src:
    pass
elif fn_anchor in src:
    src = src.replace(fn_anchor, define_block + fn_anchor, 1)
else:
    print("ERROR: read_data_continuous signature anchor not matched", file=sys.stderr)
    sys.exit(2)

# ---------------------------------------------------------------------------
# Transformation 3: in read_data_continuous, when a segment is definitively
# skipped due to failure, count it and bail once a run exceeds the bound.
# Matched against the exact upstream skip block so an upstream change is loud.
# ---------------------------------------------------------------------------
old_skip = (
    '            if (segment_retries >= c->seg_max_retry) {\n'
    '                av_log(v->parent, AV_LOG_WARNING, "Segment %"PRId64" of playlist %d failed too many times, skipping\\n",\n'
    '                       v->cur_seq_no,\n'
    '                       v->index);\n'
    '                v->cur_seq_no++;\n'
    '                segment_retries = 0;\n'
    '            } else {\n'
    '                segment_retries++;\n'
    '            }\n'
    '            goto restart;\n'
)
new_skip = (
    '            if (segment_retries >= c->seg_max_retry) {\n'
    '                av_log(v->parent, AV_LOG_WARNING, "Segment %"PRId64" of playlist %d failed too many times, skipping\\n",\n'
    '                       v->cur_seq_no,\n'
    '                       v->index);\n'
    '                v->cur_seq_no++;\n'
    '                segment_retries = 0;\n'
    '                /* FIREDOWN-HLS-SEGFAIL: a definitively-failed (skipped)\n'
    '                 * segment. Count consecutive failures across segments; once\n'
    '                 * a run exceeds the bound the whole playlist is treated as\n'
    '                 * unreadable and the open error (e.g. AVERROR_HTTP_FORBIDDEN)\n'
    '                 * is propagated, so a stream whose every fragment fails\n'
    '                 * cannot skip + reload forever. Reset on a successful open. */\n'
    '                v->firedown_seg_open_failures++;\n'
    '                if (v->firedown_seg_open_failures > FIREDOWN_HLS_MAX_CONSECUTIVE_SEG_FAILURES) {\n'
    '                    av_log(v->parent, AV_LOG_ERROR,\n'
    '                           "Playlist %d: %d consecutive segments failed to open, giving up\\n",\n'
    '                           v->index, v->firedown_seg_open_failures);\n'
    '                    return ret;\n'
    '                }\n'
    '            } else {\n'
    '                segment_retries++;\n'
    '            }\n'
    '            goto restart;\n'
)
if new_skip in src:
    pass
elif old_skip in src:
    src = src.replace(old_skip, new_skip, 1)
else:
    print("ERROR: read_data_continuous skip block not matched", file=sys.stderr)
    sys.exit(2)

# ---------------------------------------------------------------------------
# Transformation 4: reset the run counter on a successful segment open.
# ---------------------------------------------------------------------------
old_ok = (
    '        segment_retries = 0;\n'
    '        just_opened = 1;\n'
)
new_ok = (
    '        segment_retries = 0;\n'
    '        v->firedown_seg_open_failures = 0; /* FIREDOWN-HLS-SEGFAIL: reset run on a successful open */\n'
    '        just_opened = 1;\n'
)
if new_ok in src:
    pass
elif old_ok in src:
    src = src.replace(old_ok, new_ok, 1)
else:
    print("ERROR: read_data_continuous success-reset anchor not matched", file=sys.stderr)
    sys.exit(2)

with open(out_path, 'w') as f:
    f.write(src)
PYEOF

# Produce the diff hunks rooted at a/libavformat/hls.c b/libavformat/hls.c.
DIFF_TMP="$(mktemp)"
diff -u "$ORIGINAL" "$MODIFIED" \
    | sed -e "1s|^--- .*|--- a/libavformat/hls.c|" \
          -e "2s|^+++ .*|+++ b/libavformat/hls.c|" \
    > "$DIFF_TMP" || true

if [[ ! -s "$DIFF_TMP" ]]; then
    echo "ERROR: no diff produced — transformations matched nothing or source already patched" >&2
    rm -f "$MODIFIED" "$DIFF_TMP"
    exit 1
fi

# Wrap in a git-format-patch-style envelope to match the other firedown patches
# (apply-firedown-patches.sh guards on a leading `From ` line).
{
    echo "From 0000000000000000000000000000000000000005 Mon Sep 17 00:00:00 2001"
    echo "From: solarizeddev <info@solarized.dev>"
    echo "Date: Thu, 1 Jan 1970 00:00:00 +0000"
    echo "Subject: [PATCH 5/5] hls: bail out after consecutive segment open failures"
    echo ""
    echo "read_data_continuous retries a segment seg_max_retry times then skips it,"
    echo "but the retry counter is per-segment, so a playlist whose every segment"
    echo "fails to open (e.g. a live broadcast whose fragments all return 403) skips"
    echo "+ reloads forever: a live playlist has no EXT-X-ENDLIST so there is no EOF,"
    echo "and the advancing live edge keeps the list 'sufficient' so max_reload /"
    echo "m3u8_hold_counters never trip. find_stream_info (the capture probe) and the"
    echo "downloader both spin on this with no exit short of the AVIO interrupt"
    echo "callback (user-cancel only)."
    echo ""
    echo "Count consecutive whole-segment open failures on the playlist, reset on any"
    echo "successful open, and once a run exceeds a small bound propagate the open"
    echo "error instead of skipping. Rides out transient fragment errors on a good"
    echo "VOD; fails fast on a fully-broken stream. Marker: FIREDOWN-HLS-SEGFAIL."
    echo "---"
    echo " libavformat/hls.c | varies"
    echo ""
    cat "$DIFF_TMP"
} > "$PATCH_OUT"

rm -f "$MODIFIED" "$DIFF_TMP"
echo "[firedown] wrote $PATCH_OUT"
