#!/usr/bin/env bash
#
# Compile ChromiumStack.exe, the Windows double-click launcher.
#
#   tools/build-exe.sh
#
# The compiled binary is committed, exactly like the macOS bundle's launcher, so
# nobody has to build anything on Windows - the point of the .exe is that it can
# be double-clicked straight out of the folder. Rerun this after editing
# tools/launcher/launcher-win.c or launcher-win.rc; the icon itself comes from a
# separate step: tools/make-icons.sh.
#
# Cross-compiled with mingw-w64, so it builds from macOS or Linux:
#   macOS: brew install mingw-w64
#   Linux: sudo apt install mingw-w64
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT/tools/launcher/launcher-win.c"
RESOURCE="$ROOT/tools/launcher/launcher-win.rc"
ICON="$ROOT/assets/icon.ico"
TARGET="$ROOT/ChromiumStack.exe"

CC="${CC_MINGW:-x86_64-w64-mingw32-gcc}"
WINDRES="${WINDRES_MINGW:-x86_64-w64-mingw32-windres}"

for tool in "$CC" "$WINDRES"; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "x  Need $tool. Install mingw-w64:" >&2
    echo "     macOS: brew install mingw-w64" >&2
    echo "     Linux: sudo apt install mingw-w64" >&2
    exit 1
  }
done
[ -f "$ICON" ] || { echo "x  Missing $ICON - run tools/make-icons.sh first." >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --include-dir is what lets the .rc name the icon relative to the project root.
"$WINDRES" --include-dir "$ROOT" -i "$RESOURCE" -o "$WORK/launcher-win.o"

# x86_64 only: 64-bit Windows has been the only version supported since Windows 11,
# and Windows on ARM runs x86_64 binaries under emulation.
# -municode gives wmain its wide argv; -static so the exe needs no mingw runtime
# DLLs alongside it; -s strips it, since a debug build is no use on someone
# else's machine.
"$CC" -O2 -Wall -Wextra -municode -static -s \
  -o "$TARGET" "$SOURCE" "$WORK/launcher-win.o"

echo "  built $TARGET"
printf '  size: %s KB\n' "$(( $(wc -c <"$TARGET") / 1024 ))"
command -v file >/dev/null 2>&1 && file -b "$TARGET" | sed 's/^/  /'
