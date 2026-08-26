#!/usr/bin/env bash
#
# ChromiumStack - run an old Chromium engine on a modern machine (macOS / Linux)
#
# Downloads a pinned Chromium build once, then launches it as an ordinary
# desktop browser with its own profile. Any milestone in catalog.tsv works, as
# does any raw revision from the Chromium snapshot archive.
#
#   ./chromium-stack.sh run 74                  # launch Chromium 74
#   ./chromium-stack.sh run 120 localhost:4173  # launch 120 on a URL
#   ./chromium-stack.sh list                    # what is installed, and how big
#   ./chromium-stack.sh remove 74               # free the disk space
#
# The GUI (./gui.sh) drives this same script, so both agree by construction.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CATALOG="$SCRIPT_DIR/catalog.tsv"
# shellcheck source=lib/preflight.sh
. "$SCRIPT_DIR/lib/preflight.sh"
BASE_URL="https://commondatastorage.googleapis.com/chromium-browser-snapshots"
LIST_API="https://www.googleapis.com/storage/v1/b/chromium-browser-snapshots/o"

# BROWSERS_EMU_HOME is what this tool was called before; still honoured so an
# existing setup does not break on a rename.
if [ -n "${CHROMIUM_STACK_HOME:-}" ] || [ -n "${BROWSERS_EMU_HOME:-}" ]; then
  ROOT="${CHROMIUM_STACK_HOME:-${BROWSERS_EMU_HOME:-}}"
  ROOT_IS_DEFAULT=0
else
  ROOT="$HOME/.chromium-stack"
  ROOT_IS_DEFAULT=1
fi
BUILDS_DIR="$ROOT/builds"
PROFILES_DIR="$ROOT/profiles"
LOGS_DIR="$ROOT/logs"

# catalog.tsv ships inside the release and often lands on a read-only volume - it
# does inside ChromiumStack.app - so anything learned at runtime is written here
# instead. The cache is the newer of the two and is always consulted first.
CACHE="$ROOT/catalog.cache.tsv"
STABLE_CACHE="$ROOT/stable.cache"
STABLE_TTL=86400                 # how long "newest stable milestone" stays fresh
MAX_DRIFT=3000                   # refuse a build this far past the branch point
DASH_API="https://chromiumdash.appspot.com/fetch_milestones"
CFT_STABLE="https://googlechromelabs.github.io/chrome-for-testing/last-known-good-versions.json"

if [ -t 1 ]; then
  B=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; RST=$'\033[0m'
else
  B=''; DIM=''; RED=''; GRN=''; YLW=''; RST=''
fi
info() { printf '%s\n' "$*"; }
warn() { printf '%s\n' "${YLW}!  $*${RST}" >&2; }
die()  { printf '%s\n' "${RED}x  $*${RST}" >&2; exit 1; }

# ---------- platform ----------
# Apple Silicon can run two different builds: the native arm64 snapshot (only
# published from ~M92 on) and the x86_64 one under Rosetta. HOST_PLATFORMS lists
# them in preference order, so an old milestone silently falls back to Rosetta.
case "$(uname -s)" in
  Darwin)
    if [ "$(uname -m)" = "arm64" ]; then
      HOST_PLATFORMS="Mac_Arm Mac"
    else
      HOST_PLATFORMS="Mac"
    fi
    ;;
  Linux) HOST_PLATFORMS="Linux_x64" ;;
  *) die "Unsupported OS: $(uname -s). On Windows use chromium-stack.ps1 or ChromiumStack.bat." ;;
esac

# ---------- catalog ----------
# Two record types, in both the shipped catalog and the runtime cache:
#   V <milestone> <version> <note>
#   B <milestone> <platform> <revision> <archive> <root>
#
# Every lookup reads the cache first and the shipped catalog second, so an answer
# learned after this copy was packaged beats the frozen one. Neither file has to
# exist: a milestone in neither is resolved against the archive on demand.

catalog_query() {       # awk args... -> first match across cache, then catalog
  local files=()
  [ -f "$CACHE" ] && files+=("$CACHE")
  [ -f "$CATALOG" ] && files+=("$CATALOG")
  [ "${#files[@]}" -gt 0 ] || return 0
  # awk exits at the first match, and the cache is listed first, so it wins.
  awk "$@" "${files[@]}"
}

catalog_version_of() {  # milestone -> version string
  catalog_query -F'\t' -v m="$1" '$1=="V" && $2==m {print $3; exit}'
}
catalog_note_of() {
  catalog_query -F'\t' -v m="$1" '$1=="V" && $2==m {print $4; exit}'
}
catalog_build() {       # milestone platform -> "revision archive root"
  catalog_query -F'\t' -v m="$1" -v p="$2" '$1=="B" && $2==m && $3==p {print $4, $5, $6; exit}'
}
catalog_milestones() {
  catalog_query -F'\t' '$1=="V" {print $2}' | sort -un
}
catalog_milestone_for_revision() {
  catalog_query -F'\t' -v r="$1" '$1=="B" && $4==r {print $2; exit}'
}

