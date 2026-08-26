#!/usr/bin/env python3
"""ChromiumStack GUI backend (macOS / Linux).

Serves the static page in this directory and a small JSON API. All real work -
install, launch, remove, reset - is delegated to chromium-stack.sh, so the GUI and
the command line cannot drift apart. State (what is installed, how big it is) is
read straight off disk, which is cheap and needs no subprocess.

Bound to 127.0.0.1 and gated on a per-run token, so a web page you happen to have
open cannot drive your browser installs.

The manager is its own window, not a page that outlives you: closing it stops
this server, the browsers it launched and the containers it brought up. See
"lifetime" below for how the window and the server keep track of each other.

    python3 gui/server.py [--port N] [--no-open] [--tab] [--keep-alive]
"""
import argparse
import json
import mimetypes
import os
import platform
import re
import secrets
import shutil
import signal
import subprocess
import sys
import threading
import time
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.dirname(HERE)
CATALOG = os.path.join(PROJECT, "catalog.tsv")
CLI = os.path.join(PROJECT, "chromium-stack.sh")


def augment_path():
    """A GUI launch inherits a bare PATH, so Homebrew and Docker's own CLI shim
    are invisible to shutil.which and to everything this starts. lib/preflight.sh
    does the same for the shell side; without it a machine with Docker installed
    was told Docker was missing."""
    extra = ["/opt/homebrew/bin", "/usr/local/bin",
             os.path.expanduser("~/.docker/bin"),
             "/Applications/Docker.app/Contents/Resources/bin"]
    parts = os.environ.get("PATH", "").split(os.pathsep)
    for directory in extra:
        if os.path.isdir(directory) and directory not in parts:
            parts.append(directory)
    os.environ["PATH"] = os.pathsep.join(parts)


augment_path()
DOCKER_CLI = os.path.join(PROJECT, "chromium-stack-docker.sh")

TOKEN = secrets.token_urlsafe(24)


# --------------------------------------------------------------------------- #
# host + catalog
# --------------------------------------------------------------------------- #

def host_platforms():
    """Snapshot platform directories this machine can run, best first.

    Apple Silicon can run both the native arm64 build and the x86_64 one under
    Rosetta, and the arm64 snapshots only start around M92 - so the fallback
    order matters and old milestones land on Rosetta.
    """
    system = platform.system()
    if system == "Darwin":
        return ["Mac_Arm", "Mac"] if platform.machine() == "arm64" else ["Mac"]
    if system == "Linux":
        return ["Linux_x64"]
    return ["Win_x64"]


def root_dir():
    override = os.environ.get("CHROMIUM_STACK_HOME") or os.environ.get("BROWSERS_EMU_HOME")
    return override or os.path.join(os.path.expanduser("~"), ".chromium-stack")


def catalog_cache():
    """Milestones chromium-stack.sh has resolved against the live archive.

    It lives under the user's root rather than next to catalog.tsv, which ships
    inside the release and is often read-only.
    """
    return os.path.join(root_dir(), "catalog.cache.tsv")


def read_catalog():
    """Merge the runtime cache over the shipped catalog, newest answer winning.

    Same precedence the CLI uses, so the two cannot show different revisions for
    the same milestone.
    """
    versions, builds = {}, {}
    for path in (CATALOG, catalog_cache()):
        try:
            handle = open(path)
        except OSError:
            continue
        with handle:
            for line in handle:
                if line.startswith("#") or not line.strip():
                    continue
                parts = line.rstrip("\n").split("\t")
                if parts[0] == "V":
                    versions[int(parts[1])] = {
                        "milestone": int(parts[1]),
                        "version": parts[2],
                        "note": parts[3] if len(parts) > 3 else "",
                    }
                elif parts[0] == "B":
                    builds.setdefault(int(parts[1]), {})[parts[2]] = {
                        "revision": int(parts[3]),
                        "archive": parts[4],
                        "root": parts[5],
                    }
    return [versions[m] for m in sorted(versions)], builds


def refresh_catalog_cache():
    """Let the CLI discover and cache milestones released since this build.

    Delegated rather than reimplemented: `catalog` is the command that knows how
    to walk the archive, and doing it here would be a second copy to keep honest.
    Failure is silent - the shipped catalog is still a complete answer.
    """
    try:
        subprocess.run(["bash", CLI, "catalog"], cwd=PROJECT, stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, timeout=120)
    except (OSError, subprocess.SubprocessError):
        pass


