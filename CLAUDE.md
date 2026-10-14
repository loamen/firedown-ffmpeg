# CLAUDE.md — firedown-ffmpeg

Guidance for Claude (and other agents) working in this repo. This is a fork of
**ffmpeg-android-maker** that builds the FFmpeg shared libraries shipped inside
the Firedown Android app. The app repo (`firedown`) consumes the `.so`s; its
own `CLAUDE.md` has the media-capture and download-flow context.

## What this repo does

`ffmpeg-android-maker.sh` downloads vanilla FFmpeg (pinned to **9.0.2** via
`scripts/parse-arguments.sh` → `SOURCE_VALUE=9.0.2`, `TAR`) and, **after**
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
| native (9.0) | `webp_anim` decoder + demuxer | Animated WebP is **built into FFmpeg 9.0** (the work formerly carried as FFmpeg PR #22975 landed upstream), so this fork no longer vendors a `webp.c` / `webp_anim_dec.c` replacement — `scripts/ffmpeg/build.sh` just adds `webp_anim` to the decoder + demuxer allow-lists. Still-WebP over HTTP uses the `image_webp_pipe` demuxer (note the `image_` prefix — the bare `webp_pipe` name matches nothing). |
| patch | `patches/0002-hls-c-remove-keepalive-branches.patch` | Removes hls.c `open_url_keepalive` paths (OkHttp pools at the transport layer). Generator: `scripts/generate-hls-patch.sh`. Marker: `FIREDOWN-HLS-PATCHED`. |
| patch | `patches/0004-hls-c-single-use-key-cache.patch` | **Single-use AES-key cache** (see below). Generator: `scripts/generate-keycache-patch.sh`. Marker: `FIREDOWN-HLS-KEYCACHE`. |
| patch | `patches/0005-hls-c-bail-on-consecutive-segment-failures.patch` | **Bail on an all-failing segment stream** (see below). Generator: `scripts/generate-segfail-patch.sh`. Marker: `FIREDOWN-HLS-SEGFAIL`. |
| patch | `patches/0006-dashdec-c-drop-xmlCleanupParser.patch` | **Drop `xmlCleanupParser()` after each DASH manifest parse** (see below). Generator: `scripts/generate-xmlcleanup-patch.sh`. Marker: `FIREDOWN-DASH-XMLCLEANUP`. Moot since fdxml; kept, harmless. |
| new files + edit | `replacements/libavformat/fdxml.{c,h}` + Step 3e of `apply-firedown-patches.sh` | **DASH manifests parsed in Java, no libxml2** (see below). libxml2's tree API under libxml2's names, backed by ONE JNI call per manifest into the app's `FFmpegXml`. Step 3e: the two-line `dashdec.c` edit (marker `FIREDOWN-DASH-FDXML`), `dash_demuxer_deps="jni"`, `fdxml.o` in the Makefile, and a guard. Verify with `sh scripts/dashxml-harness/run.sh`. |
| patch | `patches/0001-…`, `patches/0003-…` | ffmpeg-android-maker build hook + configure flags. |

`apply-firedown-patches.sh` is **idempotent** — each edit is gated on a marker
or canonical content, so re-runs and partial states are safe. Each hls.c patch
is applied only if its marker is absent. **Per-site request quirks (headers a
site needs) live in the app/parser emit, never in `http.c`** — the bridge is
generic and host-agnostic.

## JNI reference discipline in `http.c` (issue #300 OOM)

`http.c` is where this fork's JNI references live at call rate (`fdxml.c`
makes one call per DASH manifest, local refs only — see its section), and HLS/DASH
opens a fresh `URLContext` — hence a fresh `FFmpegOkhttp` object and a fresh set
of jfields class refs — **per segment, key and playlist**. At that call rate any
per-open leak is unbounded, so three rules hold:

- **Every exit path releases.** ffmpeg calls `url_close` **only** for a context
  that connected (`ffurl_closep()` gates on `h->is_connected`, set only after
  `url_open2` returns 0), so `okhttp_open`'s **failure** path must do the
  close-equivalent cleanup itself — that was issue #300, where each failed open
  (403/404 segments, cancelled probes, live-edge reload storms) permanently
  leaked the `FFmpegOkhttp` object with its `mUrl`/`mHeaders` (KBs of cookies)
  plus 4 global refs, until the Java heap was gone. `okhttp_close` likewise
  never bails early: no `env` means the *JNI* releases are impossible, not that
  the native `mime_type` free should be skipped too.
