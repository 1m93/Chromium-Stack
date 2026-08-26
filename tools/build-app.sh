#!/usr/bin/env bash
#
# Compile and sign EngineShelf.app's launcher.
#
#   tools/build-app.sh
#
# The compiled binary is committed because a .app cannot work without one.
# Rerun this after editing tools/launcher/launcher.c. Icons come from a separate
# step: tools/make-icons.sh.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/EngineShelf.app"
SOURCE="$ROOT/tools/launcher/launcher.c"
TARGET="$APP/Contents/MacOS/EngineShelf"

[ "$(uname -s)" = "Darwin" ] || { echo "x  macOS only." >&2; exit 1; }
command -v cc >/dev/null 2>&1 || { echo "x  Need the Xcode command line tools: xcode-select --install" >&2; exit 1; }

mkdir -p "$APP/Contents/MacOS"

# Universal, so the same bundle runs on Apple Silicon and Intel - but each slice
# is compiled on its own so it can carry its own floor. Given no -mmacosx-version-min,
# clang stamps the *host* OS version into LC_BUILD_VERSION, and dyld refuses to load a
# binary whose minos is newer than the running system: built on macOS 26, the app would
# refuse to start on macOS 15 whatever LSMinimumSystemVersion claims. 10.13 matches the
# Info.plist floor; arm64 macOS only exists from 11.0, so that slice cannot go lower.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cc -arch x86_64 -mmacosx-version-min=10.13 -O2 -Wall -Wextra -o "$WORK/x86_64" "$SOURCE"
cc -arch arm64  -mmacosx-version-min=11.0  -O2 -Wall -Wextra -o "$WORK/arm64"  "$SOURCE"
lipo -create -output "$TARGET" "$WORK/x86_64" "$WORK/arm64"
chmod +x "$TARGET"

# Ad-hoc signature: no developer account involved, but it gives the bundle a
# stable identity, which is what lets macOS remember a granted permission.
codesign --force --sign - "$APP"

echo "  built $TARGET"
lipo -archs "$TARGET" | sed 's/^/  architectures: /'
# Guard the whole point of the two-slice build: a stale minos here is invisible on the
# machine that built it and fatal on every older Mac.
# Two load commands to read: a 10.13 target still uses the old LC_VERSION_MIN_MACOSX,
# while the arm64 slice gets LC_BUILD_VERSION.
vtool -show-build "$TARGET" 2>/dev/null | awk '
  /\(architecture/              { arch = $3; sub(/\):$/, "", arch) }
  /cmd LC_VERSION_MIN_MACOSX/   { key = "version" }
  /cmd LC_BUILD_VERSION/        { key = "minos" }
  key != "" && $1 == key        { print "  runs on " arch ": macOS " $2 " and later"; key = "" }
'
codesign -dv "$APP" 2>&1 | sed -n 's/^Identifier=/  identifier: /p'