# --------------------------------------------------------------------------- #
# disk usage
# --------------------------------------------------------------------------- #

_size_cache = {}
_size_lock = threading.Lock()


def dir_size(path, ttl=15):
    """Total bytes under path, cached briefly - the profile can hold many files."""
    if not os.path.isdir(path):
        return 0
    now = time.time()
    with _size_lock:
        hit = _size_cache.get(path)
        if hit and now - hit[0] < ttl:
            return hit[1]
    total = 0
    for dirpath, _dirnames, filenames in os.walk(path, followlinks=False):
        for name in filenames:
            try:
                total += os.lstat(os.path.join(dirpath, name)).st_size
            except OSError:
                pass
    with _size_lock:
        _size_cache[path] = (now, total)
    return total


def invalidate_sizes():
    with _size_lock:
        _size_cache.clear()


def read_meta(path):
    """Parse the shell-sourced .meta written by chromium-stack.sh."""
    meta = {}
    try:
        with open(path) as handle:
            for line in handle:
                if "=" not in line:
                    continue
                key, _, value = line.strip().partition("=")
                meta[key] = value.strip().strip("'")
    except OSError:
        return {}
    return meta


def installed_builds():
    builds = {}
    base = os.path.join(root_dir(), "builds")
    if not os.path.isdir(base):
        return builds
    for name in os.listdir(base):
        path = os.path.join(base, name)
        if not name.isdigit() or not os.path.exists(os.path.join(path, ".complete")):
            continue
        meta = read_meta(os.path.join(path, ".meta"))
        builds[int(name)] = {
            "revision": int(name),
            "path": path,
            "version": meta.get("META_VERSION") or f"r{name}",
            "platformDir": meta.get("META_PLATFORM") or "?",
            "milestone": meta.get("META_MILESTONE") or "?",
            "installedAt": meta.get("META_INSTALLED") or "",
            "sizeBytes": dir_size(path),
            "profileBytes": dir_size(os.path.join(root_dir(), "profiles", name)),
        }
    return builds


# The names chromium-stack-docker.sh gives the things it creates. The manager
# reads them back, which is the only way a version living in a container can look
# like one living on disk; renaming any of them means changing both files.
CONTAINER_PREFIX = "chromium-stack-"
IMAGE_REPO = "chromium-stack"
VOLUME_PREFIX = "chromium-stack-profile-"

# `docker info` takes the best part of a second and the page asks for the state
# every four; the answer does not change that fast.
_docker_cache = {"at": 0.0, "value": None}
_volume_cache = {"at": 0.0, "value": None}


def docker_out(args, timeout=8):
    """stdout of a docker command, or "" if it failed or docker is not there."""
    try:
        done = subprocess.run(["docker", *args], capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.SubprocessError):
        return ""
    return done.stdout if done.returncode == 0 else ""


_DECIMAL = {"B": 1, "KB": 10 ** 3, "MB": 10 ** 6, "GB": 10 ** 9, "TB": 10 ** 12}


def parse_human_bytes(text):
    """"10.13MB" -> bytes. Docker's own read-outs use decimal units."""
    found = re.match(r"^\s*([\d.]+)\s*([KMGT]?B)\s*$", str(text), re.I)
    if not found:
        return 0
    return int(float(found.group(1)) * _DECIMAL[found.group(2).upper()])


def published_port(mapping):
    """"127.0.0.1:6081->6080/tcp" -> 6081.

    The launcher takes whichever port it can get, so asking what a container
    published is the only way to know where its desktop is listening.
    """
    for part in str(mapping).split(","):
        found = re.search(r":(\d+)->6080/", part)
        if found:
            return int(found.group(1))
    return None


