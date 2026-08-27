#!/usr/bin/env bash
#
# EngineShelf - Docker edition (macOS / Linux)
#
# Runs the Linux x86_64 build of a browser inside a container and shows its
# desktop in a tab of your normal browser.
#
# All four engines, and why a container earns its gigabyte differs for each.
# Chromium, because it never goes through Rosetta and so inherits neither of the
# crashes Rosetta causes on Apple Silicon. Edge, because the enterprise feed that
# serves mac and Windows keeps about six months while the Linux package pool has
# kept every build since 2021 - for an old Edge this is the only way in at all.
# WebKit, because Playwright pins a different revision for older macOS releases
# and deletes what it no longer needs: r1860 (WebKit 16.4) is still published for
# Linux and has no macOS archive. Firefox, because one desktop that runs all four
# is worth more than four ways to run three.
#
#   ./engineshelf-docker.sh start 74            # build if needed, run, open it
#   ./engineshelf-docker.sh start webkit:16.4   # a version no Mac can run natively
#   ./engineshelf-docker.sh build 74            # build the image and stop there
#   ./engineshelf-docker.sh stop 74             # stop the container
#   ./engineshelf-docker.sh logs 74             # follow its log
#   ./engineshelf-docker.sh list                # what is running
#   ./engineshelf-docker.sh rebuild 74          # rebuild the image from scratch
#   ./engineshelf-docker.sh purge 74            # delete that version's image
#
# Each version gets its own image, container, profile volume and port, so several
# can run side by side.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CATALOG="$SCRIPT_DIR/catalog.tsv"
# The other half of the catalog. Milestones resolved against the live archive land
# here, and reading only the shipped file is what made a container look impossible
# for every milestone nobody had catalogued by hand.
CATALOG_CACHE="${ENGINESHELF_HOME:-${BROWSERS_EMU_HOME:-$HOME/.engineshelf}}/catalog.cache.tsv"
# shellcheck source=lib/preflight.sh
. "$SCRIPT_DIR/lib/preflight.sh"
DOCKER_DIR="$SCRIPT_DIR/docker"
BASE_PORT=6080

if [ -t 1 ]; then
  B=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GRN=$'\033[32m'; RST=$'\033[0m'
else
  B=''; DIM=''; RED=''; GRN=''; RST=''
fi
die() { printf '%s\n' "${RED}x  $*${RST}" >&2; exit 1; }
warn() { printf '%s\n' "${DIM}!  $*${RST}" >&2; }

# Sourced after those, so the coloured versions above are the ones it uses. This
# is where Firefox's and Edge's Linux downloads are resolved from - the same code
# the native launcher runs, rather than a second copy of each vendor's URLs.
# shellcheck source=lib/engines.sh
. "$SCRIPT_DIR/lib/engines.sh"

OS="$(uname -s)"

# ---------- docker availability ----------
# Install and start live in lib/preflight.sh so the CLI, this script and the
# manager all offer the same thing, in the same words, with the same consent.
ensure_docker() {
  pf_status_docker
  [ "$PF_STATUS" = "ok" ] && return 0

  if [ "$PF_STATUS" = "missing" ]; then
    echo ""
    echo "  ${B}The Docker edition needs Docker, which is not installed.${RST}"
    echo "  ${DIM}The native launcher needs nothing: ./engineshelf.sh run <version>${RST}"
  fi

  pf_offer docker || die "Docker is not available, so the Docker edition cannot run.
   Use the native launcher instead: ./engineshelf.sh run <version>"
}

