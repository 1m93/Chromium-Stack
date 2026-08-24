#!/usr/bin/env bash
#
# ChromiumStack - dependency checks, shared by the CLI, the Docker launcher and
# the manager.
#
# Sourced, never run directly:
#   . "$SCRIPT_DIR/lib/preflight.sh"
#
# Everything here answers three questions about one component: is it there, does
# this machine even need it, and what exact command would install it. Nothing is
# ever installed without the caller asking first - pf_offer prints the command it
# would run and waits for a yes.
#
# Components:
#   python3   the manager is written in it; the CLI does not need it
#   curl      downloads the browser archives
#   unzip     extracts them on Linux (macOS uses ditto; python3 also works)
#   docker    the Docker edition only
#   rosetta   Apple Silicon running the x86_64 builds (milestones up to 90)

# ---------- presentation ----------
if [ -t 1 ]; then
  PF_B=$'\033[1m'; PF_DIM=$'\033[2m'; PF_RED=$'\033[31m'
  PF_GRN=$'\033[32m'; PF_YLW=$'\033[33m'; PF_RST=$'\033[0m'
else
  PF_B=''; PF_DIM=''; PF_RED=''; PF_GRN=''; PF_YLW=''; PF_RST=''
fi

pf_have() { command -v "$1" >/dev/null 2>&1; }
pf_is_mac() { [ "$(uname -s)" = "Darwin" ]; }
pf_is_arm_mac() { pf_is_mac && [ "$(uname -m)" = "arm64" ]; }

# A question can only be asked where someone can answer it. A terminal counts,
# and so does a pipe carrying a scripted answer; the manager runs these with
# stdin on /dev/null, which counts as neither - it must be told it cannot ask
# rather than block forever on a prompt nobody will see.
pf_interactive() { [ -t 0 ] || [ -p /dev/stdin ] || [ -f /dev/stdin ]; }

pf_confirm() {
  local answer=""
  pf_interactive || return 1
  printf '  %s [y/N]: ' "$1"
  read -r answer || return 1        # end of input means no
  case "$answer" in [yY]*) return 0 ;; *) return 1 ;; esac
}

# ---------- linux package manager ----------
pf_linux_install_cmd() {
  local package="$1"
  if pf_have apt-get;   then printf 'sudo apt-get install -y %s\n' "$package"
  elif pf_have dnf;     then printf 'sudo dnf install -y %s\n' "$package"
  elif pf_have yum;     then printf 'sudo yum install -y %s\n' "$package"
  elif pf_have pacman;  then printf 'sudo pacman -S --noconfirm %s\n' "$package"
  elif pf_have zypper;  then printf 'sudo zypper install -y %s\n' "$package"
  elif pf_have apk;     then printf 'sudo apk add %s\n' "$package"
  else return 1
  fi
}

# ---------- per component: status, why, and the fix ----------
# pf_status_<name> sets PF_STATUS to ok | missing | inactive | na
#   ok        present and usable
#   missing   not installed
#   inactive  installed but not running (docker)
#   na        this machine does not need it

pf_status_python3() {
  if pf_have python3; then PF_STATUS=ok; return; fi
  if pf_have python && python -c 'import sys; sys.exit(0 if sys.version_info[0] == 3 else 1)' 2>/dev/null; then
    PF_STATUS=ok; return
  fi
  PF_STATUS=missing
}

pf_status_curl() { pf_have curl && PF_STATUS=ok || PF_STATUS=missing; }

pf_status_unzip() {
  # macOS extracts with ditto, which is part of the OS; python3 can stand in
  # elsewhere. So unzip is only genuinely required on Linux without python3.
  if pf_is_mac; then PF_STATUS=na; return; fi
  if pf_have unzip; then PF_STATUS=ok; return; fi
  if pf_have python3; then PF_STATUS=na; return; fi
  PF_STATUS=missing
}

pf_status_docker() {
  if ! pf_have docker; then PF_STATUS=missing; return; fi
  if docker info >/dev/null 2>&1; then PF_STATUS=ok; else PF_STATUS=inactive; fi
}