def docker_profile_sizes():
    """Bytes in each version's profile volume, keyed by revision.

    Only `docker system df -v` knows, and it takes over a second, so it gets a
    longer cache than the rest: a profile grows by megabytes over a session, and
    a slightly stale figure is cheaper than a page that stalls on every refresh.
    """
    now = time.time()
    if _volume_cache["value"] is not None and now - _volume_cache["at"] < 60:
        return _volume_cache["value"]
    try:
        listed = json.loads(docker_out(["system", "df", "-v", "--format",
                                        "{{json .Volumes}}"], timeout=20) or "[]")
    except ValueError:
        listed = []
    sizes = {}
    for volume in listed or []:
        name = str(volume.get("Name", ""))
        if name.startswith(VOLUME_PREFIX):
            sizes[name[len(VOLUME_PREFIX):]] = parse_human_bytes(volume.get("Size"))
    _volume_cache.update(at=now, value=sizes)
    return sizes


def docker_status():
    """What Docker is holding for ChromiumStack: images, their size, containers.

    Without this the shelf could say nothing true about a version that runs in a
    container: no size for an image costing a gigabyte, and no sign it was
    running at all, because the job that starts a container exits as soon as the
    desktop answers - leaving a row that looked untouched with a browser open.
    """
    now = time.time()
    if _docker_cache["value"] and now - _docker_cache["at"] < 10:
        return _docker_cache["value"]

    cli = shutil.which("docker") is not None
    running = False
    if cli:
        try:
            running = subprocess.run(
                ["docker", "info"], stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL, timeout=6,
            ).returncode == 0
        except (OSError, subprocess.SubprocessError):
            running = False

    by_revision = {}
    containers = []

    def slot(revision):
        return by_revision.setdefault(str(revision), {
            "imageBytes": 0, "profileBytes": 0, "state": None, "status": "", "port": None,
        })

    if running:
        # One image per version, tagged with the revision it was built from. The
        # tag list is cheap; the exact byte count needs an inspect, and `docker
        # images` only prints a rounded decimal string.
        tags = [tag for tag in docker_out(["images", IMAGE_REPO, "--format", "{{.Tag}}"]).split()
                if tag and tag != "<none>"]
        if tags:
            sizes = docker_out(["image", "inspect", "--format", "{{.Size}}",
                                *[f"{IMAGE_REPO}:{tag}" for tag in tags]]).split()
            for tag, size in zip(tags, sizes):
                slot(tag)["imageBytes"] = int(size) if size.isdigit() else 0

        # One container per version, named chromium-stack-<revision>. Stopped
        # ones are listed too: a container that exits the moment it starts is a
        # fault worth showing, not a row that quietly does nothing.
        listing = docker_out(["ps", "-a", "--filter", f"name={CONTAINER_PREFIX}",
                              "--format", "{{.Names}}\t{{.State}}\t{{.Status}}\t{{.Ports}}"])
        for line in listing.splitlines():
            parts = line.split("\t")
            if len(parts) < 4 or not parts[0].startswith(CONTAINER_PREFIX):
                continue
            revision = parts[0][len(CONTAINER_PREFIX):]
            entry = slot(revision)
            entry["state"] = parts[1]
            entry["status"] = parts[2]
            entry["port"] = published_port(parts[3])
            if parts[1] == "running":
                containers.append(revision)

        for revision, size in docker_profile_sizes().items():
            slot(revision)["profileBytes"] = size

    value = {
        "cli": cli, "running": running, "containers": containers,
        "supported": os.path.exists(DOCKER_CLI),
        "byRevision": by_revision,
        "imageBytes": sum(e["imageBytes"] for e in by_revision.values()),
        "profileBytes": sum(e["profileBytes"] for e in by_revision.values()),
    }
    _docker_cache.update(at=now, value=value)
    return value


def docker_row(revision, status):
    """The Docker side of one shelf row, or None if there is nothing to offer.

    A container always runs the Linux x86_64 build, so its revision is not the
    one this host installs natively - and comparing those two is exactly what
    used to hide a running container from the row it belonged to.
    """
    if revision is None or not status.get("supported"):
        return None
    entry = status["byRevision"].get(str(revision), {})
    return {
        "revision": revision,
        "imageBytes": entry.get("imageBytes", 0),
        "profileBytes": entry.get("profileBytes", 0),
        "state": entry.get("state"),
        "status": entry.get("status", ""),
        "port": entry.get("port"),
    }


_doctor_cache = {"at": 0.0, "value": None}


def forget_doctor():
    """Called when a job ends: installing a dependency should show up at once."""
    _doctor_cache["value"] = None


