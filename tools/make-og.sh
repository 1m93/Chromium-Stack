#!/usr/bin/env bash
#
# Render the social card from assets/og-image.svg.
#
#   tools/make-og.sh
#
# Produces:
#   docs/assets/og-image.png     1200x630, what Slack/Twitter/iMessage unfurl
#
# The generated file is committed, so this only needs rerunning when the SVG
# changes. Rendering needs a Chromium-family browser; if none is installed the
# project's own downloaded builds are used, which is the one dependency this
# repo can always satisfy.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

die() { printf 'x  %s\n' "$*" >&2; exit 1; }

# Same search order as tools/make-icons.sh.
find_browser() {
  if [ -n "${CHROMIUM_STACK_RENDERER:-}" ]; then
    printf '%s\n' "$CHROMIUM_STACK_RENDERER"; return 0
  fi
  local candidate
  for candidate in \
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
    "/Applications/Chromium.app/Contents/MacOS/Chromium" \
    "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge" \
    "$(command -v google-chrome || true)" \
    "$(command -v chromium || true)" \
    "$(command -v chromium-browser || true)"
  do
    [ -n "$candidate" ] && [ -x "$candidate" ] && { printf '%s\n' "$candidate"; return 0; }
  done
  local home="${ENGINESHELF_HOME:-$HOME/.engineshelf}"
  for candidate in "$home"/builds/*/chrome-mac/Chromium.app/Contents/MacOS/Chromium \
                   "$home"/builds/*/chrome-linux/chrome; do
    [ -x "$candidate" ] && { printf '%s\n' "$candidate"; return 0; }
  done
  return 1
}

BROWSER="$(find_browser)" || die "No Chromium-family browser found to render the SVG.
   Install one, point CHROMIUM_STACK_RENDERER at it, or run:
     ./engineshelf.sh install 130"

SRC="$ROOT/assets/og-image.svg"
OUT="$ROOT/docs/assets/og-image.png"
[ -f "$SRC" ] || die "Missing assets/og-image.svg"

cat > "$WORK/page.html" <<HTML
<style>html,body{margin:0;padding:0;background:#0d1017;overflow:hidden}
img{display:block;width:1200px;height:630px}</style>
<img src="file://$SRC">
HTML

echo "  Renderer: $BROWSER"
"$BROWSER" --headless=new --disable-gpu --force-device-scale-factor=1 \
  --hide-scrollbars --screenshot="$OUT" --window-size=1200,630 \
  --virtual-time-budget=4000 "file://$WORK/page.html" >/dev/null 2>&1
[ -s "$OUT" ] || die "Rendering failed - is $BROWSER usable?"

# Social crawlers fetch this on every unfurl. The card is flat colour over one
# soft gradient, so 256 dithered colours are indistinguishable from truecolour
# here and cost a seventh of the bytes.
python3 - "$OUT" <<'PY'
import sys
from PIL import Image
path = sys.argv[1]
image = Image.open(path).convert("RGB")
image.quantize(colors=256, method=Image.MAXCOVERAGE,
               dither=Image.FLOYDSTEINBERG).save(path, optimize=True)
PY
echo "  wrote docs/assets/og-image.png"