# ---------- catalog ----------
# The container always runs the Linux x86_64 build, whatever this host is, so a
# selector naming a Mac or Windows revision still resolves to the right image.
# A selector names an engine and a version, the same as the native launcher:
# webkit:16.4, or a bare number for Chromium.
#
# Sets DOCKER_ENGINE, DOCKER_ID (what the vendor calls the build), DOCKER_KEY (the
# name the image, container and volume are built from) and DOCKER_VERSION (what to
# print). Chromium's key stays the bare revision it has always been, so images and
# containers already on this machine are still found - and so the manager, which
# parses those names, keeps working.
# Cache first, then the shipped catalog - the same precedence the native launcher
# uses, so the two cannot disagree about which revision a milestone is.
catalog_field() {       # awk args...
  local files=()
  [ -f "$CATALOG_CACHE" ] && files+=("$CATALOG_CACHE")
  [ -f "$CATALOG" ] && files+=("$CATALOG")
  [ "${#files[@]}" -gt 0 ] || return 0
  awk "$@" "${files[@]}"
}

resolve() {
  local raw="${1:-}" engine token milestone
  DOCKER_SELECTOR="$raw"
  [ -n "$raw" ] || die "\
Which version? A bare number is Chromium: 74. Otherwise name the engine:
   webkit:16.4   chromium:120
   Try: ./engineshelf.sh catalog"

  case "$raw" in
    *:*) engine="${raw%%:*}"; token="${raw#*:}" ;;
    *)   engine="chromium";   token="$raw" ;;
  esac
  engine="$(printf '%s' "$engine" | tr '[:upper:]' '[:lower:]')"
  # Only Firefox and Edge are handed a resolved download; this runs under
  # `set -u`, so it has to exist for the other two as well.
  DOCKER_URL=""

  case "$engine" in
    chromium) ;;
    webkit)   resolve_webkit_docker "$token"; return 0 ;;
    firefox|edge) resolve_linux_docker "$engine" "$token"; return 0 ;;
    *) die "Unknown engine: $engine. Known: $ENGINES" ;;
  esac

  token="${token#[MmRr]}"
  case "$token" in
    ''|*[!0-9]*) die "Not a Chromium version or revision: $raw" ;;
  esac

  if [ "$token" -lt 1000 ]; then
    milestone="$token"
  else
    milestone="$(catalog_field -F'\t' -v r="$token" '$1=="B" && $4==r {print $2; exit}')"
    if [ -z "$milestone" ]; then
      # An uncatalogued revision: assume the caller means that exact Linux build.
      DOCKER_ENGINE="chromium"; DOCKER_MILESTONE="?"
      DOCKER_VERSION="r$token"; DOCKER_REVISION="$token"
      DOCKER_ID="$token"; DOCKER_KEY="$token"
      return 0
    fi
  fi

  DOCKER_ENGINE="chromium"
  DOCKER_VERSION="$(catalog_field -F'\t' -v m="$milestone" '$1=="V" && $2==m {print $3; exit}')"
  DOCKER_REVISION="$(catalog_field -F'\t' -v m="$milestone" '$1=="B" && $2==m && $3=="Linux_x64" {print $4; exit}')"
  if [ -z "$DOCKER_REVISION" ]; then
    # Only twenty-odd milestones carry a hand-verified row, and the native
    # launcher has always asked the archive for the rest. This asks the same
    # question about the Linux build instead of refusing - which is what limited
    # the Docker edition to the catalogued milestones and nothing between them.
    info "  ${DIM}Chromium $milestone has no catalogued Linux build - asking the archive...${RST}"
    DOCKER_REVISION="$("$SCRIPT_DIR/engineshelf.sh" resolve-for Linux_x64 "$milestone" 2>/dev/null)" || true
    DOCKER_VERSION="$(catalog_field -F'\t' -v m="$milestone" '$1=="V" && $2==m {print $3; exit}')"
  fi
  [ -n "$DOCKER_REVISION" ] || die "\
No Linux x86_64 build of Chromium $milestone is available. It is in neither the
   catalog nor the cache, and the archive could not be reached to look it up."
  DOCKER_MILESTONE="$milestone"
  DOCKER_VERSION="${DOCKER_VERSION:-r$DOCKER_REVISION}"
  DOCKER_ID="$DOCKER_REVISION"
  DOCKER_KEY="$DOCKER_REVISION"
}