- **`log_ctx` is `h` or `c` — NEVER `c->thiz`.** `av_log` dereferences its first
  argument as an `AVClass **` and calls `item_name` out of it; a `jobject` is an
  opaque handle, so passing one reads a function pointer from arbitrary memory.
  It only fires with a Java exception pending — and `okhttpSeek`/`okhttpGetMime`/
  `okhttpClose` have **no** Java-side `catch`, so a heap-exhaustion
  `OutOfMemoryError` lands there and turns a diagnosable Java OOM into a native
  SIGSEGV. That masked #300's own signature.
- **Local refs are NOT free here.** These calls arrive on long-lived *attached
  native* download threads, never via a Java frame, so local refs accumulate
  until ART's 512-entry table overflows and aborts. Delete every local ref on
  every path, and **clear a pending exception before returning** — the next JNI
  call made with one pending is a CheckJNI process abort.

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

## dashdec.c drop `xmlCleanupParser()` (`patches/0006`)

**Status since fdxml (next section):** dashdec.c no longer uses libxml2, so
the race below cannot happen — `xmlCleanupParser()` is a no-op macro in
`fdxml.h`. The patch still applies and is kept: harmless, and it is the
protection if fdxml is ever reverted. Retire it once fdxml has shipped.

**Root cause it fixes ("pthread_mutex_lock called on a destroyed mutex"):** a
1.1.91 tombstone — `SIGABRT` on a capture-probe pool thread, `libavformat`
under `avformat_open_input` ← `jni_extract_metadata`. Symbolized against the
shipped `.so` (`libfiredown.so` BuildId matched the tombstone): `dash_read_header`
→ `parse_manifest` → libxml2 parser teardown → `xmlDictFree` →
`pthread_mutex_lock` on the **static** global `xmlDictMutex`. Vanilla
`dashdec.c` ends **every** manifest parse with `xmlCleanupParser()` — libxml2's
process-exit teardown, whose own doc says calling it while another thread uses
the library "may crash the application". In the libxml2 this fork builds
(2.13.6) it runs `xmlCleanupDictInternal()` = `pthread_mutex_destroy` on that
mutex (plus the globals/memory mutexes). Firedown runs ffmpeg on several
threads of one process (capture-probe pool of `cores/2`, the downloader, the
post-download metadata refresh), so two DASH manifest parses overlapping is
enough: thread A finishes and destroys the mutex, thread B, still parsing,
frees its parser-context dictionary, locks the destroyed mutex, and bionic's
FORTIFY aborts the process. A **live** DASH download makes the overlap likelier
— `refresh_manifest()` re-runs `parse_manifest()` periodically for the whole
download. Upstream still has the call (checked against master); it is harmless
only in single-threaded users like the ffmpeg CLI.

**The fix:** delete the call. **It does not leak** — check it in libxml2, not
by intuition: every per-document allocation is freed by `xmlFreeDoc()` (kept)
and by `xmlReadMemory()` freeing its own parser context; `xmlCleanupParser()`
only tears down the one-time library state `xmlInitParser()` creates, and
2.13's `xmlInitParser()` is written to make **no allocations** ("the
initialization code must not make memory allocations"). The encoding-handler
table it frees holds only application-registered handlers (dashdec registers
none; the defaults are a `static const` array), the catalog/schema caches are
empty unless loaded, and per-thread globals are freed by a TLS destructor on
thread exit regardless. So without the call the process keeps a few hundred
bytes of static state for its lifetime; with it, dashdec tore that state down
and rebuilt it per manifest — churn on top of the race.

**Design decisions to preserve:**
- **Belongs in the fork, not upstream** — same reasoning as the key cache:
  libavformat assumes one consumer per process, Firedown's several share one.
- **No app-side workaround exists.** The app cannot know an input is DASH
  before `avformat_open_input` runs the demuxer, so it cannot serialize only
  DASH opens, and serializing every probe/download would throw away the pool.
- **Don't "fix" it by adding `xmlCleanupParser()` to a global close hook
  instead.** Any call while another thread may parse is the same bug; on
  Android the process is simply killed, so "never" is the correct answer.