# Pick the best platform this host can run for a milestone.
platform_for_milestone() {
  local milestone="$1" platform
  for platform in $HOST_PLATFORMS; do
    if [ -n "$(catalog_build "$milestone" "$platform")" ]; then
      printf '%s\n' "$platform"
      return 0
    fi
  done
  return 1
}

# ---------- runtime cache ----------
# Rows are only ever appended, and through a whole new file that is moved into
# place: several versions can be launched at once, each resolving something
# different, and a reader must never see a half-written line.
cache_add() {           # rows on stdin
  local rows tmp
  rows="$(cat)"
  [ -n "$rows" ] || return 0
  tmp="$CACHE.$$"
  {
    if [ -f "$CACHE" ]; then cat "$CACHE"; else
      printf '%s\n' "# ChromiumStack cache - milestones resolved against the live archive."
    fi
    printf '%s\n' "$rows"
  } > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$CACHE" 2>/dev/null || { rm -f "$tmp"; return 1; }
}

cache_has() {           # milestone -> is it in the cache rather than the catalog
  [ -f "$CACHE" ] || return 1
  awk -F'\t' -v m="$1" '$1=="B" && $2==m {found=1} END {exit !found}' "$CACHE"
}

# A cached row goes stale in exactly one way: the bucket drops a revision. Forget
# it and the next lookup asks the archive again instead of failing forever.
cache_forget() {        # milestone
  local tmp
  [ -f "$CACHE" ] || return 0
  tmp="$CACHE.$$"
  awk -F'\t' -v m="$1" '!(($1=="V" || $1=="B") && $2==m)' "$CACHE" > "$tmp" 2>/dev/null \
    || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$CACHE" 2>/dev/null || { rm -f "$tmp"; return 1; }
}

# ---------- live resolution ----------
# The shipped catalog freezes at whatever was current when the release was cut.
# Everything below asks the archive the same questions instead, so a milestone
# that shipped after this copy was built still runs. An answer is permanent - a
# branch point never moves and the snapshot bucket only ever grows - so it is
# cached without a TTL. Only "which milestone is stable now" gets one.

net_get() { curl -fsS -m 30 "$1" 2>/dev/null || true; }

# milestone -> "<branch-position> <branch>"
live_milestone_info() {
  local body position branch
  body="$(net_get "$DASH_API?mstone=$1")"
  [ -n "$body" ] || return 1
  body="$(printf '%s' "$body" | tr ',' '\n')"
  position="$(printf '%s\n' "$body" | grep -o '"chromium_main_branch_position":[[:space:]]*[0-9]*' \
              | grep -o '[0-9]*$' | head -1)"
  branch="$(printf '%s\n' "$body" | grep -o '"chromium_branch":[[:space:]]*"[0-9]*"' \
            | grep -o '[0-9][0-9]*' | head -1)"
  [ -n "$position" ] && [ -n "$branch" ] || return 1
  printf '%s %s\n' "$position" "$branch"
}

# First archived revision at or after target. Not every commit position is built
# and the gap runs to tens of commits, so the bucket listing is what decides.
# GCS lists lexicographically and the bucket still holds ancient short revision
# folders - Linux_x64/97277 sorts after 972766 - so only tokens of the target's
# own digit width are compared.
live_nearest_revision() {
  local platform="$1" target="$2" width low high body found attempt=0
  width="${#target}"
  low="$platform/$target"
  high="$platform/$(printf '%s' "$target" | sed 's/./9/g')"
  while [ "$attempt" -lt 6 ]; do
    attempt=$((attempt + 1))
    body="$(net_get "$LIST_API?delimiter=/&prefix=$platform/&startOffset=$low&endOffset=$high&maxResults=200")"
    [ -n "$body" ] || return 1
    body="$(printf '%s' "$body" | tr ',' '\n' | grep -o "\"$platform/[0-9]*/\"" \
            | sed "s|.*/\([0-9]*\)/\"|\1|")"
    [ -n "$body" ] || return 1
    found="$(printf '%s\n' "$body" | awk -v w="$width" -v t="$target" \
             'length($0)==w && $0+0>=t' | sort -n | head -1)"
    if [ -n "$found" ]; then
      [ "$((found - target))" -lt "$MAX_DRIFT" ] || return 1
      printf '%s\n' "$found"
      return 0
    fi
    low="$platform/$(printf '%s\n' "$body" | tail -1)"
  done
  return 1
}

