#!/usr/bin/env bash
#
# Build clean, self-contained, obfuscated ChromiumStack releases into dist/.
#
#   tools/release.sh                 # build every artifact this machine can
#   tools/release.sh --no-obfuscate  # readable source (for debugging a release)
#   tools/release.sh --ps-heavy      # heavy-obfuscate PowerShell too (see note)
#   tools/release.sh --version 2.1   # stamp a version into the artifact names
#
# Produces, in dist/:
#   ChromiumStack-<ver>-macOS.zip      a single self-contained .app, zipped
#   ChromiumStack-<ver>-Windows.zip    ChromiumStack.exe + hidden app/ scripts
#   ChromiumStack-<ver>-Linux.tar.gz   ./ChromiumStack launcher + scripts
#   SHA256SUMS.txt                     checksums for every artifact above
#
# Obfuscation is deterrence, not protection - see tools/obfuscate.sh. bash and
# Python are wrapped and TESTED on this machine. PowerShell defaults to a safe
# comment-strip; --ps-heavy switches to an encoded wrapper that is written but
# UNTESTED here (no pwsh), so verify it on Windows before shipping.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$ROOT/dist"
# shellcheck source=tools/obfuscate.sh
source "$ROOT/tools/obfuscate.sh"

OBFUSCATE=1
PS_HEAVY=0
VERSION=""
for arg in "$@"; do
  case "$arg" in
    --no-obfuscate) OBFUSCATE=0 ;;
    --ps-heavy)     PS_HEAVY=1 ;;
    --version)      : ;;                 # handled below
    *)              if [ "${PREV:-}" = "--version" ]; then VERSION="$arg"; fi ;;
  esac
  PREV="$arg"
done
if [ -z "$VERSION" ]; then
  # Prefer the latest git tag (strip a leading v) so the artifact version matches
  # the release being cut; fall back to Info.plist, then "dev".
  VERSION="$(git -C "$ROOT" describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')"
  if [ -z "$VERSION" ]; then
    VERSION="$(sed -n 's/.*CFBundleShortVersionString<\/key>[^<]*<string>\([^<]*\)<.*/\1/p' \
               "$ROOT/ChromiumStack.app/Contents/Info.plist" 2>/dev/null | head -1)"
  fi
  VERSION="${VERSION:-dev}"
fi

say() { printf '  %s\n' "$*"; }
step() { printf '\n== %s ==\n' "$*"; }

