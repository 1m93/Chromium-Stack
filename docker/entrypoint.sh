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

# Through novnc-serve.py rather than the websockify CLI: it is that plus one
# response header. Every container's desktop is http://localhost:6080, and
# websockify serves noVNC's 2021 file dates with no Cache-Control at all - so a
# browser pins core/ from the first container it ever opened and links a rebuilt
# ui.js against it. See the file for the exact failure.
novnc-serve --web=/usr/share/novnc 6080 localhost:5900 >/dev/null 2>&1 &

mkdir -p /data/profile

# One container per volume, by design - so any lock still sitting here belongs to
# a container that is already gone, whatever it says. Chromium reads the hostname
# out of it, sees a machine that is not this one, and refuses to start rather than
# risk two browsers on one profile; that left a version permanently unstartable
# after one hard stop, a reboot or a crash.
# Chromium and Edge, which is Chromium: WebKit's MiniBrowser keeps no such lock
# and has no profile flag, and Firefox's own lock is a symlink it clears itself.
case "${ENGINE:-chromium}" in
  chromium|edge)
    rm -f /data/profile/SingletonLock /data/profile/SingletonCookie \
          /data/profile/SingletonSocket ;;
esac

# Fill the virtual screen exactly. --start-maximized leaves a gap under fluxbox,
# and every pixel of viewport matters when the point is checking layout.
WIDTH=${SCREEN%%x*}
REST=${SCREEN#*x}
HEIGHT=${REST%%x*}

# ---------- cameras, microphones, and the origin they are asked from ----------
#
# Two different things make a getUserMedia test fail in here, and they need
# different answers - which is why "the camera does not work in Docker" was one
# complaint covering two faults.
#
# No device. A container has whatever /dev nodes it was given and no others, and
# on macOS and Windows there is nothing to give: Docker Desktop runs this inside
# a Linux VM that has no USB passthrough, so a webcam plugged into the machine
# cannot reach it by any route. On a Linux host it can, and the launcher passes
# /dev/video* in when they exist. So the rule here is: use a real device if one
# arrived, and otherwise let Chromium's own fake camera stand in - a test page
# then reaches its own code with a stream in hand rather than dying on
# NotFoundError, which is the only useful thing that can be offered.
#
# The wrong origin. The dev server on the host is reached at
# http://host.docker.internal:<port>, and that is not a secure origin - so
# navigator.mediaDevices is undefined there, getUserMedia does not exist, and the
# page reports "no camera" when the real answer is "not localhost". Chromium is
# told to treat that host as secure, which is what localhost gets for free.
# INSECURE_ORIGINS overrides it; comma-separated, origins or hostname patterns.
MEDIA_ARGS=()
if ls /dev/video* >/dev/null 2>&1; then
  echo "Camera: $(ls -d /dev/video* | tr '\n' ' ')passed through from the host."
else
  # --use-fake-ui-for-media-stream as well: the permission prompt in a desktop
  # nobody is sitting in front of is one more click over VNC for an answer that
  # is always yes, and a fake camera has nothing to protect.
  MEDIA_ARGS+=(--use-fake-device-for-media-stream --use-fake-ui-for-media-stream)
  # A recording in the profile volume replaces the rolling test pattern, which
  # is the difference between "getUserMedia resolves" and actually testing what
  # the camera sees - a QR code, a document, a face. Put a file at
  # <volume>/camera.y4m and it becomes the camera, looped:
  #
  #   ffmpeg -f avfoundation -framerate 30 -i "0" -t 10 -pix_fmt yuv420p camera.y4m
  #   docker cp camera.y4m engineshelf-<revision>:/data/camera.y4m
  #
  # A regular file only. A fifo was the obvious way to pipe this machine's own
  # camera in live, and Chromium refuses one - it seeks back to loop, a pipe
  # cannot, and the request fails with NotFoundError rather than degrading.
  if [ -f /data/camera.y4m ]; then
    MEDIA_ARGS+=(--use-file-for-fake-video-capture=/data/camera.y4m)
    echo "Camera: /data/camera.y4m is the camera (looped)."
  else
    echo "Camera: no device reached this container - Chromium's fake camera stands in."
    echo "        Drop a .y4m recording at /data/camera.y4m to film something real."
  fi
fi

# A hostname pattern rather than a list of origins, and the difference matters:
# an origin includes its port, so a list can only ever cover the dev-server ports
# somebody thought of - 4173 and 5173 and 3000 - and the first person to run on
# 4291 is back to "no camera" with no way to tell why. The pattern form covers
# every port on the host, which is the whole of what host.docker.internal ever
# addresses. Measured, not assumed: with the list, a page on :4291 reported
# isSecureContext=false; with this, true.
# INSECURE_ORIGINS overrides it - that is the way to name a host reached some
# other way, an IP on the LAN say, which no pattern here can cover.
DEV_ORIGINS="${INSECURE_ORIGINS:-*.docker.internal}"

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
  firefox)
    BROWSER_NAME="Firefox"
    BROWSER_BIN=/opt/firefox/firefox
    # -profile takes one dash, and -no-remote stops a second launch from being
    # handed to the first instance instead of starting one. No window-size flag
    # worth having: fluxbox and the Xvfb screen decide, as they do for WebKit.
    BROWSER_ARGS=(-profile /data/profile -no-remote)
    # Firefox has no switch for either of the two above; both are prefs, and a
    # pref is only read out of the profile - so they are written into it here,
    # once, and left alone afterwards so anything changed in about:config
    # survives a restart.
    mkdir -p /data/profile
    if [ ! -e /data/profile/user.js ]; then
      {
        echo '// Written by EngineShelf on the container'"'"'s first start.'
        echo '// A dev server on the host is http://host.docker.internal:<port>,'
        echo '// which is not a secure origin - without these two, getUserMedia'
        echo '// and enumerateDevices are simply not there.'
        echo 'user_pref("media.devices.insecure.enabled", true);'
        echo 'user_pref("media.getusermedia.insecure.enabled", true);'
        if ! ls /dev/video* >/dev/null 2>&1; then
          echo '// No camera can reach a container on macOS or Windows, so this'
          echo '// stands one in rather than failing the request outright.'
          echo 'user_pref("media.navigator.streams.fake", true);'
          echo 'user_pref("media.navigator.permission.disabled", true);'
        fi
      } > /data/profile/user.js
    fi
    ;;
  edge)
    BROWSER_NAME="Edge"
    BROWSER_BIN=/opt/microsoft/msedge/msedge
    # Edge is Chromium, so it takes the Chromium switches - including the ones
    # that stop it from eating viewport height with infobars.
    BROWSER_ARGS=(
      --user-data-dir=/data/profile
      --no-first-run
      --no-default-browser-check
      --no-sandbox
      --test-type
      --disable-background-networking
      --disable-component-update
      --disable-features=TranslateUI,msEdgeWelcomePage
      --window-position=0,0
      "--window-size=${WIDTH},${HEIGHT}"
      "--unsafely-treat-insecure-origin-as-secure=${DEV_ORIGINS}"
      ${MEDIA_ARGS[@]+"${MEDIA_ARGS[@]}"}
    )
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
      "--unsafely-treat-insecure-origin-as-secure=${DEV_ORIGINS}"
      ${MEDIA_ARGS[@]+"${MEDIA_ARGS[@]}"}
    )
    ;;
esac

# Chromium and WebKit images are built from a revision, Firefox's and Edge's from
# a version. Whichever this image carries is what it says: it used to print
# "Firefox r?" for the two that have no revision, which reads like a fault.
BUILD_ID="${REVISION:+r$REVISION}"
BUILD_ID="${BUILD_ID:-${FIREFOX_VERSION:-${EDGE_VERSION:-?}}}"

# The port printed here is the one inside the container; the launcher publishes
# it on a free host port and prints that, which is the URL to open.
echo "$BROWSER_NAME $BUILD_ID is up on container port 6080 (/vnc.html?autoconnect=1&resize=scale)"
echo "To reach a dev server on your machine use http://host.docker.internal:<port>"
echo "Those origins are treated as secure, so getUserMedia and friends work there."
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
