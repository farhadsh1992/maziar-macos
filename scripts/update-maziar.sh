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

# In-app updates know their bundle path. Recovery from an older app also checks
# the standard Applications locations, so the existing Dock shortcut keeps working.
is_replaceable() {
  local candidate="$1"
  [[ "$candidate" == /*.app && -d "$candidate" && ! -L "$candidate" && -w "$(dirname "$candidate")" ]] &&
    [[ "$(plutil -extract CFBundleIdentifier raw "$candidate/Contents/Info.plist" 2>/dev/null)" == com.farhadshad.maziar ]]
}

if is_replaceable "${3:-}"; then
  installed="$3"
elif [[ -z "${MAZIAR_UPDATE_DIR:-}" ]]; then
  for candidate in "/Applications/Maziar.app" "$HOME/Applications/Maziar.app"; do
    if is_replaceable "$candidate"; then
      installed="$candidate"
      break
    fi
  done
fi
if [[ -e "$installed" || -L "$installed" ]]; then
  if ! is_replaceable "$installed"; then
    printf 'Cannot safely replace %s. Move that item aside and retry.\n' "$installed" >&2
    exit 1
  fi
fi

# Stage the signed bundle on the destination volume so the final moves are renames.
swap="$(mktemp -d "$(dirname "$installed")/.maziar-swap.XXXXXXXX")"
previous="$swap/Previous.app"
replacement="$swap/Maziar.app"
cleanup() {
  rm -rf "$stage"
  if [[ -e "$previous" && ! -e "$installed" ]]; then
    if ! mv "$previous" "$installed"; then
      printf 'The previous app is preserved at %s\n' "$previous" >&2
      return
    fi
  fi
  rm -rf "$swap"
}
trap cleanup EXIT
ditto "$app" "$replacement"
codesign --verify --deep --strict "$replacement"
if [[ -e "$installed" ]]; then mv "$installed" "$previous"; fi
mv "$replacement" "$installed"

version="$(plutil -extract CFBundleShortVersionString raw "$installed/Contents/Info.plist")"
printf 'Installed Maziar %s at %s\n' "$version" "$installed"
if [[ "${2:-}" == "--open" ]]; then open -n "$installed"; fi
printf '%s\n' "$installed"
