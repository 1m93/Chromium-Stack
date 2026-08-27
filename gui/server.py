#!/usr/bin/env python3
"""EngineShelf GUI backend (macOS / Linux).

Serves the static page in this directory and a small JSON API. All real work -
install, launch, remove, reset - is delegated to engineshelf.sh, so the GUI and
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
import errno
import json
import mimetypes
import os
import platform
import re
import secrets
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time
import urllib.request
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.dirname(HERE)
CATALOG = os.path.join(PROJECT, "catalog.tsv")
CLI = os.path.join(PROJECT, "engineshelf.sh")

# Kept in step with lib/engines.sh. The display names are what the page shows;
# "WebKit" is never called Safari, for the reasons in that file.
ENGINES = ("chromium", "firefox", "edge", "webkit")
ENGINE_NAMES = {"chromium": "Chromium", "firefox": "Firefox",
                "edge": "Edge", "webkit": "WebKit"}

# Selectors reach the CLI as one argv element, so there is no shell to inject
# into - but a bare `.isdigit()` was the whole guard before there was more than
# one engine, and it has to widen without becoming "anything goes". Versions are
# alphanumeric and dotted (115.0, 140.14.0esr, 26.5); nothing here can be a path,
# an option, or a second word.
SELECTOR_RE = re.compile(
    r"^(?:(?:%s):)?[0-9A-Za-z][0-9A-Za-z.]{0,31}$" % "|".join(ENGINES))


try:
    # A pipe makes stdout block-buffered, and the app that owns the window reads
    # this pipe line by line to find out where the manager is serving. Buffered,
    # that line arrives 8 KB later - which is to say never - and the window sits
    # on "Starting the manager" with a perfectly good server behind it.
    sys.stdout.reconfigure(line_buffering=True)
    sys.stderr.reconfigure(line_buffering=True)
except (AttributeError, ValueError, OSError):
    pass


def say(*parts):
    """print, but never at the cost of the manager.

    The app that owns the window is also the far end of this process's stdout.
    Kill the app and that pipe goes with it, and the next print raises - which,
    on the shutdown path, took the watchdog thread down with it and left a
    server running with nothing watching it and no window to reach it by.
    """
    try:
        print(*parts, flush=True)
    except OSError:
        pass


def engine_of_key(key):
    """Which engine an on-disk build directory belongs to.

    Chromium's directories are the bare snapshot revision, as they have always
    been; every other engine prefixes its name. Same rule as engine_of_key in
    lib/engines.sh, and it has to stay the same rule.
    """
    for engine in ENGINES:
        if engine != "chromium" and key.startswith(engine + "-"):
            return engine
    return "chromium"


def selector_label(selector):
    """"firefox:115" -> "Firefox 115". What a job is called while it runs."""
    engine, _, version = selector.rpartition(":")
    return "%s %s" % (ENGINE_NAMES.get(engine or "chromium", "Chromium"), version)


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
DOCKER_CLI = os.path.join(PROJECT, "engineshelf-docker.sh")

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


def os_platforms():
    """Every platform directory this operating system could ever use.

    Wider than host_platforms(), which is an ordered preference for this exact
    machine. This answers a different question: which B rows count as evidence
    about this host at all. A Linux row cached so the container knows which build
    to run says nothing about a Mac - and read as evidence it said the opposite,
    turning "not catalogued yet" into "no build for this host".
    """
    system = platform.system()
    if system == "Darwin":
        return ("Mac", "Mac_Arm")
    if system == "Linux":
        return ("Linux_x64",)
    return ("Win_x64",)


def root_dir():
    override = os.environ.get("ENGINESHELF_HOME") or os.environ.get("BROWSERS_EMU_HOME")
    return override or os.path.join(os.path.expanduser("~"), ".engineshelf")


def known_bad_keys():
    """Versions this machine has already watched fail to start, any engine.

    engineshelf.sh appends one `os-major<TAB>key` line the first time a build
    dies before its window appears, and nothing but a real launch can know it:
    whether a 2019 x86_64 build still survives this year's Rosetta and
    libsystem_malloc is not something a catalogue can say. Keyed by macOS major
    so the answer is asked again after an upgrade rather than inherited.

    The key is a bare milestone for Chromium - all this file used to hold - and
    `engine:version` for the other three, so a cache written before those three
    could be recorded still means what it meant.
    """
    if platform.system() != "Darwin":
        return set()
    try:
        with open(os.path.join(root_dir(), "arch-fallback.cache")) as handle:
            lines = handle.read().splitlines()
    except OSError:
        return set()
    major = platform.mac_ver()[0].split(".")[0]
    bad = set()
    for line in lines:
        parts = line.split("\t")
        if len(parts) == 2 and parts[0] == major and parts[1]:
            bad.add(parts[1])
    return bad


# ---------- what the vendors still serve ----------
# A shelf row says a version was released. Whether it can still be downloaded is a
# different question, and only the vendor can answer it: Microsoft's enterprise
# feed keeps about six months of Edge and drops the rest, and Playwright deletes
# the older macOS WebKit archives while keeping the Linux ones. Rows for those
# versions were offered as ordinary downloads and failed at the vendor, which is
# the worst place to find out.
#
# Both answers are asked for through the CLI rather than reimplemented here, so
# they cannot drift from what a launch will actually find.
NATIVE_TTL = {"edge": 6 * 3600, "webkit": 3 * 86400, "versions": 7 * 86400}
# Engines with a Linux container. All four, which is why a version the vendor has
# dropped is still reachable rather than gone.
CONTAINERISED = frozenset(ENGINES)
_native_lock = threading.Lock()
_native_probing = set()


def native_path():
    return os.path.join(root_dir(), "native.json")


def read_native():
    try:
        with open(native_path()) as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def write_native(data):
    tmp = native_path() + ".%d" % os.getpid()
    try:
        with open(tmp, "w") as handle:
            json.dump(data, handle)
        os.replace(tmp, native_path())
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass


def native_stale(data, engine):
    entry = data.get(engine)
    if not isinstance(entry, dict):
        return True
    return time.time() - entry.get("at", 0) > NATIVE_TTL[engine]


def cli_lines(args, timeout=90):
    """Lines of stdout from the CLI, or None when it said it had no answer."""
    try:
        done = subprocess.run(["bash", CLI, *args], capture_output=True,
                              text=True, timeout=timeout)
    except (OSError, subprocess.SubprocessError):
        return None
    if done.returncode != 0:
        return None
    return [line.strip() for line in done.stdout.splitlines() if line.strip()]


def probe_native(selector, timeout=90):
    try:
        done = subprocess.run(["bash", CLI, "probe", selector],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                              timeout=timeout)
    except (OSError, subprocess.SubprocessError):
        return None
    return done.returncode == 0


def webkit_native_floor(ids):
    """The oldest WebKit build this host can still download, by halving.

    Playwright deletes from the old end and never from the middle, so one probe
    rules out or admits half the shelf at a time: six requests instead of the
    fifty-three that asking about every row would take. Returns None when even
    the newest has no archive for this host - which is the whole answer on
    Windows, where WebKit has no native build at all.
    """
    order = sorted(ids)
    if not order:
        return None
    if not probe_native("webkit:%s" % order[-1]):
        return None
    low, high = 0, len(order) - 1
    while low < high:
        middle = (low + high) // 2
        if probe_native("webkit:%s" % order[middle]):
            high = middle
        else:
            low = middle + 1
    return order[low]


def refresh_native(engine, ids=None):
    """Ask one vendor what it still serves, and keep the answer. Never on the
    request path: the Edge feed is one request but the WebKit search is six, and
    a page that waited for either would be a page that hangs when a CDN does."""
    with _native_lock:
        if engine in _native_probing:
            return
        _native_probing.add(engine)
    try:
        found = None
        if engine == "edge":
            offers = cli_lines(["offers", "edge"], timeout=45)
            if offers is not None:
                found = {"offers": offers}
        elif engine == "webkit":
            floor = webkit_native_floor(ids or [])
            found = {"floor": floor}
        if found is None:
            return
        with _native_lock:
            data = read_native()
            data[engine] = dict(found, at=time.time())
            write_native(data)
    finally:
        with _native_lock:
            _native_probing.discard(engine)


def fill_versions(milestones):
    """Ask the dashboard what the uncatalogued Chromium milestones are called.

    Twenty-one milestones carry a hand-written version; the other seventy had
    nothing to print under their name, because a milestone number is not a
    version and inventing one would be worse than a blank. One request each, and
    the answer is a V row in the catalog cache - permanent, and no claim that a
    build has been found for this machine.
    """
    with _native_lock:
        if "versions" in _native_probing:
            return
        _native_probing.add("versions")
    try:
        cli_lines(["name-versions", *[str(m) for m in milestones]], timeout=180)
        with _native_lock:
            data = read_native()
            # Stamped even when some milestone could not be resolved, so a
            # dashboard that is down does not turn into a request every four
            # seconds for as long as the manager is open.
            data["versions"] = {"at": time.time()}
            write_native(data)
    finally:
        with _native_lock:
            _native_probing.discard("versions")


def native_available(engine, ident, native):
    """Can this host download this row, as far as anything here knows?

    True when nothing says otherwise: an unasked question is not a no, and a row
    that has never been probed behaves exactly as it did before any of this.
    """
    entry = native.get(engine)
    if not isinstance(entry, dict):
        return True
    if engine == "edge":
        offers = entry.get("offers")
        return True if not isinstance(offers, list) else ident in offers
    if engine == "webkit":
        floor = entry.get("floor")
        if floor is None:
            return False
        try:
            return int(ident) >= int(floor)
        except (TypeError, ValueError):
            return True
    return True


# The first Firefox whose mac package is universal. Below it Apple Silicon runs an
# x86_64 build under Rosetta, with no arm64 build to fall back to.
FIREFOX_UNIVERSAL = 84


def rosetta_ceiling(builds):
    """The highest milestone the catalog proves has no arm64 Mac build.

    Only twenty-odd milestones carry a verified row, so most of the shelf does
    not know which platform directory it will come from until a launch resolves
    it - and a row that says nothing about Rosetta cannot advise anything about
    it either. This is the part that can be said without resolving anything: at
    or below this milestone, no arm64 build exists, so Apple Silicon runs the
    x86_64 one under translation.

    Deliberately the last proven x86_64-only milestone rather than the first
    proven arm64 one. The gap between them is where nobody has checked, and
    guessing into it would put a warning on rows that may well run natively.
    """
    ceiling = None
    for milestone, platforms in builds.items():
        if "Mac" in platforms and "Mac_Arm" not in platforms:
            if ceiling is None or milestone > ceiling:
                ceiling = milestone
    return ceiling


_features_cache = {"at": None, "value": {}}


def features_path():
    return os.path.join(PROJECT, "features.tsv")


def read_features():
    """What each shelf version brought, keyed by (engine, id).

    Written by tools/features.py from MDN's browser-compat-data and shipped with
    the release: twenty megabytes of compat data resolved once, on someone else's
    machine, so nothing here fetches anything and the shelf works offline. Before
    it existed the only notes on the shelf were twenty-odd hand-written lines on
    curated Chromium milestones, and 270 rows had nothing to say at all.
    """
    try:
        stamp = os.path.getmtime(features_path())
    except OSError:
        return {}
    if _features_cache["at"] == stamp:
        return _features_cache["value"]
    found = {}
    try:
        with open(features_path()) as handle:
            for line in handle:
                parts = line.rstrip("\n").split("\t")
                if len(parts) < 5 or parts[0] != "F":
                    continue
                try:
                    count = int(parts[3])
                except ValueError:
                    continue
                names = [name for name in parts[4].split("|") if name]
                found[(parts[1], parts[2])] = {"count": count, "names": names}
    except OSError:
        return {}
    _features_cache["at"] = stamp
    _features_cache["value"] = found
    return found


def catalog_cache():
    """Milestones engineshelf.sh has resolved against the live archive.

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