# Windows switched from chrome-win32.zip to chrome-win.zip partway through the
# catalogued range, so the listing decides this too rather than a guess.
platform_archives() {
  case "$1" in
    Mac|Mac_Arm) printf 'chrome-mac.zip\n' ;;
    Linux_x64)   printf 'chrome-linux.zip\n' ;;
    *)           printf 'chrome-win.zip\nchrome-win32.zip\n' ;;
  esac
}

live_archive_at() {
  local platform="$1" revision="$2" names candidate
  names="$(net_get "$LIST_API?delimiter=/&prefix=$platform/$revision/" \
           | tr ',' '\n' | grep -o '"name":[[:space:]]*"[^"]*"' | sed 's|.*/\([^"/]*\)"$|\1|')"
  [ -n "$names" ] || return 1
  for candidate in $(platform_archives "$platform"); do
    if printf '%s\n' "$names" | grep -qx "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

# Resolve a milestone and print its catalog rows. Only the platforms this host
# can run are tried, and only until one works: the cache is per-machine, so a
# row for a platform this machine cannot launch would never be read back.
live_resolve_milestone() {
  local milestone="$1" info position branch version platform revision archive
  info="$(live_milestone_info "$milestone")" || return 1
  position="${info%% *}"
  branch="${info##* }"
  version="$milestone.0.$branch.0"
  for platform in $HOST_PLATFORMS; do
    revision="$(live_nearest_revision "$platform" "$position")" || continue
    archive="$(live_archive_at "$platform" "$revision")" || continue
    printf 'V\t%s\t%s\t%s\n' "$milestone" "$version" "Resolved from the live archive."
    printf 'B\t%s\t%s\t%s\t%s\t%s\n' "$milestone" "$platform" "$revision" "$archive" "${archive%.zip}"
    return 0
  done
  return 1
}

# Newest stable milestone. This is the one thing here that does go out of date,
# roughly every four weeks, so it carries a TTL - and offline the last answer
# stands rather than nothing.
newest_stable_milestone() {
  local stamp="" cached="" now body milestone tmp
  now="$(date +%s)"
  if [ -f "$STABLE_CACHE" ]; then
    read -r stamp cached < "$STABLE_CACHE" 2>/dev/null || true
    case "$stamp" in ''|*[!0-9]*) stamp=0 ;; esac
    if [ -n "$cached" ] && [ "$((now - stamp))" -lt "$STABLE_TTL" ]; then
      printf '%s\n' "$cached"
      return 0
    fi
  fi
  body="$(net_get "$CFT_STABLE" | tr ',' '\n')"
  milestone="$(printf '%s\n' "$body" | sed -n '/"Stable"/,/"Beta"/p' \
               | grep -o '"version":[[:space:]]*"[0-9]*' | grep -o '[0-9]*$' | head -1)"
  if [ -n "$milestone" ]; then
    tmp="$STABLE_CACHE.$$"
    printf '%s %s\n' "$now" "$milestone" > "$tmp" 2>/dev/null \
      && mv "$tmp" "$STABLE_CACHE" 2>/dev/null || rm -f "$tmp"
    printf '%s\n' "$milestone"
    return 0
  fi
  [ -n "$cached" ] || return 1
  printf '%s\n' "$cached"
}

# Milestones past the end of what is known, on the same five-milestone spacing,
# plus the current stable itself.
discover_new_milestones() {
  local newest known last milestone out=""
  newest="$(newest_stable_milestone)" || return 0
  known="$(catalog_milestones)"
  last="$(printf '%s\n' "$known" | tail -1)"
  case "$last" in ''|*[!0-9]*) last=60 ;; esac
  milestone=$(( (last / 5) * 5 + 5 ))
  while [ "$milestone" -le "$newest" ]; do
    printf '%s\n' "$known" | grep -qx "$milestone" || out="$out $milestone"
    milestone=$((milestone + 5))
  done
  if ! printf '%s\n' "$known" | grep -qx "$newest"; then
    case " $out " in *" $newest "*) ;; *) out="$out $newest" ;; esac
  fi
  printf '%s\n' "${out# }"
}