def doctor_report():
    """Whatever `chromium-stack.sh doctor --json` says.

    The checks live in lib/preflight.sh so the CLI, the Docker launcher and this
    page cannot disagree about what is missing or how to fix it. Cached briefly:
    it shells out and probes the machine, and the page polls every four seconds.
    """
    now = time.time()
    if _doctor_cache["value"] and now - _doctor_cache["at"] < 12:
        return _doctor_cache["value"]
    try:
        result = subprocess.run(
            ["bash", CLI, "doctor", "--json"], cwd=PROJECT, capture_output=True,
            text=True, timeout=25,
        )
        report = json.loads(result.stdout)
    except (OSError, subprocess.SubprocessError, ValueError):
        return {"os": platform.system().lower(), "arch": platform.machine(), "components": []}
    _doctor_cache.update(at=now, value=report)
    return report


def linux_revision(milestone, builds):
    """The revision a container would run for this milestone, if there is one.

    Rows with no Linux x86_64 build cannot go in a container at all, and the
    manager used to offer it anyway - the launcher then died on "no Linux x86_64
    build in the catalog" with the reason buried in a job log.
    """
    return (builds.get(milestone, {}).get("Linux_x64") or {}).get("revision")


def milestone_of(revision, builds):
    """Which milestone a raw revision belongs to, on any platform."""
    for milestone, platforms in builds.items():
        if any(build["revision"] == revision for build in platforms.values()):
            return milestone
    return None


def build_state():
    versions, builds = read_catalog()
    hosts = host_platforms()
    installed = installed_builds()
    docker = docker_status()
    catalogued = set()
    rows = []

    for entry in versions:
        milestone = entry["milestone"]
        available = builds.get(milestone, {})
        chosen_platform = next((p for p in hosts if p in available), None)
        row = dict(entry)
        row["platformDir"] = chosen_platform
        row["supported"] = chosen_platform is not None
        row["native"] = chosen_platform != "Mac" or platform.machine() != "arm64"
        row["docker"] = docker_row(linux_revision(milestone, builds), docker)
        if chosen_platform:
            build = available[chosen_platform]
            row["revision"] = build["revision"]
            catalogued.add(build["revision"])
            local = installed.get(build["revision"])
            row["installed"] = local is not None
            row["sizeBytes"] = local["sizeBytes"] if local else 0
            row["profileBytes"] = local["profileBytes"] if local else 0
            row["installedAt"] = local["installedAt"] if local else ""
        else:
            row["revision"] = None
            row["installed"] = False
            row["sizeBytes"] = row["profileBytes"] = 0
            row["installedAt"] = ""
        rows.append(row)

    # Builds installed by raw revision that no catalogue row claims. A container
    # for one of these still runs the Linux build of whatever milestone it
    # belongs to, so it is looked up the same way the launcher looks it up.
    extra = []
    for revision, info in sorted(installed.items()):
        if revision in catalogued:
            continue
        milestone = milestone_of(revision, builds)
        drev = linux_revision(milestone, builds) if milestone is not None else revision
        extra.append(dict(info, note="Installed by revision.", supported=True, native=True,
                          docker=docker_row(drev, docker)))

    total = sum(i["sizeBytes"] + i["profileBytes"] for i in installed.values())
    return {
        "root": root_dir(),
        "os": platform.system().lower(),
        "arch": platform.machine(),
        "hostPlatforms": hosts,
        "versions": rows,
        "extra": extra,
        "totalBytes": total,
        # Images and profile volumes are the other place gigabytes go, and they
        # are invisible from the file tree the rest of this reads.
        "dockerBytes": docker["imageBytes"] + docker["profileBytes"],
        "docker": docker,
        "doctor": doctor_report(),
        "jobs": jobs.summary(),
    }


# --------------------------------------------------------------------------- #
# jobs
# --------------------------------------------------------------------------- #