def read_shelf():
    """The S rows: every release tools/discover.py found, per engine.

    Read separately from read_catalog because the two answer different questions
    and have different owners. V and B rows are Chromium's snapshot bookkeeping,
    written by refresh-catalog.py. S rows are the shelf itself, across all four
    engines, and carry a release date - which is what lets the page arrange them
    by year instead of by an engine's own version numbering, none of which line
    up with each other.
    """
    shelf = {engine: [] for engine in ENGINES}
    seen = set()
    # Cache last, so a row learned at runtime replaces the shipped one.
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
                if parts[0] != "S" or len(parts) < 6:
                    continue
                engine = parts[1]
                if engine not in shelf:
                    continue
                key = (engine, parts[3])
                if key in seen:
                    continue
                seen.add(key)
                shelf[engine].append({
                    "engine": engine,
                    "year": int(parts[2]),
                    "id": parts[3],
                    "label": parts[4],
                    "date": parts[5],
                })
    for releases in shelf.values():
        releases.sort(key=lambda r: r["date"], reverse=True)
    return shelf


def installed_by_key():
    """Every installed build, keyed by its directory name, whatever the engine.

    The directory name is the identity the CLI writes and the one Docker tags
    its images with, so this single lookup answers "is it on disk" for all four
    engines. It replaced a numeric, Chromium-only version of the same walk.
    """
    builds = {}
    base = os.path.join(root_dir(), "builds")
    if not os.path.isdir(base):
        return builds
    for name in os.listdir(base):
        path = os.path.join(base, name)
        if not os.path.exists(os.path.join(path, ".complete")):
            continue
        meta = read_meta(os.path.join(path, ".meta"))
        builds[name] = {
            "key": name,
            "engine": meta.get("META_ENGINE") or engine_of_key(name),
            "version": meta.get("META_VERSION") or name,
            "platformDir": meta.get("META_PLATFORM") or "?",
            "installedAt": meta.get("META_INSTALLED") or "",
            "sizeBytes": dir_size(path),
            "profileBytes": dir_size(os.path.join(root_dir(), "profiles", name)),
        }
    return builds


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
    """Parse the shell-sourced .meta written by engineshelf.sh."""
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


