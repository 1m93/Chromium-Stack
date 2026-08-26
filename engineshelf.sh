#!/usr/bin/env bash
#
# EngineShelf - run an old Chromium engine on a modern machine (macOS / Linux)
#
# Downloads a pinned Chromium build once, then launches it as an ordinary
# desktop browser with its own profile. Any milestone in catalog.tsv works, as
# does any raw revision from the Chromium snapshot archive.
#
#   ./engineshelf.sh run 74                  # launch Chromium 74
#   ./engineshelf.sh run 120 localhost:4173  # launch 120 on a URL
#   ./engineshelf.sh list                    # what is installed, and how big
#   ./engineshelf.sh remove 74               # free the disk space
#
# The GUI (./gui.sh) drives this same script, so both agree by construction.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CATALOG="$SCRIPT_DIR/catalog.tsv"
# shellcheck source=lib/preflight.sh
. "$SCRIPT_DIR/lib/preflight.sh"
# shellcheck source=lib/engines.sh
. "$SCRIPT_DIR/lib/engines.sh"
BASE_URL="https://commondatastorage.googleapis.com/chromium-browser-snapshots"
LIST_API="https://www.googleapis.com/storage/v1/b/chromium-browser-snapshots/o"

# This tool has been named three things: browsers-emu, then ChromiumStack, now
# EngineShelf. Both old variables are still honoured, newest winning, so an
# existing setup does not break on a rename.
if [ -n "${ENGINESHELF_HOME:-}" ] || [ -n "${CHROMIUM_STACK_HOME:-}" ] \
   || [ -n "${BROWSERS_EMU_HOME:-}" ]; then
  ROOT="${ENGINESHELF_HOME:-${CHROMIUM_STACK_HOME:-${BROWSERS_EMU_HOME:-}}}"
  ROOT_IS_DEFAULT=0
else
  ROOT="$HOME/.engineshelf"
  ROOT_IS_DEFAULT=1
fi
BUILDS_DIR="$ROOT/builds"
PROFILES_DIR="$ROOT/profiles"
LOGS_DIR="$ROOT/logs"

# catalog.tsv ships inside the release and often lands on a read-only volume - it
# does inside EngineShelf.app - so anything learned at runtime is written here
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
# Which builds this host can run is an engine's own answer - see
# engine_platforms in lib/engines.sh. HOST_PLATFORMS stays as the Chromium
# answer, in preference order, because the Chromium resolver below is built
# around it: on Apple Silicon that is the native arm64 snapshot (published only
# from ~M92 on) and then the x86_64 one under Rosetta, so an old milestone
# silently falls back rather than failing.
case "$(uname -s)" in
  Darwin|Linux) ;;
  *) die "Unsupported OS: $(uname -s). On Windows use engineshelf.ps1 or EngineShelf.bat." ;;
esac
HOST_PLATFORMS="$(engine_platforms chromium)" \
  || die "Unsupported machine: $(uname -s)/$(uname -m)."

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
      printf '%s\n' "# EngineShelf cache - milestones resolved against the live archive."
    fi
    printf '%s\n' "$rows"
  } > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$CACHE" 2>/dev/null || { rm -f "$tmp"; return 1; }
}

# Some milestones will not start natively on some versions of macOS at all. On
# macOS 26, Chromium 120 dies with SIGSEGV before a window appears - and so does
# the x86_64 build of the same milestone under Rosetta, within seconds, at random.
# Measured, not assumed: both were tried.
#
# So there is no second native build to fall back to, and offering to download
# one would cost 136 MB to fail again. What does work is the container - it runs
# the Linux build and never touches Rosetta - so that is what gets suggested.
#
# Recorded the first time it happens, and keyed by macOS major version as well as
# milestone: an OS upgrade can fix or break this, and either way the answer
# should be found again rather than inherited.
ARCH_CACHE="$ROOT/arch-fallback.cache"