class Jobs:
    """Background CLI invocations, with their output kept for the page to poll."""

    def __init__(self):
        self._jobs = {}
        self._lock = threading.Lock()
        self._next = 1

    def start(self, kind, revision, argv, label, env=None):
        with self._lock:
            job_id = str(self._next)
            self._next += 1
            job = {
                "id": job_id, "kind": kind, "revision": revision, "label": label,
                "status": "running", "lines": [], "started": time.time(), "code": None,
            }
            self._jobs[job_id] = job
        threading.Thread(target=self._run, args=(job, argv, env or {}), daemon=True).start()
        return job_id

    def _run(self, job, argv, extra_env):
        try:
            process = subprocess.Popen(
                argv, cwd=PROJECT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                stdin=subprocess.DEVNULL, text=True, bufsize=1,
                env=dict(os.environ, TERM="dumb", **extra_env), start_new_session=True,
            )
        except OSError as error:
            with self._lock:
                job["status"] = "error"
                job["lines"].append(str(error))
            return

        with self._lock:
            job["pid"] = process.pid

        for line in process.stdout:
            line = line.rstrip("\n")
            with self._lock:
                job["lines"].append(line)
                # A download is one long carriage-return progress bar; keeping the
                # last few hundred lines is plenty for the page to render.
                if len(job["lines"]) > 400:
                    del job["lines"][:200]
        code = process.wait()
        invalidate_sizes()
        forget_doctor()
        _docker_cache["value"] = None
        _volume_cache["value"] = None
        with self._lock:
            job["code"] = code
            if job.get("stopping"):
                job["status"] = "stopped"
            else:
                job["status"] = "done" if code == 0 else "error"

    def stop(self, job_id):
        """Terminate a job and everything it started.

        SIGTERM goes to the whole process group so the launcher dies alongside
        the browser; killing the browser alone would trip the launcher's
        crash-restart loop and reopen it.
        """
        with self._lock:
            job = self._jobs.get(job_id)
            if not job or job["status"] != "running":
                return False
            pid = job.get("pid")
            if not pid:
                return False
            job["stopping"] = True
        try:
            os.killpg(os.getpgid(pid), signal.SIGTERM)
        except (ProcessLookupError, PermissionError, OSError):
            return False
        return True

    def get(self, job_id):
        with self._lock:
            job = self._jobs.get(job_id)
            if not job:
                return None
            return {k: v for k, v in job.items() if k != "lines"} | {"output": "\n".join(job["lines"])}

    def summary(self):
        with self._lock:
            return [
                {"id": j["id"], "kind": j["kind"], "revision": j["revision"],
                 "label": j["label"], "status": j["status"]}
                for j in self._jobs.values() if j["status"] == "running"
            ]


jobs = Jobs()


# --------------------------------------------------------------------------- #
# lifetime
#
# The manager used to be a tab you closed and a server you forgot about, still
# holding a port and still parenting every browser it had launched. Now the
# window is the app: when it goes, everything it started goes with it.
#
# Two things can say the window is gone, and both are needed. The browser process
# hosting it exits - immediate and certain, but only when we own that process.
# And the page stops asking: any authorised request counts as a heartbeat, so a
# tab in someone's own browser is covered too, at the cost of a grace period long
# enough that a reload does not read as a goodbye.
# --------------------------------------------------------------------------- #

# Long enough to ride out a reload, a sleeping laptop's first second back, or a
# slow render; short enough that closing the window does not leave a stray server
# holding the port.
GRACE_SECONDS = 12

_life = {
    "seen": 0.0,        # last authorised request from a page
    "shell": None,      # the browser process hosting the window, if we own it
    "auto": True,       # quit when the window is gone
    "quitting": False,
    "server": None,
}


def find_app_browser():
    """A Chromium-family browser to host the manager's own window.

    Only Chromium-family: --app is what turns a tab into a window with no
    address bar and no session of its own, and nothing else understands it.
    Without one the manager opens as an ordinary tab instead.
    """
    override = os.environ.get("CHROMIUM_STACK_APP_BROWSER")
    if override:
        return override if os.access(override, os.X_OK) else None
    if platform.system() == "Darwin":
        candidates = [
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            "/Applications/Chromium.app/Contents/MacOS/Chromium",
            "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
            "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser",
        ]
    else:
        candidates = [shutil.which(name) for name in
                      ("google-chrome", "chromium", "chromium-browser",
                       "microsoft-edge", "brave-browser")]
    for path in candidates:
        if path and os.access(path, os.X_OK):
            return path
    return None