pf_status_rosetta() {
  pf_is_arm_mac || { PF_STATUS=na; return; }
  # Actually running an x86_64 binary is the only answer that means anything;
  # checking for the oahd process reports false negatives on a fresh boot.
  if arch -x86_64 /usr/bin/true >/dev/null 2>&1; then PF_STATUS=ok; else PF_STATUS=missing; fi
}

pf_label() {
  case "$1" in
    python3) printf 'Python 3\n' ;;
    curl)    printf 'curl\n' ;;
    unzip)   printf 'unzip\n' ;;
    docker)  printf 'Docker\n' ;;
    rosetta) printf 'Rosetta 2\n' ;;
  esac
}

pf_need() {   # required | recommended | optional
  case "$1" in
    curl)    printf 'required\n' ;;
    unzip)   printf 'required\n' ;;
    python3) printf 'recommended\n' ;;
    rosetta) printf 'recommended\n' ;;
    docker)  printf 'optional\n' ;;
  esac
}

pf_why() {
  case "$1" in
    python3) printf 'Runs the graphical manager. The command line works without it.\n' ;;
    curl)    printf 'Downloads the browser archives. Nothing can be installed without it.\n' ;;
    unzip)   printf 'Extracts the downloaded archives on Linux.\n' ;;
    docker)  printf 'Only for the Docker edition, which avoids Rosetta on Apple Silicon.\n' ;;
    rosetta) printf 'Runs the x86_64 builds - every milestone up to 90 - on Apple Silicon.\n' ;;
  esac
}

# The exact command that would be run. Empty means this cannot be fixed
# automatically here, and the caller should say so instead of pretending.
pf_fix_cmd() {
  local component="$1" status="${2:-}"
  case "$component" in
    python3)
      if pf_is_mac; then
        if pf_have brew; then printf 'brew install python\n'; else printf 'xcode-select --install\n'; fi
      else
        pf_linux_install_cmd python3 || true
      fi
      ;;
    curl)
      pf_is_mac && return 0        # part of macOS; if it is gone something is very wrong
      pf_linux_install_cmd curl || true
      ;;
    unzip)
      pf_linux_install_cmd unzip || true
      ;;
    rosetta)
      printf 'softwareupdate --install-rosetta --agree-to-license\n'
      ;;
    docker)
      if [ "$status" = "inactive" ]; then
        if pf_have colima; then printf 'colima start\n'
        elif pf_is_mac && [ -d /Applications/Docker.app ]; then printf 'open -a Docker\n'
        elif pf_have systemctl; then printf 'sudo systemctl start docker\n'
        fi
        return 0
      fi
      if pf_is_mac; then
        # Colima and the docker CLI, never Docker Desktop: both are open source,
        # there is no licence to check, and nothing installs a background app.
        pf_have brew && printf 'brew install colima docker\n'
      else
        # Docker Engine and the CLI from Docker's own script - again, no Desktop.
        printf 'curl -fsSL https://get.docker.com | sudo sh\n'
      fi
      ;;
  esac
}

# Extra warning shown next to the offer, where the command has consequences
# beyond installing a package. Takes the status too: what is worth saying about
# installing Docker is not what is worth saying about starting it.
pf_fix_note() {
  local component="$1" status="${2:-}"
  case "$component" in
    rosetta) printf 'Asks for your password. A few hundred MB from Apple.\n' ;;
    docker)
      if [ "$status" = "inactive" ]; then
        printf 'Starts the daemon. First start of a colima VM takes about a minute.\n'
      elif pf_is_mac; then
        printf 'Colima and the docker CLI, not Docker Desktop. A few hundred MB via Homebrew.\n'
      else
        printf 'Docker Engine and the CLI, not Docker Desktop. Needs sudo, and you may have to log out and back in afterwards.\n'
      fi
      ;;
    python3) pf_is_mac && ! pf_have brew && printf 'Opens the Apple installer dialog for the command line tools.\n' ;;
  esac
}

PF_COMPONENTS="curl unzip python3 rosetta docker"