host_os_major() { sw_vers -productVersion 2>/dev/null | cut -d. -f1; }

native_known_bad() {    # milestone
  [ -f "$ARCH_CACHE" ] || return 1
  grep -qx "$(host_os_major)	$1" "$ARCH_CACHE" 2>/dev/null
}

remember_native_bad() {
  native_known_bad "$1" && return 0
  printf '%s\t%s\n' "$(host_os_major)" "$1" >> "$ARCH_CACHE" 2>/dev/null || true
}

# Said in both places this can be discovered: before a launch that is already
# known to fail, and after one that just did.
suggest_container() {   # milestone
  warn "Chromium $1 does not start natively on macOS $(host_os_major) - neither the"
  warn "arm64 build nor the x86_64 one under Rosetta, which crashes at random."
  warn "The container runs the Linux build and never touches Rosetta:"
  warn "    ./engineshelf-docker.sh start $1"
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
# A selector names an engine and a version: firefox:115, edge:151, webkit:18.2.
# A bare number means Chromium, which is every selector this tool accepted before
# there was more than one engine - 74, M74, or a raw archive revision like
# 638880. Milestones are small and revisions are six digits or more, so those two
# stay distinguishable without asking which was meant.
#
# Sets, for every engine:
#   SEL_ENGINE   which engine
#   SEL_KEY      the on-disk name for this build - what builds/ and profiles/ use
#   SEL_VERSION  what to print
#   SEL_PLATFORM the vendor's platform name this host resolved to
#   SEL_URL      where to download it
#   SEL_FORMAT   how to unpack it, for engine_extract
#   SEL_ROOT     the directory inside the archive, "" when it unpacks flat
# and, for Chromium only, SEL_MILESTONE SEL_REVISION SEL_ARCHIVE, which the
# snapshot archive needs and no other engine has an equivalent of.
resolve_selector() {
  local raw="${1:-}" engine token
  [ -n "$raw" ] || die "\
Which version? A bare number is Chromium: 74. Otherwise name the engine:
   firefox:115   edge:151   webkit:18.2   chromium:120
   Try: $0 catalog"

  case "$raw" in
    *:*) engine="${raw%%:*}"; token="${raw#*:}" ;;
    *)   engine="chromium";   token="$raw" ;;
  esac
  engine="$(printf '%s' "$engine" | tr '[:upper:]' '[:lower:]')"
  engine_known "$engine" || die "Unknown engine: $engine. Known: $ENGINES"
  [ -n "$token" ] || die "Which version of $(engine_display "$engine")?"

  SEL_ENGINE="$engine"
  SEL_MILESTONE=""; SEL_REVISION=""; SEL_ARCHIVE=""; SEL_ROOT=""
  SEL_URL=""; SEL_FORMAT=""

  if [ "$engine" != "chromium" ]; then
    resolve_engine "$engine" "$token"
    return 0
  fi

  token="${token#[MmRr]}"
  case "$token" in
    ''|*[!0-9]*) die "Not a Chromium version or revision: $raw" ;;
  esac
  if [ "$token" -lt 1000 ]; then
    resolve_milestone "$token"
  else
    resolve_revision "$token"
  fi
  # Chromium's identity on disk stays the bare revision it has always been, so
  # builds already downloaded are still found.
  SEL_KEY="$(engine_key chromium "$SEL_REVISION")"
  SEL_URL="$BASE_URL/$SEL_PLATFORM/$SEL_REVISION/$SEL_ARCHIVE"
  case "$SEL_PLATFORM" in
    Mac|Mac_Arm) SEL_FORMAT="zip-ditto" ;;
    *)           SEL_FORMAT="zip" ;;
  esac
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

# key root platform [engine] -> the executable, asked of the engine itself.
binary_path() {
  local engine="${4:-$(engine_of_key "$1")}"
  engine_binary "$engine" "$(build_dir "$1")" "$2" "$3"
}