def open_app_window(url):
    """Open the manager in a window of its own; return the process behind it.

    The separate profile directory is not tidiness. Pointed at the browser's
    normal profile, the window is handed to the copy of Chrome already running
    and this process exits immediately - taking away the one signal that says
    for certain when the window has closed. It also keeps a manager window out
    of the user's own session, history and extensions.
    """
    browser = find_app_browser()
    if not browser:
        return None
    argv = [
        browser,
        f"--app={url}",
        f"--user-data-dir={os.path.join(root_dir(), 'manager-window')}",
        "--no-first-run",
        "--no-default-browser-check",
        "--window-size=1440,920",
        # A window showing one local page needs none of this, and an update
        # check or a restore-pages prompt in it would be pure noise.
        "--disable-background-networking",
        "--disable-component-update",
        "--disable-features=Translate",
    ]
    try:
        # Its own session, so a crash here does not take the window with it and
        # Ctrl-C in a terminal does not land on the browser sideways.
        return subprocess.Popen(argv, stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL, start_new_session=True)
    except OSError:
        return None


def stop_containers():
    """Stop and remove the containers this project runs, if any are up.

    Named the way chromium-stack-docker.sh names them, and stopped the way it
    stops them: SIGTERM first, because killed outright the browser inside leaves
    a lock in its profile volume that breaks the next start.
    """
    listed = docker_out(["ps", "--filter", f"name={CONTAINER_PREFIX}",
                         "--format", "{{.Names}}"], timeout=8)
    names = [name for name in listed.split() if name.startswith(CONTAINER_PREFIX)]
    if not names:
        return
    print(f"  Stopping {len(names)} Docker container{'s' if len(names) > 1 else ''}...",
          flush=True)
    docker_out(["stop", "-t", "10", *names], timeout=90)
    docker_out(["rm", "-f", *names], timeout=30)


def tidy_cut_off(revisions):
    """Clear up after downloads the shutdown interrupted.

    chromium-stack.sh removes both of these itself when a download fails, but a
    job killed outright never reaches that code - and closing the window is now
    an ordinary way for a download to end, so an 80 MB orphan every time is not
    acceptable. The zip cannot be resumed either: the CLI fetches it whole.

    Only revisions this process was working on. Another manager may be running
    against the same directory, and its download is not ours to delete.
    """
    root = root_dir()
    for revision in revisions:
        try:
            os.remove(os.path.join(root, f".download-{revision}.zip"))
        except OSError:
            pass
        build = os.path.join(root, "builds", str(revision))
        # Absent .complete, this is a half-unpacked build that nothing will use.
        if os.path.isdir(build) and not os.path.exists(os.path.join(build, ".complete")):
            shutil.rmtree(build, ignore_errors=True)


def stop_everything():
    """Every browser and every job this manager started, closed.

    Jobs are killed by process group, which is what brings a launched browser
    down along with the launcher watching it.
    """
    running = jobs.summary()
    if running:
        print(f"  Stopping {len(running)} running job{'s' if len(running) > 1 else ''}...",
              flush=True)
        for job in running:
            jobs.stop(job["id"])
        # Let SIGTERM land before clearing up after what it interrupted.
        time.sleep(0.6)
    tidy_cut_off([job["revision"] for job in running
                  if job["kind"] in ("install", "launch")])
    stop_containers()

    shell = _life["shell"]
    if shell is not None and shell.poll() is None:
        # Quitting from the page, so the window is still there to close.
        try:
            shell.terminate()
        except OSError:
            pass


def quit_now(reason):
    if _life["quitting"]:
        return
    _life["quitting"] = True
    print(f"\n  Closing ({reason}).", flush=True)
    stop_everything()
    server = _life["server"]
    if server is not None:
        # From another thread: shutdown() cannot be called from the one serving.
        threading.Thread(target=server.shutdown, daemon=True).start()


def watch_window():
    """Quit once the window is gone, by either of the two signals above."""
    last_tick = time.time()
    while not _life["quitting"]:
        time.sleep(1)
        now = time.time()
        slept, last_tick = now - last_tick, now
        # A second that took much longer than a second means the machine was
        # suspended, not that the window closed - and on wake the page has had no
        # chance to say anything yet. Without this, shutting a laptop lid for a
        # minute took the manager and everything it was running down with it.
        if slept > 5:
            _life["seen"] = now
            continue
        if not _life["auto"]:
            continue
        shell = _life["shell"]
        if shell is not None and shell.poll() is not None:
            return quit_now("the manager window was closed")
        # Nothing has connected yet: the browser may still be starting, and a
        # manager that quit before its own window opened would be a fine joke.
        if not _life["seen"]:
            continue
        if time.time() - _life["seen"] > GRACE_SECONDS:
            return quit_now("the manager page stopped answering")