# Resolving is a handful of requests per milestone, so they go out together. This
# is a one-off: the answers land in the cache and every later run is offline-fast.
resolve_missing() {
  local milestone tmpdir running=0
  [ $# -gt 0 ] || return 0
  tmpdir="$(mktemp -d "$ROOT/.resolve.XXXXXX" 2>/dev/null)" || return 0
  info "${DIM}Resolving $# new milestone(s) against the archive - once only.${RST}"
  for milestone in "$@"; do
    ( live_resolve_milestone "$milestone" > "$tmpdir/$milestone" 2>/dev/null || true ) &
    running=$((running + 1))
    if [ "$running" -ge 6 ]; then wait; running=0; fi
  done
  wait
  cat "$tmpdir"/* 2>/dev/null | cache_add || true
  rm -rf "$tmpdir"
}

# ---------- selector resolution ----------
# A selector is a milestone (74, M74) or a raw archive revision (638880, r638880).
# Milestones are small and revisions are six digits or more, so the split is
# unambiguous without asking the user which they meant.
#
# Sets: SEL_MILESTONE SEL_VERSION SEL_PLATFORM SEL_REVISION SEL_ARCHIVE SEL_ROOT
resolve_selector() {
  local raw="${1:-}" token
  [ -n "$raw" ] || die "Which version? e.g. 74, or a revision like 638880. Try: $0 catalog"
  token="${raw#[MmRr]}"
  case "$token" in
    ''|*[!0-9]*) die "Not a version or revision: $raw" ;;
  esac

  if [ "$token" -lt 1000 ]; then
    resolve_milestone "$token"
  else
    resolve_revision "$token"
  fi
}

resolve_milestone() {
  local milestone="$1" platform build
  if ! platform="$(platform_for_milestone "$milestone")"; then
    # Known to neither the cache nor the shipped catalog. Ask the archive, keep
    # the answer, and try once more - this is how a milestone released after
    # this copy was packaged becomes runnable without an update.
    info "${DIM}Chromium $milestone is not catalogued here - asking the archive...${RST}"
    live_resolve_milestone "$milestone" | cache_add || true
    platform="$(platform_for_milestone "$milestone")" || die "\
No $(printf '%s' "$HOST_PLATFORMS" | tr ' ' '/') build of Chromium $milestone is available.
   It is in neither the catalog nor the cache, and the archive could not be
   reached to look it up. Try: $0 catalog"
  fi
  SEL_VERSION="$(catalog_version_of "$milestone")"
  build="$(catalog_build "$milestone" "$platform")"
  SEL_MILESTONE="$milestone"
  SEL_PLATFORM="$platform"
  SEL_REVISION="$(printf '%s' "$build" | cut -d' ' -f1)"
  SEL_ARCHIVE="$(printf '%s' "$build" | cut -d' ' -f2)"
  SEL_ROOT="$(printf '%s' "$build" | cut -d' ' -f3)"
}

# A revision the catalog does not know about: believe the archive, not a guess.
# If it is already installed, the recorded metadata answers offline.
resolve_revision() {
  local revision="$1" milestone meta platform names archive
  meta="$BUILDS_DIR/$revision/.meta"
  if [ -f "$meta" ]; then
    # shellcheck disable=SC1090
    . "$meta"
    SEL_MILESTONE="${META_MILESTONE:-?}"; SEL_VERSION="${META_VERSION:-r$revision}"
    SEL_PLATFORM="$META_PLATFORM"; SEL_REVISION="$revision"
    SEL_ARCHIVE="$META_ARCHIVE"; SEL_ROOT="$META_ROOT"
    return 0
  fi

  milestone="$(catalog_milestone_for_revision "$revision")"
  if [ -n "$milestone" ]; then
    platform="$(platform_for_milestone "$milestone")" || true
    if [ -n "${platform:-}" ]; then
      local build
      build="$(catalog_build "$milestone" "$platform")"
      if [ "$(printf '%s' "$build" | cut -d' ' -f1)" = "$revision" ]; then
        resolve_milestone "$milestone"
        return 0
      fi
    fi
  fi

  for platform in $HOST_PLATFORMS; do
    names="$(curl -fsS -m 30 "$LIST_API?delimiter=/&prefix=$platform/$revision/" 2>/dev/null \
             | tr ',' '\n' | grep -o '"name": *"[^"]*"' | sed 's/.*\/\([^"/]*\)"$/\1/' || true)"
    for archive in chrome-mac.zip chrome-linux.zip chrome-win.zip chrome-win32.zip; do
      if printf '%s\n' "$names" | grep -qx "$archive"; then
        SEL_MILESTONE="${milestone:-?}"
        SEL_VERSION="${milestone:+$milestone.x}"; SEL_VERSION="${SEL_VERSION:-r$revision}"
        SEL_PLATFORM="$platform"; SEL_REVISION="$revision"
        SEL_ARCHIVE="$archive"; SEL_ROOT="${archive%.zip}"
        return 0
      fi
    done
  done
  die "Revision $revision is not archived for $(printf '%s' "$HOST_PLATFORMS" | tr ' ' '/').
   Pick a nearby position from the snapshot archive, or use a catalogued version: $0 catalog"
}

build_dir()   { printf '%s\n' "$BUILDS_DIR/$1"; }
profile_dir() { printf '%s\n' "$PROFILES_DIR/$1"; }
log_file()    { printf '%s\n' "$LOGS_DIR/$1.log"; }

binary_path() {  # revision root platform
  local dir; dir="$(build_dir "$1")"
  case "$3" in
    Mac|Mac_Arm) printf '%s\n' "$dir/$2/Chromium.app/Contents/MacOS/Chromium" ;;
    *)           printf '%s\n' "$dir/$2/chrome" ;;
  esac
}

is_installed() { [ -f "$(build_dir "$1")/.complete" ]; }

# ---------- migration ----------
# This tool used to be called browsers-emu and kept the same layout under
# ~/.browsers-emu. Nothing inside changed, so moving the directory across is the
# whole migration - no re-download, no lost profiles.
adopt_previous_root() {
  local previous="$HOME/.browsers-emu"
  [ "${ROOT_IS_DEFAULT:-0}" -eq 1 ] || return 0
  [ -d "$previous" ] || return 0
  [ -e "$ROOT" ] && return 0
  mv "$previous" "$ROOT" 2>/dev/null || return 0
  info "${DIM}Moved your existing browsers into $ROOT (renamed from browsers-emu).${RST}"
}

# The single-version layout was ~/.chrome74/<revision>/ plus one shared profile.
# Move it across once so an existing install is not re-downloaded. This only ever
# runs against the default root: if the home was pointed elsewhere the legacy
# directory belongs to a different setup and must be left alone.
migrate_legacy() {
  local legacy="$HOME/.chrome74" dir revision
  [ "${ROOT_IS_DEFAULT:-0}" -eq 1 ] || return 0
  [ -d "$legacy" ] || return 0
  [ -f "$ROOT/.migrated" ] && return 0

  for dir in "$legacy"/*/; do
    [ -d "$dir" ] || continue
    revision="$(basename "$dir")"
    case "$revision" in
      ''|*[!0-9]*) continue ;;
    esac
    [ -f "$dir/.complete" ] || continue
    [ -d "$BUILDS_DIR/$revision" ] && continue

    mv "$dir" "$BUILDS_DIR/$revision" 2>/dev/null || continue
    write_meta_for "$revision"
    info "${DIM}Adopted the existing Chromium install (r$revision) - not re-downloading.${RST}"
    if [ -d "$legacy/profile" ] && [ ! -d "$PROFILES_DIR/$revision" ]; then
      mv "$legacy/profile" "$PROFILES_DIR/$revision" 2>/dev/null || true
    fi
  done
  touch "$ROOT/.migrated"
}

