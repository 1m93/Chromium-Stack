# ChromiumStack

Run an **old browser engine** on a modern machine, as an ordinary desktop browser you
can click around in.

Pick a Chromium version from a list, press **Launch**, and it downloads that build once
and opens it. No Node, no build step, no BrowserStack account, nothing to sign up for.
Sixteen milestones from **Chromium 60 (2017)** to **130 (2024)** are catalogued, and any
other build in the Chromium snapshot archive works too.

## Why you might want this

- A site has to keep working on an **old Android System WebView** — kiosks, POS
  terminals, handheld scanners and industrial devices routinely ship a WebView that is
  years behind, and it is the *engine*, not the OS, that decides whether your CSS
  survives.
- Your `browserslist` claims to support an old floor and you would like to find out
  whether that is true.
- A customer is stuck on a locked-down browser and reports a bug you cannot reproduce.
- **A bug appeared somewhere between two versions** and you want to bisect it by opening
  the same page in 90, 105 and 120 side by side.

An unsupported CSS declaration in an old engine is **dropped, not degraded**, so layouts
break in ways that never show up in a current browser.

## Quick start

| OS | Do this |
|---|---|
| **macOS** | Double-click **`ChromiumStack.app`** |
| **Windows** | Double-click **`ChromiumStack.exe`** |
| **Linux** | Run `./gui.sh` (or double-click `chromium-stack.desktop`) |

Keep the launcher inside the project folder — it finds everything else relative to
itself.

On Windows, `ChromiumStack.exe` carries its own icon and needs nothing installed: it
chdirs next to itself and hands over to `gui.ps1` with `-ExecutionPolicy Bypass`, so an
unconfigured machine does not refuse the script. `ChromiumStack.bat` still works and does
the same thing, if you would rather run a script you can read than a binary. To get the
launcher out of the project folder, `tools\install-shortcut.ps1` puts a shortcut to it on
your Desktop and in the Start Menu.

That opens the **manager** in your normal browser: a list of every version, which ones
are installed, how much disk each is using, and a button to launch, install or delete
each one.

The first launch of any version downloads it (~90–300 MB, a few minutes). Later launches
are instant.

Prefer the terminal? Everything the manager does is one command:

```bash
./chromium-stack.sh run 74        # install if needed, then launch Chromium 74
```

## The manager

Everything is on one page, served from `127.0.0.1` by a small local server.

- **Launch / Install & launch** — downloads the build if it is missing, then opens it.
- **Open URL** — type a URL once at the top and every launch opens it. A bare
  `localhost:4173` is fine.
- **Window size** and **Graphics** apply to the next launch.
- **···** on each row — download without launching, run that version in Docker, reset its
  profile, or delete it.
- **Add by revision** — install any snapshot revision, not just the catalogued ones.
- **System check** in the header — the same dependency report as `doctor`, with buttons
  that install what is missing.
- **The log panel** at the bottom — everything the manager runs, whether a download, a
  dependency install or a Docker container, streams its output there line by line, the same
  text a terminal would show. While a job is running the row it belongs to says so, and
  clicking that row's button brings its log back up.
- The disk figure in the header is the total across every downloaded browser and profile,
  so it is obvious when it is time to delete something.

Closing the terminal window stops the manager. Browsers it launched keep running.

Nothing listens outside this machine: the server binds to `127.0.0.1` and every request
has to carry a token generated for that run, so a web page you happen to have open
cannot drive your browser installs.

> The manager needs **Python 3** on macOS and Linux (macOS: it comes with
> `xcode-select --install`). Windows uses PowerShell and needs nothing extra. The command
> line needs neither.

## When something is missing

ChromiumStack needs very little, and tells you when a piece is absent rather than failing
halfway through a download.

```bash
./chromium-stack.sh doctor         # what is installed, what is not, and why it matters
./chromium-stack.sh doctor --fix   # offer to install each missing piece
./chromium-stack.sh doctor --json  # the same report, for scripts
```

It never installs anything silently. For each missing piece it prints the exact command
it would run, what that will cost you, and waits for a yes:

```
  Docker - Only for the Docker edition, which avoids Rosetta on Apple Silicon.
  This will run:
    brew install colima docker
  Colima and the docker CLI, not Docker Desktop. A few hundred MB via Homebrew.

  Run it now? [y/N]:
```

| | Needed for | If missing |
|---|---|---|
| **curl** | downloading the browsers | nothing works |
| **unzip** | extracting them on Linux | not needed if `python3` is there; macOS uses `ditto` |
| **Python 3** | the graphical manager | the command line still works |
| **Rosetta 2** | milestones up to 90 on Apple Silicon | those versions will not start |
| **Docker** | the Docker edition only | everything else works |

