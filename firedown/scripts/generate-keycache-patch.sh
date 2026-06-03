#!/usr/bin/env bash
#
# generate-keycache-patch.sh
#
# One-time helper: given a vanilla FFmpeg source tree, produces a real
# unified-diff patch at
#   firedown/patches/0004-hls-c-single-use-key-cache.patch
# that applies cleanly with `patch -p1`.
#
# Run this whenever you bump FFmpeg versions in the build, to regenerate the
# patch against the new upstream hls.c.
#
# What the patch does — the Niconico domand "endless probing / 720p hangs" fix:
#
#   Some CDNs hand out a *single-use* HLS AES-128 content key. nicovideo's
#   delivery.domand is the example: its key endpoint
#   (…/keys/<rendition>.key, "Cache-Control: private, no-cache") returns the
#   real 16-byte key only on the FIRST fetch after an access-rights/hls session
#   is minted; every later fetch of that same URL returns a *different* garbage
#   decoy with HTTP 200 (no error).
#
#   A normal download opens the stream twice — avformat_find_stream_info probes
#   it, then the reader opens it again — and each open is a separate
#   AVFormatContext with its own HLSContext/playlist. libavformat's existing
#   within-context cache (open_input's `strcmp(seg->key, pls->key_url)`) only
#   spans one open, so the probe burns fetch #1 (the real key) and the reader
#   gets a decoy. A wrong AES key decrypts every fMP4 segment to garbage; the
#   nested mov demuxer reads that garbage as one box with a multi-hundred-MB
#   size and skips it across the whole track to EOF — a silent multi-minute
#   read that scales with rendition size (the "720p hangs" symptom).
#
#   Fix: a small process-global cache, keyed by the *full signed key URL*,
#   that remembers the first successfully fetched key and reuses those bytes on
#   any later read_key for the same URL — so the second/third open never burns
#   a decoy. The signed URL embeds the session token, so the key is identical
#   across the probe and reader opens of one download (one real fetch, reused)
#   and differs across sessions (each fresh session fetches its own key #1).
#
# Usage:
#   ./generate-keycache-patch.sh <path-to-vanilla-ffmpeg-source>

set -euo pipefail

FFMPEG_DIR="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIREDOWN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PATCH_OUT="$FIREDOWN_DIR/patches/0004-hls-c-single-use-key-cache.patch"

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
# Transformation 1: pull in libavutil/thread.h for the static AVMutex that
# guards the key cache. Anchor on the existing time.h include so we land in the
# libavutil include block.
# ---------------------------------------------------------------------------
inc_anchor = '#include "libavutil/time.h"\n'
inc_add = '#include "libavutil/thread.h"\n'
if inc_add in src:
    pass  # already present
elif inc_anchor in src:
    src = src.replace(inc_anchor, inc_anchor + inc_add, 1)
else:
    print("WARNING: libavutil/time.h include anchor not matched", file=sys.stderr)

# ---------------------------------------------------------------------------
# Transformation 2: replace read_key() with a cache-and-reuse version, and add
# the process-global cache + helpers just above it. Matched against the exact
# upstream function body so a mismatch (upstream change) is loud, not silent.
# ---------------------------------------------------------------------------
old_read_key = (
    'static int read_key(HLSContext *c, struct playlist *pls, struct segment *seg)\n'
    '{\n'
    '    AVIOContext *pb = NULL;\n'
    '\n'
    '    int ret = open_url(pls->parent, &pb, seg->key, &c->avio_opts, NULL, NULL);\n'
    '    if (ret < 0) {\n'
    '        av_log(pls->parent, AV_LOG_ERROR, "Unable to open key file %s, %s\\n",\n'
    '               seg->key, av_err2str(ret));\n'
    '        return ret;\n'
    '    }\n'
    '\n'
    '    ret = avio_read(pb, pls->key, sizeof(pls->key));\n'
    '    ff_format_io_close(pls->parent, &pb);\n'
    '    if (ret != sizeof(pls->key)) {\n'
    '        if (ret < 0) {\n'
    '            av_log(pls->parent, AV_LOG_ERROR, "Unable to read key file %s, %s\\n",\n'
    '                   seg->key, av_err2str(ret));\n'
    '        } else {\n'
    '            av_log(pls->parent, AV_LOG_ERROR, "Unable to read key file %s, read bytes %d != %zu\\n",\n'
    '                   seg->key, ret, sizeof(pls->key));\n'
    '            ret = AVERROR_INVALIDDATA;\n'
    '        }\n'
    '\n'
    '        return ret;\n'
    '    }\n'
    '\n'
    '    av_strlcpy(pls->key_url, seg->key, sizeof(pls->key_url));\n'
    '\n'
    '    return 0;\n'
    '}\n'
)