# ---------- reporting ----------
pf_symbol() {
  case "$1" in
    ok)       printf '%s\n' "${PF_GRN}ok${PF_RST}" ;;
    missing)  printf '%s\n' "${PF_RED}missing${PF_RST}" ;;
    inactive) printf '%s\n' "${PF_YLW}not running${PF_RST}" ;;
    na)       printf '%s\n' "${PF_DIM}not needed${PF_RST}" ;;
  esac
}

# Sets PF_PROBLEMS to the components that are missing or inactive.
pf_scan() {
  local component
  PF_PROBLEMS=""
  for component in $PF_COMPONENTS; do
    "pf_status_$component"
    eval "PF_RESULT_$component=\$PF_STATUS"
    case "$PF_STATUS" in
      missing|inactive) PF_PROBLEMS="$PF_PROBLEMS $component" ;;
    esac
  done
  PF_PROBLEMS="${PF_PROBLEMS# }"
}

pf_report() {
  local component status
  pf_scan
  printf '\n%s\n\n' "${PF_B}System check${PF_RST} ${PF_DIM}($(uname -s) $(uname -m))${PF_RST}"
  for component in $PF_COMPONENTS; do
    eval "status=\$PF_RESULT_$component"
    printf '  %-11s %-22b %s\n' "$(pf_label "$component")" "$(pf_symbol "$status")" \
      "${PF_DIM}$(pf_need "$component")${PF_RST}"
  done
  printf '\n'
  if [ -z "$PF_PROBLEMS" ]; then
    printf '  %s\n\n' "${PF_GRN}Everything ChromiumStack needs is present.${PF_RST}"
    return 0
  fi
  for component in $PF_PROBLEMS; do
    eval "status=\$PF_RESULT_$component"
    printf '  %s %s\n' "${PF_B}$(pf_label "$component")${PF_RST}" "${PF_DIM}- $(pf_why "$component")${PF_RST}"
  done
  printf '\n'
  return 1
}

# ---------- fixing ----------
# pf_offer <component> [--yes]
# Prints exactly what it would run, asks, then runs it. Returns 0 only if the
# component ends up usable.
pf_offer() {
  local component="$1" assume_yes="${2:-}" status command note
  "pf_status_$component"
  status="$PF_STATUS"

  case "$status" in
    ok) printf '  %s %s is already there.\n' "${PF_GRN}ok${PF_RST}" "$(pf_label "$component")"; return 0 ;;
    na) printf '  %s is not needed on this machine.\n' "$(pf_label "$component")"; return 0 ;;
  esac

  command="$(pf_fix_cmd "$component" "$status")"
  if [ -z "$command" ]; then
    printf '  %s %s cannot be installed automatically here.\n' "${PF_RED}x${PF_RST}" "$(pf_label "$component")" >&2
    case "$component" in
      python3) printf '     Install Python 3 from https://www.python.org/downloads/ and try again.\n' >&2 ;;
      docker)
        if pf_is_mac; then
          printf '     Install Homebrew from https://brew.sh, then: brew install colima docker\n' >&2
        else
          printf '     Install Docker Engine: curl -fsSL https://get.docker.com | sudo sh\n' >&2
        fi
        printf '     The native launcher needs none of this: ./chromium-stack.sh run 74\n' >&2
        ;;
    esac
    return 1
  fi

  printf '\n  %s %s\n' "${PF_B}$(pf_label "$component")${PF_RST}" "${PF_DIM}- $(pf_why "$component")${PF_RST}"
  printf '  This will run:\n    %s\n' "${PF_DIM}${command}${PF_RST}"
  note="$(pf_fix_note "$component" "$status")"
  [ -n "$note" ] && printf '  %s\n' "${PF_DIM}${note}${PF_RST}"
  printf '\n'

  if [ "$assume_yes" != "--yes" ]; then
    if ! pf_interactive; then
      printf '  %s Cannot ask for confirmation without a terminal.\n' "${PF_YLW}!${PF_RST}" >&2
      printf '     Run this yourself, or: ./chromium-stack.sh doctor --fix\n' >&2
      return 1
    fi
    pf_confirm "Run it now?" || { printf '  Nothing was installed.\n'; return 1; }
  fi

  if ! pf_run_fix "$component" "$command"; then
    printf '  %s That command did not complete. See its output above.\n' "${PF_RED}x${PF_RST}" >&2
    return 1
  fi

  # Docker's daemon takes a moment to answer after being started. Only worth
  # waiting for when something was actually started - a fresh install of colima
  # and the CLI leaves no daemon to wait for.
  if [ "$component" = "docker" ] && [ "$status" = "inactive" ]; then
    printf '  Waiting for the Docker daemon'
    local i
    for i in $(seq 1 90); do
      if docker info >/dev/null 2>&1; then printf '\n'; break; fi
      printf '.'
      sleep 1
    done
    printf '\n'
  fi

  # Installing colima and the CLI gets you as far as having them; the next thing
  # needed is colima start. Offer it now rather than making the user run
  # doctor --fix again to be told the obvious. Once only, so a daemon that
  # refuses to come up cannot turn into a loop.
  if [ "$component" = "docker" ] && [ "$status" = "missing" ] && [ -z "${PF_DOCKER_CHAINED:-}" ]; then
    pf_status_docker
    if [ "$PF_STATUS" = "inactive" ]; then
      PF_DOCKER_CHAINED=1
      pf_offer docker "$assume_yes"
      return $?
    fi
  fi

  "pf_status_$component"
  if [ "$PF_STATUS" = "ok" ]; then
    printf '  %s %s is ready.\n\n' "${PF_GRN}ok${PF_RST}" "$(pf_label "$component")"
    return 0
  fi
  printf '  %s %s still is not usable.\n\n' "${PF_YLW}!${PF_RST}" "$(pf_label "$component")" >&2
  return 1
}

