#!/usr/bin/env python3
"""Re-take the manager screenshots the landing page ships.

The old ones were staged by hand, which is exactly why they went stale: by the
time the shelf held four engines they still showed a Chromium-only list, under
the project's previous name, with paths from a machine nobody has. Nothing could
regenerate them.

So the scene is scripted instead. A throwaway server answers the manager's own
API with a fixed state - the same shape gui/server.py returns, borrowed from it
so this cannot drift from the real thing - and headless Chromium photographs the
page twice, once per theme. Sizes and paths are constants, so re-running this
produces the same picture unless the page itself changed.

    python3 tools/make-screenshots.py [--keep]

Writes the landing page's pair (both themes) and the README's hero, all from the
same staged shelf so the three agree with each other.

Needs a Chromium to shoot with: whichever one EngineShelf has downloaded, or
Chrome. Pillow turns the PNGs into the WebPs the page prefers.
"""
import argparse
import glob
import http.server
import json
from urllib.parse import unquote
import os
import platform
import shutil
import socket
import subprocess
import sys
import threading

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.dirname(HERE)
GUI = os.path.join(PROJECT, "gui")

sys.path.insert(0, GUI)

TOKEN = "screenshot"

# Retina: the page is laid out at this size and captured at twice the density,
# which is what the <img width/height> on the landing page already declares.
WIDTH, HEIGHT, SCALE = 1400, 830, 2

# A believable machine rather than this one. Fixed so the image is reproducible
# and so nobody's home directory ends up on a public page.
ROOT = "/Users/you/.engineshelf"

# The three jobs the scene is about: two browsers open, one still downloading.
# Keyed by the selector the manager would have posted, because that is what a
# job carries and what the page matches rows on.
RUNNING = "firefox:115.0"
RUNNING_2 = "webkit:2336"
DOWNLOADING = "105"

# What is on this imaginary shelf, and how big. One per engine plus a second
# Chromium, so the list shows all four marks without becoming a wall.
INSTALLED = {
    "firefox:115.0": (376_000_000, 31_000_000),
    "webkit:2336": (294_000_000, 12_000_000),
    "edge:151.0.4129.107": (962_000_000, 15_000_000),
    "1217378": (285_000_000, 16_000_000),
}

# curl's plain meter, mid-download. Twelve columns, which is what the page parses:
#   %Total Total %Recd Recd %Xferd Xferd Dload Upload Total Spent Left Speed
METER = (
    " 43  232M   43 99.8M    0     0  8400k      0  0:00:28  0:00:12  0:00:16 9000k"
)


def job_output(label, platform_dir, phase):
    """The lines engineshelf.sh prints, in the order it prints them.

    Colours are off whenever stdout is not a tty, which is every launch the
    manager makes - so this is the plain text the page really parses.
    """
    lines = [
        "",
        f"Downloading {label} ({platform_dir}, one time only)",
        f"-> {ROOT}/builds/1027019",
        "",
        "  % Total    % Received % Xferd  Average Speed   Time    Time     Time  Current",
        "                                 Dload  Upload   Total   Spent    Left  Speed",
        METER,
    ]
    if phase == "downloading":
        return "\n".join(lines)
    lines += ["", "Extracting...", f"v {label} ready.", ""]
    lines += [f"  > {label} ({platform_dir})", "  > http://localhost:4173",
              f"  Profile: {ROOT}/profiles/x", f"  Log: {ROOT}/logs/x.log", ""]
    return "\n".join(lines)


# Output is filed against a log per version rather than per job, so each of these
# names the log it writes to and what that log is called - exactly what the page
# is handed by a real manager.
JOBS = {
    "1": {"kind": "launch", "revision": RUNNING, "label": "Firefox 115.0",
          "stream": "firefox:115.0", "streamLabel": "Firefox 115.0",
          "output": job_output("Firefox 115.0", "mac", "open")},
    "2": {"kind": "launch", "revision": RUNNING_2, "label": "WebKit 26.5",
          "stream": "webkit:2336", "streamLabel": "WebKit 26.5",
          "output": job_output("WebKit 26.5", "mac-26-arm64", "open")},
    "3": {"kind": "launch", "revision": DOWNLOADING, "label": "Chromium 105",
          "stream": "chromium:105", "streamLabel": "Chromium 105",
          "output": job_output("Chromium 105.0.5195.0", "Mac_Arm", "downloading")},
}


def staged_logs():
    """The log list the page builds its tab strip from."""
    return [{"key": j["stream"], "label": j["streamLabel"],
             "lines": len(j["output"].split("\n")),
             "updated": 0,
             "job": {"id": i, "kind": j["kind"], "revision": j["revision"],
                     "label": j["label"], "status": "running", "code": None,
                     "stream": j["stream"]}}
            for i, j in JOBS.items()]


