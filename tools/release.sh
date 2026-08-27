#!/usr/bin/env bash
#
# Build clean, self-contained, obfuscated EngineShelf releases into dist/.
#
#   tools/release.sh                 # build every artifact this machine can
#   tools/release.sh --no-obfuscate  # readable source (for debugging a release)
#   tools/release.sh --ps-heavy      # heavy-obfuscate PowerShell too (see note)
#   tools/release.sh --version 2.1   # stamp a version into the artifact names
#
# Produces, in dist/:
#   EngineShelf-<ver>-macOS.zip      a single self-contained .app, zipped
#   EngineShelf-<ver>-Windows.zip    EngineShelf.bat + hidden app/ scripts
#   EngineShelf-<ver>-Linux.tar.gz   ./EngineShelf launcher + scripts
#   SHA256SUMS.txt                   checksums for every artifact above
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
               "$ROOT/EngineShelf.app/Contents/Info.plist" 2>/dev/null | head -1)"
  fi
  VERSION="${VERSION:-dev}"
fi

say() { printf '  %s\n' "$*"; }
step() { printf '\n== %s ==\n' "$*"; }

# gzip+base64 encoded PowerShell is the single strongest antivirus trigger on
# Windows: Defender/AMSI flag base64-encoded scriptblocks as a malware signature.
# The light (comment-strip) default ships readable, unflagged PowerShell - keep
# it that way for anything the public downloads.
if [ "$PS_HEAVY" = "1" ]; then
  printf '\n  !! --ps-heavy encodes PowerShell as base64 - Windows Defender/SmartScreen\n' >&2
  printf '     flag this pattern heavily. Do NOT use it for public release builds.\n\n' >&2
fi