new_read_key = r'''/* FIREDOWN-HLS-KEYCACHE: process-global cache of fetched HLS AES-128 keys,
 * keyed by the full (signed) key URL.
 *
 * Why: some CDNs hand out a *single-use* content key — notably nicovideo's
 * delivery.domand, whose key endpoint (…/keys/<rendition>.key,
 * "Cache-Control: private, no-cache") returns the real 16-byte key only on the
 * FIRST fetch after an access-rights/hls session is minted; every later fetch
 * of that same URL returns a *different* garbage decoy with HTTP 200 (no
 * error). A normal download opens the stream twice — avformat_find_stream_info
 * probes it, then the reader opens it again — and each open is a separate
 * AVFormatContext with its own HLSContext/playlist. libavformat's existing
 * within-context cache (open_input's `strcmp(seg->key, pls->key_url)`) only
 * spans one open, so the probe burns fetch #1 (the real key) and the reader
 * gets a decoy. With a wrong AES key every fMP4 segment decrypts to garbage;
 * the nested mov demuxer reads that garbage as one box with a multi-hundred-MB
 * size and skips it across the whole track to EOF — the "endless probing /
 * 720p hangs" symptom (no error, just a multi-minute read that scales with
 * rendition size).
 *
 * Fix: remember the first successfully fetched key for a given URL and reuse
 * those bytes on any later read_key for the same URL, so the second/third open
 * never burns a decoy. The cache key is the *full signed URL*, which embeds
 * the session token: identical across the probe and reader opens of one
 * download (one real fetch, reused) and different across sessions (each fresh
 * session fetches its own key #1). That keying is correct whether the content
 * key is static-per-content or minted-per-session — we never serve one
 * session's bytes to another; a re-minted session always produces a
 * *different* URL, so it simply gets its own cache entry.
 *
 * Scope is deliberately tiny: one key URL per playlist per session, so a
 * handful of entries with FIFO eviction is plenty. Guarded by a static mutex
 * because the probe and the reader can run on different threads.
 */
#define HLS_KEY_CACHE_MAX 16

struct hls_key_cache_entry {
    char *url;
    uint8_t key[16];
};

static struct hls_key_cache_entry hls_key_cache[HLS_KEY_CACHE_MAX];
static int hls_key_cache_count;
static int hls_key_cache_next; /* FIFO eviction cursor */
static AVMutex hls_key_cache_mutex = AV_MUTEX_INITIALIZER;

/* Copy the cached key for `url` into `out` (16 bytes).
 * Returns 1 on a cache hit, 0 on a miss. */
static int hls_key_cache_get(const char *url, uint8_t *out)
{
    int found = 0;
    int i;

    ff_mutex_lock(&hls_key_cache_mutex);
    for (i = 0; i < hls_key_cache_count; i++) {
        if (hls_key_cache[i].url == NULL) {
            continue;
        }
        if (strcmp(hls_key_cache[i].url, url) == 0) {
            memcpy(out, hls_key_cache[i].key, 16);
            found = 1;
            break;
        }
    }
    ff_mutex_unlock(&hls_key_cache_mutex);

    return found;
}

/* Store the 16 key bytes for `url`. First-writer-wins: best-effort, and on an
 * allocation failure the entry is simply not cached. */
static void hls_key_cache_put(const char *url, const uint8_t *key)
{
    int slot;
    int i;

    ff_mutex_lock(&hls_key_cache_mutex);

    /* First-writer-wins: if this URL is already cached, keep the existing
     * bytes. read_key() does get()->fetch->put() with the lock released across
     * the fetch, so two threads can both miss and both fetch the same URL; the
     * FIRST fetch of a single-use key URL is the real one, so a later (racing)
     * fetch that returns a decoy must not clobber it. A re-minted session
     * always yields a *different* URL, so there is never a legitimate need to
     * overwrite an entry in place. */
    for (i = 0; i < hls_key_cache_count; i++) {
        if (hls_key_cache[i].url != NULL && strcmp(hls_key_cache[i].url, url) == 0) {
            ff_mutex_unlock(&hls_key_cache_mutex);
            return;
        }
    }

    if (hls_key_cache_count < HLS_KEY_CACHE_MAX) {
        slot = hls_key_cache_count;
        hls_key_cache_count++;
    } else {
        /* Table full: evict the oldest entry (FIFO). */
        slot = hls_key_cache_next;
        hls_key_cache_next = (hls_key_cache_next + 1) % HLS_KEY_CACHE_MAX;
        av_freep(&hls_key_cache[slot].url);
    }

    hls_key_cache[slot].url = av_strdup(url);
    if (hls_key_cache[slot].url != NULL) {
        memcpy(hls_key_cache[slot].key, key, 16);
    }

    ff_mutex_unlock(&hls_key_cache_mutex);
}

static int read_key(HLSContext *c, struct playlist *pls, struct segment *seg)
{
    AVIOContext *pb = NULL;
    int ret;

    /* FIREDOWN-HLS-KEYCACHE: serve a previously fetched key for this exact URL
     * without a server round-trip, so a second open (probe vs. reader) cannot
     * burn a single-use key and get a decoy. See the note above. */
    if (hls_key_cache_get(seg->key, pls->key)) {
        av_strlcpy(pls->key_url, seg->key, sizeof(pls->key_url));
        return 0;
    }

    ret = open_url(pls->parent, &pb, seg->key, &c->avio_opts, NULL, NULL);
    if (ret < 0) {
        av_log(pls->parent, AV_LOG_ERROR, "Unable to open key file %s, %s\n",
               seg->key, av_err2str(ret));
        return ret;
    }

    ret = avio_read(pb, pls->key, sizeof(pls->key));
    ff_format_io_close(pls->parent, &pb);
    if (ret != sizeof(pls->key)) {
        if (ret < 0) {
            av_log(pls->parent, AV_LOG_ERROR, "Unable to read key file %s, %s\n",
                   seg->key, av_err2str(ret));
        } else {
            av_log(pls->parent, AV_LOG_ERROR, "Unable to read key file %s, read bytes %d != %zu\n",
                   seg->key, ret, sizeof(pls->key));
            ret = AVERROR_INVALIDDATA;
        }

        return ret;
    }

    av_strlcpy(pls->key_url, seg->key, sizeof(pls->key_url));

    /* FIREDOWN-HLS-KEYCACHE: remember this freshly fetched key so the next
     * open of the same stream reuses it instead of re-fetching (and burning) a
     * single-use key. */
    hls_key_cache_put(seg->key, pls->key);

    return 0;
}
'''