def staged_state():
    """The real state document, with every volatile field replaced.

    Built from gui/server.py rather than written out by hand: the page reads
    dozens of fields and a hand-made fixture would quietly fall behind the first
    time one of them changed.
    """
    import server as backend                      # gui/server.py

    state = backend.build_state()
    state["root"] = ROOT
    state["os"] = "darwin"
    state["arch"] = "arm64"
    state["hostPlatforms"] = ["Mac_Arm", "Mac"]
    # Everything green: a system-check banner across the top of the shot would be
    # about this machine, not about the product.
    state["doctor"] = {"os": "darwin", "arch": "arm64", "components": []}
    # No containers in this scene: a second gigabyte-sized bar here only crowds
    # the disk card.
    state["docker"] = {"cli": True, "running": True, "containers": [],
                       "supported": True, "byRevision": {},
                       "imageBytes": 0, "profileBytes": 0}
    state["dockerBytes"] = 0

    browsers = profiles = 0
    for row in list(state["versions"]) + list(state["extra"]):
        row["docker"] = None
        held = INSTALLED.get(row["selector"])
        row["installed"] = held is not None
        row["sizeBytes"], row["profileBytes"] = held or (0, 0)
        row["installedAt"] = "2026-08-20T09:00:00Z" if held else ""
        if held:
            browsers += held[0]
            profiles += held[1]
    # Builds installed by raw revision are a real feature but a distraction here;
    # the scene is about what the shelf itself offers.
    state["extra"] = []
    state["installedCount"] = len(INSTALLED)
    state["browserBytes"] = browsers
    state["profileBytes"] = profiles
    state["totalBytes"] = browsers + profiles
    state["jobs"] = [{"id": i, "kind": j["kind"], "revision": j["revision"],
                      "label": j["label"], "status": "running", "code": None,
                      "stream": j["stream"]}
                     for i, j in JOBS.items()]
    state["logs"] = staged_logs()
    return state


# Two things the page cannot be asked to do from a URL.
#
# The theme is stored, not queried, so it is seeded before app.js reads it -
# which also leaves the theme button in the right state. Forcing data-theme
# afterwards would light the page correctly and leave that button saying the
# opposite.
THEME = """
<script>
  try {
    localStorage.setItem('engineshelf.theme', '__SCHEME__');
  } catch (error) {
    /* headless has storage; if it ever does not, the system theme is fine */
  }
</script>
"""

# And opening the job log on a chosen tab, which is a click. Injected into the
# served copy of index.html rather than added to the product, because a
# screenshot is the only thing that wants it.
STAGE = """
<script>
  (function stage() {
    if (typeof state === 'undefined' || !state || !state.jobs.length) {
      return setTimeout(stage, 40);
    }
    watch('chromium:105', 'Chromium 105');
  })();
</script>
"""

# The three pictures, from one shelf. The pair share a <picture> on the landing
# page and so must come out the same size; the hero stands alone.
SHOTS = (
    ("jobs-dark", "docs/assets", "screenshot-jobs.png", "?sort=new&shot=dark", True),
    ("jobs-light", "docs/assets", "screenshot-jobs-light.png", "?sort=new&shot=light", True),
    # The README's hero. The list, because that is what the manager opens on -
    # and no job log over it, because the point of this one is the shelf itself.
    ("list", "assets", "screenshot-manager.png", "?sort=new&shot=dark&nolog=1", False),
)


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def _send(self, body, kind):
        self.send_response(200)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _json(self, payload):
        self._send(json.dumps(payload).encode(), "application/json")

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/api/token":
            return self._json({"token": TOKEN})
        if path == "/api/state":
            return self._json(STATE)
        if path == "/api/ping":
            # True, or the page draws the "stays running when closed" warning
            # over every screenshot: that badge is for a manager old enough
            # to have had the mode, and this one is a fixture.
            return self._json({"autoQuit": True, "grace": 12})
        # The shelf's changelogs. Served from features.tsv through the backend's
        # own reader, because without it every row on the shot reads "N/A" -
        # which is what the page says when a version has nothing to report, and
        # would be a picture of a missing file rather than of the product.
        if path == "/api/features":
            import server as backend
            return self._json({"%s:%s" % key: value
                               for key, value in backend.read_features().items()})
        if path.startswith("/api/job/"):
            job = JOBS.get(path.rsplit("/", 1)[-1])
            if not job:
                return self._json({"error": "no such job"})
            return self._json(dict(job, status="running", code=None))
        if path == "/api/logs":
            return self._json({"streams": staged_logs()})
        if path.startswith("/api/log/"):
            key = unquote(path[len("/api/log/"):])
            found = next((s for s in staged_logs() if s["key"] == key), None)
            if not found:
                return self._json({"error": "no such log"})
            lines = JOBS[found["job"]["id"]]["output"].split("\n")
            # Whole thing every time: the page asks for a delta and one request
            # is all a screenshot ever makes.
            return self._json(dict(found, first=0, total=len(lines),
                                   mark=0, lines=lines))
        if path in ("/", "/index.html"):
            with open(os.path.join(GUI, "index.html"), encoding="utf-8") as handle:
                page = handle.read()
            scheme = "light" if "light" in self.path else "dark"
            page = page.replace(
                '<script src="app.js"></script>',
                THEME.replace("__SCHEME__", scheme) + '<script src="app.js"></script>')
            if "nolog=1" not in self.path:
                page = page.replace("</body>", STAGE + "</body>")
            return self._send(page.encode(), "text/html")
        name = os.path.normpath(path.lstrip("/"))
        target = os.path.join(GUI, name)
        if not target.startswith(GUI + os.sep) or not os.path.isfile(target):
            self.send_error(404)
            return
        kinds = {".js": "text/javascript", ".css": "text/css",
                 ".svg": "image/svg+xml", ".png": "image/png"}
        with open(target, "rb") as handle:
            self._send(handle.read(), kinds.get(os.path.splitext(target)[1],
                                                "application/octet-stream"))