# --------------------------------------------------------------------------- #
# stage the runtime tree for one flavour and obfuscate it in place
#   $1 dest dir   $2 flavour: posix | windows
# --------------------------------------------------------------------------- #
stage_tree() {
  local dest="$1" flavour="$2"
  mkdir -p "$dest/lib" "$dest/gui" "$dest/docker"

  # Shared, never obfuscated: data and container-internal plumbing.
  cp "$ROOT/catalog.tsv"            "$dest/"
  cp "$ROOT/gui/icon.svg"           "$dest/gui/"
  cp "$ROOT/docker/Dockerfile"      "$dest/docker/"
  cp "$ROOT/docker/entrypoint.sh"   "$dest/docker/"   # runs inside the container

  # Served assets: minified (comments + indentation stripped).
  cp "$ROOT/gui/index.html" "$dest/gui/"
  cp "$ROOT/gui/app.js"     "$dest/gui/"
  cp "$ROOT/gui/styles.css" "$dest/gui/"

  if [ "$flavour" = "posix" ]; then
    cp "$ROOT/chromium-stack.sh"        "$dest/"
    cp "$ROOT/chromium-stack-docker.sh" "$dest/"
    cp "$ROOT/gui.sh"                   "$dest/"
    cp "$ROOT/lib/preflight.sh"         "$dest/lib/"
    cp "$ROOT/gui/server.py"            "$dest/gui/"
    chmod +x "$dest"/*.sh
  else
    cp "$ROOT/chromium-stack.ps1"        "$dest/"
    cp "$ROOT/chromium-stack-docker.ps1" "$dest/"
    cp "$ROOT/gui.ps1"                   "$dest/"
    cp "$ROOT/lib/preflight.ps1"         "$dest/lib/"
    cp "$ROOT/gui/server.ps1"            "$dest/gui/"
  fi

  [ "$OBFUSCATE" = "1" ] || { say "obfuscation skipped"; return; }

  min_web "$dest/gui/index.html"
  min_web "$dest/gui/app.js"
  min_web "$dest/gui/styles.css"

  if [ "$flavour" = "posix" ]; then
    obf_bash "$dest/chromium-stack.sh"
    obf_bash "$dest/chromium-stack-docker.sh"
    obf_bash "$dest/gui.sh"
    obf_bash "$dest/lib/preflight.sh"
    obf_py   "$dest/gui/server.py"
    say "obfuscated: 4 bash + 1 python + 3 web assets"
  else
    local fn=obf_ps1_light label="light (comment strip)"
    [ "$PS_HEAVY" = "1" ] && { fn=obf_ps1_heavy; label="heavy (encoded, UNTESTED here)"; }
    "$fn" "$dest/chromium-stack.ps1"
    "$fn" "$dest/chromium-stack-docker.ps1"
    "$fn" "$dest/gui.ps1"
    "$fn" "$dest/lib/preflight.ps1"
    "$fn" "$dest/gui/server.ps1"
    say "obfuscated: 5 powershell [$label] + 3 web assets"
  fi
}

# --------------------------------------------------------------------------- #
step "ChromiumStack release  (version $VERSION, obfuscate=$OBFUSCATE ps-heavy=$PS_HEAVY)"
rm -rf "$DIST"; mkdir -p "$DIST"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# ---- macOS: self-contained .app -> .zip ----------------------------------- #
build_macos() {
  [ "$(uname -s)" = "Darwin" ] || { say "skip macOS (not on Darwin)"; return; }
  step "macOS  (.app -> .zip)"
  local app="$WORK/ChromiumStack.app"
  # Copy the built bundle skeleton (launcher + Info.plist + icon), then fill
  # Contents/Resources with the runtime tree so the .app stands alone.
  cp -R "$ROOT/ChromiumStack.app" "$app"
  rm -rf "$app/Contents/_CodeSignature"           # stale, we re-sign below
  stage_tree "$app/Contents/Resources" posix

  codesign --force --deep --sign - "$app" 2>/dev/null
  say "signed $(codesign -dv "$app" 2>&1 | sed -n 's/^Identifier=//p')"

  ( cd "$WORK" && zip -qr -X "$DIST/ChromiumStack-$VERSION-macOS.zip" ChromiumStack.app )
  say "wrote ChromiumStack-$VERSION-macOS.zip"
}

# ---- Windows: exe + hidden app/ scripts ----------------------------------- #
build_windows() {
  step "Windows  (.zip)"
  [ -f "$ROOT/ChromiumStack.exe" ] || { say "skip Windows (ChromiumStack.exe missing)"; return; }
  local top="$WORK/win/ChromiumStack"
  mkdir -p "$top/app"
  cp "$ROOT/ChromiumStack.exe" "$top/"
  stage_tree "$top/app" windows

  # The .exe runs gui.ps1 next to itself; this shim hands over to the real,
  # obfuscated one under app/, keeping the top folder clean.
  cat > "$top/gui.ps1" <<'SHIM'
# ChromiumStack launcher shim - forwards to the packaged scripts under .\app\.
[CmdletBinding()]
param([int]$Port = 7411, [switch]$NoOpen)
$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'app\gui.ps1') -Port $Port -NoOpen:$NoOpen
SHIM
  # A readable alternative for anyone who would rather run a script than a binary.
  cat > "$top/ChromiumStack.bat" <<'BAT'
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0app\gui.ps1" %*
if errorlevel 1 pause
BAT
  cp "$ROOT/README.md" "$top/README.md" 2>/dev/null || true

  ( cd "$WORK/win" && zip -qr -X "$DIST/ChromiumStack-$VERSION-Windows.zip" ChromiumStack )
  say "wrote ChromiumStack-$VERSION-Windows.zip"
}

# ---- Linux: tarball with a clean top launcher ----------------------------- #
build_linux() {
  step "Linux  (.tar.gz)"
  local top="$WORK/linux/chromium-stack"
  mkdir -p "$top"
  stage_tree "$top" posix
  cp "$ROOT/chromium-stack.desktop" "$top/" 2>/dev/null || true
  cp "$ROOT/assets/icon-512.png"    "$top/" 2>/dev/null || true

  # A capitalised launcher so the extracted folder has one obvious entry point.
  cat > "$top/ChromiumStack" <<'RUN'
#!/usr/bin/env bash
cd "$(dirname "$(readlink -f "$0")")" && exec ./gui.sh "$@"
RUN
  chmod +x "$top/ChromiumStack"

  ( cd "$WORK/linux" && tar -czf "$DIST/ChromiumStack-$VERSION-Linux.tar.gz" chromium-stack )
  say "wrote ChromiumStack-$VERSION-Linux.tar.gz"
}

build_macos
build_windows
build_linux

# ---- checksums ------------------------------------------------------------ #
step "checksums"
( cd "$DIST" && shasum -a 256 ChromiumStack-* > SHA256SUMS.txt && cat SHA256SUMS.txt )

step "done"
say "artifacts in $DIST"
ls -lh "$DIST"
