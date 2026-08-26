#!/usr/bin/env bash
#
# ChromiumStack - open the graphical manager (macOS / Linux)
#
# Starts a small local web server and opens it in a window of its own. Nothing
# is installed and nothing listens outside this machine: the server binds to
# 127.0.0.1 and every request has to carry a token generated for this run.
#
# Closing the window quits the manager, the browsers it launched and any Docker
# containers it started.
#
#   ./gui.sh                # open the manager
#   ./gui.sh --port 8080    # use a specific port
#   ./gui.sh --tab          # a tab in your default browser instead of a window
#   ./gui.sh --no-open      # start it but open nothing
#   ./gui.sh --keep-alive   # keep serving after the window closes
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/preflight.sh
. "$SCRIPT_DIR/lib/preflight.sh"

# The manager is written in Python, so it cannot be the thing that tells you
# Python is missing. That check has to happen out here, before it starts.
find_python() {
  if command -v python3 >/dev/null 2>&1; then
    PYTHON=python3
    return 0
  fi
  if command -v python >/dev/null 2>&1 &&
     python -c 'import sys; sys.exit(0 if sys.version_info[0] == 3 else 1)' 2>/dev/null; then
    PYTHON=python
    return 0
  fi
  return 1
}

if ! find_python; then
  printf '\n  %s\n\n' "${PF_B}The graphical manager needs Python 3, which is not installed.${PF_RST}"
  printf '  %s\n' "${PF_DIM}The command line does not need it:${PF_RST}"
  printf '  %s\n' "${PF_DIM}  ./chromium-stack.sh catalog${PF_RST}"
  printf '  %s\n' "${PF_DIM}  ./chromium-stack.sh run 74${PF_RST}"

  # Offer the install rather than leaving the user to work it out.
  if pf_offer python3 && find_python; then
    printf '  %s\n\n' "${PF_GRN}Starting the manager.${PF_RST}"
  else
    printf '\n  %s\n' "Run ./chromium-stack.sh doctor --fix once Python 3 is in place."
    exit 1
  fi
fi

exec "$PYTHON" "$SCRIPT_DIR/gui/server.py" "$@"