is_installed() { [ -f "$(build_dir "$1")/.complete" ]; }

# ---------- migration ----------
# This tool used to be called browsers-emu and kept the same layout under
# ~/.browsers-emu. Nothing inside changed, so moving the directory across is the
# whole migration - no re-download, no lost profiles.
adopt_previous_root() {
  local previous
  [ "${ROOT_IS_DEFAULT:-0}" -eq 1 ] || return 0
  [ -e "$ROOT" ] && return 0
  # Newest name first: somebody who used both should end up with the later one.
  for previous in "$HOME/.chromium-stack" "$HOME/.browsers-emu"; do
    [ -d "$previous" ] || continue
    mv "$previous" "$ROOT" 2>/dev/null || continue
    info "${DIM}Moved your existing browsers into $ROOT (renamed from $(basename "$previous")).${RST}"
    return 0
  done
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
# Downloads and unpacks whatever resolve_selector settled on. It reads the SEL_*
# variables rather than taking eight positional arguments, because six of the
# eight differed per engine and the call sites all had to know which.
install_build() {
  local dir archive binary failed=0 engine key
  engine="$SEL_ENGINE"; key="$SEL_KEY"

  # A build directory is removed before it is written, so an empty key here would
  # mean rm -rf on builds/ itself and every browser already downloaded. That is
  # a resolver bug rather than user input, so it is a hard stop, not a warning.
  case "$key" in
    ''|*/*) die "Internal error: refusing to install with build key '$key'." ;;
  esac

  dir="$(build_dir "$key")"
  is_installed "$key" && return 0

  info ""
  info "${B}Downloading $(engine_display "$engine") $SEL_VERSION${RST} ${DIM}($SEL_PLATFORM, one time only)${RST}"
  info "${DIM}-> $dir${RST}"
  info ""

  rm -rf "$dir"
  mkdir -p "$dir"
  archive="$ROOT/.download-$key"

  # A bar reads better for a person watching a terminal, but curl's plain meter
  # carries the byte counts and the time left, which is what the graphical
  # manager puts in its status bar. Colours switch on the same test.
  if [ -t 1 ]; then
    curl -fL --progress-bar -o "$archive" "$SEL_URL" || failed=1
  else
    curl -fL -o "$archive" "$SEL_URL" || failed=1
  fi

  if [ "$failed" -eq 1 ]; then
    rm -rf "$dir" "$archive"
    # The one way a cached Chromium row goes bad: the bucket dropped that
    # revision. Drop the row too, so the retry resolves afresh rather than
    # failing forever. No other engine has a cache to invalidate.
    if [ "$engine" = "chromium" ] && [ -n "$SEL_MILESTONE" ] \
       && [ "$SEL_MILESTONE" != "?" ] && cache_has "$SEL_MILESTONE"; then
      cache_forget "$SEL_MILESTONE"
      die "Download failed - r$SEL_REVISION is no longer in the archive.
   The stale entry has been forgotten; run the same command again to re-resolve."
    fi
    die "Download failed. Check your connection or proxy."
  fi

  info "Extracting..."
  engine_extract "$SEL_FORMAT" "$archive" "$dir" \
    || { rm -rf "$dir" "$archive"; die "Extraction failed."; }
  rm -f "$archive"

  # Tarballs and zips do not always carry the executable bit through, and the
  # Linux sandbox helper needs it too.
  binary="$(binary_path "$key" "$SEL_ROOT" "$SEL_PLATFORM" "$engine")"
  chmod +x "$binary" 2>/dev/null || true
  chmod +x "$dir/$SEL_ROOT/chrome_sandbox" 2>/dev/null || true
  [ -f "$dir/pw_run.sh" ] && chmod +x "$dir/pw_run.sh" 2>/dev/null || true

  [ -x "$binary" ] || { rm -rf "$dir"; die "\
Expected browser binary missing: $binary
   The archive unpacked, but not into the shape this engine expects. Please
   report the engine and version."; }

  # Gatekeeper refuses to run an unsigned downloaded bundle without this, and
  # every mac build here is downloaded and unsigned as far as it is concerned.
  case "$SEL_PLATFORM" in
    Mac|Mac_Arm|mac|mac-*|Mac_Universal)
      xattr -dr com.apple.quarantine "$dir" 2>/dev/null || true ;;
  esac

  cat > "$dir/.meta" <<META
META_ENGINE='$engine'
META_MILESTONE='$SEL_MILESTONE'
META_VERSION='$SEL_VERSION'
META_PLATFORM='$SEL_PLATFORM'
META_ARCHIVE='$SEL_ARCHIVE'
META_ROOT='$SEL_ROOT'
META_INSTALLED='$(date -u +%Y-%m-%dT%H:%M:%SZ)'
META
  touch "$dir/.complete"
  info "${GRN}v${RST} $(engine_display "$engine") $SEL_VERSION ready."
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
  local dir key size profile total=0 any=0 engine
  mkdir -p "$BUILDS_DIR"
  printf '%s\n\n' "${B}Installed browsers${RST} ${DIM}($ROOT)${RST}"
  for dir in "$BUILDS_DIR"/*/; do
    [ -d "$dir" ] || continue
    key="$(basename "$dir")"
    is_installed "$key" || continue
    any=1
    # A build that predates .meta only exists for Chromium; write_meta_for knows
    # how to reconstruct one from the catalog.
    [ -f "$dir/.meta" ] || write_meta_for "$key" || true
    META_ENGINE=""; META_VERSION=""; META_PLATFORM=""; META_MILESTONE=""
    [ -f "$dir/.meta" ] && . "$dir/.meta"
    engine="${META_ENGINE:-$(engine_of_key "$key")}"
    size=$(du -sk "$dir" 2>/dev/null | cut -f1); size=${size:-0}
    profile=0
    [ -d "$(profile_dir "$key")" ] && profile=$(du -sk "$(profile_dir "$key")" 2>/dev/null | cut -f1)
    total=$((total + size + profile))
    printf '  %-9s %-14s %-16s %6s MB browser  %6s MB profile\n' \
      "$(engine_display "$engine")" "${META_VERSION:-$key}" "${META_PLATFORM:-?}" \
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
  local dry=0 selector=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) dry=1; shift ;;
      *)         selector="$1"; shift ;;
    esac
  done
  resolve_selector "$selector"
  # Resolution is the part that talks to four different vendors and gets things
  # wrong; being able to see its answer without spending 400 MB to find out is
  # what makes it testable, and is what the manager asks for before it offers a
  # download.
  if [ "$dry" -eq 1 ]; then
    printf 'engine    %s\n' "$SEL_ENGINE"
    printf 'version   %s\n' "$SEL_VERSION"
    printf 'platform  %s\n' "$SEL_PLATFORM"
    printf 'key       %s\n' "$SEL_KEY"
    printf 'format    %s\n' "$SEL_FORMAT"
    printf 'url       %s\n' "$SEL_URL"
    printf 'installed %s\n' "$(is_installed "$SEL_KEY" && echo yes || echo no)"
    return 0
  fi
  install_build
}

