#!/usr/bin/env python3
"""ChromiumStack GUI backend (macOS / Linux).

Serves the static page in this directory and a small JSON API. All real work -
install, launch, remove, reset - is delegated to chromium-stack.sh, so the GUI and
the command line cannot drift apart. State (what is installed, how big it is) is
read straight off disk, which is cheap and needs no subprocess.

Bound to 127.0.0.1 and gated on a per-run token, so a web page you happen to have
open cannot drive your browser installs.

    python3 gui/server.py [--port N] [--no-open]
"""
import argparse
import json
import mimetypes
import os
import platform
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


def docker_status():
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
    return {"cli": cli, "running": running, "supported": os.path.exists(DOCKER_CLI)}


def doctor_report():
    """Whatever `chromium-stack.sh doctor --json` says.

    The checks live in lib/preflight.sh so the CLI, the Docker launcher and this
    page cannot disagree about what is missing or how to fix it.
    """
    try:
        result = subprocess.run(
            ["bash", CLI, "doctor", "--json"], cwd=PROJECT, capture_output=True,
            text=True, timeout=25,
        )
        return json.loads(result.stdout)
    except (OSError, subprocess.SubprocessError, ValueError):
        return {"os": platform.system().lower(), "arch": platform.machine(), "components": []}


def build_state():
    versions, builds = read_catalog()
    hosts = host_platforms()
    installed = installed_builds()
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

    # Builds installed by raw revision that no catalogue row claims.
    extra = [dict(info, note="Installed by revision.", supported=True, native=True)
             for revision, info in sorted(installed.items()) if revision not in catalogued]

    total = sum(i["sizeBytes"] + i["profileBytes"] for i in installed.values())
    return {
        "root": root_dir(),
        "os": platform.system().lower(),
        "arch": platform.machine(),
        "hostPlatforms": hosts,
        "versions": rows,
        "extra": extra,
        "totalBytes": total,
        "docker": docker_status(),
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
        POSTing here, so every API call must carry the token printed at start."""
        host = (self.headers.get("Host") or "").split(":")[0]
        if host not in ("127.0.0.1", "localhost", "[::1]", "::1"):
            return False
        return secrets.compare_digest(self.headers.get("X-ChromiumStack-Token", ""), TOKEN)

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
            if action not in ("start", "stop", "logs"):
                return self._json({"error": "bad action"}, 400)
            job_id = jobs.start("docker", selector, ["bash", DOCKER_CLI, action, selector],
                                f"Docker {action} {selector}")
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
    parser.add_argument("--no-open", action="store_true")
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

    print()
    print(f"  ChromiumStack manager  ->  {url}")
    print(f"  Files: {root_dir()}")
    print("  Press Ctrl-C to stop the manager (running browsers stay open).")
    print(flush=True)

    if not args.no_open:
        threading.Timer(0.4, lambda: webbrowser.open(url)).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n  Manager stopped.")


if __name__ == "__main__":
    main()
