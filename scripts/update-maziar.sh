#!/bin/bash
# Build the upstream revision separately, preserving the user's tracked and untracked source files.
set -euo pipefail

checkout="${1:-}"
destination="${MAZIAR_UPDATE_DIR:-$HOME/Library/Application Support/Maziar/Updates}"
mkdir -p "$destination"
stage="$(mktemp -d "$destination/.build.XXXXXXXX")"
trap 'rm -rf "$stage"' EXIT
mkdir "$stage/source"

if [[ -n "$checkout" ]]; then
  git -C "$checkout" fetch --quiet origin main
  commit="$(git -C "$checkout" rev-parse FETCH_HEAD)"
  git -C "$checkout" archive "$commit" | tar -x -C "$stage/source"
else
  git clone --quiet --depth 1 --branch main https://github.com/farhadsh1992/maziar-macos.git "$stage/repository"
  commit="$(git -C "$stage/repository" rev-parse HEAD)"
  git -C "$stage/repository" archive "$commit" | tar -x -C "$stage/source"
fi

MAZIAR_BUILD_COMMIT="$commit" MAZIAR_BUILD_CHECKOUT="$checkout" /bin/bash "$stage/source/build_app.sh" release
app="$stage/source/dist/Maziar.app"
codesign --verify --deep --strict "$app"
installed="$destination/Maziar.app"
previous="$stage/Previous.app"
if [[ -e "$installed" ]]; then mv "$installed" "$previous"; fi
if ! mv "$app" "$installed"; then
  if [[ -e "$previous" ]]; then mv "$previous" "$installed"; fi
  exit 1
fi

if [[ "${2:-}" == "--open" ]]; then open "$installed"; fi
printf '%s\n' "$installed"