The manager shows the same information under **System check**, and puts a panel at the
top of the page when something is missing. Its **Install** buttons run the same commands.
Where a fix needs administrator rights, macOS asks through the system password dialog;
elsewhere the manager says plainly that it needs a terminal rather than failing on
`sudo: no tty present`.

The manager is written in Python, so it cannot be what tells you Python is missing —
`gui.sh` checks first and offers the install before starting.

Windows needs none of this: PowerShell 5.1 ships with the OS and runs both the launcher
and the manager, downloads go through `Invoke-WebRequest` and archives through .NET. Only
Docker is ever reported as missing there.

## Command line

The manager is a front end for this; both do the same things, so they cannot drift apart.

```bash
./chromium-stack.sh catalog                    # versions available for this machine
./chromium-stack.sh list                       # what is installed, with disk usage
./chromium-stack.sh run 74                     # install if needed, then launch
./chromium-stack.sh run 120 localhost:4173     # launch 120 on a URL
./chromium-stack.sh run 638880                 # launch a raw snapshot revision
./chromium-stack.sh install 90                 # download without launching
./chromium-stack.sh remove 90                  # delete a downloaded browser
./chromium-stack.sh clean 90                   # reset that version's profile
./chromium-stack.sh doctor                     # check dependencies
./chromium-stack.sh gui                        # open the manager
```

Options for `run`:

```bash
--size 1280x800      # fixed window size
--gpu / --no-gpu     # force hardware acceleration on or off
--no-restart         # do not relaunch after a crash
-- --any-chrome-flag # anything after -- goes to Chromium
```

`<version>` is a milestone (`74`) or a snapshot revision (`638880`). Milestones are small
and revisions are six digits or more, so there is no ambiguity to resolve.

Windows uses the same commands via `.\chromium-stack.ps1`.

## Profiles are per version

Every version gets **its own profile**. This is not tidiness — Chromium writes a version
number into the profile and **refuses to open one written by a newer build**, so a single
shared profile would break the moment you ran a newer version and then went back. Logging
into a test environment in 74 does not affect 120, and neither touches your everyday
browser.

## It is a real browser

Address bar, tabs, bookmarks, history, downloads and DevTools all work, and each profile
persists between launches. Visit anything you like.

Bear in mind the old ones really are old: sites that require a modern engine may refuse
to load or render oddly, and some will nag you to upgrade. That is the browser being
honest, not the tool misbehaving.

## Testing your own site

**Point it at a production build, not your dev server.** Most modern dev servers (Vite,
Next.js, and friends) ship your source untranspiled and skip the CSS-fallback step, so an
old browser chokes on the dev server even when the shipped build is perfectly fine. A
blank page on `localhost:3000` usually means "the dev server is modern", not "my code is
broken".

Build the site the way you deploy it, serve the output, and open *that*.

## Managing disk space

Each version is a separate 90–300 MB download, so a few of them add up. The **···** menu
on any installed row offers:

| Action | Frees | Keeps |
|---|---|---|
| **Reset profile** | the profile | the browser |
| **Delete browser** | the browser | the profile, so reinstalling restores your session |
| **Delete browser and profile** | both | nothing |

From the command line:

```bash
./chromium-stack.sh list                    # what is installed, and how big
./chromium-stack.sh remove 74               # delete the browser, keep the profile
./chromium-stack.sh remove 74 --with-profile
./chromium-stack.sh clean 74                # reset just the profile
```

Docker images are the other place disk quietly disappears:

```bash
./chromium-stack-docker.sh list             # containers and images
./chromium-stack-docker.sh purge 74         # remove that version's image
```

## Which versions are available

`catalog.tsv` pins one verified build per milestone per platform. Each revision in it was
confirmed to exist in the archive, because not every commit position is built — the
nearest archived build is sometimes tens of commits away.

| | |
|---|---|
| **60, 65, 70** | 2017–2018. Hard floors for very old WebViews. |
| **74, 76, 80** | 2019–2020. No flexbox `gap`; optional chaining arrives in 80. |
| **85, 90** | 2020–2021. Flexbox `gap`, `aspect-ratio`, `:is()`. |
| **95, 100, 105** | 2021–2022. Container queries and `:has()` arrive in 105. |
| **110, 115, 120** | 2023. `dvh`, CSS nesting, view transitions, `subgrid`. |
| **125, 130** | 2024. Near-current — useful as the control when bisecting. |

