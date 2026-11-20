#!/bin/bash
# Runs Maziar's OpenPrism checkout as a standalone dev server (port 8790 by default), using the same
# projects folder as the app and the debug spell helper (`swift build` first). For testing OpenPrism
# changes in a normal browser without touching the server Maziar itself runs.
set -e
MAZIAR_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HOME/Library/Application Support/Maziar/OpenPrism/repo"
export PORT="${PORT:-8790}"
export OPENPRISM_DATA_DIR="$HOME/Library/Application Support/Maziar/OpenPrism/data"
export MAZIAR_SPELL_HELPER="$MAZIAR_DIR/.build/debug/MaziarSpell"
export PATH="/Library/TeX/texbin:/opt/homebrew/bin:/usr/local/bin:$PATH"
exec node apps/backend/src/index.js