# Reconstruct .meta for a build that arrived without one (migrated from the old
# layout). The extracted top folder names the archive, and the catalog names the
# version, so nothing has to be guessed.
write_meta_for() {
  local revision="$1" dir root platform milestone version
  dir="$(build_dir "$revision")"
  [ -f "$dir/.meta" ] && return 0

  for root in chrome-mac chrome-linux chrome-win chrome-win32; do
    [ -d "$dir/$root" ] && break
    root=""
  done
  [ -n "$root" ] || return 1

  case "$root" in
    chrome-mac)   platform="$(printf '%s' "$HOST_PLATFORMS" | cut -d' ' -f1)" ;;
    chrome-linux) platform="Linux_x64" ;;
    *)            platform="Win_x64" ;;
  esac
  # A migrated mac build predates multi-version support, so it is the x86_64 one.
  [ "$root" = "chrome-mac" ] && [ "$(uname -s)" = "Darwin" ] && platform="Mac"

  milestone="$(catalog_milestone_for_revision "$revision")"
  version="${milestone:+$(catalog_version_of "$milestone")}"

  cat > "$dir/.meta" <<META
META_MILESTONE='${milestone:-?}'
META_VERSION='${version:-r$revision}'
META_PLATFORM='$platform'
META_ARCHIVE='$root.zip'
META_ROOT='$root'
META_INSTALLED='$(date -u +%Y-%m-%dT%H:%M:%SZ)'
META
}