# The names engineshelf-docker.sh gives the things it creates. The manager
# reads them back, which is the only way a version living in a container can look
# like one living on disk; renaming any of them means changing both files.
CONTAINER_PREFIX = "engineshelf-"
IMAGE_REPO = "engineshelf"
VOLUME_PREFIX = "engineshelf-profile-"

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
    """What Docker is holding for EngineShelf: images, their size, containers.

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
        # One image per version, tagged with the revision it was built from.
        #
        # The size comes from `docker images`, rounded, and not from `image
        # inspect --format {{.Size}}`, which is exact and measures the wrong
        # thing. Against the containerd image store that field is the compressed
        # content size: two images here inspected as 371 MB and 507 MB while
        # `docker images` and `docker system df` both said 1.49 GB and 1.96 GB.
        # A gauge that exists to show what is filling the disk cannot be off by
        # four times, so a rounded true number beats an exact wrong one.
        for line in docker_out(["images", IMAGE_REPO,
                                "--format", "{{.Tag}}\t{{.Size}}"]).splitlines():
            parts = line.split("\t")
            if len(parts) < 2 or not parts[0] or parts[0] == "<none>":
                continue
            slot(parts[0])["imageBytes"] = parse_human_bytes(parts[1])

        # One container per version, named engineshelf-<revision>. Stopped
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


def docker_row(revision, status, selector=None):
    """The Docker side of one shelf row, or None if there is nothing to offer.

    A container always runs the Linux x86_64 build, so its revision is not the
    one this host installs natively - and comparing those two is exactly what
    used to hide a running container from the row it belonged to.
    """
    if not status.get("supported"):
        return None
    # A revision of None means "there is a container, but which Linux build it
    # runs has not been looked up yet". The launcher asks the archive when the
    # button is pressed and the answer lands in the catalog cache, so the row
    # fills itself in on the next read. Refusing to offer it until then is what
    # kept the Docker edition to the hand-catalogued milestones and nothing in
    # between them.
    if revision is None and selector is None:
        return None
    entry = (status["byRevision"].get(str(revision), {})
             if revision is not None else {})
    return {
        "revision": revision,
        # What to post back to run or stop this container. For Chromium that is
        # the Linux revision the image is built from; for WebKit the row's own
        # selector, which resolves to the same revision on both sides.
        "selector": selector if selector is not None else str(revision),
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
    """Whatever `engineshelf.sh doctor --json` says.

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