def find_browser():
    """A Chromium to shoot with: one EngineShelf downloaded, or Chrome."""
    if platform.system() == "Darwin":
        found = sorted(glob.glob(os.path.expanduser(
            "~/.engineshelf/builds/*/chrome-mac/Chromium.app/Contents/MacOS/Chromium")))
        if found:
            return found[-1]
        for candidate in (
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            "/Applications/Chromium.app/Contents/MacOS/Chromium",
        ):
            if os.path.exists(candidate):
                return candidate
    for name in ("chromium", "chromium-browser", "google-chrome"):
        found = shutil.which(name)
        if found:
            return found
    raise SystemExit(
        "No Chromium to shoot with. Download one first:  ./engineshelf.sh install 140")


def shoot(browser, url, out):
    subprocess.run([
        browser, "--headless", "--disable-gpu", "--no-sandbox", "--hide-scrollbars",
        f"--force-device-scale-factor={SCALE}",
        "--virtual-time-budget=8000",
        f"--screenshot={out}", f"--window-size={WIDTH},{HEIGHT}", url,
    ], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if not os.path.exists(out):
        raise SystemExit(f"Chromium wrote no file for {url}")


def trim_bottom(png):
    """Cut the blank band headless leaves under the app shell.

    The shell is 100vh, but a headless capture comes back a little taller than
    the layout viewport, so the page background runs on below the status bar. The
    strip is a solid colour and the status bar above it is not, so the boundary
    can be found rather than guessed - which keeps this reproducible.
    """
    from PIL import Image

    with Image.open(png) as image:
        rgb = image.convert("RGB")
        width, height = rgb.size
        pixel = rgb.load()
        base = pixel[width // 2, height - 1]
        row = height
        while row > 1:
            # Sampled across, not every pixel: the status bar carries text and
            # buttons, so any real row differs at some of these.
            if any(pixel[x, row - 1] != base for x in range(0, width, 17)):
                break
            row -= 1
        if row < height:
            rgb.crop((0, 0, width, row)).save(png)
            return width, row
        return width, height


def to_webp(png):
    from PIL import Image

    webp = os.path.splitext(png)[0] + ".webp"
    with Image.open(png) as image:
        image.save(webp, "webp", quality=82, method=6)
    return webp


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--keep", action="store_true",
                        help="leave the server up so the staged page can be opened")
    args = parser.parse_args()

    global STATE
    STATE = staged_state()

    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
    server = http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    url = f"http://127.0.0.1:{port}/"
    print(f"  staged manager -> {url}")

    if args.keep:
        print("  --keep: open it with ?sort=new, ?shot=light. Ctrl-C to stop.")
        try:
            threading.Event().wait()
        except KeyboardInterrupt:
            return

    browser = find_browser()
    print(f"  shooting with {browser}")
    paired = set()
    for label, folder, name, query, is_pair in SHOTS:
        out = os.path.join(PROJECT, folder)
        os.makedirs(out, exist_ok=True)
        png = os.path.join(out, name)
        shoot(browser, url + query, png)
        size = trim_bottom(png)
        webp = to_webp(png) if is_pair else None
        print(f"  {label:11} {os.path.relpath(png, PROJECT):38} {size[0]}x{size[1]}"
              + (f"  ->  {os.path.relpath(webp, PROJECT)}" if webp else ""))
        if is_pair:
            paired.add(size)
    server.shutdown()

    # The pair underlay each other in one <picture>, so a mismatch would make the
    # theme swap jump - and the landing page states these numbers in its markup.
    if len(paired) != 1:
        raise SystemExit(f"The paired shots came out different sizes: {paired}")
    width, height = paired.pop()
    print(f'  docs/index.html must declare width="{width}" height="{height}".')


if __name__ == "__main__":
    main()