# ---------- install ----------
install_build() {
  local revision="$1" platform="$2" archive="$3" root="$4" version="$5" milestone="$6"
  local dir zip binary
  dir="$(build_dir "$revision")"
  is_installed "$revision" && return 0

  info ""
  info "${B}Downloading Chromium $version${RST} ${DIM}($platform r$revision, one time only)${RST}"
  info "${DIM}-> $dir${RST}"
  info ""

  rm -rf "$dir"
  mkdir -p "$dir"
  zip="$ROOT/.download-$revision.zip"

  if ! curl -fL --progress-bar -o "$zip" "$BASE_URL/$platform/$revision/$archive"; then
    rm -rf "$dir" "$zip"
    # The one way a cached row goes bad: the bucket dropped that revision. Drop
    # the row too, so the retry resolves afresh instead of failing forever.
    if [ -n "$milestone" ] && [ "$milestone" != "?" ] && cache_has "$milestone"; then
      cache_forget "$milestone"
      die "Download failed - r$revision is no longer in the archive.
   The stale entry has been forgotten; run the same command again to re-resolve."
    fi
    die "Download failed. Check your connection or proxy."
  fi

  info "Extracting..."
  case "$platform" in
    Mac|Mac_Arm)
      # ditto preserves the symlinks and permissions inside the .app bundle;
      # plain unzip corrupts the framework and the browser will not start.
      ditto -x -k "$zip" "$dir" || { rm -rf "$dir" "$zip"; die "Extraction failed."; }
      ;;
    *)
      if command -v unzip >/dev/null 2>&1; then
        unzip -q "$zip" -d "$dir" || { rm -rf "$dir" "$zip"; die "Extraction failed."; }
      elif command -v python3 >/dev/null 2>&1; then
        python3 -m zipfile -e "$zip" "$dir" || { rm -rf "$dir" "$zip"; die "Extraction failed."; }
      else
        rm -rf "$dir" "$zip"
        die "Need 'unzip' or 'python3' to extract. Install one: sudo apt install unzip"
      fi
      chmod +x "$dir/$root/chrome" 2>/dev/null || true
      chmod +x "$dir/$root/chrome_sandbox" 2>/dev/null || true
      ;;
  esac
  rm -f "$zip"

  binary="$(binary_path "$revision" "$root" "$platform")"
  [ -x "$binary" ] || { rm -rf "$dir"; die "Expected browser binary missing: $binary"; }

  case "$platform" in
    Mac|Mac_Arm)
      # Gatekeeper refuses to run an unsigned downloaded bundle without this.
      xattr -dr com.apple.quarantine "$dir/$root/Chromium.app" 2>/dev/null || true
      ;;
  esac

  cat > "$dir/.meta" <<META
META_MILESTONE='$milestone'
META_VERSION='$version'
META_PLATFORM='$platform'
META_ARCHIVE='$archive'
META_ROOT='$root'
META_INSTALLED='$(date -u +%Y-%m-%dT%H:%M:%SZ)'
META
  touch "$dir/.complete"
  info "${GRN}v${RST} Chromium $version ready."
}

# ---------- commands ----------
cmd_catalog() {
  local milestone version platform build revision state new
  # Anything Chrome has shipped since this copy was packaged gets resolved and
  # cached here, so the list keeps growing without a new release of this tool.
  new="$(discover_new_milestones)"
  if [ -n "$new" ]; then
    # shellcheck disable=SC2086
    resolve_missing $new
  fi
  printf '%s\n' "${B}Available Chromium versions${RST} ${DIM}(host: $(printf '%s' "$HOST_PLATFORMS" | cut -d' ' -f1))${RST}"
  printf '\n'
  for milestone in $(catalog_milestones); do
    version="$(catalog_version_of "$milestone")"
    platform="$(platform_for_milestone "$milestone")" || { 
      printf '  %-6s %-16s %s\n' "$milestone" "$version" "${DIM}no build for this host${RST}"
      continue
    }
    build="$(catalog_build "$milestone" "$platform")"
    revision="$(printf '%s' "$build" | cut -d' ' -f1)"
    if is_installed "$revision"; then state="${GRN}installed${RST}"; else state="${DIM}not installed${RST}"; fi
    printf '  %-6s %-16s r%-9s %-12s %b\n' "$milestone" "$version" "$revision" "$platform" "$state"
  done
  printf '\n%s\n' "${DIM}Install and run:  $0 run <version>${RST}"
  [ -f "$CACHE" ] && printf '%s\n' "${DIM}Milestones newer than this release are resolved live and cached in $CACHE${RST}"
  return 0
}

