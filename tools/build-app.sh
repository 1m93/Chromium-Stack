#!/usr/bin/env bash
#
# Compile and sign ChromiumStack.app's launcher.
#
#   tools/build-app.sh
#
# The compiled binary is committed because a .app cannot work without one.
# Rerun this after editing tools/launcher/launcher.c. Icons come from a separate
# step: tools/make-icons.sh.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/ChromiumStack.app"
SOURCE="$ROOT/tools/launcher/launcher.c"
TARGET="$APP/Contents/MacOS/ChromiumStack"

[ "$(uname -s)" = "Darwin" ] || { echo "x  macOS only." >&2; exit 1; }
command -v cc >/dev/null 2>&1 || { echo "x  Need the Xcode command line tools: xcode-select --install" >&2; exit 1; }

mkdir -p "$APP/Contents/MacOS"

# Universal, so the same bundle runs on Apple Silicon and Intel.
cc -arch arm64 -arch x86_64 -O2 -Wall -Wextra -o "$TARGET" "$SOURCE"
chmod +x "$TARGET"

# Ad-hoc signature: no developer account involved, but it gives the bundle a
# stable identity, which is what lets macOS remember a granted permission.
codesign --force --sign - "$APP"

echo "  built $TARGET"
lipo -archs "$TARGET" | sed 's/^/  architectures: /'
codesign -dv "$APP" 2>&1 | sed -n 's/^Identifier=/  identifier: /p'