Regenerate it against the live archive at any time:

```bash
python3 tools/refresh-catalog.py           # rewrite catalog.tsv
python3 tools/refresh-catalog.py --check   # verify without writing
```

To add a milestone, put it in `MILESTONES` in that script and rerun.

### A version that is not in the catalog

Use **Add by revision** in the manager, or pass the revision straight to the CLI. Look up
the branch base position for a milestone:

```bash
curl -s "https://chromiumdash.appspot.com/fetch_milestones?mstone=74" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['chromium_main_branch_position'])"
# 638880
```

Then `./chromium-stack.sh run 638880`. If that exact position was never archived for your
platform the tool says so — try one a few commits later.

## Docker edition

Runs the **Linux x86_64** build in a container and shows its desktop in a tab of your
normal browser (noVNC). It never touches Rosetta, so on Apple Silicon it avoids the crash
described under *Stability*.

```bash
./chromium-stack-docker.sh start 74      # build if needed, run, open the desktop
./chromium-stack-docker.sh stop 74
./chromium-stack-docker.sh logs 74
./chromium-stack-docker.sh rebuild 74    # rebuild the image from scratch
./chromium-stack-docker.sh list          # containers and images
./chromium-stack-docker.sh purge 74      # delete that version's image
```

Each version gets its own image, container, profile volume and port, so several can run
side by side. Windows uses `.\chromium-stack-docker.ps1` with the same commands.

Things to know:

- **Reaching your machine.** Inside the container, `localhost` is the container. Use
  **`http://host.docker.internal:4173`** to reach a server running on your own machine.
- **On Apple Silicon** the container is emulated, so it is noticeably slower than the
  native launcher. Fine for a careful pass over a screen, tiring for a long session.
- **Viewport.** The browser window fills the virtual screen (1440×900 by default, change
  `SCREEN` in `docker/Dockerfile`), and Chromium's warning infobars are suppressed so they
  do not eat viewport height and skew a layout check.
- The first start of each version builds an image (several minutes under x86 emulation).
  After that the launcher reuses it.

### If the machine has no Docker

**Docker is optional.** The native launcher needs nothing installed, and that is what most
people should use. Only reach for this edition if the native one crashes too often for
you.

The launcher does not install anything behind your back. What it does:

- **Docker installed but not running** → it starts it for you (Colima, `systemctl`, the
  engine in your WSL distro, or a Docker Desktop you installed yourself — whichever
  applies) and waits up to 90 seconds for the daemon.
- **Docker not installed at all** → it prints the exact command it would run, says how big
  the download is, and asks `[y/N]`. Answer `n` and it stops without touching anything.

| OS | Offer | What that is |
|---|---|---|
| macOS | `brew install colima docker` | Colima and the `docker` CLI. Needs Homebrew. |
| Linux | `curl -fsSL https://get.docker.com \| sudo sh` | Docker Engine and the CLI. Needs sudo. |
| Windows | `winget install -e --id Docker.DockerCLI` | The CLI only — it still needs an engine, see below. |

On macOS, installing the two and starting the VM are one flow: answer yes and it runs
`brew install colima docker`, then offers `colima start` straight after, rather than
telling you to run `doctor --fix` a second time.

> **Docker Desktop is never installed.** Every offer above is a CLI and an engine, nothing
> more — Colima on macOS, Docker Engine on Linux, the standalone `docker` CLI on Windows.
> Desktop is over a gigabyte, wants administrator rights and usually a reboot, and its
> licence is only free for personal use, education and small companies. If you have chosen
> to install it yourself, `doctor` will happily *start* it when the daemon is down; it just
> will not put it there.

On Windows the CLI on its own has no engine behind it. Without Desktop the usual route is
WSL 2 — `wsl --install`, then inside the distro `curl -fsSL https://get.docker.com | sudo sh`
— and either work inside that distro or have `dockerd` listen on `tcp://localhost:2375` so
the Windows CLI can reach it through `DOCKER_HOST`. Worth knowing before you start: on
Windows the native launcher runs the x86_64 builds directly, with no Rosetta anywhere in
the picture, so the Docker edition buys you nothing there. Use
`.\chromium-stack.ps1 run 74` instead.

## Stability: what to expect on an Apple Silicon Mac

**This only affects the older milestones.** Chromium publishes native arm64 macOS builds
from roughly M92 on, so **95 and later run natively** and behave like any other Mac app.
The manager labels those rows *native arm64*.

**60 through 90 have no arm64 build**, so they run through Rosetta — the rows the manager
marks *x86_64 · Rosetta*. Two failure modes come out of that:

**1. GPU process crash — fixed.** The Apple GPU driver cannot answer the browser's query
for the system memory size (`AGX: getSystemMemorySize(): Verification failed`), the GPU
process dies, and it takes the browser with it. Rosetta builds therefore run with
`--disable-gpu` (software rendering) by default, which removes those AGX errors
completely. Native arm64 and Linux builds keep hardware acceleration. Override either way
with `--gpu` / `--no-gpu`, or the **Graphics** control in the manager.

**2. Stack-profiler crash — mitigated, not fixed.** Chromium's stack sampling profiler
walks thread stacks with libunwind, and under Rosetta that unwinder occasionally segfaults
on a synthesised x86 frame, killing the browser (`Received signal 11 SEGV_MAPERR`). An
unbranded Chromium build enables the profiler on a random ~80% of launches and there is no
switch to turn it off, so it cannot be fixed from the outside. Measured here on Chromium
74: 2 of 7 sessions died within 25 seconds of loading a heavy news site — call it a
quarter to a third of sessions on a heavy page, and much rarer on a light one.

So the launcher relaunches the browser and lets Chromium restore your tabs, up to 5 times.
You will see `Chromium crashed after Ns — restarting and restoring your tabs`. Use
`--no-restart` if you would rather it stop and show the log. If the interruptions get in
the way, use the **Docker edition**: on the same site, the container survived 3 of 3 runs.

> Tried and rejected: `--disable-features=StackSamplingProfiler,SamplingProfilerReporting`
> looks like the obvious fix and makes things **much worse** — 4 crashes out of 4 runs
> versus 0 out of 4 without it. Do not add it back.

**Intel Macs, Windows and Linux run x86_64 natively**, do not go through the Rosetta
unwinder, and should not see the second failure mode at all.

## What lives where

| Path | Contents |
|---|---|
| `~/.chromium-stack/builds/<revision>/` | a downloaded browser |
| `~/.chromium-stack/profiles/<revision>/` | that version's profile (cookies, logins, storage) |
| `~/.chromium-stack/logs/<revision>.log` | that version's stderr from its last run |
| `%USERPROFILE%\.chromium-stack\` | same, on Windows |
| docker volume `chromium-stack-profile-<revision>` | the Docker edition's profile |

Set `CHROMIUM_STACK_HOME` to put all of that somewhere else.

An existing `~/.chrome74` install from the single-version days is **adopted on first run**
rather than re-downloaded, and its profile becomes Chromium 74's. That happens only when
the home is the default one; if `CHROMIUM_STACK_HOME` is set, the old directory is left
alone.

## Troubleshooting

**macOS — “ChromiumStack.app cannot be opened because it is from an unidentified
developer.”**
Right-click the app → **Open** → **Open**. Once. The app carries an ad-hoc signature, not
a paid developer one.

**macOS — the app bounces once and a permission alert appears.**
If the project sits in `~/Documents`, `~/Desktop` or `~/Downloads`, macOS gates access to
that folder. Allow ChromiumStack under **System Settings → Privacy & Security → Files and
Folders**, or move the folder somewhere unprotected. Running `./gui.sh` from Terminal is
unaffected.

**The manager will not start — “needs Python 3”.**
It offers to install it for you. To do it yourself: macOS `xcode-select --install`, Linux
`sudo apt install python3`. Or skip the manager: `./chromium-stack.sh run 74`.
`./chromium-stack.sh doctor` reports everything at once.

**macOS on Apple Silicon, an old version will not start.** Milestones up to 90 run under
Rosetta: `softwareupdate --install-rosetta`.

**Windows — SmartScreen says “Windows protected your PC”.** Both launchers are unsigned:
signing needs a paid certificate, and an unknown `.exe` has no download reputation to go
on. Click **More info** → **Run anyway**, once. If you would rather not, `ChromiumStack.bat`
is a three-line script you can read first, and `.\chromium-stack.ps1 run 74` skips the
launcher entirely.

**Linux — extraction fails.** Install `unzip`: `sudo apt install unzip`.

**Linux — the desktop entry has no icon.** Desktop environments look icons up by name, so
copy it where they can find it:
`mkdir -p ~/.local/share/icons && cp assets/icon-512.png ~/.local/share/icons/chromium-stack.png`

**The browser starts and immediately closes.** Check
`~/.chromium-stack/logs/<revision>.log`. Three crashes in a row within 5 seconds each and
the launcher stops retrying, assuming the setup is broken rather than the random crash
above.

**A revision is rejected as “not archived”.** Not every commit position is built. Pick one
a few commits later, or use a catalogued milestone.

**A proxy blocks the download.** The browsers come from
`https://commondatastorage.googleapis.com/chromium-browser-snapshots/` and the catalog tool
also reads `https://www.googleapis.com/storage/v1/` and `https://chromiumdash.appspot.com/`.
Those hosts must be reachable.