# WebKit is the one engine a container reaches further than the host can. Measured:
# r1860 (WebKit 16.4) is still published as webkit-ubuntu-22.04.zip and has no
# macOS archive at all, because Playwright pins a different revision for older
# macOS releases. So on a Mac this is not a slower alternative to the native
# launcher - for those versions it is the only way in.
resolve_webkit_docker() {
  local token="$1" revision
  case "$token" in
    ''|*[!0-9]*) revision="" ;;
    *)           [ "$token" -ge 1000 ] && revision="$token" || revision="" ;;
  esac
  if [ -z "$revision" ]; then
    revision="$(awk -F'\t' -v l="$token" \
      '$1=="S" && $2=="webkit" && ($5==l || $4==l) {r=$4} END {if (r) print r}' "$CATALOG")"
  fi
  [ -n "$revision" ] || die "\
No WebKit build known as $token.
   WebKit versions come from the shelf. Refresh it with:
       python3 tools/discover.py --write"

  DOCKER_ENGINE="webkit"
  DOCKER_ID="$revision"
  DOCKER_KEY="webkit-$revision"
  DOCKER_MILESTONE="?"
  DOCKER_REVISION="$revision"
  DOCKER_VERSION="$(awk -F'\t' -v r="$revision" \
    '$1=="S" && $2=="webkit" && $4==r {print $5; exit}' "$CATALOG")"
  DOCKER_VERSION="${DOCKER_VERSION:-r$revision}"
}

# Firefox and Edge, resolved against their Linux downloads.
#
# The URL is not built here. lib/engines.sh already knows that Mozilla switched
# from bzip2 to xz partway through and that Edge's Linux builds come from the apt
# pool rather than the enterprise feed - so it is asked, with the platform forced,
# and it answers. Two copies of that knowledge is how the container and the
# native launcher would come to disagree about which file is version 114.
#
# Worth saying plainly why Edge is here at all: the enterprise feed that serves
# mac and Windows holds about six months, so on those hosts the native launcher
# cannot reach Edge 114 or 95 at any price. The apt pool has kept every .deb
# since 2021. For old Edge this image is not an alternative, it is the only route.
resolve_linux_docker() {
  local engine="$1" token="$2" platform
  case "$engine" in
    firefox) platform="linux-x86_64" ;;
    edge)    platform="Linux_x64" ;;
  esac

  # Scoped to this one call: everything after it must see the host's own answer
  # again, or `list` would start describing a machine nobody is running.
  ENGINE_PLATFORM_OVERRIDE="$platform" resolve_engine "$engine" "$token"
  ENGINE_PLATFORM_OVERRIDE=""

  DOCKER_ENGINE="$engine"
  DOCKER_ID="$SEL_ID"
  DOCKER_KEY="$engine-$SEL_ID"
  DOCKER_MILESTONE="?"
  DOCKER_REVISION=""
  DOCKER_VERSION="$SEL_VERSION"
  DOCKER_URL="$SEL_URL"
}

# Which Dockerfile builds this engine, and what it needs told. Chromium and WebKit
# share the desktop and the entrypoint; they share nothing else, which is why they
# are two files rather than one with branches.
engine_dockerfile() {
  case "$1" in
    webkit)  printf '%s\n' "Dockerfile.webkit" ;;
    firefox) printf '%s\n' "Dockerfile.firefox" ;;
    edge)    printf '%s\n' "Dockerfile.edge" ;;
    *)       printf '%s\n' "Dockerfile" ;;
  esac
}

engine_label() {
  case "$1" in
    webkit)  printf 'WebKit\n' ;;
    firefox) printf 'Firefox\n' ;;
    edge)    printf 'Edge\n' ;;
    *)       printf 'Chromium\n' ;;
  esac
}

