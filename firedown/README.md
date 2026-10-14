# firedown/

This directory contains everything Firedown adds on top of upstream `ffmpeg-android-maker`. Nothing here exists in `Javernaut/ffmpeg-android-maker` — keeping it isolated means upstream merges won't conflict with our changes.

## Contents

```
firedown/
├── apply-firedown-patches.sh    # Invoked by ffmpeg-android-maker.sh during build.
│                                # Applies replacements + patches to the FFmpeg
│                                # source tree before configure runs.
│
├── replacements/                # Files copied into the FFmpeg source tree
│   └── libavformat/
│       ├── http.c               # OkHttp JNI backend (replaces FFmpeg's HTTP)
│       └── fdxml.c, fdxml.h     # NEW files: the DASH demuxer's XML tree, parsed
│                                # in Java (FFmpegXml) through JNI — replaces
│                                # libxml2 (wired in by Step 3e of the apply script)
│
├── patches/                     # Documentation patches — already applied in this fork.
│   │                            # Kept for reference and re-application against
│   │                            # future upstream merges.
│   │
│   ├── 0001-ffmpeg-android-maker-add-firedown-hook.patch
│   │                            # The 9-line hook added to ffmpeg-android-maker.sh
│   │
│   ├── 0002-hls-c-remove-keepalive-branches.patch
│   │                            # libavformat/hls.c — generated against your
│   │                            # specific FFmpeg version, NOT applied in this
│   │                            # repo (applied at build time by apply-firedown-patches.sh)
│   │
│   ├── 0003-build-sh-firedown-configure-flags.patch
│   │                            # Firedown's configure flags added to scripts/ffmpeg/build.sh
│   │
│   ├── 0004-hls-c-single-use-key-cache.patch
│   │                            # libavformat/hls.c — process-global cache of
│   │                            # single-use AES keys (build-time, like 0002)
│   │
│   ├── 0005-hls-c-bail-on-consecutive-segment-failures.patch
│   │                            # libavformat/hls.c — fail fast when every
│   │                            # segment fails to open (build-time)
│   │
│   └── 0006-dashdec-c-drop-xmlCleanupParser.patch
│                                # libavformat/dashdec.c — drop the per-parse
│                                # xmlCleanupParser() that destroyed libxml2's
│                                # global mutexes under concurrent use (build-time;
│                                # moot since fdxml, kept as harmless)
│
└── scripts/
    ├── install-firedown-hook.sh # One-time: re-applies the modification to
    │                            # ffmpeg-android-maker.sh against a fresh
    │                            # upstream pull. Idempotent.
    │
    ├── generate-hls-patch.sh    # Generates patches/0002 from a vanilla
    │                            # FFmpeg source tree. Run when bumping
    │                            # FFmpeg version.
    ├── generate-keycache-patch.sh   # Generates patches/0004, same contract.
    ├── generate-segfail-patch.sh    # Generates patches/0005, same contract.
    └── generate-xmlcleanup-patch.sh # Generates patches/0006, same contract.
```

## Two kinds of changes

This fork has **two categories** of modifications, handled differently:

### Category A: Changes to the `ffmpeg-android-maker` repo itself (committed in this fork's tree)

These are modifications to files that live in this repo's source — not in FFmpeg's source. Committed directly in their modified form:

| File | What changed | Documented at |
|---|---|---|
| `ffmpeg-android-maker.sh` | Hook to invoke `apply-firedown-patches.sh` | `firedown/patches/0001-...patch` |
| `scripts/ffmpeg/build.sh` | Firedown configure flags (`--enable-jni`, protocol/muxer trim, etc.) | `firedown/patches/0003-...patch` |

The patches in `firedown/patches/` for these are documentation only — they're already applied in this fork. They exist so:
- A reader can see at a glance what was changed and why
- If upstream rewrites these files in a future merge, the patches can be re-applied (or `install-firedown-hook.sh` can do it for `ffmpeg-android-maker.sh`)

### Category B: Changes to FFmpeg source (applied at build time)

These modify files inside the FFmpeg source tree, which is downloaded fresh each build. They cannot be pre-committed because the FFmpeg source isn't part of this repo:

| FFmpeg file | What changes | Mechanism |
|---|---|---|
| `libavformat/http.c` | Full replacement with OkHttp JNI backend | `firedown/replacements/libavformat/http.c` is copied over at build time |
| `libavformat/hls.c` | Remove `open_url_keepalive` code paths | `firedown/patches/0002-...patch` is applied at build time |
| `libavformat/hls.c` | Single-use AES-key cache; bail on an all-failing segment stream | `firedown/patches/0004-...patch` and `0005-...patch`, applied at build time |
| `libavformat/dashdec.c` | Drop the per-parse `xmlCleanupParser()` (destroys libxml2's global mutexes; crashed concurrent DASH probes) | `firedown/patches/0006-...patch` is applied at build time |
| `libavformat/dashdec.c` + `fdxml.{c,h}` | Parse DASH manifests through the app's `FFmpegXml` (JNI) instead of libxml2: two lines in `dashdec.c` (include + parse call), the shim copied in, and a build failure if `dashdec.c` uses a libxml2 name the shim lacks | Step 3e of `apply-firedown-patches.sh`; verified by `scripts/dashxml-harness/run.sh` |
| `libavformat/Makefile` | Build `fdxml.o` with the dash demuxer | Step 3e |
| `configure` | Add `http_protocol_deps="jni"` and `https_protocol_deps="jni"` | `apply-firedown-patches.sh` uses `awk` to insert the declarations |
| `configure` | `dash_demuxer_deps="libxml2"` → `"jni"` (build without `-xml2`) | Step 3e |

`apply-firedown-patches.sh` is invoked by the modified `ffmpeg-android-maker.sh` after FFmpeg source is downloaded but before any per-ABI build runs. Every step is idempotent.

## Initial setup

If you've just forked this repo, the only thing you need to do before the first build is **generate the real hls.c patch** against your target FFmpeg version:

```bash
# Outside the repo
wget https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz
tar -xf ffmpeg-9.0.2.tar.xz

# Inside the repo
./firedown/scripts/generate-hls-patch.sh /path/to/ffmpeg-9.0.2
```

The placeholder file at `firedown/patches/0002-hls-c-remove-keepalive-branches.patch` will be overwritten with a real, applying patch. Commit it.

After that, normal builds via `./ffmpeg-android-maker.sh` will pick up Firedown's modifications automatically.

## When upstream changes

If `Javernaut/ffmpeg-android-maker` releases a new version and you want to merge:

1. Pull upstream into your fork (`git pull upstream master` after adding the upstream remote)
2. Resolve any conflicts in `ffmpeg-android-maker.sh` and `scripts/ffmpeg/build.sh`. If overwriting them is easier:
   - Re-run `./firedown/scripts/install-firedown-hook.sh` to put the main script hook back
   - Manually re-apply `0003-build-sh-firedown-configure-flags.patch` to `scripts/ffmpeg/build.sh`
3. If FFmpeg version was bumped, regenerate the hls.c patch via `generate-hls-patch.sh`
4. Test build end-to-end before tagging a release

## When the hls.c regex stops matching

If `generate-hls-patch.sh` warns "block not found", upstream FFmpeg has rewritten the affected regions of `libavformat/hls.c`. Open the script, locate the regex patterns (clearly commented), and update them to match the new code. The patch generator is forgiving of context drift — it does the work of producing a real diff once it can find the blocks.