# --------------------------------------------------------------------------- #
# http
# --------------------------------------------------------------------------- #

class Handler(BaseHTTPRequestHandler):
    server_version = "ChromiumStack"

    def log_message(self, *_args):
        pass                       # the console belongs to the launcher, not the server

    # -- helpers ----------------------------------------------------------- #
    def _json(self, payload, status=200):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _authorised(self):
        """Loopback binding alone does not stop a page in your browser from
        POSTing here, so every API call must carry the token printed at start.

        A call that gets through is also proof the window is still open, which is
        what keeps the manager alive - see "lifetime" above.
        """
        host = (self.headers.get("Host") or "").split(":")[0]
        if host not in ("127.0.0.1", "localhost", "[::1]", "::1"):
            return False
        if not secrets.compare_digest(self.headers.get("X-ChromiumStack-Token", ""), TOKEN):
            return False
        _life["seen"] = time.time()
        return True

    def _body(self):
        length = int(self.headers.get("Content-Length") or 0)
        if not length:
            return {}
        try:
            return json.loads(self.rfile.read(length) or b"{}")
        except ValueError:
            return {}

    # -- routes ------------------------------------------------------------ #
    def do_GET(self):
        path = self.path.split("?", 1)[0]

        if path == "/api/state":
            if not self._authorised():
                return self._json({"error": "unauthorised"}, 403)
            return self._json(build_state())

        if path.startswith("/api/job/"):
            if not self._authorised():
                return self._json({"error": "unauthorised"}, 403)
            job = jobs.get(path.rsplit("/", 1)[-1])
            return self._json(job or {"error": "no such job"}, 200 if job else 404)

        if path == "/api/ping":
            # _authorised() has already noted the time; the body is only so the
            # page can tell whether closing it will end the session.
            if not self._authorised():
                return self._json({"error": "unauthorised"}, 403)
            return self._json({"autoQuit": _life["auto"], "grace": GRACE_SECONDS})

        if path == "/api/token":
            # Handed to the page once, from the loopback origin it was opened on.
            return self._json({"token": TOKEN})

        return self._static(path)

    def do_POST(self):
        path = self.path.split("?", 1)[0]
        if not self._authorised():
            return self._json({"error": "unauthorised"}, 403)
        body = self._body()

        if path == "/api/stop":
            job_id = str(body.get("job", "")).strip()
            return self._json({"stopped": jobs.stop(job_id)})

        if path == "/api/doctor":
            return self._json(doctor_report())

        # Before the selector guard below: a dependency is named by component, and
        # has no revision to check. Behind the guard it answered "bad selector" to
        # every install the manager asked for.
        if path == "/api/doctor-install":
            component = str(body.get("component", "")).strip()
            if not component.isalnum():
                return self._json({"error": "bad component"}, 400)
            job_id = jobs.start(
                "doctor", component,
                ["bash", CLI, "doctor", "--install", component, "--yes"],
                f"Installing {component}",
                # Tells preflight there is no terminal here, so a fix needing
                # root asks through the system dialog instead of failing on sudo.
                env={"PF_GUI": "1"},
            )
            return self._json({"job": job_id})

        selector = str(body.get("selector", "")).strip()

        if not selector.isdigit():
            return self._json({"error": "bad selector"}, 400)

        if path == "/api/install":
            job_id = jobs.start("install", selector, ["bash", CLI, "install", selector],
                                f"Installing Chromium {selector}")
            return self._json({"job": job_id})

        if path == "/api/launch":
            argv = ["bash", CLI, "run", selector]
            url = str(body.get("url", "")).strip()
            if url:
                argv.append(url)
            size = str(body.get("size", "")).strip()
            if size:
                argv += ["--size", size]
            if body.get("gpu") is True:
                argv.append("--gpu")
            elif body.get("gpu") is False:
                argv.append("--no-gpu")
            job_id = jobs.start("launch", selector, argv, f"Chromium {selector}")
            return self._json({"job": job_id})

        if path == "/api/remove":
            argv = ["bash", CLI, "remove", selector]
            if body.get("withProfile"):
                argv.append("--with-profile")
            job_id = jobs.start("remove", selector, argv, f"Removing {selector}")
            return self._json({"job": job_id})

        if path == "/api/clean":
            job_id = jobs.start("clean", selector, ["bash", CLI, "clean", selector],
                                f"Resetting profile {selector}")
            return self._json({"job": job_id})

        if path == "/api/docker":
            action = str(body.get("action", "start"))
            if action not in ("start", "stop", "rebuild", "purge"):
                return self._json({"error": "bad action"}, 400)
            argv = ["bash", DOCKER_CLI, action, selector]
            # An image is a gigabyte, so removing one has to be possible from the
            # shelf; otherwise the only way to get that disk back is raw docker.
            if action == "purge" and body.get("withProfile"):
                argv.append("--with-profile")
            job_id = jobs.start("docker", selector, argv, f"Docker {action} {selector}")
            return self._json({"job": job_id})

        return self._json({"error": "no such endpoint"}, 404)

    # -- static ------------------------------------------------------------ #
    def _static(self, path):
        name = "index.html" if path == "/" else path.lstrip("/")
        target = os.path.normpath(os.path.join(HERE, name))
        if not target.startswith(HERE + os.sep) or not os.path.isfile(target):
            self.send_error(404)
            return
        kind = mimetypes.guess_type(target)[0] or "application/octet-stream"
        with open(target, "rb") as handle:
            body = handle.read()
        self.send_response(200)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)