# Both of these delete a directory built from the resolved key, so both check it
# first: an empty key would make the path builds/ itself.
require_key() {
  case "${SEL_KEY:-}" in
    ''|*/*) die "Internal error: refusing to act on build key '${SEL_KEY:-}'." ;;
  esac
}

cmd_remove() {
  resolve_selector "${1:-}"
  require_key
  local dir profile removed=0 label
  label="$(engine_display "$SEL_ENGINE") $SEL_VERSION"
  dir="$(build_dir "$SEL_KEY")"
  profile="$(profile_dir "$SEL_KEY")"
  if [ -d "$dir" ]; then rm -rf "$dir"; removed=1; fi
  if [ "${2:-}" = "--with-profile" ] && [ -d "$profile" ]; then rm -rf "$profile"; fi
  rm -f "$(log_file "$SEL_KEY")"
  if [ "$removed" -eq 1 ]; then
    info "${GRN}v${RST} Removed $label."
  else
    warn "$label was not installed."
  fi
}

cmd_clean() {
  resolve_selector "${1:-}"
  require_key
  rm -rf "$(profile_dir "$SEL_KEY")"
  info "${GRN}v${RST} Profile reset for $(engine_display "$SEL_ENGINE") $SEL_VERSION."
}

# Everything the launch needs, in globals, because a shell function cannot
# return an array - and this has to be recomputed if the browser turns out not
# to run and a different build is chosen instead.
prepare_launch() {
  local want_gpu="$1" window_size="$2" line gpu
  LAUNCH_BINARY="$(binary_path "$SEL_KEY" "$SEL_ROOT" "$SEL_PLATFORM" "$SEL_ENGINE")"
  LAUNCH_PROFILE="$(profile_dir "$SEL_KEY")"
  LAUNCH_LOG="$(log_file "$SEL_KEY")"
  mkdir -p "$LAUNCH_PROFILE" "$LOGS_DIR"
  engine_prepare_profile "$SEL_ENGINE" "$LAUNCH_PROFILE"

  # The flags that isolate the profile and disable the updater are the engine's
  # own answer: Chromium and Edge take --user-data-dir, Firefox takes -profile,
  # and the WebKit MiniBrowser takes neither.
  # `[ -n "$line" ] && ...` would leave the loop's exit status at 1 whenever the
  # last line is blank - which it always is, a command substitution ends with a
  # newline - and `set -e` then kills the script here without printing anything.
  LAUNCH_ARGS=()
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    LAUNCH_ARGS+=("$line")
  done <<ARGS
$(engine_launch_args "$SEL_ENGINE" "$LAUNCH_PROFILE")
ARGS

  # Under Rosetta, Chromium's GPU process cannot read the system memory size
  # from the Apple AGX driver, crashes, and takes the browser with it. Software
  # rendering removes that entirely. Native arm64 and Linux builds are fine, so
  # they keep hardware acceleration unless asked otherwise.
  gpu="$want_gpu"
  if [ -z "$gpu" ]; then
    if [ "$SEL_PLATFORM" = "Mac" ] && [ "$(uname -m)" = "arm64" ]; then gpu=0; else gpu=1; fi
  fi

  # These are all Chromium switches. Firefox has no equivalent worth forcing,
  # and an unknown -flag opens a dialog rather than being ignored.
  case "$SEL_ENGINE" in
    chromium|edge)
      [ "$gpu" -eq 0 ] && LAUNCH_ARGS+=(--disable-gpu)
      [ -n "$window_size" ] && LAUNCH_ARGS+=("--window-size=${window_size/x/,}")
      # The setuid sandbox in these builds does not survive modern
      # kernels/AppArmor.
      case "$SEL_PLATFORM" in
        Linux_x64) LAUNCH_ARGS+=(--no-sandbox --test-type) ;;
      esac ;;
    firefox)
      [ -n "$window_size" ] && LAUNCH_ARGS+=(-width "${window_size%%x*}" -height "${window_size##*x}") ;;
  esac

  LAUNCH_ENV=()
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    LAUNCH_ENV+=("$line")
  done <<ENVV
$(engine_launch_env "$SEL_ENGINE" "$(build_dir "$SEL_KEY")")
ENVV
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
  # Warned before the download, not after: this is already known to fail here.
  if [ "$SEL_ENGINE" = "chromium" ] && [ -n "$SEL_MILESTONE" ] \
     && native_known_bad "$SEL_MILESTONE"; then
    suggest_container "$SEL_MILESTONE"
    info ""
  fi
  install_build
  prepare_launch "$use_gpu" "$window_size"

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

  local label
  label="$(engine_display "$SEL_ENGINE") $SEL_VERSION"
  info ""
  info "  ${GRN}>${RST} ${B}$label${RST} ${DIM}($SEL_PLATFORM)${RST}"
  if [ -n "$url" ]; then
    info "  ${GRN}>${RST} $url"
  else
    info "  ${DIM}Use the address bar to go anywhere.${RST}"
  fi
  info "  ${DIM}Profile: $LAUNCH_PROFILE${RST}"
  info "  ${DIM}Log: $LAUNCH_LOG${RST}"
  info ""

  # Chromium's stack sampling profiler walks thread stacks with libunwind. Under
  # Rosetta that unwinder occasionally segfaults on a synthesised x86 frame and
  # kills the browser - random, with no flag to disable it in an unbranded build.
  # Relaunch and let Chromium restore the tabs rather than handing that to QA.
  local attempt=0 fast_crashes=0 started status ran noted_bad=0
  local launch_args=("$url")
  [ -z "$url" ] && launch_args=()

  while :; do
    started=$(date +%s)
    set +e
    env "${LAUNCH_ENV[@]+"${LAUNCH_ENV[@]}"}" \
      "$LAUNCH_BINARY" "${LAUNCH_ARGS[@]+"${LAUNCH_ARGS[@]}"}" \
      "${extra_args[@]+"${extra_args[@]}"}" \
      "${launch_args[@]+"${launch_args[@]}"}" >>"$LAUNCH_LOG" 2>&1
    status=$?
    set -e

    [ "$status" -eq 0 ] && break
    ran=$(( $(date +%s) - started ))

    # Dying before a window appears, on macOS, is the version-against-OS failure
    # rather than a flaky run. Record it so the next launch says so up front, and
    # name the way that does work instead of retrying into the same wall.
    if [ "$ran" -lt 5 ] && [ "$noted_bad" -eq 0 ] && [ "$SEL_ENGINE" = "chromium" ] \
       && [ "$(uname -s)" = "Darwin" ] && [ -n "$SEL_MILESTONE" ] \
       && [ "$SEL_MILESTONE" != "?" ]; then
      noted_bad=1
      remember_native_bad "$SEL_MILESTONE"
      suggest_container "$SEL_MILESTONE"
    fi

    if [ "$auto_restart" -eq 0 ]; then
      warn "$label exited with status $status after ${ran}s. Last lines of $LAUNCH_LOG:"
      tail -n 15 "$LAUNCH_LOG" >&2 || true
      exit "$status"
    fi

    attempt=$((attempt + 1))
    if [ "$ran" -lt 5 ]; then fast_crashes=$((fast_crashes + 1)); else fast_crashes=0; fi
    if [ "$fast_crashes" -ge 3 ] || [ "$attempt" -gt "$max_restarts" ]; then
      warn "$label crashed after ${ran}s (status $status), giving up after $attempt attempt(s)."
      warn "Last lines of $LAUNCH_LOG:"
      tail -n 15 "$LAUNCH_LOG" >&2 || true
      exit "$status"
    fi

    warn "$label crashed after ${ran}s - restarting ($attempt/$max_restarts)."
    # Restoring the session is a Chromium switch; Firefox does it by itself and
    # would show an unknown-argument dialog instead.
    case "$SEL_ENGINE" in
      chromium|edge) launch_args=(--restore-last-session) ;;
    esac
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
${B}EngineShelf${RST} - run an old Chromium engine on a modern machine

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
so newly released Chromium versions work without updating EngineShelf.

Options for run:
  --size WxH                 Fixed window size, e.g. --size 1280x800
  --gpu / --no-gpu           Force hardware acceleration on or off
  --no-restart               Do not relaunch after a crash
  -- <flags>                 Everything after -- goes to Chromium

Each version keeps its own profile, so a newer build never upgrades a profile
out from under an older one.

Files live in $ROOT (override with ENGINESHELF_HOME).
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
