#!/bin/bash
# SessionStart hook for gstack on Claude Code on the web.
# Goal: make `bun run dev <cmd>` work in fresh remote sessions.
#
# Steps:
#   1. bun install (if node_modules missing).
#   2. Verify Playwright Chromium can launch.
#   3. If launch fails, try `bunx playwright install chromium`.
#   4. If download is blocked (sandbox firewall), shim the playwright-expected
#      paths to whatever chromium-NNNN already lives in PLAYWRIGHT_BROWSERS_PATH.
set -euo pipefail

# Skip on local dev machines — `./setup` already handles install there.
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

cd "${CLAUDE_PROJECT_DIR:-$(pwd)}"

log() { echo "[gstack-session-start] $*"; }

# 1. Bun deps.
if [ ! -d node_modules ]; then
  log "Installing bun dependencies..."
  bun install
fi

verify_chromium() {
  bun --eval 'import { chromium } from "playwright"; const b = await chromium.launch({ chromiumSandbox: false }); await b.close();' >/dev/null 2>&1
}

# 2. Quick path: chromium already launches.
if verify_chromium; then
  log "Playwright Chromium ready."
  exit 0
fi

# 3. Try the canonical Playwright install. May 403 in sandboxed networks.
log "Chromium not launchable; trying 'bunx playwright install chromium'..."
if bunx playwright install chromium >/dev/null 2>&1; then
  if verify_chromium; then
    log "Chromium installed via Playwright. Ready."
    exit 0
  fi
fi

# 4. Fallback shim: use whatever chromium-NNNN is pre-baked in PLAYWRIGHT_BROWSERS_PATH.
PWBASE="${PLAYWRIGHT_BROWSERS_PATH:-$HOME/.cache/ms-playwright}"
if [ ! -d "$PWBASE" ]; then
  log "WARN: PLAYWRIGHT_BROWSERS_PATH ($PWBASE) not found. /browse will not work this session."
  exit 0
fi

WANT=$(bun --eval '
  const b = require("./node_modules/playwright-core/browsers.json");
  const c = b.browsers.find(x => x.name === "chromium");
  if (c) console.log(c.revision);
' 2>/dev/null || true)
if [ -z "$WANT" ]; then
  log "WARN: could not read playwright-core chromium revision. /browse will not work this session."
  exit 0
fi

# Pick any chromium-NNNN dir that already exists (excluding the wanted revision).
HAVE_DIR=$(find "$PWBASE" -maxdepth 1 -type d -name 'chromium-[0-9]*' \
  ! -name "chromium-${WANT}" -print -quit 2>/dev/null || true)
if [ -z "$HAVE_DIR" ]; then
  log "WARN: chromium-${WANT} not in $PWBASE and no fallback chromium-* found. /browse will not work this session."
  exit 0
fi
HAVE=$(basename "$HAVE_DIR" | sed 's/^chromium-//')

log "Shimming chromium-${WANT} -> chromium-${HAVE}."

# Full chromium dir (only used in headed mode; symlink the whole tree).
if [ ! -e "$PWBASE/chromium-${WANT}" ]; then
  ln -sfn "$PWBASE/chromium-${HAVE}" "$PWBASE/chromium-${WANT}"
fi

# Headless shell: layout + binary name changed between revisions.
#   New (1208+): chromium_headless_shell-NNNN/chrome-headless-shell-linux64/chrome-headless-shell
#   Old (1194):  chromium_headless_shell-NNNN/chrome-linux/headless_shell
HS_SRC_DIR="$PWBASE/chromium_headless_shell-${HAVE}/chrome-linux"
HS_DST_DIR="$PWBASE/chromium_headless_shell-${WANT}/chrome-headless-shell-linux64"

if [ -d "$HS_SRC_DIR" ] && [ ! -e "$HS_DST_DIR/chrome-headless-shell" ]; then
  mkdir -p "$HS_DST_DIR"
  for f in "$HS_SRC_DIR"/*; do
    name=$(basename "$f")
    [ -e "$HS_DST_DIR/$name" ] || ln -sfn "$f" "$HS_DST_DIR/$name"
  done
  # Rename binary: 1208 wants chrome-headless-shell, 1194 has headless_shell.
  if [ -x "$HS_SRC_DIR/headless_shell" ] && [ ! -e "$HS_DST_DIR/chrome-headless-shell" ]; then
    ln -sfn "$HS_SRC_DIR/headless_shell" "$HS_DST_DIR/chrome-headless-shell"
  fi
fi

if verify_chromium; then
  log "Chromium shim works. /browse ready."
else
  log "WARN: shim attempted but Chromium still won't launch. /browse may not work this session."
fi