- The generator refuses to emit a patch if any `xmlCleanupParser();` call
  survives in `dashdec.c`, and `apply-firedown-patches.sh` re-checks that
  after applying — a future FFmpeg that adds a second call fails the build
  loudly instead of shipping the race back.

## DASH manifests: XML from Java (fdxml) — no libxml2

**Why.** `dashdec.c` was libxml2's only consumer here, and it uses libxml2 as a
small DOM: about twenty calls (first element child, next element sibling, an
attribute by name, a node's text, a few writes to BaseURL nodes). For that the
build linked the whole library — Schema, XPath, the HTML parser and catalogs
came along — ~1.15 MB of stripped code per ABI (measured on a host build of the
same 2.13.6 configuration; ~0.24 MB with every optional module configured out),
a C XML parser in front of manifests from any website (the app's generic
catcher picks up any `<MPD>` body), and process-global state whose teardown
crashed concurrent parses (patch 0006). The device's own libxml2 is not an
option: since Android 7 an app may only load the NDK's public libraries, and
libxml2 is not one. The platform parser an app CAN reach is the Java one.

**Shape.** `dashdec.c` keeps calling libxml2's names; `fdxml.h` maps them onto
`fdxml.c`, whose tree comes from ONE JNI call per manifest:
`ff_fdxml_read_memory()` → `FFmpegXml.parse(ByteBuffer)` in the app → the
platform's `XmlPullParser` (KXmlParser) → one `byte[]` (wire format `FDX1`,
documented in `FFmpegXml`'s javadoc — the two sides must match byte for byte)
→ `ff_fdxml_doc_from_blob()`. The manifest goes over as a DIRECT ByteBuffer on
`buf.str` (no copy, and none of JNI's modified-UTF-8 near the document); every
JNI reference, the class included (`ff_jni_init_jfields(..., global = 0)`), is
local and deleted before returning; no tree state is shared between threads.
So `dashdec.c` changes in two lines, which is what keeps FFmpeg bumps cheap.
Don't "improve" it into a JNI call per `xmlGetProp` (a SegmentTimeline is
thousands of nodes, each call a local ref on a long-lived attached thread),
and don't move MPD semantics into Java (that is a dashdec rewrite to rebase on
every bump).

**The semantics are libxml2 2.13's, as far as dashdec can observe them, and
several are load-bearing** (each pinned by the harness below):
- **Names:** a prefix declared in scope (and `xml:`) is stripped — `<mpd:MPD>`
  is `MPD`, `xml:lang` is `lang` — but an UNDECLARED prefix stays in the name
  (`<mspr:pro>` is `mspr:pro`). libxml2 only warns about undeclared prefixes;
  KXmlParser's namespace mode rejects the whole document. The first version
  left prefixes to the parser and lost real manifests (PlayReady `mspr:pro`,
  SCTE-35, YouTube `yt:`), so `FFmpegXml` resolves prefixes itself with the
  parser's namespace processing OFF.
- **`xmlGetProp`** matches the local name whatever its namespace, first wins
  (`xml:lang="de" lang="en"` reads `de`).
- **`xmlNodeGetContent`** of an element is its descendant text + CDATA, and
  `""` — never NULL — when there is none: `resolve_content_path` compares it
  with `""` unguarded (the NULL mutant crashes 85 manifests under ASan).
- **Text, CDATA and comment children stay distinct nodes:** `get_content_url`
  reads a BaseURL only when its FIRST child is text. That reproduces an
  upstream quirk (a root-relative BaseURL in CDATA, or after a comment,
  resolves wrong with libxml2 too) — on purpose: the goal is identical output.
- **`xmlEncodeSpecialChars` + `xmlNodeSetContent` are an identity pair**
  (libxml2 escapes, then decodes entity references on set). Keep them in step.
- Entity references merge into the surrounding text node; an undefined entity
  refuses the document (libxml2: fatal). Nesting is capped at 256 on both
  sides (libxml2's limit without `XML_PARSE_HUGE`). A literal tab in an
  attribute becomes a space (XML attribute normalization; KXmlParser does CR/LF
  only) — a `&#9;` reference does too, where libxml2 keeps a tab: accepted.
- **The one deliberate difference: a DOCTYPE is refused** (the WebDAV PROPFIND
  rule — no MPD carries one, and it is the door to entity expansion). Listed in
  `scripts/dashxml-harness/expected-diffs.txt`; keep that list short.

**Guard.** Step 3e fails the build (exit 10) if `dashdec.c`'s code (comments
excluded) uses an `xml*` / `XML_*` / `LIBXML_*` name `fdxml.h` does not
provide — an FFmpeg bump that adds a libxml2 call must fail there, not compile
against a stray macro.

