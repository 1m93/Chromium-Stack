#!/usr/bin/env bash
#
# ChromiumStack - Docker edition (macOS / Linux)
#
# Runs the Linux x86_64 build of a Chromium version inside a container and shows
# its desktop in a tab of your normal browser. Slower than the native launcher,
# but it does not go through Rosetta, so it does not inherit the random crash
# Rosetta's stack unwinder causes on Apple Silicon.
#
#   ./chromium-stack-docker.sh start 74     # build if needed, run, open the desktop
#   ./chromium-stack-docker.sh stop 74      # stop the container
#   ./chromium-stack-docker.sh logs 74      # follow its log
#   ./chromium-stack-docker.sh list         # what is running
#   ./chromium-stack-docker.sh rebuild 74   # rebuild the image from scratch
#
# Each version gets its own image, container, profile volume and port, so several
# can run side by side.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CATALOG="$SCRIPT_DIR/catalog.tsv"
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
    echo "  ${DIM}The native launcher needs nothing: ./chromium-stack.sh run <version>${RST}"
  fi

  pf_offer docker || die "Docker is not available, so the Docker edition cannot run.
   Use the native launcher instead: ./chromium-stack.sh run <version>"
}

# ---------- catalog ----------
# The container always runs the Linux x86_64 build, whatever this host is, so a
# selector naming a Mac or Windows revision still resolves to the right image.
resolve() {
  local raw="${1:-}" token milestone
  [ -n "$raw" ] || die "Which version? e.g. 74. Try: ./chromium-stack.sh catalog"
  token="${raw#[MmRr]}"
  case "$token" in
    ''|*[!0-9]*) die "Not a version or revision: $raw" ;;
  esac

  if [ "$token" -lt 1000 ]; then
    milestone="$token"
  else
    milestone="$(awk -F'\t' -v r="$token" '$1=="B" && $4==r {print $2; exit}' "$CATALOG")"
    if [ -z "$milestone" ]; then
      # An uncatalogued revision: assume the caller means that exact Linux build.
      DOCKER_MILESTONE="?"; DOCKER_VERSION="r$token"; DOCKER_REVISION="$token"
      return 0
    fi
  fi

  DOCKER_VERSION="$(awk -F'\t' -v m="$milestone" '$1=="V" && $2==m {print $3; exit}' "$CATALOG")"
  DOCKER_REVISION="$(awk -F'\t' -v m="$milestone" '$1=="B" && $2==m && $3=="Linux_x64" {print $4; exit}' "$CATALOG")"
  [ -n "$DOCKER_REVISION" ] || die "No Linux x86_64 build of Chromium $milestone in the catalog."
  DOCKER_MILESTONE="$milestone"
  DOCKER_VERSION="${DOCKER_VERSION:-r$DOCKER_REVISION}"
}

image_name()     { printf 'chromium-stack:%s\n' "$1"; }
container_name() { printf 'chromium-stack-%s\n' "$1"; }
volume_name()    { printf 'chromium-stack-profile-%s\n' "$1"; }

# Ports are handed out per container; ask Docker what a running one actually got
# rather than recomputing and guessing wrong.
running_port() {
  docker port "$(container_name "$1")" 6080 2>/dev/null | head -n1 | sed 's/.*://'
}

free_port() {
  local port="$BASE_PORT"
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

open_url() {
  case "$OS" in
    Darwin) open "$1" 2>/dev/null || true ;;
    Linux)  xdg-open "$1" >/dev/null 2>&1 || true ;;
  esac
}

