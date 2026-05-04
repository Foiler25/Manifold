#!/usr/bin/env bash
set -euo pipefail

# release-github.sh — two-phase GitHub release tool.
#
# Phase 1 (default):  ./release-github.sh
#   Reads .release-metadata written by build-dmg.sh, generates
#   .release-notes-draft.md (commit list + diffstat since last tag), and
#   prints instructions to have Claude turn it into RELEASE_NOTES.md.
#
# Phase 2 (publish):  ./release-github.sh --publish
#   Validates RELEASE_NOTES.md is present, tags the build commit, pushes
#   the tag, and creates the GitHub release with the .dmg attached.

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

METADATA_FILE=".release-metadata"
DRAFT_FILE=".release-notes-draft.md"
NOTES_FILE="RELEASE_NOTES.md"

PUBLISH=false
if [[ "${1-}" == "--publish" ]]; then
  PUBLISH=true
elif [[ "${1-}" != "" ]]; then
  echo "usage: $0 [--publish]" >&2
  exit 1
fi

if [[ ! -f "$METADATA_FILE" ]]; then
  echo "error: $METADATA_FILE not found. Run ./build-dmg.sh first." >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$METADATA_FILE"

: "${VERSION:?missing VERSION in $METADATA_FILE}"
: "${DMG:?missing DMG in $METADATA_FILE}"
: "${SHA256:?missing SHA256 in $METADATA_FILE}"
: "${COMMIT:?missing COMMIT in $METADATA_FILE}"
: "${COMMIT_SHORT:?missing COMMIT_SHORT in $METADATA_FILE}"
: "${SPARKLE_SIGNATURE_LINE:?missing SPARKLE_SIGNATURE_LINE in $METADATA_FILE}"
: "${DMG_SIZE:?missing DMG_SIZE in $METADATA_FILE}"

TAG="v${VERSION}"

if ! command -v gh >/dev/null 2>&1; then
  echo "error: gh not found. Install with: brew install gh" >&2
  exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "error: gh is not authenticated. Run: gh auth login" >&2
  exit 1
fi

if [[ ! -f "$DMG" ]]; then
  echo "error: $DMG not found. Run ./build-dmg.sh to rebuild." >&2
  exit 1
fi

if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  echo "error: tag $TAG already exists locally. Delete it before redoing the release." >&2
  exit 1
fi

if git ls-remote --exit-code --tags origin "$TAG" >/dev/null 2>&1; then
  echo "error: tag $TAG already exists on origin." >&2
  exit 1
fi

if [[ "$PUBLISH" == false ]]; then
  # ───── Phase 1: generate draft for Claude ────────────────────────────
  echo "==> Generating release notes draft from commits since ${PREVIOUS_TAG:-<start of history>}"

  if [[ -n "${PREVIOUS_TAG-}" ]]; then
    RANGE="${PREVIOUS_TAG}..${COMMIT}"
    LOG_ARGS=("$RANGE")
    STAT_ARGS=("$RANGE")
  else
    ROOT_COMMIT="$(git rev-list --max-parents=0 "$COMMIT" | head -n1)"
    RANGE="${ROOT_COMMIT}..${COMMIT}"
    LOG_ARGS=("$COMMIT")
    STAT_ARGS=("$RANGE")
  fi

  {
    echo "# Release draft: Manifold $VERSION"
    echo ""
    echo "- Tag to be created: \`$TAG\`"
    echo "- Build commit: \`$COMMIT_SHORT\` ($COMMIT)"
    echo "- DMG asset: \`$DMG\`"
    echo "- SHA-256: \`$SHA256\`"
    echo "- Previous tag: ${PREVIOUS_TAG:-_(none — first release)_}"
    echo ""
    echo "## Commits"
    echo ""
    echo '```'
    git log --format="%h %s%n%n%b%n---" "${LOG_ARGS[@]}"
    echo '```'
    echo ""
    echo "## Files changed"
    echo ""
    echo '```'
    git diff --stat "${STAT_ARGS[@]}"
    echo '```'
    echo ""
    echo "## Instructions for the notes writer"
    echo ""
    echo "- Audience: end users, not developers. Skip pure refactors/tooling unless they affect user experience."
    echo "- Group changes under sections like **New**, **Fixed**, **Changed**."
    echo "- Inspect diffs with \`git show <sha>\` or \`git diff ${RANGE} -- <path>\` before writing user-facing prose — commit messages in this repo are not always user-facing."
    echo "- End the notes with an **Install & update** section covering both the auto-update path for existing users and the unsigned-app install flow for new ones:"
    echo "    > - **Already installed?** Manifold auto-updates — pick *Check for Updates…* in Settings → Updates to grab it now, or wait for the next scheduled check."
    echo "    > - **First time?** Download \`$DMG\`, open it, drag Manifold to Applications. First launch: right-click → Open, then System Settings → Privacy & Security → Open Anyway."
    echo "- Write the final notes to \`$NOTES_FILE\`."
  } > "$DRAFT_FILE"

  cat <<BANNER

==============================================================
  PHASE 1 COMPLETE — draft written to $DRAFT_FILE
