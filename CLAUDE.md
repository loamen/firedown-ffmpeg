# CLAUDE.md — firedown-ffmpeg

Guidance for Claude (and other agents) working in this repo. This is a fork of
**ffmpeg-android-maker** that builds the FFmpeg shared libraries shipped inside
the Firedown Android app. The app repo (`firedown`) consumes the `.so`s; its
own `CLAUDE.md` has the media-capture and download-flow context.

## What this repo does

`ffmpeg-android-maker.sh` downloads vanilla FFmpeg (pinned to **8.1.1** via
`scripts/parse-arguments.sh` → `SOURCE_VALUE=8.1.1`, `TAR`) and, **after**
download / **before** per-ABI builds, applies Firedown's modifications via
`firedown/apply-firedown-patches.sh` (wired in by the hook in
`ffmpeg-android-maker.sh`). Output `.so`s are synced into the app with the app
repo's `scripts/sync-ffmpeg.sh`.

If you bump the FFmpeg version, the patches/replacements must be regenerated /
re-validated against the new source (the generators below diff against vanilla).

## The Firedown modifications (`firedown/`)

| kind | file | purpose |
|------|------|---------|
| replacement | `replacements/libavformat/http.c` | **OkHttp JNI backend.** FFmpeg's HTTP is bridged to the app's OkHttp client (`FFmpegOkhttp`) via a custom AVIO handler. Carries headers/Range/206 handling. Also sets `h->is_streamed = (total <= 0)` so a seekable-but-unknown-size fMP4 segment stream doesn't defeat the mov `read_header` early-out (see "two different walks" below). |
| replacement | `replacements/libavcodec/webp.c`, `replacements/libavformat/webp_anim_dec.c` | Animated WebP decoder + demuxer (FFmpeg PR #22975). |
| patch | `patches/0002-hls-c-remove-keepalive-branches.patch` | Removes hls.c `open_url_keepalive` paths (OkHttp pools at the transport layer). Generator: `scripts/generate-hls-patch.sh`. Marker: `FIREDOWN-HLS-PATCHED`. |
| patch | `patches/0004-hls-c-single-use-key-cache.patch` | **Single-use AES-key cache** (see below). Generator: `scripts/generate-keycache-patch.sh`. Marker: `FIREDOWN-HLS-KEYCACHE`. |
| patch | `patches/0005-hls-c-bail-on-consecutive-segment-failures.patch` | **Bail on an all-failing segment stream** (see below). Generator: `scripts/generate-segfail-patch.sh`. Marker: `FIREDOWN-HLS-SEGFAIL`. |
| patch | `patches/0001-…`, `patches/0003-…` | ffmpeg-android-maker build hook + configure flags. |

`apply-firedown-patches.sh` is **idempotent** — each edit is gated on a marker
or canonical content, so re-runs and partial states are safe. Each hls.c patch
is applied only if its marker is absent. **Per-site request quirks (headers a
site needs) live in the app/parser emit, never in `http.c`** — the bridge is
generic and host-agnostic.

## hls.c single-use AES-key cache (`patches/0004`) — the important one

**Root cause it fixes (Niconico domand "endless probing / 720p hangs"):** the
domand AES key URL is **single-use per session** — the first GET of
`…/keys/<rendition>.key` returns the real 16-byte key; every later GET of that
*same URL* returns a different **garbage decoy** (HTTP 200, no error). A wrong
key → AES-CBC garbage → the `mov` demuxer reads a phantom multi-hundred-MB box
and `avio_skip`s it across the whole track → `find_stream_info` walks every
segment to EOF → the hang.

It triggers because the **same** key URL is fetched **more than once per
session**: Firedown opens the stream twice (the app's `metadatareader` probe,
then `downloader`), two separate `AVFormatContext`s of one session. (It can also
double-fetch within a *single* open when a walk makes `update_init_section`
re-read the init segment — a symptom, covered too.)

**The fix:** `read_key()` consults a **process-global cache keyed by the full
signed key URL** before fetching; on a miss it fetches and stores; on a hit it
copies the cached 16 bytes and skips the round-trip. So the first (real) fetch
is reused by every later open in the process → no second fetch → no decoy.
Properties: **first-writer-wins** (a racing decoy can't clobber a cached real
key), FIFO-bounded to 16 entries, guarded by a static `AVMutex`
(`libavutil/thread.h`, no-op when threads are disabled).

**Design decisions to preserve (don't "improve" these away):**
- **It is UNCONDITIONAL — not gated behind an AVOption.** A gated/opt-in design
  was rejected: `metadatareader` (open #1) is always the *first* key consumer,
  so it always gets the real key and always succeeds (the item shows in the
  app's Capture fragment) **regardless of any option**; only `downloader`
  (open #2) needs the cache. A gated cache would have to be set on *both* opens,
  and a miss would silently produce "shows in Capture, then hangs on download."
  Forcing it on removes that trap and is safe — it's URL-keyed (no
  cross-content collision) and, for a normal stream, the cached bytes equal what
  a re-fetch would return (transparent). The only case where reuse differs is a
  *stable-URL, rotating-key* stream — that's **live** HLS; the app downloads
  VOD. If a site ever misbehaves, prefer an **opt-OUT** (default on) over opt-in.
- **Belongs in the fork, not upstream.** libavformat is reentrant with no shared
  global state and opens a stream once per context; the process-global cache
  violates that contract, so upstream would reject it. It's correct here because
  Firedown's two opens share one process.

**Rotating keys:** standard rotation (a *new* key URL per `#EXT-X-KEY`) is fully
handled — each URL is its own entry/fetch. Same-URL rotation (stable URL,
changing bytes) is **not** handled (serves stale until eviction); hls.c cannot
re-mint a session (that's an app-level re-capture), and a blind re-fetch would
return a decoy for a single-use key. Refresh-on-garbage is therefore deferred;
if implemented it must be guarded (needs mov→hls feedback). See the app repo's
CLAUDE.md "Niconico domand AES key" section for the full investigation,
confounds already disproven (headers/cookies/Range/`is_streamed`), and the
diagnostic discipline (clean test = fresh session, ffmpeg as the first key
consumer).

## hls.c bail-on-all-failing-segments (`patches/0005`)

**Root cause it fixes ("endless probing on a dead live stream"):** ffmpeg's HLS
reader (`read_data_continuous`) retries a segment `seg_max_retry` times (default
0) then **skips** it (`cur_seq_no++`) and reloads the playlist. But the retry
counter is **per-segment** (a local, reset on every skip), so there is **no
bound across segments**. A playlist whose *every* segment fails to open just
skips one, reloads, skips the next, reloads — forever. A **live** playlist has
no `#EXT-X-ENDLIST` (no EOF to end it), and because the live edge keeps
advancing the list is never "insufficient", so vanilla's `max_reload` /
`m3u8_hold_counters` (which only catch a *stalled* list) never trip either.
`avformat_find_stream_info` (the `metadatareader` capture probe) and the
downloader both sit on this loop with no exit short of the `AVIOInterruptCB`,
which only fires on a user cancel. The trigger seen in the wild: a YouTube
**live** broadcast captured as HLS (live uses HLS, not SABR — see the app repo)
whose `videoplayback` fragments all return **403** (a stale/untransformed n-param
token); the manifest host serves the playlist fine, every `rr*.googlevideo.com`
segment 403s, and the probe spins.

**The fix:** count **consecutive whole-segment open failures** on the playlist
(`firedown_seg_open_failures`), reset to 0 on any successful open, and once a run
exceeds `FIREDOWN_HLS_MAX_CONSECUTIVE_SEG_FAILURES` (10) **propagate the open
error** (`return ret`, e.g. `AVERROR_HTTP_FORBIDDEN`) instead of skipping +
reloading. So an isolated bad fragment on an otherwise-good VOD is still skipped
(the count resets the moment one segment opens), but a fully-broken stream fails
fast — within ~10 fragments. On a live stream those skips are paced by the
reload wait (~one target-duration each), so the bound is ~10×segment-duration of
wall time; lower the constant if that feels long.

**Design decisions to preserve:**
- **It belongs in the demuxer, NOT the okhttp protocol** (`http.c` /
  `FFmpegOkhttp`). Each fragment is a *separate* `URLContext` with a fresh
  `FFmpegOkhttp` instance, so the protocol has no cross-fragment state to count
  "all subsequent failed"; it already returns the 403 correctly. Only the
  demuxer owns the skip/reload loop and the per-playlist state, and only it can
  decide a *run* of failures means "give up". The protocol must keep mapping a
  403 to `AVERROR_HTTP_FORBIDDEN` (skippable) — **not** `AVERROR_EXIT`, which is
  reserved for cancel and would abort on a *single* bad VOD segment.
- **A wall-clock timer was rejected.** A deadline on the interrupt callback would
  also bound it, but it's blunt — it can't tell "broken" from "legitimately
  slow", and would risk tripping a slow-but-working probe. Counting the actual
  failure condition (a run of open failures) is precise and resets on progress.
- **HLS only, for now.** This patches `read_data_continuous` (the audio/video
  segment reader). The subtitle reader (`read_data_subtitle_segment`) and the
  DASH demuxer (`dashdec.c`) have the same unbounded-skip shape; if a dead DASH
  stream is ever observed to hang, mirror this counter there.

## Two different "walks to EOF" — don't conflate them

1. **read_header walk (seekability):** a seekable-but-unknown-size segment
   stream defeats mov's `read_header` early-out → mov walks moof/mdat to EOF
   *during `avformat_open_input`*. Fixed in `replacements/libavformat/http.c`
   (`is_streamed`). Independent of the key.
2. **find_stream_info walk (decoy key):** a wrong AES key → garbage → mov skips
   a phantom box to EOF *during `find_stream_info`*. Fixed by the `0004` key
   cache. `is_streamed` does **not** affect this one.

## After changing a patch / bumping FFmpeg

- Regenerate against the new vanilla source: `scripts/generate-hls-patch.sh
  <ffmpeg-src>` and `scripts/generate-keycache-patch.sh <ffmpeg-src>`.
- Confirm `apply-firedown-patches.sh <ffmpeg-src>` applies cleanly and is
  idempotent (run twice).
- Rebuild the `.so`s and run the app repo's `scripts/sync-ffmpeg.sh`.
- Don't push to `master`/default without being asked; develop on a branch.
