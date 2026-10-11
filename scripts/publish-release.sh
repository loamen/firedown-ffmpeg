#!/usr/bin/env bash
# scripts/publish-release.sh — tag this tree and publish its build output as a
# GitHub Release, which is how the compiled libraries travel between machines.
#
#   scripts/publish-release.sh <tag>            e.g. scripts/publish-release.sh v9.0.2-1
#   scripts/publish-release.sh <tag> --allow-dirty   (skip the clean-tree check)
#
# Steps: refuse a dirty tree (the tag must name EXACTLY the source that built
# output/) → create + push an annotated tag at HEAD → package output/
# (scripts/package-release.sh) → `gh release create` with the tarball + its
# .sha256 → print the pin line for the app's gradle.properties.
#
# Needs the GitHub CLI, logged in (`gh auth login`); the repo is private, so the
# app-side fetch needs the same login. Run this on the machine that built the
# libraries; afterwards any other machine gets them with a plain clone + gradle
# sync of the app (see firedown/docs/NEW-MACHINE.md).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAG="${1:-}"
ALLOW_DIRTY=0
[[ "${2:-}" == "--allow-dirty" ]] && ALLOW_DIRTY=1

if [[ -z "$TAG" ]]; then
  echo "usage: $0 <tag> [--allow-dirty]    (tag format v<ffmpeg-version>-<n>)" >&2
  exit 2
fi
command -v gh >/dev/null || { echo "ERROR: gh (GitHub CLI) not installed" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "ERROR: gh is not logged in — run: gh auth login" >&2; exit 1; }

cd "$ROOT"
# Name the GitHub repo EXPLICITLY, from origin: gh otherwise infers it from the
# remotes and refuses when there is more than one ("No default remote
# repository has been set") — which is exactly the case in a fork carrying an
# `upstream` remote. The release must land on OUR repo, never upstream's.
GH_REPO="$(git -C "$ROOT" remote get-url origin | sed -E 's#^.*github\.com[:/]##; s#\.git$##')"
if [[ ! "$GH_REPO" =~ ^[^/]+/[^/]+$ ]]; then
  echo "ERROR: cannot derive owner/repo from origin ($(git -C "$ROOT" remote get-url origin))" >&2
  exit 1
fi
if [[ $ALLOW_DIRTY -eq 0 ]] && [[ -n "$(git status --porcelain)" ]]; then
  echo "ERROR: working tree is dirty — commit first so the tag names the exact source" >&2
  echo "       that produced output/ (or pass --allow-dirty if you know better)." >&2
  git status --short >&2
  exit 1
fi
# A tag that already exists is fine ONLY when it points at HEAD — that is a
# re-run after the upload step failed (the tag is pushed before the release is
# created, so a gh error strands exactly this state). A tag on another commit
# would name the wrong source for this output/.
TAG_EXISTS=0
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  if [[ "$(git rev-parse "$TAG^{commit}")" != "$(git rev-parse HEAD)" ]]; then
    echo "ERROR: tag $TAG already exists and is not at HEAD — pick the next -<n>" >&2
    exit 1
  fi
  TAG_EXISTS=1
  echo "tag $TAG already at HEAD — reusing it"
fi
if gh release view -R "$GH_REPO" "$TAG" >/dev/null 2>&1; then
  echo "ERROR: a release $TAG already exists on GitHub — pick the next -<n>" >&2
  exit 1
fi

bash "$ROOT/scripts/package-release.sh" "$TAG"
ASSET="$ROOT/dist/firedown-ffmpeg-$TAG-android.tar.gz"

if [[ $TAG_EXISTS -eq 0 ]]; then
  git tag -a "$TAG" -m "firedown-ffmpeg $TAG"
fi
git push origin "refs/tags/$TAG"

NOTES="Prebuilt FFmpeg for the Firedown app.

$(tar -xzOf "$ASSET" version.txt)

Consumed by firedown/scripts/fetch-prebuilts.sh — pin in firedown/gradle.properties:
    firedown.ffmpegRelease=$TAG"

gh release create -R "$GH_REPO" "$TAG" "$ASSET" "$ASSET.sha256" \
  --title "firedown-ffmpeg $TAG" --notes "$NOTES"

echo
echo "[ok] published. Now pin it in the app:"
echo "       firedown/gradle.properties:  firedown.ffmpegRelease=$TAG"
echo "     then commit that line; every clone fetches this build on its next gradle sync."