**Build and release.**
- Build **without `-xml2`** (`./ffmpeg-android-maker.sh -dav1d …`): nothing
  needs libxml2 any more, and `dash_demuxer_deps="jni"` means a non-JNI (host)
  FFmpeg build has no DASH demuxer at all.
- A `.so` built from this needs the app's `FFmpegXml` (kept by name in
  `proguard-rules.pro` — it is only ever called from native). Without it
  `FindClass` fails, every DASH manifest is refused, and the log says
  `fdxml: jfields init failed`. Ship the app side no later than the `.so`.

**Verify with `sh scripts/dashxml-harness/run.sh`** — after any change to
`fdxml.{c,h}`, to `FFmpegXml.java`, to Step 3e, and on every FFmpeg bump. It
compiles `dashdec.c`'s REAL `parse_manifest()` twice — vanilla against libxml2,
and as the REAL `apply-firedown-patches.sh` leaves it against fdxml fed by the
REAL `FFmpegXml.java` in a JVM — and diffs everything it extracts over a corpus:
`corpus/*.mpd` (hand-written, one behaviour each), `gen-corpus.py` (a 2.8 MB
segment list, nesting at and past 256) and the DASH test manifests of
ExoPlayer, Shaka Player and dash.js (sparse-cloned once; `DASHXML_EXTERNAL=0`
to skip). Under ASan/UBSan; fdxml may leak nothing libxml2 doesn't (upstream
`resolve_content_path` leaks a little in both); `fdxml.c` must compile
warning-free with and without `CONFIG_JNI`; and four planted bugs (three in
`fdxml.c`, the namespace one in `FFmpegXml.java`) must each be caught. At
write time: 120 manifests, 119 identical plus the DOCTYPE, 753 checks. About a
minute warm; the first run also builds FFmpeg and libxml2 for the host
(cached under `~/.cache/firedown-harness/dashxml`). Lesson it already taught:
LeakSanitizer exits with `_exit()` from an exit handler, so a dump that did
not flush stdout compared "identical" to another empty one — every output
must now end with `end`, and every hand-written case must parse in the
reference build, so "identical" never means "both failed".