# What each Dockerfile needs told. Chromium and WebKit are addressed by revision
# and build their own URL; the other two are handed the one already resolved.
engine_build_args() {
  case "$1" in
    firefox) printf '%s\n' "FIREFOX_URL=$DOCKER_URL" "FIREFOX_VERSION=$DOCKER_VERSION" ;;
    edge)    printf '%s\n' "EDGE_URL=$DOCKER_URL" "EDGE_VERSION=$DOCKER_VERSION" ;;
    *)       printf '%s\n' "REVISION=$DOCKER_ID" ;;
  esac
}

# One build, however many --build-arg the engine needs. Fed through a while-read
# rather than word splitting, because a URL is one argument even if it ever grew
# a character the shell would split on.
build_image() {
  local image="$1"; shift
  local args=() line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    args+=(--build-arg "$line")
  done <<EOF
$(engine_build_args "$DOCKER_ENGINE")
EOF
  docker build "$@" --platform linux/amd64 \
    -f "$DOCKER_DIR/$(engine_dockerfile "$DOCKER_ENGINE")" \
    "${args[@]}" -t "$image" "$DOCKER_DIR"
}

# These three names are the whole contract between this script and the manager:
# gui/server.py reads them back to show which versions have an image, how much
# disk it costs and which containers are up, so a rename here has to happen
# there too (grep CONTAINER_PREFIX).
image_name()     { printf 'engineshelf:%s\n' "$1"; }
container_name() { printf 'engineshelf-%s\n' "$1"; }
volume_name()    { printf 'engineshelf-profile-%s\n' "$1"; }

# Ports are handed out per container; ask Docker what a running one actually got
# rather than recomputing and guessing wrong.
running_port() {
  docker port "$(container_name "$1")" 6080 2>/dev/null | head -n1 | sed 's/.*://'
}

free_port() {
  local port="${1:-$BASE_PORT}"
  while [ "$port" -lt $((BASE_PORT + 60)) ]; do
    if ! docker ps --format '{{.Ports}}' 2>/dev/null | grep -q ":$port->"; then
      if ! (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
        printf '%s\n' "$port"
        return 0
      fi
      exec 3<&- 2>/dev/null || true
    fi
    port=$((port + 1))
  done
  die "No free port between $BASE_PORT and $((BASE_PORT + 60))."
}

# Published on the loopback address only. The desktop in there has no password
# and a real browser attached to it, and the rest of EngineShelf is careful to
# stay off the network; a plain -p put it in front of everyone on the wifi.
#
# Between choosing a port and binding it another container can take it, and that
# is exactly what happens when two versions are started together: both saw 6080
# free, the second lost the race and reported "Could not start the container".
# Docker is the only thing that can answer for certain, so a refused binding
# moves up a port and tries again instead of ending the launch.
CONTAINER_PORT=""
start_container() {
  local image="$1" container="$2" volume="$3"
  local floor="$BASE_PORT" attempt port output
  for attempt in 1 2 3 4 5 6; do
    port="$(free_port "$floor")"
    if output="$(docker run -d --name "$container" --platform linux/amd64 \
        -p "127.0.0.1:$port:6080" \
        -v "$volume:/data" \
        --add-host "host.docker.internal:host-gateway" \
        --shm-size=1g \
        "$image" 2>&1)"; then
      CONTAINER_PORT="$port"
      return 0
    fi
    # A named container that failed to start still exists, and the next attempt
    # cannot reuse the name until it is gone.
    docker rm -f "$container" >/dev/null 2>&1 || true
    case "$output" in
      *"already allocated"*|*"address already in use"*|*"Bind for"*)
        floor=$((port + 1)) ;;
      *)
        printf '%s\n' "$output" >&2
        return 1 ;;
    esac
  done
  echo "  Every port tried was taken by something else." >&2
  return 1
}

open_url() {
  case "$OS" in
    Darwin) open "$1" 2>/dev/null || true ;;
    Linux)  xdg-open "$1" >/dev/null 2>&1 || true ;;
  esac
}

