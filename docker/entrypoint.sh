#!/bin/bash
# Brings up X, a window manager, VNC and noVNC, then runs the browser build in
# this image in the foreground. Which browser that is comes from ENGINE, set by
# the image: the desktop is the same either way, the command line is not. If the
# browser dies the loop restarts it, so a crash
# does not leave the container up with an empty desktop.
set -u

cleanup() { kill $(jobs -p) 2>/dev/null; }
trap cleanup EXIT

# Docker sends SIGTERM to this process and to nothing else. The browser is the one
# that has to hear about it: killed outright it leaves a lock behind in the
# profile volume, and the next start of this version dies on "the profile appears
# to be in use by another Chromium process".
stopping=0
browser_pid=""
term() {
  stopping=1
  [ -n "$browser_pid" ] && kill -TERM "$browser_pid" 2>/dev/null
  return 0
}
trap term TERM INT

Xvfb "$DISPLAY" -screen 0 "$SCREEN" -nolisten tcp &
for i in $(seq 1 50); do
  [ -e "/tmp/.X11-unix/X${DISPLAY#:}" ] && break
  sleep 0.2
done

fluxbox -log /dev/null >/dev/null 2>&1 &
x11vnc -display "$DISPLAY" -forever -shared -nopw -quiet -bg >/dev/null 2>&1

# Text arriving from the browser tab is written to the X selections by x11vnc,
# but an old Chromium reads PRIMARY or CLIPBOARD depending on how the paste was
# asked for. autocutsel keeps the two in step through the cut buffer, so it does
# not matter which one the build in this image happens to look at.
# Backgrounded by the shell rather than with autocutsel's own -fork, which does
# not return here and left the container up with no websockify and no browser.
autocutsel -selection CLIPBOARD >/dev/null 2>&1 &
autocutsel -selection PRIMARY >/dev/null 2>&1 &

websockify --web=/usr/share/novnc 6080 localhost:5900 >/dev/null 2>&1 &

mkdir -p /data/profile

# One container per volume, by design - so any lock still sitting here belongs to
# a container that is already gone, whatever it says. Chromium reads the hostname
# out of it, sees a machine that is not this one, and refuses to start rather than
# risk two browsers on one profile; that left a version permanently unstartable
# after one hard stop, a reboot or a crash.
# Chromium only: WebKit's MiniBrowser keeps no such lock and has no profile flag.
if [ "${ENGINE:-chromium}" = "chromium" ]; then
  rm -f /data/profile/SingletonLock /data/profile/SingletonCookie \
        /data/profile/SingletonSocket
fi

# Fill the virtual screen exactly. --start-maximized leaves a gap under fluxbox,
# and every pixel of viewport matters when the point is checking layout.
WIDTH=${SCREEN%%x*}
REST=${SCREEN#*x}
HEIGHT=${REST%%x*}

# Everything above is the same desktop whatever is going to run on it. What the
# browser is, and what it wants on its command line, is not - so it is decided
# here, once, the same split the native launcher makes in lib/engines.sh.
case "${ENGINE:-chromium}" in
  webkit)
    BROWSER_NAME="WebKit"
    BROWSER_BIN=/opt/webkit/pw_run.sh
    # The MiniBrowser takes no profile flag - its state lives beside the bundle,
    # which is per-image already - and none of the Chromium switches below exist
    # for it. It also has no window-size flag; fluxbox and the Xvfb screen decide.
    BROWSER_ARGS=()
    ;;
  *)
    BROWSER_NAME="Chromium"
    BROWSER_BIN=/opt/chrome-linux/chrome
    BROWSER_ARGS=(
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
    ;;
esac

# The port printed here is the one inside the container; the launcher publishes
# it on a free host port and prints that, which is the URL to open.
echo "$BROWSER_NAME r${REVISION:-?} is up on container port 6080 (/vnc.html?autoconnect=1&resize=scale)"
echo "To reach a dev server on your machine use http://host.docker.internal:<port>"
echo "Clipboard: the host's copy and paste shortcuts work in the browser tab."

attempt=0
while :; do
  started=$(date +%s)
  # Backgrounded so the shell stays responsive to signals while it runs; a
  # foreground child would make bash sit on the SIGTERM until Chromium exited on
  # its own, which is exactly the ten seconds Docker waits before SIGKILL.
  "$BROWSER_BIN" "${BROWSER_ARGS[@]+"${BROWSER_ARGS[@]}"}" "$@" &
  browser_pid=$!
  wait "$browser_pid"
  status=$?
  if [ "$stopping" = "1" ]; then
    # Let it finish writing the profile out. Docker allows ten seconds; this
    # asks for eight of them and gives up quietly.
    for _ in $(seq 1 40); do
      kill -0 "$browser_pid" 2>/dev/null || break
      sleep 0.2
    done
    echo "Stopped."
    break
  fi
  ran=$(( $(date +%s) - started ))
  [ "$status" -eq 0 ] && break
  attempt=$((attempt + 1))
  if [ "$ran" -lt 5 ] && [ "$attempt" -ge 3 ]; then
    echo "$BROWSER_NAME keeps failing to start (status $status). Giving up." >&2
    exit "$status"
  fi
  echo "$BROWSER_NAME exited with status $status after ${ran}s — restarting." >&2
  set -- --restore-last-session
done