if old_read_key in src:
    src = src.replace(old_read_key, new_read_key, 1)
else:
    print("WARNING: read_key() body not matched — upstream may have changed",
          file=sys.stderr)

with open(out_path, 'w') as f:
    f.write(src)
PYEOF

# Build a unified diff.
TMP_DIFF="$(mktemp)"
diff -u \
    --label "a/libavformat/hls.c" \
    --label "b/libavformat/hls.c" \
    "$ORIGINAL" "$MODIFIED" > "$TMP_DIFF" || true

if [[ ! -s "$TMP_DIFF" ]]; then
    echo "ERROR: no changes produced — check the WARNING output above" >&2
    rm -f "$MODIFIED" "$TMP_DIFF"
    exit 2
fi

# Wrap with git-format-patch headers.
{
cat <<'HEADER_EOF'
From 0000000000000000000000000000000000000004 Mon Sep 17 00:00:00 2001
From: solarizeddev <info@solarized.dev>
Date: Thu, 1 Jan 1970 00:00:00 +0000
Subject: [PATCH 4/4] hls: cache and reuse single-use AES keys (Niconico domand)

Some CDNs hand out a single-use HLS AES-128 content key — notably
nicovideo's delivery.domand, whose key endpoint returns the real key only
on the first fetch of a signed key URL and a different garbage decoy (HTTP
200) on every later fetch. libavformat opens the stream twice for a normal
download (find_stream_info probe + reader), each a separate AVFormatContext
whose per-playlist key cache does not span the other, so the probe burns the
real key and the reader decrypts every segment to garbage — the nested mov
demuxer then walks the whole track to EOF (the "endless probing / 720p
hangs" symptom).

This patch adds a small process-global cache in read_key(), keyed by the
full signed key URL, that stores the first successfully fetched key and
reuses those bytes on any later read_key for the same URL. The signed URL
embeds the session token, so the key is identical across the probe and
reader opens of one download and differs across sessions.

Adds a FIREDOWN-HLS-KEYCACHE marker comment so apply-firedown-patches.sh can
detect when the patch is already applied.
HEADER_EOF

echo "---"
echo " libavformat/hls.c | varies"
echo ""
cat "$TMP_DIFF"
echo "-- "
echo "2.40.0"
} > "$PATCH_OUT"

rm -f "$MODIFIED" "$TMP_DIFF"

echo "[firedown] Generated: $PATCH_OUT"
echo "[firedown] Review with: less $PATCH_OUT"
