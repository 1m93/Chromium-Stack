#!/usr/bin/env bash
#
# Build every raster icon from assets/icon.svg and assets/icon-small.svg.
#
#   tools/make-icons.sh
#
# Produces:
#   EngineShelf.app/Contents/Resources/AppIcon.icns   macOS bundle icon
#   assets/icon.ico                                   Windows shortcut icon
#   assets/icon-512.png                               Linux desktop entry icon
#
# The generated files are committed, so this only needs rerunning when the SVGs
# change. Rendering needs a Chromium-family browser; if none is installed the
# project's own downloaded builds are used, which is the one dependency this
# repo can always satisfy.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

die() { printf 'x  %s\n' "$*" >&2; exit 1; }

# ---------- find something that can render an SVG ----------
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
  # Fall back to a Chromium this project already downloaded.
  local home="${ENGINESHELF_HOME:-$HOME/.engineshelf}"
  for candidate in "$home"/builds/*/chrome-mac/Chromium.app/Contents/MacOS/Chromium \
                   "$home"/builds/*/chrome-linux/chrome; do
    [ -x "$candidate" ] && { printf '%s\n' "$candidate"; return 0; }
  done
  return 1
}

BROWSER="$(find_browser)" || die "No Chromium-family browser found to render the SVGs.
   Install one, point CHROMIUM_STACK_RENDERER at it, or run:
     ./engineshelf.sh install 130"

# ---------- render one PNG at an exact pixel size ----------
render() {
  local svg="$1" size="$2" out="$3"
  cat > "$WORK/page.html" <<HTML
<style>html,body{margin:0;padding:0;background:transparent}
img{display:block;width:${size}px;height:${size}px}</style>
<img src="file://$svg">
HTML
  "$BROWSER" --headless=new --disable-gpu --force-device-scale-factor=1 \
    --default-background-color=00000000 --hide-scrollbars \
    --screenshot="$out" --window-size="$size,$size" \
    --virtual-time-budget=3000 "file://$WORK/page.html" >/dev/null 2>&1
  [ -s "$out" ] || die "Rendering failed at ${size}px - is $BROWSER usable?"
}

MAIN="$ROOT/assets/icon.svg"
SMALL="$ROOT/assets/icon-small.svg"
[ -f "$MAIN" ] && [ -f "$SMALL" ] || die "Missing assets/icon.svg or assets/icon-small.svg"

# Which source each size uses is decided by the size it is *displayed* at, not
# the pixel count: a 32px @2x file is shown at 16pt, so it wants the reduced art.
pick_source() { [ "$1" -le 48 ] && printf '%s\n' "$SMALL" || printf '%s\n' "$MAIN"; }

echo "  Renderer: $BROWSER"

# ---------- macOS .icns ----------
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
emit() {  # display-size  file-pixels  name
  render "$(pick_source "$1")" "$2" "$ICONSET/$3"
}
emit 16   16   icon_16x16.png
emit 16   32   icon_16x16@2x.png
emit 32   32   icon_32x32.png
emit 32   64   icon_32x32@2x.png
emit 128  128  icon_128x128.png
emit 128  256  icon_128x128@2x.png
emit 256  256  icon_256x256.png
emit 256  512  icon_256x256@2x.png
emit 512  512  icon_512x512.png
emit 512  1024 icon_512x512@2x.png

if command -v iconutil >/dev/null 2>&1; then
  mkdir -p "$ROOT/EngineShelf.app/Contents/Resources"
  iconutil -c icns "$ICONSET" -o "$ROOT/EngineShelf.app/Contents/Resources/AppIcon.icns"
  echo "  wrote EngineShelf.app/Contents/Resources/AppIcon.icns"
else
  echo "  ! iconutil not found (macOS only) - skipped AppIcon.icns"
fi

# ---------- Windows .ico ----------
for size in 16 32 48 64 128 256; do
  render "$(pick_source "$size")" "$size" "$WORK/ico-$size.png"
done
python3 - "$WORK" "$ROOT/assets/icon.ico" <<'PY'
import struct, sys, os

# A modern .ico is just a directory of PNGs. Writing it by hand keeps this
# script free of an image library.
work, out = sys.argv[1], sys.argv[2]
sizes = [16, 32, 48, 64, 128, 256]
blobs = [open(os.path.join(work, f"ico-{s}.png"), "rb").read() for s in sizes]

header = struct.pack("<HHH", 0, 1, len(sizes))
offset = len(header) + 16 * len(sizes)
entries, body = b"", b""
for size, blob in zip(sizes, blobs):
    dimension = 0 if size >= 256 else size      # 0 means 256 in this format
    entries += struct.pack("<BBBBHHII", dimension, dimension, 0, 0, 1, 32, len(blob), offset)
    offset += len(blob)
    body += blob
open(out, "wb").write(header + entries + body)
print(f"  wrote {out}")
PY

# ---------- Linux desktop entry ----------
render "$MAIN" 512 "$ROOT/assets/icon-512.png"
echo "  wrote assets/icon-512.png"
echo "  done"