def shelf_row(engine, release, installed, builds, hosts, notes, docker,
               known_bad, rosetta_max, native):
    """One release, in the shape the list draws.

    Built from the S rows, which is where the whole shelf lives, plus everything
    needed to act on a row: the platform a build would come from, the Docker
    side, the curated note where there is one.
    """
    ident = release["id"]
    row = {
        "engine": engine,
        "id": ident,
        "label": release["label"],
        "year": release["year"],
        "date": release["date"],
        "note": "",
        "milestone": None,
        "revision": None,
        "docker": None,
        "native": True,
        "knownBad": False,
        # Whether the vendor will still hand this over. Separate from "native",
        # which is about architecture: a build can be perfectly runnable here and
        # simply no longer downloadable.
        "nativeAvailable": True,
    }

    if engine == "chromium":
        milestone = int(ident)
        available = builds.get(milestone, {})
        chosen = next((p for p in hosts if p in available), None)
        curated = notes.get(milestone) or {}
        row["milestone"] = milestone
        # Only twenty-odd milestones carry a hand-written note naming the
        # features that land there. The rest are shelf stock: real releases with
        # nothing to say about them beyond when they shipped.
        row["note"] = curated.get("note", "")
        row["version"] = curated.get("version") or release["label"]
        row["platformDir"] = chosen
        # Unknown is not unavailable. B rows exist only for the catalogued
        # milestones; every other one is resolved against the live archive on
        # first launch, so no B row means no key yet - not no build. Only rows
        # for this operating system's own platforms count as an answer.
        row["supported"] = chosen is not None or not any(
            key in available for key in os_platforms())
        row["native"] = chosen != "Mac" or platform.machine() != "arm64"
        # Same answer for a milestone with no verified row, where `chosen` is
        # None and the platform is settled at launch. Left alone, three quarters
        # of the shelf said nothing about Rosetta and so could not warn about it
        # either - including every milestone between the catalogued ones.
        if (chosen is None and rosetta_max is not None
                and milestone <= rosetta_max
                and platform.system() == "Darwin"
                and platform.machine() == "arm64"):
            row["native"] = False
        # Not "no build for this host" - a build that downloads, starts, and
        # dies. The row still offers the native launch; what changes is which
        # button leads.
        row["knownBad"] = str(milestone) in known_bad
        # Addressed by milestone rather than by the Linux revision: for most of
        # the shelf that revision is not resolved yet, and the launcher takes
        # either.
        row["docker"] = docker_row(linux_revision(milestone, builds), docker,
                                   str(milestone))
        if chosen:
            row["revision"] = available[chosen]["revision"]
            # The revision is what a Chromium build directory has always been
            # named and what the launcher has always been given, so it stays
            # both the key and the selector.
            row["key"] = row["selector"] = str(row["revision"])
        else:
            row["key"] = None
            row["selector"] = str(milestone)
    else:
        row["version"] = ident
        # Mozilla's mac package is universal from 84 on and x86_64 before it -
        # which is why lib/engines.sh has only one Firefox mac platform to name.
        # No S row says which of the two a version is, so the version number is
        # the only thing that can; and since the platform directory stays "mac"
        # either way, a download does not settle it later.
        if (engine == "firefox" and platform.system() == "Darwin"
                and platform.machine() == "arm64"):
            head = ident.split(".")[0]
            if head.isdigit() and int(head) < FIREFOX_UNIVERSAL:
                row["native"] = False
        row["nativeAvailable"] = native_available(engine, ident, native)
        row["key"] = "%s-%s" % (engine, ident)
        # The id, not the label: two WebKit builds are both called 26.5 and only
        # the id says which one this is.
        row["selector"] = "%s:%s" % (engine, ident)
        # Which platform a build comes from is settled against the vendor's own
        # index at launch time, so until then there is nothing honest to print.
        row["platformDir"] = None
        row["supported"] = True
        row["knownBad"] = row["selector"] in known_bad
        # All four engines have a container now, and for these three its image
        # is tagged with the same key the build directory uses - so the row can
        # see it without a second lookup. Chromium is the exception above: its
        # container runs a Linux revision this host never installs.
        row["docker"] = docker_row(row["key"], docker, row["selector"])

    local = installed.get(row["key"]) if row["key"] else None
    row["installed"] = local is not None
    row["sizeBytes"] = local["sizeBytes"] if local else 0
    row["profileBytes"] = local["profileBytes"] if local else 0
    row["installedAt"] = local["installedAt"] if local else ""
    # Once it is downloaded the platform is no longer a guess.
    if local and local.get("platformDir") and local["platformDir"] != "?":
        row["platformDir"] = local["platformDir"]
    return row


