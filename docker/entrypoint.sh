#!/bin/bash
# Brings up X, a window manager, VNC and noVNC, then runs Chromium 74 in the
# foreground. If Chromium dies the loop restarts it, so a crash does not leave
# the container up with an empty desktop.
set -u

cleanup() { kill $(jobs -p) 2>/dev/null; }
trap cleanup EXIT

Xvfb "$DISPLAY" -screen 0 "$SCREEN" -nolisten tcp &
for i in $(seq 1 50); do
  [ -e "/tmp/.X11-unix/X${DISPLAY#:}" ] && break
  sleep 0.2
done

fluxbox -log /dev/null >/dev/null 2>&1 &
x11vnc -display "$DISPLAY" -forever -shared -nopw -quiet -bg >/dev/null 2>&1
websockify --web=/usr/share/novnc 6080 localhost:5900 >/dev/null 2>&1 &

mkdir -p /data/profile

# Fill the virtual screen exactly. --start-maximized leaves a gap under fluxbox,
# and every pixel of viewport matters when the point is checking layout.
WIDTH=${SCREEN%%x*}
REST=${SCREEN#*x}
HEIGHT=${REST%%x*}

CHROME_ARGS=(
  --user-data-dir=/data/profile
  --no-first-run
  --no-default-browser-check
  --no-sandbox                      # no user namespaces inside a plain container
  # Silences the "unsupported command-line flag: --no-sandbox" infobar, which
  # would otherwise steal ~45px of viewport height from every page.
  --test-type
  --disable-background-networking   # the 2019 update pinger is long dead
  --disable-component-update
  --disable-features=TranslateUI
  --window-position=0,0
  "--window-size=${WIDTH},${HEIGHT}"
)

echo "Chromium 74 is up — open http://localhost:6080/vnc.html?autoconnect=1&resize=scale"
echo "To reach a dev server on your machine use http://host.docker.internal:<port>"

attempt=0
while :; do
  started=$(date +%s)
  /opt/chrome-linux/chrome "${CHROME_ARGS[@]}" "$@"
  status=$?
  ran=$(( $(date +%s) - started ))
  [ "$status" -eq 0 ] && break
  attempt=$((attempt + 1))
  if [ "$ran" -lt 5 ] && [ "$attempt" -ge 3 ]; then
    echo "Chromium keeps failing to start (status $status). Giving up." >&2
    exit "$status"
  fi
  echo "Chromium exited with status $status after ${ran}s — restarting." >&2
  set -- --restore-last-session
done