# ---------- commands ----------
cmd_start() {
  local build force_build="${2:-0}" image container volume port url
  resolve "${1:-}"
  ensure_docker

  image="$(image_name "$DOCKER_KEY")"
  container="$(container_name "$DOCKER_KEY")"
  volume="$(volume_name "$DOCKER_KEY")"

  # Already up? Just point the user at it again.
  if docker ps --format '{{.Names}}' | grep -qx "$container"; then
    port="$(running_port "$DOCKER_KEY")"
    url="http://localhost:$port/vnc.html?autoconnect=1&resize=scale"
    echo ""
    echo "  ${GRN}>${RST} ${B}$(engine_label "$DOCKER_ENGINE") $DOCKER_VERSION is already running${RST}  $url"
    open_url "$url"
    return 0
  fi
  docker rm -f "$container" >/dev/null 2>&1 || true

  echo ""
  # "r1217362" is a Chromium snapshot revision and a WebKit Playwright revision;
  # for the other two the id is the version, and printing "r95.0.1020.40" made it
  # look like a fourth kind of number.
  case "$DOCKER_ENGINE" in
    chromium|webkit) build="r$DOCKER_ID" ;;
    *)               build="$DOCKER_ID" ;;
  esac
  echo "  ${B}$(engine_label "$DOCKER_ENGINE") $DOCKER_VERSION in Docker${RST} ${DIM}(Linux x86_64 $build)${RST}"
  echo ""

  # Build only when the image is missing or a rebuild was asked for: under x86
  # emulation a from-scratch build is an eight-minute wait.
  if [ "$force_build" = "1" ]; then
    echo "  ${DIM}Rebuilding the image from scratch...${RST}"
    build_image "$image" --no-cache || die "Image build failed."
  elif ! docker image inspect "$image" >/dev/null 2>&1; then
    echo "  ${DIM}First run for this version: building the image. Several minutes, once.${RST}"
    build_image "$image" || die "Image build failed."
  fi

  start_container "$image" "$container" "$volume" || die "Could not start the container."
  port="$CONTAINER_PORT"

  url="http://localhost:$port/vnc.html?autoconnect=1&resize=scale"
  printf '  Waiting for the desktop'
  local ok=0 i
  for i in $(seq 1 60); do
    if curl -fsS -o /dev/null -m 2 "http://localhost:$port/vnc.html" 2>/dev/null; then ok=1; break; fi
    if ! docker ps --format '{{.Names}}' | grep -qx "$container"; then
      echo ""
      docker logs --tail 20 "$container" >&2 || true
      die "The container exited while starting."
    fi
    printf '.'
    sleep 1
  done
  echo ""
  [ "$ok" = "1" ] || die "No answer on port $port. Check: $0 logs $DOCKER_KEY"

  echo ""
  echo "  ${GRN}>${RST} ${B}$url${RST}"
  echo "  ${DIM}Copy and paste work across the tab in both directions.${RST}"
  echo "  ${DIM}To reach a dev server on this machine, type${RST}"
  echo "  ${DIM}http://host.docker.internal:4173 in the browser's address bar.${RST}"
  # The selector as typed, not the milestone: for WebKit there is no milestone,
  # and printing "stop ?" told nobody anything.
  echo "  ${DIM}Stop it with: $0 stop $DOCKER_SELECTOR${RST}"
  echo ""
  open_url "$url"
}

# Build the image and stop there. The native side has always been able to
# download without launching - a shelf you fill now and use later - and this is
# that, for the container: the eight-minute build happens when it suits, not in
# front of someone waiting for a browser.
cmd_build() {
  local force_build="${2:-0}" image
  resolve "${1:-}"
  ensure_docker
  image="$(image_name "$DOCKER_KEY")"

  echo ""
  echo "  ${B}$(engine_label "$DOCKER_ENGINE") $DOCKER_VERSION in Docker${RST} ${DIM}(image only)${RST}"
  echo ""
  if [ "$force_build" != "1" ] && docker image inspect "$image" >/dev/null 2>&1; then
    echo "${GRN}v${RST} The image is already built. Run it with: $0 start $DOCKER_SELECTOR"
    return 0
  fi
  if [ "$force_build" = "1" ]; then
    echo "  ${DIM}Rebuilding the image from scratch. Several minutes.${RST}"
    build_image "$image" --no-cache || die "Image build failed."
  else
    echo "  ${DIM}Building the image. Several minutes, once.${RST}"
    build_image "$image" || die "Image build failed."
  fi
  echo ""
  echo "${GRN}v${RST} Built. Nothing is running: $0 start $DOCKER_SELECTOR opens it."
}