def build_state():
    versions, builds = read_catalog()
    hosts = host_platforms()
    docker = docker_status()
    # Keyed by directory name rather than by revision, which is what lets one
    # lookup serve all four engines.
    everything = installed_by_key()
    notes = {entry["milestone"]: entry for entry in versions}
    known_bad = known_bad_keys()
    rosetta_max = rosetta_ceiling(builds)
    native = read_native()

    # The list used to be the V rows and nothing else - twenty-one curated
    # Chromium milestones - so it showed Chromium alone while the S rows beside
    # it showed four engines. Same shelf, same rows, one source.
    rows = []
    for engine, releases in read_shelf().items():
        for release in releases:
            rows.append(shelf_row(engine, release, everything, builds, hosts,
                                  notes, docker, known_bad, rosetta_max,
                                  native))
    # Asked in the background, after the rows are built from whatever the last
    # answer was: the first page load of a fresh install is exactly as fast as
    # before, and the shelf sharpens a few seconds later.
    for engine in ("edge", "webkit"):
        if native_stale(native, engine):
            ids = [r["id"] for r in rows if r["engine"] == engine]
            threading.Thread(target=refresh_native, args=(engine, ids),
                             daemon=True).start()

    if native_stale(native, "versions"):
        unnamed = [row["milestone"] for row in rows
                   if row["engine"] == "chromium" and row["milestone"]
                   and row["version"] == row["label"]]
        if unnamed:
            threading.Thread(target=fill_versions, args=(unnamed,),
                             daemon=True).start()

    # Nothing anywhere can run this version: the vendor stopped serving it and its
    # engine has no container either. A row that cannot be acted on at all is not
    # information, it is a dead entry in a list of 288.
    #
    # Deliberately not "and Docker is not installed on this machine": that would
    # hide seventy versions from someone who has yet to set Docker up and hand
    # them back when they do, which is a shelf that changes size for reasons
    # nobody can see. As it stands all four engines have a container, so this
    # removes nothing - it is one vendor decision away from mattering.
    rows = [row for row in rows
            if row["nativeAvailable"] or row["engine"] in CONTAINERISED]

    # Newest first across engines. A release date is the only ordering four
    # numbering schemes share; the page re-sorts, this just makes the default sane.
    rows.sort(key=lambda r: r["date"], reverse=True)

    # Builds sitting in the builds directory that no shelf row claims: added by
    # raw revision, or left behind by a release that has since dropped off a
    # vendor's index. A container for a Chromium one still runs the Linux build
    # of whatever milestone it belongs to, so it is looked up the same way the
    # launcher looks it up.
    claimed = {row["key"] for row in rows if row["key"]}
    extra = []
    for key, info in sorted(everything.items()):
        if key in claimed:
            continue
        engine = info["engine"]
        row = dict(info, note="Installed by revision.", supported=True,
                   native=True, docker=None, milestone=None, revision=None,
                   knownBad=False, nativeAvailable=True,
                   label=info["version"], id=key, year=None, date="")
        row["id"] = key if engine == "chromium" else key[len(engine) + 1:]
        if engine == "chromium" and key.isdigit():
            revision = int(key)
            row["revision"] = revision
            row["selector"] = key
            milestone = milestone_of(revision, builds)
            row["knownBad"] = milestone is not None and str(milestone) in known_bad
            row["docker"] = docker_row(
                linux_revision(milestone, builds) if milestone is not None
                else revision, docker)
        else:
            row["selector"] = "%s:%s" % (engine, key[len(engine) + 1:])
            row["docker"] = docker_row(key, docker, row["selector"])
        extra.append(row)

    # Summed over every engine, not over the rows above: those are Chromium's
    # catalogue, so a gauge built from them reported a 2.2 GB directory as 589 MB
    # the moment anything other than Chromium was installed.
    browser_bytes = sum(i["sizeBytes"] for i in everything.values())
    profile_bytes = sum(i["profileBytes"] for i in everything.values())
    total = browser_bytes + profile_bytes
    return {
        "root": root_dir(),
        "os": platform.system().lower(),
        "arch": platform.machine(),
        "hostPlatforms": hosts,
        "versions": rows,
        "extra": extra,
        "engines": [{"id": e, "name": ENGINE_NAMES[e]} for e in ENGINES],
        "installedCount": len(everything),
        "browserBytes": browser_bytes,
        "profileBytes": profile_bytes,
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

    def revision(self):
        """What a window needs in order to know it has missed something.

        Two windows onto one manager each poll on their own four-second clock,
        so a download started in one took up to four seconds to appear in the
        other. This rides along on the heartbeat instead - it changes exactly
        when a job appears, finishes or is stopped, which is when the other
        window has to look again. Progress is not in here: that is what the
        faster refresh while something is running is for.
        """
        with self._lock:
            return ",".join(f"{job['id']}:{job['status']}"
                            for job in self._jobs.values())

    def summary(self):
        with self._lock:
            return [
                {"id": j["id"], "kind": j["kind"], "revision": j["revision"],
                 "label": j["label"], "status": j["status"]}
                for j in self._jobs.values() if j["status"] == "running"
            ]


jobs = Jobs()


# --------------------------------------------------------------------------- #
# raising a window
#
# A running container's desktop is a tab this page opened, so the page can focus
# it on its own. A native window belongs to the machine: nothing in the browser
# has a handle on it, and the row's only offer used to be Stop or a second launch
# of something already running. So the server raises it, with whatever the
# platform gives it and an honest answer when it has nothing.
# --------------------------------------------------------------------------- #

def _text_of(argv, timeout=4):
    """stdout of a short command, or '' if it is not there or does not answer."""
    try:
        done = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.SubprocessError):
        return ""
    return done.stdout


def _worked(argv, timeout=4):
    try:
        return subprocess.run(argv, capture_output=True, timeout=timeout).returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