cmd_list() {
  local dir revision size profile total=0 any=0
  mkdir -p "$BUILDS_DIR"
  printf '%s\n\n' "${B}Installed browsers${RST} ${DIM}($ROOT)${RST}"
  for dir in "$BUILDS_DIR"/*/; do
    [ -d "$dir" ] || continue
    revision="$(basename "$dir")"
    is_installed "$revision" || continue
    any=1
    [ -f "$dir/.meta" ] || write_meta_for "$revision" || true
    META_VERSION=""; META_PLATFORM=""; META_MILESTONE=""
    [ -f "$dir/.meta" ] && . "$dir/.meta"
    size=$(du -sk "$dir" 2>/dev/null | cut -f1); size=${size:-0}
    profile=0
    [ -d "$(profile_dir "$revision")" ] && profile=$(du -sk "$(profile_dir "$revision")" 2>/dev/null | cut -f1)
    total=$((total + size + profile))
    printf '  %-16s r%-9s %-10s %6s MB browser  %6s MB profile\n' \
      "${META_VERSION:-r$revision}" "$revision" "${META_PLATFORM:-?}" \
      "$((size / 1024))" "$((profile / 1024))"
  done
  if [ "$any" -eq 0 ]; then
    printf '  %s\n\n' "${DIM}Nothing installed yet. See: $0 catalog${RST}"
    return 0
  fi
  printf '\n  %s\n' "${DIM}Total: $((total / 1024)) MB${RST}"
  printf '  %s\n' "${DIM}Remove one with: $0 remove <version|revision>${RST}"
}

cmd_install() {
  resolve_selector "${1:-}"
  install_build "$SEL_REVISION" "$SEL_PLATFORM" "$SEL_ARCHIVE" "$SEL_ROOT" "$SEL_VERSION" "$SEL_MILESTONE"
}

cmd_remove() {
  resolve_selector "${1:-}"
  local dir profile removed=0
  dir="$(build_dir "$SEL_REVISION")"
  profile="$(profile_dir "$SEL_REVISION")"
  if [ -d "$dir" ]; then rm -rf "$dir"; removed=1; fi
  if [ "${2:-}" = "--with-profile" ] && [ -d "$profile" ]; then rm -rf "$profile"; fi
  rm -f "$(log_file "$SEL_REVISION")"
  if [ "$removed" -eq 1 ]; then
    info "${GRN}v${RST} Removed Chromium $SEL_VERSION (r$SEL_REVISION)."
  else
    warn "Chromium $SEL_VERSION (r$SEL_REVISION) was not installed."
  fi
}

cmd_clean() {
  resolve_selector "${1:-}"
  rm -rf "$(profile_dir "$SEL_REVISION")"
  info "${GRN}v${RST} Profile reset for Chromium $SEL_VERSION (r$SEL_REVISION)."
}

cmd_run() {
  local url="" window_size="" use_gpu="" auto_restart=1 max_restarts=5
  local selector="" extra_args=()

  selector="${1:-}"; shift || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --gpu)        use_gpu=1; shift ;;
      --no-gpu)     use_gpu=0; shift ;;
      --no-restart) auto_restart=0; shift ;;
      --size)       window_size="${2:-}"; shift 2 ;;
      --)           shift; extra_args+=("$@"); break ;;
      -*)           die "Unknown option: $1" ;;
      *)            url="$1"; shift ;;
    esac
  done

  resolve_selector "$selector"
  install_build "$SEL_REVISION" "$SEL_PLATFORM" "$SEL_ARCHIVE" "$SEL_ROOT" "$SEL_VERSION" "$SEL_MILESTONE"

  local binary profile log
  binary="$(binary_path "$SEL_REVISION" "$SEL_ROOT" "$SEL_PLATFORM")"
  profile="$(profile_dir "$SEL_REVISION")"
  log="$(log_file "$SEL_REVISION")"
  mkdir -p "$profile" "$LOGS_DIR"

  # Bare host:port typed by hand - be forgiving.
  if [ -n "$url" ]; then
    case "$url" in
      http://*|https://*|file://*|data:*|about:*) ;;
      *) url="http://$url" ;;
    esac
  fi

  if [ "$SEL_PLATFORM" = "Mac" ] && [ "$(uname -m)" = "arm64" ] && ! pgrep -q oahd 2>/dev/null; then
    warn "This build is x86_64 and Rosetta does not look installed."
    warn "If the browser fails to start, run: softwareupdate --install-rosetta"
  fi

  local args=(
    "--user-data-dir=$profile"
    --no-first-run
    --no-default-browser-check
    --disable-background-networking
    --disable-component-update
    --disable-features=TranslateUI
  )

  # Under Rosetta, Chromium's GPU process cannot read the system memory size from
  # the Apple AGX driver, crashes, and takes the browser with it. Software
  # rendering removes that entirely. Native arm64 and Linux builds are fine, so
  # they keep hardware acceleration unless asked otherwise.
  if [ -z "$use_gpu" ]; then
    if [ "$SEL_PLATFORM" = "Mac" ] && [ "$(uname -m)" = "arm64" ]; then use_gpu=0; else use_gpu=1; fi
  fi
  [ "$use_gpu" -eq 0 ] && args+=(--disable-gpu)
  [ -n "$window_size" ] && args+=("--window-size=${window_size/x/,}")
  # The setuid sandbox in these builds does not survive modern kernels/AppArmor.
  [ "$SEL_PLATFORM" = "Linux_x64" ] && args+=(--no-sandbox --test-type)

  info ""
  info "  ${GRN}>${RST} ${B}Chromium $SEL_VERSION${RST} ${DIM}(r$SEL_REVISION, $SEL_PLATFORM)${RST}"
  if [ -n "$url" ]; then
    info "  ${GRN}>${RST} $url"
  else
    info "  ${DIM}Use the address bar to go anywhere.${RST}"
  fi
  info "  ${DIM}Profile: $profile${RST}"
  info "  ${DIM}Log: $log${RST}"
  info ""

  # Chromium's stack sampling profiler walks thread stacks with libunwind. Under
  # Rosetta that unwinder occasionally segfaults on a synthesised x86 frame and
  # kills the browser - random, with no flag to disable it in an unbranded build.
  # Relaunch and let Chromium restore the tabs rather than handing that to QA.
  local attempt=0 fast_crashes=0 started status ran
  local launch_args=("$url")
  [ -z "$url" ] && launch_args=()

  while :; do
    started=$(date +%s)
    set +e
    "$binary" "${args[@]}" "${extra_args[@]+"${extra_args[@]}"}" "${launch_args[@]+"${launch_args[@]}"}" \
      >>"$log" 2>&1
    status=$?
    set -e

    [ "$status" -eq 0 ] && break

    ran=$(( $(date +%s) - started ))
    if [ "$auto_restart" -eq 0 ]; then
      warn "Chromium exited with status $status after ${ran}s. Last lines of $log:"
      tail -n 15 "$log" >&2 || true
      exit "$status"
    fi

    attempt=$((attempt + 1))
    if [ "$ran" -lt 5 ]; then fast_crashes=$((fast_crashes + 1)); else fast_crashes=0; fi
    if [ "$fast_crashes" -ge 3 ] || [ "$attempt" -gt "$max_restarts" ]; then
      warn "Chromium crashed after ${ran}s (status $status), giving up after $attempt attempt(s)."
      warn "Last lines of $log:"
      tail -n 15 "$log" >&2 || true
      exit "$status"
    fi

    warn "Chromium crashed after ${ran}s - restarting and restoring your tabs ($attempt/$max_restarts)."
    launch_args=(--restore-last-session)
  done
}

cmd_doctor() {
  local mode="report" component="" assume_yes=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --json)    mode="json"; shift ;;
      --fix)     mode="fix"; shift ;;
      --install) mode="install"; component="${2:-}"; shift 2 ;;
      --yes|-y)  assume_yes="--yes"; shift ;;
      *)         die "Unknown option for doctor: $1" ;;
    esac
  done

  case "$mode" in
    json)
      pf_json
      return 0
      ;;
    install)
      [ -n "$component" ] || die "Which component? e.g. --install docker"
      case " $PF_COMPONENTS " in
        *" $component "*) ;;
        *) die "Unknown component: $component (one of: $PF_COMPONENTS)" ;;
      esac
      pf_offer "$component" "$assume_yes"
      return $?
      ;;
  esac

  if pf_report; then
    return 0
  fi

  if [ "$mode" != "fix" ]; then
    info "  ${DIM}Offer to install the missing pieces:  $0 doctor --fix${RST}"
    info ""
    return 1
  fi

  # Walk the problems in the order they are listed, so a required piece is
  # offered before an optional one.
  local failed=0
  for component in $PF_PROBLEMS; do
    pf_offer "$component" "$assume_yes" || failed=1
  done
  return "$failed"
}

usage() {
  cat <<USAGE
${B}ChromiumStack${RST} - run an old Chromium engine on a modern machine

  $0 <command> [args]

Commands:
  catalog                    List the Chromium versions available for this host
  list                       List what is installed, with disk usage
  run <version> [url]        Install if needed, then launch
  install <version>          Download without launching
  remove <version>           Delete a downloaded browser
        [--with-profile]     ...and its profile
  clean <version>            Reset a version's profile (cookies, logins, storage)
  doctor                     Check that everything this needs is installed
        --fix                ...and offer to install what is missing
  gui                        Open the graphical manager

<version> is a milestone (74) or a raw snapshot revision (638880). A milestone
this copy has never heard of is looked up in the snapshot archive and remembered,
so newly released Chromium versions work without updating ChromiumStack.

Options for run:
  --size WxH                 Fixed window size, e.g. --size 1280x800
  --gpu / --no-gpu           Force hardware acceleration on or off
  --no-restart               Do not relaunch after a crash
  -- <flags>                 Everything after -- goes to Chromium

Each version keeps its own profile, so a newer build never upgrades a profile
out from under an older one.

Files live in $ROOT (override with CHROMIUM_STACK_HOME).
USAGE
}

adopt_previous_root
mkdir -p "$ROOT" "$BUILDS_DIR" "$PROFILES_DIR" "$LOGS_DIR"
migrate_legacy

COMMAND="${1:-}"
[ $# -gt 0 ] && shift || true
case "$COMMAND" in
  catalog|versions) cmd_catalog "$@" ;;
  list|ls)          cmd_list "$@" ;;
  run|launch)       cmd_run "$@" ;;
  install)          cmd_install "$@" ;;
  remove|rm|uninstall) cmd_remove "$@" ;;
  clean)            cmd_clean "$@" ;;
  doctor|check)     cmd_doctor "$@" ;;
  gui)              exec "$SCRIPT_DIR/gui.sh" "$@" ;;
  ''|-h|--help|help) usage ;;
  *)                die "Unknown command: $COMMAND (try --help)" ;;
esac