def pick_port(preferred):
    import socket
    for port in range(preferred, preferred + 40):
        with socket.socket() as probe:
            try:
                probe.bind(("127.0.0.1", port))
                return port
            except OSError:
                continue
    raise SystemExit("No free port in range")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=7411)
    parser.add_argument("--no-open", action="store_true",
                        help="start the server without opening anything")
    parser.add_argument("--tab", action="store_true",
                        help="open a tab in the default browser instead of a window")
    parser.add_argument("--keep-alive", action="store_true",
                        help="keep serving after the window closes")
    args = parser.parse_args()

    if not os.path.exists(CLI):
        raise SystemExit(f"Missing {CLI}")

    # Adopting a pre-multi-version ~/.chrome74 install happens inside the CLI, so
    # touch it once before serving. Without this the first page load reports an
    # already-downloaded browser as missing until something else invokes the CLI.
    try:
        subprocess.run(["bash", CLI, "list"], cwd=PROJECT, stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, timeout=30)
    except (OSError, subprocess.SubprocessError):
        pass

    # Off the startup path: it talks to the network, and the page is perfectly
    # usable from the shipped catalog while it runs. The next refresh picks up
    # whatever it found.
    threading.Thread(target=refresh_catalog_cache, daemon=True).start()

    port = pick_port(args.port)
    url = f"http://127.0.0.1:{port}/"
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    _life["server"] = server

    # Nothing was opened, so there is no window whose closing could mean anything;
    # this is the shape a script or a remote session asks for, and it waits.
    _life["auto"] = not (args.keep_alive or args.no_open)

    shell = None
    if not args.no_open and not args.tab:
        shell = open_app_window(url)
        _life["shell"] = shell
    elif not args.no_open:
        threading.Timer(0.4, lambda: webbrowser.open(url)).start()

    print()
    print(f"  ChromiumStack manager  ->  {url}")
    print(f"  Files: {root_dir()}")
    if shell is not None:
        print("  Closing the window quits the manager, the browsers it opened")
        print("  and any Docker containers it started.")
    elif not _life["auto"]:
        print("  Press Ctrl-C to stop the manager.")
    else:
        # No window of our own: the page's heartbeat is the only thing that can
        # say it is still there, so say what silence will be taken to mean.
        print("  Opened as a browser tab. Closing it quits the manager, the")
        print(f"  browsers it opened and any containers it started, {GRACE_SECONDS}s later.")
    print("  Ctrl-C does the same.", flush=True)
    print(flush=True)

    threading.Thread(target=watch_window, daemon=True).start()

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        quit_now("Ctrl-C")
    print("  Manager stopped.", flush=True)


if __name__ == "__main__":
    main()