def raise_window(pid):
    """Bring a launched browser's own window to the front.

    A job's pid is the launcher, not the browser - the thing with a window is
    whatever the launcher started in the same process group, which is why the
    group is what gets searched rather than the pid. Returns None once something
    has been raised, or the reason it could not be.
    """
    if not pid:
        return "That browser is no longer running."
    try:
        pgid = os.getpgid(pid)
    except (ProcessLookupError, PermissionError, OSError):
        return "That browser is no longer running."
    pids = [word for word in _text_of(["pgrep", "-g", str(pgid)]).split() if word.isdigit()]
    if not pids:
        return "That browser is no longer running."

    if sys.platform == "darwin":
        # Every mac build runs out of a bundle, and `open -a` on a bundle whose
        # app is already up activates that copy rather than starting a second
        # one. The two obvious alternatives - System Events, or an activate
        # Apple event - both need a permission this app has never asked for, and
        # a machine that has not granted it refuses them without a word.
        for one in pids:
            command = _text_of(["ps", "-o", "comm=", "-p", one]).strip()
            cut = command.find(".app/Contents/MacOS/")
            if cut < 0:
                continue
            if _worked(["open", "-a", command[:cut + len(".app")]]):
                return None
        return "Could not find a window belonging to that browser."

    # X11. wmctrl first because it lists the owning pid of every window, so the
    # right one is picked before anything is activated; xdotool searches by pid
    # instead, which is the same answer by a different route.
    wanted = set(pids)
    for line in _text_of(["wmctrl", "-l", "-p"]).splitlines():
        parts = line.split(None, 4)
        if len(parts) >= 3 and parts[2] in wanted:
            if _worked(["wmctrl", "-i", "-a", parts[0]]):
                return None
    for one in pids:
        for window in _text_of(["xdotool", "search", "--pid", one]).split():
            if _worked(["xdotool", "windowactivate", window]):
                return None
    return (
        "Raising a window from here needs wmctrl or xdotool and neither "
        "answered. Under Wayland neither can do it at all - the browser is "
        "open, so switch to it the way the desktop does."
    )


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
    "port": 0,
    "url": "",
    "owner": 0,         # the app hosting the window, when it is not a browser
}


# --------------------------------------------------------------------------- #
# one manager at a time
#
# Opening the app again while it is running used to start a second manager: a
# second server on the next free port, and a second window - which the copy of
# Chrome already running takes over, so the process this one was watching exits
# immediately. That reads as "the window was closed", and the new manager quits
# a second after starting, stopping the containers the first one was running on
# its way out. The window it opened is left pointing at a server that is gone.
#
# So a launch asks first, and if a manager answers, this one opens that
# manager's window again and gets out of the way.
# --------------------------------------------------------------------------- #

def state_path():
    return os.path.join(root_dir(), "manager.json")


def write_state(port, url):
    """Where the next launch will look. Best effort: a manager that cannot
    write this still runs, the next one just has to find it by port."""
    try:
        with open(state_path(), "w") as handle:
            json.dump({"pid": os.getpid(), "port": port, "url": url,
                       "started": time.time()}, handle)
    except OSError:
        pass


def read_state():
    try:
        with open(state_path()) as handle:
            state = json.load(handle)
    except (OSError, ValueError):
        return None
    return state if isinstance(state, dict) else None


def clear_state():
    """Only if it is still ours. A manager that started over a stale file has
    already been replaced there by the one that took the port."""
    try:
        with open(state_path()) as handle:
            if json.load(handle).get("pid") != os.getpid():
                return
        os.remove(state_path())
    except (OSError, ValueError):
        pass


def alive_at(port):
    """The manager answering on this port, or None.

    Unauthenticated on purpose: this is how a launch finds out that another one
    is already here, before there is any way for it to have been handed a token.
    It says nothing that connecting to the port would not already say.
    """
    try:
        with urllib.request.urlopen(
            f"http://127.0.0.1:{port}/api/alive", timeout=2
        ) as response:
            answer = json.loads(response.read().decode("utf-8"))
    except Exception:
        # Refused, timed out, or something else entirely listening there.
        return None
    return answer if isinstance(answer, dict) and answer.get("engineshelf") else None


def pid_alive(pid):
    if not isinstance(pid, int) or pid <= 0 or pid == os.getpid():
        return False
    try:
        os.kill(pid, 0)
    except OSError as error:
        # Not ours to signal is still a process that exists.
        return getattr(error, "errno", None) == errno.EPERM
    return True


def port_open(port):
    if not isinstance(port, int):
        return False
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=0.5):
            return True
    except OSError:
        return False


def running_manager(preferred_port):
    """Whichever manager is already up on this machine, if any."""
    state = read_state()
    ports = []
    if state and isinstance(state.get("port"), int):
        ports.append(state["port"])
    # The file can be missing - deleted, or never written by a manager that had
    # nowhere to write it - and the default port is where one would be anyway.
    for port in (preferred_port, 7411):
        if port not in ports:
            ports.append(port)
    for port in ports:
        found = alive_at(port)
        if found and found.get("root", root_dir()) == root_dir():
            return found
    # A manager a second old has claimed its port and written its file but is
    # not answering yet: it runs the CLI once before it starts serving. Two
    # quick presses on the app icon land exactly there, so a live process
    # holding the port it claimed counts as one.
    if state and pid_alive(state.get("pid")) and port_open(state.get("port")):
        return state
    return None


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


def running_containers():
    listed = docker_out(["ps", "--filter", f"name={CONTAINER_PREFIX}",
                         "--format", "{{.Names}}"], timeout=8)
    return [name for name in listed.split() if name.startswith(CONTAINER_PREFIX)]


# Which containers were already up when this manager opened. Anything in here
# belongs to somebody else - another manager, or a `./engineshelf-docker.sh start`
# in a terminal - and quitting must not take it down with us.
_inherited = set()


def note_inherited():
    _inherited.update(running_containers())