## Layout

```
ChromiumStack.app                     double-click, opens the manager (macOS)
ChromiumStack.exe                     double-click, opens the manager (Windows)
ChromiumStack.bat                     the same, as a readable script
chromium-stack.desktop                Linux desktop entry
gui.sh / gui.ps1                      start the manager
gui/index.html, app.js, styles.css    the manager page
gui/server.py                         manager backend, macOS/Linux (stdlib only)
gui/server.ps1                        manager backend, Windows (PowerShell only)
chromium-stack.sh / .ps1              the launcher everything else drives
chromium-stack-docker.sh / .ps1       Docker launcher, one image per version
lib/preflight.sh, preflight.ps1       dependency checks and the install offers,
                                      shared by the CLI, Docker and the manager
catalog.tsv                           verified revisions per milestone per platform
tools/refresh-catalog.py              regenerate catalog.tsv from the archive
docker/Dockerfile                     Chromium + Xvfb + fluxbox + x11vnc + noVNC
docker/entrypoint.sh                  brings up X and supervises the browser
assets/icon.svg, icon-small.svg       icon sources: full detail, and reduced for
                                      small sizes where detail turns to mush
assets/icon.ico, icon-512.png         generated, for Windows and Linux
tools/make-icons.sh                   rebuild every raster icon from the SVGs
tools/build-app.sh                    compile and sign the macOS bundle launcher
tools/launcher/launcher.c             that launcher's source
tools/build-exe.sh                    cross-compile ChromiumStack.exe (mingw-w64)
tools/launcher/launcher-win.c         its source, and launcher-win.rc its icon
tools/install-shortcut.ps1            Windows Desktop / Start Menu shortcut
```

Both launchers are committed binaries, so nothing has to be built to use this.

`ChromiumStack.app/Contents/MacOS/ChromiumStack` is a universal binary. A `.app` cannot
work without a compiled executable, and a shell script will not do: when the project lives
in a folder macOS protects, a script-based bundle has its file access attributed to
`/bin/bash`, which macOS denies without ever prompting. All it does is `chdir` and hand
over to `gui.sh`.

`ChromiumStack.exe` exists for a smaller reason — a `.bat` cannot carry an icon, so
Explorer shows it as a script rather than as a program. It is a console program on
purpose: the manager has no quit button, so the window it opens is the off switch, exactly
as with the `.bat`. Rebuild either one after editing its source:

```bash
tools/build-app.sh    # macOS bundle launcher, needs Xcode command line tools
tools/build-exe.sh    # ChromiumStack.exe, cross-compiled: brew install mingw-w64
```

Everything is self-contained: zip the folder and hand it to someone, no clone needed.

## Status

Verified end to end on macOS 15 (Apple Silicon): catalog generation against the live
archive, the manager (install, launch, delete, reset, disk accounting, token auth),
downloading and launching a native arm64 build, per-version profile isolation, adoption of
an existing `~/.chrome74` install, and the macOS app bundle launching from a TCC-protected
folder.

**Nothing on the Windows side has been run on Windows.** `ChromiumStack.exe` is
cross-compiled from macOS with mingw-w64, and its embedded icon and version resources were
verified by reading the PE file, not by launching it. The scripts are written for
PowerShell 5.1 (which ships with Windows 10/11) and reviewed, but if you are the first to
try any of it there, expect to find something. The manager's Windows backend deliberately speaks HTTP over a
plain `TcpListener` rather than `System.Net.HttpListener`, which would need a `netsh` URL
reservation or an elevated prompt.

**The per-version Docker images have not been built for every milestone.** The Dockerfile
is parameterised by revision and the Debian package list covers old and new builds, but a
given milestone may want a library the list does not have.

## Credits

Built by [@1m93](https://github.com/1m93).

Chromium builds come from the [Chromium snapshot
archive](https://commondatastorage.googleapis.com/chromium-browser-snapshots/index.html);
this project only downloads and launches them.

> **Renamed.** This was called *browsers-emu*. An existing `~/.browsers-emu` directory is
> moved to `~/.chromium-stack` on first run — same layout, nothing re-downloaded — and
> `BROWSERS_EMU_HOME` still works as a fallback for `CHROMIUM_STACK_HOME`.
