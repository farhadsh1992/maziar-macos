#!/bin/bash
# Publishes Maziar and Numenor together:
#   1. pushes this maziar repo (commit your changes first), then
#   2. mirrors its Numenor/ folder into github.com/farhadsh1992/numenor and pushes that too, with a commit
#      message taken from the maziar commits that changed Numenor since the last sync.
# Numenor/ in this repo is the one source of truth — never edit the numenor repo directly, or the next
# sync overwrites those edits.
set -euo pipefail
cd "$(dirname "$0")/.."
MAZIAR_DIR="$(pwd)"
NUMENOR_REMOTE="${NUMENOR_REMOTE:-https://github.com/farhadsh1992/numenor.git}"

if [ -n "$(git status --porcelain)" ]; then
  echo "maziar has uncommitted changes — commit them first, then run this again." >&2
  exit 1
fi

echo "→ Pushing maziar…"
git push origin HEAD

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
echo "→ Syncing Numenor…"
git clone -q "$NUMENOR_REMOTE" "$WORK/numenor"
rsync -a --delete --exclude .git --exclude node_modules --exclude 'apps/frontend/dist' --exclude data --exclude .DS_Store \
  "$MAZIAR_DIR/Numenor/" "$WORK/numenor/"

cd "$WORK/numenor"
git add -A
if git diff --cached --quiet; then
  echo "Numenor is already up to date on GitHub."
  exit 0
fi

# Commit message: the maziar commits that touched Numenor/ since the maziar commit last synced.
LAST_SYNC="$(git log -1 --format=%B 2>/dev/null | sed -n 's/^Synced from maziar@\([0-9a-f]*\).*/\1/p' | head -1 || true)"
if [ -n "$LAST_SYNC" ] && git -C "$MAZIAR_DIR" cat-file -e "$LAST_SYNC" 2>/dev/null; then
  SUBJECTS="$(git -C "$MAZIAR_DIR" log --format='- %s' "$LAST_SYNC..HEAD" -- Numenor)"
else
  SUBJECTS="$(git -C "$MAZIAR_DIR" log -1 --format='- %s' -- Numenor)"
fi
FIRST="$(printf '%s\n' "$SUBJECTS" | head -1 | sed 's/^- //')"
HEAD_SHA="$(git -C "$MAZIAR_DIR" rev-parse --short HEAD)"
git commit -q -m "${FIRST:-Update Numenor}" -m "$SUBJECTS" -m "Synced from maziar@$HEAD_SHA"
git push -q origin HEAD:main
echo "Numenor pushed: $(git log -1 --format='%h %s')"