# SIGTERM before SIGKILL, so the browser inside gets to close its profile. A
# container removed outright left a lock in the profile volume that stopped the
# next start of this version dead; the entrypoint clears a stale one now, but
# stopping politely is still the right way round.
cmd_stop() {
  resolve "${1:-}"
  ensure_docker
  local container; container="$(container_name "$DOCKER_KEY")"
  if docker ps --format '{{.Names}}' | grep -qx "$container"; then
    docker stop -t 12 "$container" >/dev/null 2>&1 || docker kill "$container" >/dev/null 2>&1 || true
    docker rm -f "$container" >/dev/null 2>&1 || true
    echo "${GRN}v${RST} Stopped $(engine_label "$DOCKER_ENGINE") $DOCKER_VERSION."
  elif docker rm -f "$container" >/dev/null 2>&1; then
    echo "${DIM}$(engine_label "$DOCKER_ENGINE") $DOCKER_VERSION was not running; cleared its stopped container.${RST}"
  else
    echo "${DIM}$(engine_label "$DOCKER_ENGINE") $DOCKER_VERSION was not running.${RST}"
  fi
}

cmd_logs() {
  resolve "${1:-}"
  ensure_docker
  docker logs -f "$(container_name "$DOCKER_KEY")"
}

cmd_list() {
  ensure_docker
  echo ""
  echo "${B}Containers${RST}"
  echo ""
  docker ps -a --filter "name=engineshelf-" \
    --format '  {{.Names}}\t{{.Status}}\t{{.Ports}}' || true
  echo ""
  echo "${B}Images${RST}"
  echo ""
  docker images "engineshelf" --format '  {{.Repository}}:{{.Tag}}\t{{.Size}}' || true
  echo ""
}

# Docker images are the other place disk quietly disappears, so make them
# removable from here too rather than sending people to raw docker commands.
cmd_purge() {
  resolve "${1:-}"
  ensure_docker
  docker rm -f "$(container_name "$DOCKER_KEY")" >/dev/null 2>&1 || true
  docker rmi -f "$(image_name "$DOCKER_KEY")" >/dev/null 2>&1 || true
  if [ "${2:-}" = "--with-profile" ]; then
    docker volume rm -f "$(volume_name "$DOCKER_KEY")" >/dev/null 2>&1 || true
  fi
  echo "${GRN}v${RST} Removed the Docker image for $(engine_label "$DOCKER_ENGINE") $DOCKER_VERSION."
}

usage() {
  # The whole leading comment block, which is the only place these commands are
  # written down. A fixed line range used to be printed instead, and it silently
  # cut the list in half the moment the block above it grew.
  sed -n '3,/^[^#]/p' "$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")" \
    | sed '$d; s/^# \{0,1\}//'
}

COMMAND="${1:-}"
[ $# -gt 0 ] && shift || true
case "$COMMAND" in
  start|up)      cmd_start "${1:-}" 0 ;;
  build|get)     cmd_build "${1:-}" 0 ;;
  rebuild)       cmd_start "${1:-}" 1 ;;
  stop|down)     cmd_stop "${1:-}" ;;
  logs)          cmd_logs "${1:-}" ;;
  list|ls|ps)    cmd_list ;;
  purge)         cmd_purge "${1:-}" "${2:-}" ;;
  ''|-h|--help)  usage ;;
  *)             die "Unknown command: $COMMAND (try --help)" ;;
esac
