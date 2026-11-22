#!/bin/bash
# Runs Numenor straight from this repo's Numenor/ folder on port 8790 (override with PORT=…), using the
# same projects folder as Maziar and the debug spell helper (run `swift build` first for spelling).
# For trying Numenor changes in a normal browser without touching the server Maziar runs.
set -euo pipefail
MAZIAR_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$MAZIAR_DIR/Numenor"
export PATH="/Library/TeX/texbin:/opt/homebrew/bin:/usr/local/bin:$PATH"
[ -d node_modules ] || npm install --no-audit --no-fund
npm run build
export PORT="${PORT:-8790}"
export NUMENOR_HOST=127.0.0.1
export NUMENOR_DATA_DIR="$HOME/Library/Application Support/Maziar/Numenor/data"
export MAZIAR_SPELL_HELPER="$MAZIAR_DIR/.build/debug/MaziarSpell"
exec node apps/backend/src/index.js