# --------------------------------------------------------------------------- #
# stage the runtime tree for one flavour and obfuscate it in place
#   $1 dest dir   $2 flavour: posix | windows
# --------------------------------------------------------------------------- #
stage_tree() {
  local dest="$1" flavour="$2"
  mkdir -p "$dest/lib" "$dest/gui" "$dest/docker"

  # Shared, never obfuscated: data and container-internal plumbing.
  cp "$ROOT/catalog.tsv"            "$dest/"
  # The per-engine changelog data both servers read for the notes column. Without
  # it every non-Chromium row falls back to "N/A", since only a couple of dozen
  # Chromium milestones carry a hand-written note.
  cp "$ROOT/features.tsv"           "$dest/"
  cp "$ROOT/gui/icon.svg"           "$dest/gui/"
  # The whole of docker/ - it is all container-internal plumbing and none of it is
  # obfuscated. Named file by file before this, which is how three of the four
  # Dockerfiles and the script the fourth one COPYs came to be left out: a
  # released copy could not build a Firefox, Edge or WebKit container at all, and
  # the Chromium build died on a missing novnc-clipboard.sh.
  cp "$ROOT/docker/"* "$dest/docker/"

  # Served assets: minified (comments + indentation stripped).
  cp "$ROOT/gui/index.html" "$dest/gui/"
  cp "$ROOT/gui/app.js"     "$dest/gui/"
  cp "$ROOT/gui/styles.css" "$dest/gui/"

  if [ "$flavour" = "posix" ]; then
    cp "$ROOT/engineshelf.sh"        "$dest/"
    cp "$ROOT/engineshelf-docker.sh" "$dest/"
    cp "$ROOT/gui.sh"                   "$dest/"
    cp "$ROOT/lib/preflight.sh"         "$dest/lib/"
    cp "$ROOT/lib/engines.sh"           "$dest/lib/"
    cp "$ROOT/gui/server.py"            "$dest/gui/"
    chmod +x "$dest"/*.sh
  else
    cp "$ROOT/engineshelf.ps1"        "$dest/"
    cp "$ROOT/engineshelf-docker.ps1" "$dest/"
    cp "$ROOT/gui.ps1"                   "$dest/"
    cp "$ROOT/lib/preflight.ps1"         "$dest/lib/"
    cp "$ROOT/lib/engines.ps1"           "$dest/lib/"
    cp "$ROOT/gui/server.ps1"            "$dest/gui/"
  fi

  [ "$OBFUSCATE" = "1" ] || { say "obfuscation skipped"; return; }

  min_web "$dest/gui/index.html"
  min_web "$dest/gui/app.js"
  min_web "$dest/gui/styles.css"

  if [ "$flavour" = "posix" ]; then
    obf_bash "$dest/engineshelf.sh"
    obf_bash "$dest/engineshelf-docker.sh"
    obf_bash "$dest/gui.sh"
    obf_bash "$dest/lib/preflight.sh"
    obf_bash "$dest/lib/engines.sh"
    obf_py   "$dest/gui/server.py"
    say "obfuscated: 5 bash + 1 python + 3 web assets"
  else
    local fn=obf_ps1_light label="light (comment strip)"
    [ "$PS_HEAVY" = "1" ] && { fn=obf_ps1_heavy; label="heavy (encoded, UNTESTED here)"; }
    "$fn" "$dest/engineshelf.ps1"
    "$fn" "$dest/engineshelf-docker.ps1"
    "$fn" "$dest/gui.ps1"
    "$fn" "$dest/lib/preflight.ps1"
    "$fn" "$dest/lib/engines.ps1"
    "$fn" "$dest/gui/server.ps1"
    say "obfuscated: 6 powershell [$label] + 3 web assets"
  fi
}

# --------------------------------------------------------------------------- #
step "EngineShelf release  (version $VERSION, obfuscate=$OBFUSCATE ps-heavy=$PS_HEAVY)"
rm -rf "$DIST"; mkdir -p "$DIST"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# ---- macOS: self-contained .app -> .zip ----------------------------------- #
build_macos() {
  [ "$(uname -s)" = "Darwin" ] || { say "skip macOS (not on Darwin)"; return; }
  step "macOS  (.app -> .zip)"
  local app="$WORK/EngineShelf.app"
  # Copy the built bundle skeleton (launcher + Info.plist + icon), then fill
  # Contents/Resources with the runtime tree so the .app stands alone.
  cp -R "$ROOT/EngineShelf.app" "$app"
  rm -rf "$app/Contents/_CodeSignature"           # stale, we re-sign below
  stage_tree "$app/Contents/Resources" posix

  codesign --force --deep --sign - "$app" 2>/dev/null
  say "signed $(codesign -dv "$app" 2>&1 | sed -n 's/^Identifier=//p')"

  cat > "$WORK/HOW TO OPEN.txt" <<'HELP'
EngineShelf - how to open (macOS)

1. Unzip this file (double-click it in Finder).
2. Double-click EngineShelf.app.
   Optional: drag it into your Applications folder first.

First time only - "unidentified developer"?
  macOS blocks apps not signed with a paid Apple certificate. Right-click
  (or Control-click) EngineShelf.app -> Open -> Open. Just once.

If the app bounces and asks for file access:
  When the folder sits in Documents, Desktop or Downloads, allow EngineShelf
  under System Settings -> Privacy & Security -> Files and Folders, or move the
  folder somewhere else.

The manager needs Python 3 (it comes with: xcode-select --install).
To stop it: close the window it opens.

More help: https://github.com/1m93/EngineShelf
HELP

  ( cd "$WORK" && zip -qr -X "$DIST/EngineShelf-$VERSION-macOS.zip" EngineShelf.app "HOW TO OPEN.txt" )
  say "wrote EngineShelf-$VERSION-macOS.zip"
}

# ---- Windows: .bat launcher + hidden app/ scripts ------------------------- #
# No .exe is shipped: an unsigned binary that spawns `powershell -Bypass` is
# exactly the pattern SmartScreen/Defender flag, and a .bat carries no such
# reputation check. A .bat cannot hold an icon, so Create-Shortcut.ps1 makes an
# icon'd Desktop/Start Menu shortcut for anyone who wants one.
build_windows() {
  step "Windows  (.zip)"
  local top="$WORK/win/EngineShelf"
  mkdir -p "$top/app"
  stage_tree "$top/app" windows

  # The one entry point: forward to the real, obfuscated gui.ps1 under app\.
  cat > "$top/EngineShelf.bat" <<'BAT'
@echo off
title EngineShelf
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0app\gui.ps1" %*
if errorlevel 1 pause
BAT

  # icon.ico + a shortcut maker, so users who want an icon can have one without
  # us shipping a binary. The shortcut is created locally on their machine, so it
  # never carries a "downloaded from the internet" mark.
  cp "$ROOT/assets/icon.ico" "$top/icon.ico" 2>/dev/null || true
  cat > "$top/Create-Shortcut.ps1" <<'SHORTCUT'
# Put a EngineShelf shortcut (with icon) on the Desktop and Start Menu.
# Run it once after extracting - right-click -> "Run with PowerShell", or:
#   powershell -ExecutionPolicy Bypass -File .\Create-Shortcut.ps1
#   powershell -ExecutionPolicy Bypass -File .\Create-Shortcut.ps1 -Remove
[CmdletBinding()]
param([switch]$Remove)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$bat  = Join-Path $root 'EngineShelf.bat'
$icon = Join-Path $root 'icon.ico'
$targets = @(
    (Join-Path ([Environment]::GetFolderPath('Desktop'))  'EngineShelf.lnk'),
    (Join-Path ([Environment]::GetFolderPath('StartMenu')) 'Programs\EngineShelf.lnk')
)
if ($Remove) {
    foreach ($p in $targets) { if (Test-Path $p) { Remove-Item $p -Force; Write-Host "removed $p" } }
    return
}
$shell = New-Object -ComObject WScript.Shell
foreach ($p in $targets) {
    $dir = Split-Path -Parent $p
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $lnk = $shell.CreateShortcut($p)
    $lnk.TargetPath       = $bat
    $lnk.WorkingDirectory = $root
    if (Test-Path $icon) { $lnk.IconLocation = "$icon,0" }
    $lnk.Description      = 'Install, launch and manage old Chromium engines'
    $lnk.Save()
    Write-Host "created $p"
}
Write-Host "`nDone. Look for EngineShelf on your Desktop and in the Start Menu."
SHORTCUT

  cat > "$top/HOW TO OPEN.txt" <<'HELP'
EngineShelf - how to open (Windows)

1. Unzip this folder (right-click the .zip -> Extract All).
2. Double-click EngineShelf.bat.
   A window opens and starts the manager. Close it to stop.

Want a Desktop / Start Menu icon?
  Right-click Create-Shortcut.ps1 -> Run with PowerShell (once).

Windows warns about the download?
  EngineShelf.bat is a short, readable script - open it in Notepad - that
  only starts the manager; there is no program to trust. A "Run anyway?" prompt
  is normal for any downloaded script without a paid certificate. If a file
  feels stuck, open PowerShell in this folder and unblock everything:

      Get-ChildItem -Recurse | Unblock-File

  (or right-click each file -> Properties -> Unblock).

Uses the PowerShell that ships with Windows 10/11 - nothing to install.

More help: https://github.com/1m93/EngineShelf
HELP

  ( cd "$WORK/win" && zip -qr -X "$DIST/EngineShelf-$VERSION-Windows.zip" EngineShelf )
  say "wrote EngineShelf-$VERSION-Windows.zip (.bat launcher, no .exe)"
}

# ---- Linux: tarball with a clean top launcher ----------------------------- #
build_linux() {
  step "Linux  (.tar.gz)"
  local top="$WORK/linux/engineshelf"
  mkdir -p "$top"
  stage_tree "$top" posix
  cp "$ROOT/engineshelf.desktop" "$top/" 2>/dev/null || true
  cp "$ROOT/assets/icon-512.png"    "$top/" 2>/dev/null || true

  # A capitalised launcher so the extracted folder has one obvious entry point.
  cat > "$top/EngineShelf" <<'RUN'
#!/usr/bin/env bash
cd "$(dirname "$(readlink -f "$0")")" && exec ./gui.sh "$@"
RUN
  chmod +x "$top/EngineShelf"

  cat > "$top/HOW TO OPEN.txt" <<'HELP'
EngineShelf - how to open (Linux)

1. Extract this archive:  tar -xzf EngineShelf-*-Linux.tar.gz
2. Run the launcher:      cd engineshelf && ./EngineShelf
   (or ./gui.sh, or double-click engineshelf.desktop in your file manager)

The manager needs Python 3:  sudo apt install python3

Desktop entry has no icon? Copy it where your desktop can find it:
  mkdir -p ~/.local/share/icons
  cp icon-512.png ~/.local/share/icons/engineshelf.png

To stop it: close the manager window (or Ctrl+C in the terminal).

More help: https://github.com/1m93/EngineShelf
HELP

  ( cd "$WORK/linux" && tar -czf "$DIST/EngineShelf-$VERSION-Linux.tar.gz" engineshelf )
  say "wrote EngineShelf-$VERSION-Linux.tar.gz"
}

build_macos
build_windows
build_linux

# ---- checksums ------------------------------------------------------------ #
step "checksums"
( cd "$DIST" && shasum -a 256 EngineShelf-* > SHA256SUMS.txt && cat SHA256SUMS.txt )

step "done"
say "artifacts in $DIST"
ls -lh "$DIST"