==============================================================

Now ask Claude:

  Read .release-notes-draft.md, inspect the commit diffs it
  references, and write user-facing release notes for
  Manifold $VERSION into RELEASE_NOTES.md. Follow the
  "Instructions for the notes writer" section in the draft.

When RELEASE_NOTES.md looks good, publish with:

  ./release-github.sh --publish

BANNER
  exit 0
fi

# ───── Phase 2: publish ───────────────────────────────────────────────
if [[ ! -f "$NOTES_FILE" ]]; then
  echo "error: $NOTES_FILE not found." >&2
  echo "Run ./release-github.sh first (phase 1), then have Claude write $NOTES_FILE." >&2
  exit 1
fi

if [[ ! -s "$NOTES_FILE" ]]; then
  echo "error: $NOTES_FILE is empty." >&2
  exit 1
fi

DIRTY=false
if ! git diff --quiet || ! git diff --cached --quiet; then
  DIRTY=true
fi

echo ""
echo "About to release:"
echo "  version : $VERSION"
echo "  tag     : $TAG  (will point at $COMMIT_SHORT)"
echo "  asset   : $DMG"
echo "  sha-256 : $SHA256"
echo "  notes   : $NOTES_FILE ($(wc -l < "$NOTES_FILE" | tr -d ' ') lines)"
if [[ "$DIRTY" == true ]]; then
  echo "  NOTE    : working tree has uncommitted changes; tag points at $COMMIT_SHORT regardless."
fi
echo ""
read -r -p "Proceed? [y/N] " CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
  echo "aborted."
  exit 1
fi

echo "==> Tagging $TAG at $COMMIT_SHORT"
git tag -a "$TAG" "$COMMIT" -m "Manifold $VERSION"

echo "==> Pushing $TAG to origin"
git push origin "$TAG"

echo "==> Creating GitHub release"
gh release create "$TAG" "$DMG" \
  --title "Manifold $VERSION" \
  --notes-file "$NOTES_FILE"

RELEASE_URL="$(gh release view "$TAG" --json url --jq .url)"
echo ""
echo "Published: $RELEASE_URL"

echo "==> Updating appcast.xml"
APPCAST="appcast.xml"
if [[ ! -f "$APPCAST" ]]; then
  echo "error: $APPCAST not found at repo root. Seed it first." >&2
  exit 1
fi
PUB_DATE="$(date -u +"%a, %d %b %Y %H:%M:%S +0000")"
ASSET_URL="https://github.com/Foiler25/Manifold/releases/download/${TAG}/${DMG}"
RELEASE_NOTES_BODY="$(cat "$NOTES_FILE")"

export APPCAST VERSION PUB_DATE ASSET_URL SPARKLE_SIGNATURE_LINE RELEASE_NOTES_BODY
python3 - <<'PY'
import os, pathlib, fcntl, tempfile
path = pathlib.Path(os.environ["APPCAST"])
item = f"""    <item>
      <title>Manifold {os.environ['VERSION']}</title>
      <pubDate>{os.environ['PUB_DATE']}</pubDate>
      <sparkle:version>{os.environ['VERSION']}</sparkle:version>
      <sparkle:shortVersionString>{os.environ['VERSION']}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <description><![CDATA[
{os.environ['RELEASE_NOTES_BODY']}
      ]]></description>
      <enclosure url="{os.environ['ASSET_URL']}" {os.environ['SPARKLE_SIGNATURE_LINE']} type="application/octet-stream" />
    </item>
"""

# Atomic read-modify-write under flock — protects against (1) concurrent
# release jobs (e.g. main + hotfix branch publishing simultaneously)
# silently overwriting each other's appcast entries, and (2) a crash
# mid-write leaving a half-written file. The os.replace step is atomic
# at the filesystem level on POSIX.
with open(path, "r+") as f:
    fcntl.flock(f, fcntl.LOCK_EX)
    text = f.read()
    new_text = text.replace("</channel>", item + "  </channel>", 1)
    if new_text == text:
        raise SystemExit(
            "error: </channel> marker not found in appcast.xml; refusing to write")
    tmp = tempfile.NamedTemporaryFile(
        "w", dir=str(path.parent), prefix=".appcast.", suffix=".tmp", delete=False)
    try:
        tmp.write(new_text)
        tmp.flush()
        os.fsync(tmp.fileno())
        tmp.close()
        os.replace(tmp.name, path)
    except Exception:
        try: os.unlink(tmp.name)
        except FileNotFoundError: pass
        raise
PY

git add "$APPCAST"
git commit -m "Publish appcast entry for ${TAG}"
git push origin HEAD

echo "==> Cleaning up handoff files"
rm -f "$METADATA_FILE" "$DRAFT_FILE"

echo ""
read -r -p "Delete $NOTES_FILE too? [y/N] " DELETE_NOTES
if [[ "$DELETE_NOTES" == "y" || "$DELETE_NOTES" == "Y" ]]; then
  rm -f "$NOTES_FILE"
  echo "Deleted: $NOTES_FILE"
else
  echo "Kept: $NOTES_FILE"
fi