# ---------- commands ----------
cmd_start() {
  local force_build="${2:-0}" image container volume port url
  resolve "${1:-}"
  ensure_docker

  image="$(image_name "$DOCKER_REVISION")"
  container="$(container_name "$DOCKER_REVISION")"
  volume="$(volume_name "$DOCKER_REVISION")"

  # Already up? Just point the user at it again.
  if docker ps --format '{{.Names}}' | grep -qx "$container"; then
    port="$(running_port "$DOCKER_REVISION")"
    url="http://localhost:$port/vnc.html?autoconnect=1&resize=scale"
    echo ""
    echo "  ${GRN}>${RST} ${B}Chromium $DOCKER_VERSION is already running${RST}  $url"
    open_url "$url"
    return 0
  fi
  docker rm -f "$container" >/dev/null 2>&1 || true

  echo ""
  echo "  ${B}Chromium $DOCKER_VERSION in Docker${RST} ${DIM}(Linux_x64 r$DOCKER_REVISION)${RST}"
  echo ""

  # Build only when the image is missing or a rebuild was asked for: under x86
  # emulation a from-scratch build is an eight-minute wait.
  if [ "$force_build" = "1" ]; then
    echo "  ${DIM}Rebuilding the image from scratch...${RST}"
    docker build --no-cache --platform linux/amd64 \
      --build-arg "REVISION=$DOCKER_REVISION" -t "$image" "$DOCKER_DIR" || die "Image build failed."
  elif ! docker image inspect "$image" >/dev/null 2>&1; then
    echo "  ${DIM}First run for this version: building the image. Several minutes, once.${RST}"
    docker build --platform linux/amd64 \
      --build-arg "REVISION=$DOCKER_REVISION" -t "$image" "$DOCKER_DIR" || die "Image build failed."
  fi

  port="$(free_port)"
  docker run -d --name "$container" --platform linux/amd64 \
    -p "$port:6080" \
    -v "$volume:/data" \
    --add-host "host.docker.internal:host-gateway" \
    --shm-size=1g \
    "$image" >/dev/null || die "Could not start the container."

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
  [ "$ok" = "1" ] || die "No answer on port $port. Check: $0 logs $DOCKER_REVISION"

  echo ""
  echo "  ${GRN}>${RST} ${B}$url${RST}"
  echo "  ${DIM}To reach a dev server on this machine, type${RST}"
  echo "  ${DIM}http://host.docker.internal:4173 in the Chromium address bar.${RST}"
  echo "  ${DIM}Stop it with: $0 stop $DOCKER_MILESTONE${RST}"
  echo ""
  open_url "$url"
}

cmd_stop() {
  resolve "${1:-}"
  ensure_docker
  local container; container="$(container_name "$DOCKER_REVISION")"
  if docker rm -f "$container" >/dev/null 2>&1; then
    echo "${GRN}v${RST} Stopped Chromium $DOCKER_VERSION."
  else
    echo "${DIM}Chromium $DOCKER_VERSION was not running.${RST}"
  fi
}

cmd_logs() {
  resolve "${1:-}"
  ensure_docker
  docker logs -f "$(container_name "$DOCKER_REVISION")"
}

cmd_list() {
  ensure_docker
  echo ""
  echo "${B}Containers${RST}"
  echo ""
  docker ps -a --filter "name=chromium-stack-" \
    --format '  {{.Names}}\t{{.Status}}\t{{.Ports}}' || true
  echo ""
  echo "${B}Images${RST}"
  echo ""
  docker images "chromium-stack" --format '  {{.Repository}}:{{.Tag}}\t{{.Size}}' || true
  echo ""
}

# Docker images are the other place disk quietly disappears, so make them
# removable from here too rather than sending people to raw docker commands.
cmd_purge() {
  resolve "${1:-}"
  ensure_docker
  docker rm -f "$(container_name "$DOCKER_REVISION")" >/dev/null 2>&1 || true
  docker rmi -f "$(image_name "$DOCKER_REVISION")" >/dev/null 2>&1 || true
  if [ "${2:-}" = "--with-profile" ]; then
    docker volume rm -f "$(volume_name "$DOCKER_REVISION")" >/dev/null 2>&1 || true
  fi
  echo "${GRN}v${RST} Removed the Docker image for Chromium $DOCKER_VERSION."
}

usage() {
  sed -n '3,20p' "$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")" | sed 's/^# \{0,1\}//'
}

COMMAND="${1:-}"
[ $# -gt 0 ] && shift || true
case "$COMMAND" in
  start|up)      cmd_start "${1:-}" 0 ;;
  rebuild)       cmd_start "${1:-}" 1 ;;
  stop|down)     cmd_stop "${1:-}" ;;
  logs)          cmd_logs "${1:-}" ;;
  list|ls|ps)    cmd_list ;;
  purge)         cmd_purge "${1:-}" "${2:-}" ;;
  ''|-h|--help)  usage ;;
  *)             die "Unknown command: $COMMAND (try --help)" ;;
esac
