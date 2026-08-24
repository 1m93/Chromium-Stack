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
      # Chromium runtime dependencies, old builds and new
      libnss3 libatk1.0-0 libatk-bridge2.0-0 libcups2 libdrm2 libxkbcommon0 \
      libxcomposite1 libxdamage1 libxfixes3 libxrandr2 libgbm1 libasound2 \
      libpango-1.0-0 libcairo2 libatspi2.0-0 libgtk-3-0 libx11-xcb1 libxss1 \
      libglib2.0-0 libxshmfence1 \
      # fonts, including CJK, so non-Latin pages are not rendered as boxes
      fonts-liberation fonts-noto-cjk fonts-noto-color-emoji \
    && rm -rf /var/lib/apt/lists/*

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

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# 6080 = noVNC over HTTP, 5900 = plain VNC for a native VNC client
EXPOSE 6080 5900
VOLUME /data

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