def stop_containers():
    """Stop and remove the containers this manager started, if any are up.

    Named the way engineshelf-docker.sh names them, and stopped the way it stops
    them: SIGTERM first, because killed outright the browser inside leaves a lock
    in its profile volume that breaks the next start.

    Only the ones that came up on our watch. This used to stop every container
    with the prefix, so a second manager quitting - or this one restarting while a
    container was up - silently took down containers it had never started.
    """
    names = [name for name in running_containers() if name not in _inherited]
    if not names:
        return
    say(f"  Stopping {len(names)} Docker container{'s' if len(names) > 1 else ''}...")
    docker_out(["stop", "-t", "10", *names], timeout=90)
    docker_out(["rm", "-f", *names], timeout=30)


def tidy_cut_off(revisions):
    """Clear up after downloads the shutdown interrupted.

    engineshelf.sh removes both of these itself when a download fails, but a
    job killed outright never reaches that code - and closing the window is now
    an ordinary way for a download to end, so an 80 MB orphan every time is not
    acceptable. The zip cannot be resumed either: the CLI fetches it whole.

    Only revisions this process was working on. Another manager may be running
    against the same directory, and its download is not ours to delete.
    """
    root = root_dir()
    for revision in revisions:
        # A job is keyed by selector and a build directory by key, and for the
        # three non-Chromium engines those differ by one character: the launcher
        # downloads webkit:2336 into builds/webkit-2336.
        key = str(revision).replace(":", "-")
        # The archive has no suffix on this side and a .zip on Windows; the
        # shutdown path only ever removed the Windows one, so every interrupted
        # download here left its archive behind.
        for partial in (f".download-{key}", f".download-{key}.zip"):
            try:
                os.remove(os.path.join(root, partial))
            except OSError:
                pass
        build = os.path.join(root, "builds", key)
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
        say(f"  Stopping {len(running)} running job{'s' if len(running) > 1 else ''}...")
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
    say(f"\n  Closing ({reason}).")
    stop_everything()
    clear_state()
    server = _life["server"]
    if server is not None:
        # From another thread: shutdown() cannot be called from the one serving.
        threading.Thread(target=server.shutdown, daemon=True).start()


def watch_window():
    """Quit once the window is gone, by either of the two signals above.

    Every second is its own attempt. The manager used to lose this thread to one
    exception and go on serving with nothing watching it: the app that owns the
    window is the far end of stdout, so killing the app broke the pipe, and the
    print on the way out took the watchdog with it.
    """
    last_tick = time.time()
    while not _life["quitting"]:
        try:
            time.sleep(1)
            now = time.time()
            slept, last_tick = now - last_tick, now
            # A second that took much longer than a second means the machine was
            # suspended, not that the window closed - and on wake the page has
            # had no chance to say anything yet. Without this, shutting a laptop
            # lid for a minute took the manager and everything it was running
            # down with it.
            if slept > 5:
                _life["seen"] = now
                continue
            if not _life["auto"]:
                continue
            # The macOS app hosts the window itself rather than handing it to a
            # browser, so there is no browser process to watch - what stands in
            # for it is the app, and a manager whose app is gone has no window.
            owner = _life["owner"]
            if owner:
                if not pid_alive(owner):
                    return quit_now("the manager window was closed")
                continue
            shell = _life["shell"]
            if shell is not None:
                # We own the window, so its process ending is the signal - and
                # the only one. A window parked in another Stage Manager set, or
                # simply covered by another app, is occluded, and Chrome
                # throttles a page it cannot see until the heartbeat below stops
                # arriving. The manager read that as a window that had closed
                # and quit while its own window was sitting there - taking the
                # browsers and containers with it.
                if shell.poll() is not None:
                    return quit_now("the manager window was closed")
                continue
            # Nothing has connected yet: the browser may still be starting, and
            # a manager that quit before its own window opened would be a fine
            # joke.
            if not _life["seen"]:
                continue
            if time.time() - _life["seen"] > GRACE_SECONDS:
                return quit_now("the manager page stopped answering")
        except Exception as error:
            say(f"  (watchdog: {error})")
            last_tick = time.time()


# --------------------------------------------------------------------------- #
# http
# --------------------------------------------------------------------------- #