**Known limit.** The harness runs upstream kxml2 2.3.0; Android's KXmlParser
is libcore's fork of it. A parser-specific difference only shows on a device:
download an RTVE video (the app's `rtveCdn` path) and a generic-catcher DASH
page, and grep `FFmpegXml` / `fdxml` in logcat on a debug build.

## AV1 needs `-dav1d` — the native `av1` decoder is a hwaccel-only stub

`libavcodec/av1dec.c` (the built-in `av1` decoder that the allow-list enables)
contains **no software decode path** — it only wraps hardware acceleration
back-ends. This build passes `--disable-hwaccels` (desktop hwaccels don't apply
on Android), so the native decoder can NEVER produce a frame: every
`avcodec_send_packet`/`receive_frame` fails with `AVERROR(ENOSYS)` (**-38** in
the app's `thumbnailer.c` logs), at every seek position including 0. Symptom in
the app: an AV1 download (YouTube serves AV1 at ≤1080p on modern devices) plays
fine via the platform's MediaCodec but shows a permanent mime-glyph thumbnail —
MediaMetadataRetriever also fails AV1 frame extraction on many devices (Samsung
a42xq confirmed), so the FFmpeg fallback is the last resort and it hits the
stub.

Software AV1 decode requires **libdav1d**, which is TWO opt-ins:

1. Build with the library: `./ffmpeg-android-maker.sh -dav1d -abis=arm64-v8a,x86_64`
   (`--enable-libdav1d` is the same flag's long form; host needs `meson`,
   `ninja` and `nasm` for the dav1d build).
2. The decoder allow-list must name it — `--enable-libdav1d` only makes the
   decoder *available*; `--disable-decoders` still excludes it unless it's in
   the `--enable-decoder=` list. `scripts/ffmpeg/build.sh` appends `,libdav1d`
   to that list automatically when the library is in
   `FFMPEG_EXTERNAL_LIBRARIES` (the `FIREDOWN_AV1_SW_DECODER` conditional), so
   the flag alone is enough — but don't remove that conditional thinking the
   list already covers AV1 via the `av1` entry (that's the stub).

Once built, no app-side change is needed: `avcodec_find_decoder(AV_CODEC_ID_AV1)`
returns `libdav1d` automatically (it registers at a higher priority than the
stub). Ship via the usual `.so` rebuild + firedown's `scripts/sync-ffmpeg.sh`.
The app side also mitigates independently: the youtube extension now prefers
H264 over AV1 at equal heights, so AV1 only appears for >1080p picks — but
already-downloaded AV1 files keep failing until this rebuild lands.

## Two different "walks to EOF" — don't conflate them

1. **read_header walk (seekability):** a seekable-but-unknown-size segment
   stream defeats mov's `read_header` early-out → mov walks moof/mdat to EOF
   *during `avformat_open_input`*. Fixed in `replacements/libavformat/http.c`
   (`is_streamed`). Independent of the key.
2. **find_stream_info walk (decoy key):** a wrong AES key → garbage → mov skips
   a phantom box to EOF *during `find_stream_info`*. Fixed by the `0004` key
   cache. `is_streamed` does **not** affect this one.

## Shipping the output — GitHub Releases, consumed by the app's fetch

`output/` is gitignored and used to live only on the box that ran the build;
the app's `scripts/sync-ffmpeg.sh` copied it over by path, so a second machine
could not build the app. The libraries now ship as a **GitHub Release asset of
this repo**, which the app fetches by a pin (`firedown.ffmpegRelease` in
firedown's `gradle.properties`; `scripts/fetch-prebuilts.sh` there, run from
its `settings.gradle` on every sync). The app repo's `docs/NEW-MACHINE.md` is
the end-to-end checklist.

- `scripts/package-release.sh <tag>` → `dist/firedown-ffmpeg-<tag>-android.tar.gz`
  + `.sha256`: `lib/<abi>/*.so` for every ABI in `output/lib`, `include/` taken
  from arm64-v8a (the canonical copy, the same convention `sync-ffmpeg.sh`
  always used — the app's CMake has one include dir), `version.txt`. It
  refuses an ABI missing one of the six libraries the app's CMake imports, and
  a tag whose version half is not `SOURCE_VALUE`. The tar is reproducible
  (fixed owner/mtime/order) so a re-run after a failed upload has the same
  sha256.
- `scripts/publish-release.sh <tag>` → clean-tree check (the tag must name the
  exact source that produced `output/`), annotated tag at HEAD pushed,
  package, `gh release create` with both files, and it prints the pin line.
- **Tag format `v<ffmpeg-version>-<n>`**, e.g. `v9.0.2-1`, `-2` for a rebuild
  on the same FFmpeg (a patch change, a new `-dav1d` build). Bumping FFmpeg
  (`SOURCE_VALUE`) starts a new series. A tag is never re-used or re-uploaded.
- `scripts/sync-ffmpeg.sh` in the app still exists for the dev loop (test a
  local build before publishing); the app's fetch leaves such a copy alone.

## After changing a patch / bumping FFmpeg

- Regenerate against the new vanilla source: `scripts/generate-hls-patch.sh
  <ffmpeg-src>`, `scripts/generate-keycache-patch.sh <ffmpeg-src>`,
  `scripts/generate-segfail-patch.sh <ffmpeg-src>` and
  `scripts/generate-xmlcleanup-patch.sh <ffmpeg-src>`.
- Confirm `apply-firedown-patches.sh <ffmpeg-src>` applies cleanly and is
  idempotent (run twice).
- Run `sh scripts/dashxml-harness/run.sh` (it reads the FFmpeg version from
  `scripts/parse-arguments.sh`): Step 3e's guard catches a new libxml2 call in
  `dashdec.c`, the harness a changed one.
- Rebuild the `.so`s, then `scripts/publish-release.sh v<ffmpeg>-<n>` and bump
  `firedown.ffmpegRelease` in the app's `gradle.properties` (or, for a local
  test first, the app repo's `scripts/sync-ffmpeg.sh`).
- Don't push to `master`/default without being asked; develop on a branch.