# ---------- running the fix ----------
# Some fixes need root. In a terminal sudo handles that; the manager has no
# terminal, so on macOS the only honest way to escalate is the system's own
# password dialog. Anywhere else, say plainly that a terminal is required
# instead of failing with "sudo: no tty present" halfway through.
pf_osa_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

pf_needs_root() {
  local component="$1" command="$2"
  [ "$component" = "rosetta" ] && return 0
  case "$command" in *sudo*) return 0 ;; esac
  return 1
}

pf_run_fix() {
  local component="$1" command="$2"

  if pf_needs_root "$component" "$command" && [ "${PF_GUI:-0}" = "1" ]; then
    if pf_is_mac && pf_have osascript; then
      # The password dialog holds the command's output until it exits, so in the
      # manager this is the only line in the log for a minute or two. Say why.
      printf '  Asking macOS for administrator rights. Output appears when it finishes.\n'
      osascript -e "do shell script \"$(pf_osa_escape "$command")\" with administrator privileges"
      return $?
    fi
    printf '  %s This needs administrator rights, which cannot be requested from here.\n' \
      "${PF_YLW}!${PF_RST}" >&2
    printf '     Run it in a terminal:  ./chromium-stack.sh doctor --fix\n' >&2
    return 1
  fi

  # Deliberately word-split: these are fixed strings from pf_fix_cmd, not input.
  sh -c "$command"
}

# ---------- machine-readable, for the manager ----------
pf_json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

pf_json() {
  local component status first=1
  pf_scan
  printf '{"os":"%s","arch":"%s","components":[' "$(uname -s | tr 'A-Z' 'a-z')" "$(uname -m)"
  for component in $PF_COMPONENTS; do
    eval "status=\$PF_RESULT_$component"
    [ "$first" -eq 1 ] || printf ','
    first=0
    printf '{"id":"%s","label":"%s","status":"%s","need":"%s","why":"%s","fix":"%s","note":"%s"}' \
      "$component" \
      "$(pf_json_escape "$(pf_label "$component")")" \
      "$status" \
      "$(pf_need "$component")" \
      "$(pf_json_escape "$(pf_why "$component")")" \
      "$(pf_json_escape "$(pf_fix_cmd "$component" "$status")")" \
      "$(pf_json_escape "$(pf_fix_note "$component" "$status")")"
  done
  printf ']}\n'
}