class Handler(BaseHTTPRequestHandler):
    server_version = "EngineShelf"

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
        if not secrets.compare_digest(self.headers.get("X-EngineShelf-Token", ""), TOKEN):
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

        if path == "/api/alive":
            # Before the token check on purpose, and not a heartbeat: this is
            # another launch asking whether it should be a manager at all.
            # The root matters: two managers pointed at two different home
            # directories are two different shelves, and neither should stand
            # aside for the other.
            return self._json({"engineshelf": True, "pid": os.getpid(),
                               "port": _life["port"], "url": _life["url"],
                               "root": root_dir()})

        if path == "/api/state":
            if not self._authorised():
                return self._json({"error": "unauthorised"}, 403)
            return self._json(build_state())

        # Its own endpoint, and not part of the state document, because it never
        # changes: a shipped file describing releases that already happened. In
        # the state it would have been 146 KB re-sent every second a job is
        # running, for the sake of a search box that only needs it once.
        if path == "/api/features":
            if not self._authorised():
                return self._json({"error": "unauthorised"}, 403)
            found = read_features()
            return self._json({"%s:%s" % key: value
                               for key, value in found.items()})

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
            return self._json({"autoQuit": _life["auto"], "grace": GRACE_SECONDS,
                               "revision": jobs.revision()})

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
            # Read before the kill: a stopped job still reports its kind, but
            # only the running one is worth clearing up after.
            job = jobs.get(job_id)
            stopped = jobs.stop(job_id)
            # Cancelling a download is now a button rather than only a side
            # effect of quitting, so it gets the same clear-up: the archive is
            # fetched whole and cannot be resumed, and a part-unpacked build
            # directory is dead weight. A launch that had already opened the
            # browser keeps everything - .complete is what says so.
            if stopped and job and job.get("kind") in ("install", "launch"):
                threading.Timer(1.0, tidy_cut_off, [[job["revision"]]]).start()
            return self._json({"stopped": stopped})

        # Before the selector guard below, like /api/stop: a raise names the job
        # whose window it wants, and the job knows its own revision.
        if path == "/api/raise":
            job = jobs.get(str(body.get("job", "")).strip())
            if not job or job.get("kind") != "launch" or job.get("status") != "running":
                return self._json({"error": "That browser is no longer running."}, 409)
            problem = raise_window(job.get("pid"))
            if problem:
                return self._json({"error": problem}, 409)
            return self._json({"raised": True})

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

        if not SELECTOR_RE.match(selector):
            return self._json({"error": "bad selector"}, 400)

        if path == "/api/install":
            job_id = jobs.start("install", selector, ["bash", CLI, "install", selector],
                                f"Installing {selector_label(selector)}")
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
            job_id = jobs.start("launch", selector, argv, selector_label(selector))
            return self._json({"job": job_id})

        if path == "/api/remove":
            argv = ["bash", CLI, "remove", selector]
            if body.get("withProfile"):
                argv.append("--with-profile")
            job_id = jobs.start("remove", selector, argv,
                                f"Removing {selector_label(selector)}")
            return self._json({"job": job_id})

        if path == "/api/clean":
            job_id = jobs.start("clean", selector, ["bash", CLI, "clean", selector],
                                f"Resetting profile {selector_label(selector)}")
            return self._json({"job": job_id})

        if path == "/api/docker":
            action = str(body.get("action", "start"))
            if action not in ("start", "build", "stop", "rebuild", "purge"):
                return self._json({"error": "bad action"}, 400)
            # Every engine has a container. An unknown one still gets refused
            # here rather than in a job log nobody has open.
            engine = selector.split(":", 1)[0] if ":" in selector else "chromium"
            if engine not in ENGINES:
                return self._json({"error": "Unknown engine: %s" % engine}, 400)
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
    parser.add_argument("--new", action="store_true",
                        help="start another manager even if one is running")
    parser.add_argument("--owner-pid", type=int, default=0,
                        help="quit when this process does; the app hosting the window")
    args = parser.parse_args()

    if not os.path.exists(CLI):
        raise SystemExit(f"Missing {CLI}")

    # Opening the app again is how someone asks for the window back, not for a
    # second manager - and a second one cannot work anyway: the window it opens
    # belongs to the browser process the first one is already watching.
    if not args.new:
        found = running_manager(args.port)
        if found:
            url = found.get("url") or f"http://127.0.0.1:{found.get('port')}/"
            say()
            say(f"  EngineShelf is already running  ->  {url}")
            if args.no_open:
                say("  Left as it is; that manager is still serving.")
            elif not args.tab and open_app_window(url) is not None:
                say("  Opened its window again.")
            else:
                webbrowser.open(url)
                say("  Opened it in a tab.")
            say()
            return

    # Claimed before the slow parts below, so a second launch a moment later
    # finds this one rather than racing it onto the next port.
    port = pick_port(args.port)
    url = f"http://127.0.0.1:{port}/"
    # Before anything of ours can be up, so the snapshot is honest about what was
    # already running.
    threading.Thread(target=note_inherited, daemon=True).start()

    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    _life["server"] = server
    _life["port"] = port
    _life["url"] = url
    write_state(port, url)

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

    # Nothing was opened, so there is no window whose closing could mean
    # anything; this is the shape a script or a remote session asks for, and it
    # waits. An owner is the exception: --no-open there means the window is
    # somewhere else, not that there is none.
    _life["owner"] = args.owner_pid if pid_alive(args.owner_pid) else 0
    _life["auto"] = not (args.keep_alive or (args.no_open and not _life["owner"]))

    # Asked to stop rather than interrupted - which is how the app that owns the
    # window says the window has closed. Without this the browsers and the
    # containers it started would be left behind.
    def on_signal(*_args):
        quit_now("asked to stop")

    try:
        signal.signal(signal.SIGTERM, on_signal)
    except (ValueError, OSError):
        pass

    shell = None
    if not args.no_open and not args.tab:
        shell = open_app_window(url)
        _life["shell"] = shell
    elif not args.no_open:
        threading.Timer(0.4, lambda: webbrowser.open(url)).start()

    say()
    say(f"  EngineShelf manager  ->  {url}")
    say(f"  Files: {root_dir()}")
    if _life["owner"]:
        # The window is the app's own, and the app is what this reads as gone.
        say("  Closing the window quits the manager, the browsers it opened")
        say("  and any Docker containers it started.")
    elif shell is not None:
        say("  Closing the window quits the manager, the browsers it opened")
        say("  and any Docker containers it started.")
    elif not _life["auto"]:
        say("  Press Ctrl-C to stop the manager.")
    else:
        # No window of our own: the page's heartbeat is the only thing that can
        # say it is still there, so say what silence will be taken to mean.
        say("  Opened as a browser tab. Closing it quits the manager, the")
        say(f"  browsers it opened and any containers it started, {GRACE_SECONDS}s later.")
    say("  Ctrl-C does the same.")
    say()

    threading.Thread(target=watch_window, daemon=True).start()

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        quit_now("Ctrl-C")
    say("  Manager stopped.")


if __name__ == "__main__":
    main()
