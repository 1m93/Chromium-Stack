# A Chromium build with a minimal X desktop, reachable from any browser over noVNC.
#
# Why this exists next to the native launcher: on Apple Silicon the old x86_64
# builds run through Rosetta, whose stack unwinder makes them crash at random
# (see ../README.md -> Stability). This image runs the Linux x86_64 build instead.
#
# REVISION is supplied by chromium-stack-docker.sh from catalog.tsv, so one
# Dockerfile covers every catalogued version.
FROM --platform=linux/amd64 debian:bookworm-slim

ARG REVISION=638880

ENV DEBIAN_FRONTEND=noninteractive \
    DISPLAY=:0 \
    SCREEN=1440x900x24

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates wget unzip \
      xvfb x11vnc fluxbox novnc websockify \
      # autocutsel bridges PRIMARY and CLIPBOARD through the cut buffer. x11vnc
      # sets both when the browser tab sends text, but an old Chromium reads
      # whichever one it feels like, and without this a paste silently landed in
      # the selection nobody was reading.
      autocutsel \
      # xclip is here so the clipboard can be inspected from `docker exec` when
      # a paste does not arrive; it is 60 kB and saves guessing.
      xclip \
      # Chromium runtime dependencies, old builds and new
      libnss3 libatk1.0-0 libatk-bridge2.0-0 libcups2 libdrm2 libxkbcommon0 \
      libxcomposite1 libxdamage1 libxfixes3 libxrandr2 libgbm1 libasound2 \
      libpango-1.0-0 libcairo2 libatspi2.0-0 libgtk-3-0 libx11-xcb1 libxss1 \
      libglib2.0-0 libxshmfence1 \
      # libgconf's own link dependency, needed by the shim below
      libdbus-glib-1-2 \
      # fonts, including CJK, so non-Latin pages are not rendered as boxes
      fonts-liberation fonts-noto-cjk fonts-noto-color-emoji \
    && rm -rf /var/lib/apt/lists/*

# The oldest milestones link against libgconf-2.so.4, which Debian dropped after
# buster - without it Chromium 60 died at exec with status 127 the moment the
# container came up, which is the opposite of a fallback for the versions Rosetta
# cannot run reliably. Extracted rather than installed, so dpkg's view of the
# system stays honest, and registered with ldconfig rather than exported through
# LD_LIBRARY_PATH: Chromium re-execs its own helpers with a scrubbed environment,
# and those helpers were still failing to find it. A failure here is not fatal -
# every milestone from 70 on links against nothing this old.
RUN set -e; \
    url="https://archive.debian.org/debian/pool/main/g/gconf/libgconf-2-4_3.2.6-7_amd64.deb"; \
    if wget -q -O /tmp/gconf.deb "$url"; then \
      mkdir -p /opt/legacy-libs && dpkg -x /tmp/gconf.deb /opt/legacy-libs; \
      rm -f /tmp/gconf.deb; \
      echo /opt/legacy-libs/usr/lib/x86_64-linux-gnu > /etc/ld.so.conf.d/chromium-stack-legacy.conf; \
      ldconfig; \
    else \
      echo "WARNING: could not fetch libgconf-2-4; Chromium 60 and 65 will not start." >&2; \
    fi

# Kept in the environment so the container can say which build it is running -
# the log used to name 74 whatever revision was actually unpacked.
ENV REVISION=${REVISION}

RUN wget -q -O /tmp/chrome.zip \
      "https://commondatastorage.googleapis.com/chromium-browser-snapshots/Linux_x64/${REVISION}/chrome-linux.zip" \
    && unzip -q /tmp/chrome.zip -d /opt \
    && rm /tmp/chrome.zip \
    && chmod +x /opt/chrome-linux/chrome

# Dummy values silence the "Google API keys are missing" infobar, which also eats
# viewport height. Chromium only checks that they are set.
ENV GOOGLE_API_KEY=no \
    GOOGLE_DEFAULT_CLIENT_ID=no \
    GOOGLE_DEFAULT_CLIENT_SECRET=no

# The clipboard bridge. noVNC ships a clipboard side panel and nothing else: the
# host's Cmd-V or Ctrl-V is swallowed by the canvas, so text copied outside the
# tab could only get in by being pasted into that panel by hand. clipboard.js
# wires the two clipboards together; it needs the page's RFB object, which ui.js
# keeps inside an ES module, hence the one-line export onto window.
COPY clipboard.js /usr/share/novnc/app/clipboard.js
RUN set -e; \
    ui=/usr/share/novnc/app/ui.js; page=/usr/share/novnc/vnc.html; \
    grep -q '^export default UI;' "$ui" || { echo "noVNC layout changed: no export in ui.js" >&2; exit 1; }; \
    grep -q 'src="app/ui.js"' "$page" || { echo "noVNC layout changed: no ui.js tag in vnc.html" >&2; exit 1; }; \
    sed -i 's|^export default UI;|window.UI = UI;   /* ChromiumStack: app/clipboard.js needs the live RFB object */\nexport default UI;|' "$ui"; \
    sed -i 's|<script type="module" crossorigin="anonymous" src="app/ui.js"></script>|&\n    <script src="app/clipboard.js" defer></script>|' "$page"; \
    grep -q 'app/clipboard.js' "$page"

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# 6080 = noVNC over HTTP, 5900 = plain VNC for a native VNC client
EXPOSE 6080 5900
VOLUME /data

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
