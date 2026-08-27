<p align="center">
  <img src="assets/banner.svg" alt="EngineShelf — four browser engines, one click away" width="100%">
</p>

<p align="center">
  <a href="https://github.com/1m93/EngineShelf/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/1m93/EngineShelf?style=flat-square&color=2f6df6&label=release"></a>
  <img alt="Platforms" src="https://img.shields.io/badge/macOS%20%C2%B7%20Windows%20%C2%B7%20Linux-ready-2b3444?style=flat-square">
  <img alt="Chromium, Firefox, Edge and WebKit" src="https://img.shields.io/badge/Chromium%20%C2%B7%20Firefox%20%C2%B7%20Edge%20%C2%B7%20WebKit-4%20engines-4b83ff?style=flat-square">
  <img alt="No install required" src="https://img.shields.io/badge/setup-double--click-1d9a5a?style=flat-square">
  <a href="https://github.com/1m93/EngineShelf/releases"><img alt="Downloads" src="https://img.shields.io/github/downloads/1m93/EngineShelf/total?style=flat-square&color=5b6472&label=downloads"></a>
</p>

<p align="center">
  <b>A shelf of real browsers, going back to 2017.</b><br>
  Pick a version of Chromium, Firefox, Edge or WebKit, press Launch, and it opens as an<br>
  ordinary desktop browser — tabs, bookmarks, DevTools and all. No account, no build
  step, nothing to configure.
</p>

<p align="center">
  <a href="#download"><b>Download</b></a> ·
  <a href="#sixty-seconds-to-your-first-old-browser">Quick start</a> ·
  <a href="#the-version-shelf">Versions</a> ·
  <a href="#inside-the-manager">The manager</a> ·
  <a href="#good-to-know">Good to know</a>
</p>

---

## Why people keep one of these around

Modern browsers are excellent liars. They quietly polyfill, gracefully degrade and make
your site look finished — right up until it meets an engine from 2019, where an
unsupported CSS declaration is **dropped, not degraded**, and a layout falls apart in a
way nothing on your machine will ever show you.

And modern browsers agree with each other far more than they used to, which hides the
other half of the problem: three engines still ship on the desktop, and the one you
develop in is the one whose bugs you will never find.

|  | The situation | What EngineShelf gives you |
|---|---|---|
| **Kiosks & devices** | POS terminals, scanners and industrial tablets ship a System WebView years behind the OS. It is the *engine* that decides whether your CSS survives. | The same engine on your desk, in a window you can click around in. |
| **The support ticket** | A customer on a locked-down browser reports a bug you cannot reproduce anywhere. | Open their engine, load the page, see it happen. |
| **“Only breaks in Firefox”** | Gecko is not Blink with different chrome. Different layout rounding, different fonts, its own certificate store. | Firefox 57 through today, beside the Chromium you already test in. |
| **The `browserslist` claim** | Your config promises support for an old floor — often across engines. Nobody has ever checked. | Two minutes to find out whether the promise is true, on each engine it names. |
| **The regression hunt** | Something broke *somewhere* between two releases. | 90, 105 and 120 open side by side, bisected by eye. |

<sub>**A word on WebKit, before you get your hopes up.** WebKit is the engine Safari is
built on, and it is the closest thing to Safari that can be downloaded — but it is not
Safari. What opens is a minimal browser shell around the engine: no Safari interface, no
Intelligent Tracking Prevention, no Safari media stack. It will catch a CSS property
Safari has not shipped. It will not reproduce a cookie being capped at seven days, an
HLS stream refusing to play, or anything specific to Safari on iOS. Those need a real
device or a simulator, and nothing here changes that. It is listed as **WebKit** rather
than Safari for exactly this reason.</sub>

---

## Download

Grab the build for your platform from the [**Releases** page][releases]. Every download is
**self-contained** — the launcher finds everything it needs inside the package. Nothing to
install, nothing to keep together, no loose folder of files to lose.

| Platform | File | How you open it |
|---|---|---|
| **macOS** | `EngineShelf-<ver>-macOS.zip` | Unzip → double-click **`EngineShelf.app`** (drag it to Applications if you like) |
| **Windows** | `EngineShelf-<ver>-Windows.zip` | Unzip → double-click **`EngineShelf.bat`** (want a Desktop icon? run `Create-Shortcut.ps1` once) |
| **Linux** | `EngineShelf-<ver>-Linux.tar.gz` | Extract → run **`./EngineShelf`** |

<sub>**Runs on** — macOS 10.13+ on Intel and 11+ on Apple Silicon · Windows 10/11, using the PowerShell 5.1 that ships with them · Linux x86_64. The manager wants Python 3 on macOS and Linux; the command line does not.</sub>

<sub>Paranoid, sensibly so? `shasum -c SHA256SUMS.txt` verifies the download against the published checksums. Prefer to build the packages yourself — see [RELEASE.md](RELEASE.md).</sub>

<sub>**Windows warns about the download?** `EngineShelf.bat` is a short, readable script — you can open it in Notepad — that just starts the manager (`app\gui.ps1`); there is no compiled program to trust. If SmartScreen or a “Run anyway?” prompt appears, that is expected for any downloaded script without a paid certificate, not a sign of anything wrong. If it feels stuck, unblock the folder first: in PowerShell, `Get-ChildItem -Recurse | Unblock-File` (clears the “downloaded from the internet” mark), or right-click each file → Properties → **Unblock**. Verify against `SHA256SUMS.txt` if you want certainty. Want a Desktop/Start-Menu icon instead of the plain `.bat`? Run `Create-Shortcut.ps1` once after extracting.</sub>

<sub>**Running from a clone instead?** Same launchers, plus `./gui.sh` (or the `engineshelf.desktop` entry) on Linux. Keep the launcher inside the project folder — it finds everything else relative to itself.</sub>

[releases]: https://github.com/1m93/EngineShelf/releases/latest

---

## Sixty seconds to your first old browser

<table>
<tr>
<td width="33%" valign="top">

### 1 · Open it

Double-click the launcher. The **manager** opens in a window of its own: every version,
what is installed, what each one costs in disk.

</td>
<td width="33%" valign="top">

### 2 · Pick a version

Scroll, search, or narrow to one engine, then press the button on its row. The first launch
of a version downloads it, 90–400 MB and a few minutes, once. Every launch after is instant.

</td>
<td width="33%" valign="top">

### 3 · Use it

A real browser window opens. Type a URL, open DevTools, log in, keep the profile. Close the
launcher window when you are done.

</td>
</tr>
</table>

<p align="center">
  <img src="assets/screenshot-manager.png" width="100%" alt="The EngineShelf manager: one shelf holding every release of all four engines, each row led by its engine's own mark — Chromium 152, Firefox 154, a running WebKit 26.5 offering Stop, Edge 151 already installed — with the engines listed down the side and a count of how many of each are on disk">
  <br>
  <sub>Every release of all four engines on one shelf, newest first, each row under its own
  mark. Version numbers do not line up between engines — Chromium 120, Firefox 121, Edge 120
  and WebKit 17.4 are contemporaries and none of those numbers say so — so the rows are
  ordered by when things shipped, which puts contemporaries next to each other. Narrow to one
  engine down the left, or search by version, date or feature.</sub>
</p>

> [!TIP]
> Type a URL in the box at the top of the manager and **every** version you launch opens
> straight to it. `localhost:4173` is fine — it is the fastest way to compare four engines
> on the same page.

Prefer the terminal? The whole thing is one command:

```bash
./engineshelf.sh run 74             # install if needed, then launch Chromium 74
./engineshelf.sh run firefox:115    # any engine, by name
./engineshelf.sh run firefox:esr    # or by the line you actually care about
./engineshelf.sh run edge:151
./engineshelf.sh run webkit:26.5
```

A bare number still means Chromium, so nothing you already type has changed.

---

## Inside the manager

One page, served locally, with everything on it.

| | |
|---|---|
| **One-click install & launch** | Missing builds download on demand, then open. No separate install step to remember. |
| **Cancel while it downloads** | A download or a Docker image build can be called off from the row or from the log panel. The half-fetched archive and the part-unpacked directory go with it, rather than sitting on disk until something retries. |
| **Docker where nothing runs natively** | Versions with no build for this machine, ones already watched crash here, and Chromium's Rosetta range lead with **Get & launch in Docker** instead of a download that would not start or would not survive. |
| **A shared URL for every launch** | Set it once at the top; every version opens there. |
| **Window size and graphics** | Fix the viewport for a layout check, or force hardware acceleration on or off. |
| **Per-row menu** | Download without launching, run that version in Docker, reset its profile, or delete it. |
| **Two views of one shelf** | The list it opens on — every release of all four engines, one per row, with the actions — or the grid below, for comparing across engines. |
| **Grouped by era** | In the list, rows sit under the years they belong to, four engines interleaved by release date, with what each era brought — jump straight to one, or sort by age or disk used. |
| **Search and filters** | Narrow to one engine, or search by version, revision, release date, or by **any feature a version was first to support** — type `aspect-ratio` and get Chromium 88 and Firefox 89 — or by what is installed, running, or stuck on Rosetta. |
| **Any revision at all** | Every build in the Chromium snapshot archive is runnable, not just the catalogued milestones — from the CLI, which takes a bare position as a selector. |
| **System check** | Tells you what is missing before it matters, with buttons that install it. |
| **A live log panel** | Downloads, dependency installs and Docker containers stream their output line by line — the same text a terminal would show, one tab per job when several are in flight. |
| **Honest disk accounting** | A running total split between browsers, profiles and Docker images, so it is obvious when to clear something out. |
| **Light or dark** | Follows the system theme, or pin it either way from the header. |
| **One manager at a time** | Opening the app while it is already running brings its window back rather than starting a second manager on the next port. `⌘N` on macOS opens another window onto the same shelf. |
| **Closes like an app** | Closing the window stops the manager, the browsers it launched and the containers it started — with a confirmation first if any of them are running. Nothing is left holding a port or a gigabyte. |

**Closing the window quits everything.** The manager is the app, not a page that outlives it:
close it and the server stops, the browsers it launched close, and any Docker container it
started comes down. Ctrl-C in a terminal does the same. If something is still running when
you close it, the browser asks you to confirm first — a stray click on the X cannot take a
download with it.

It opens in a window of its own. **On macOS that window belongs to EngineShelf.app itself**
— an ordinary Mac window drawn by the app, so the Dock icon is EngineShelf's, pressing it
brings the manager back from Stage Manager or a hidden desktop, and `⌘N` opens a second
window onto the same shelf. **On Windows and Linux** it is a Chromium-family browser in
`--app` mode with a profile of its own, which keeps the manager out of your own browsing
session; opening the launcher again there gives you another window onto the same manager
rather than a second one. Without such a browser installed it falls back to a tab, and then
it is the tab closing that ends the session, twelve seconds later. `--tab` asks for that on
purpose; `--keep-alive` leaves the server running whatever the window does.

> [!NOTE]
> **Nothing listens outside your machine.** The server binds to `127.0.0.1` and every
> request must carry a token generated for that run, so a web page you happen to have open
> cannot drive your browser installs. On macOS and Linux the manager needs **Python 3**
> (macOS: it arrives with `xcode-select --install`); Windows needs nothing extra; the
> command line needs neither.

---

## The version shelf

Nothing here is a list somebody typed in. Each engine has an index its own vendor
publishes, every one of those carries release dates, and the shelf is built from them — so
it keeps growing on its own and cannot go stale. A version this build has never heard of is
looked up the first time you ask for it and remembered afterwards. See
[Keeping up](#keeping-up-with-chrome).

How far back each engine reaches is not a choice; it is however much its vendor still
publishes. They differ a lot, and it is worth knowing before you go looking:

| Engine | Reaches back to | Where the builds come from | The catch |
|---|---|---|---|
| **Chromium** | 2017 · milestone 60 | the Chromium snapshot archive | nothing is pruned — any revision in the archive works, not just catalogued ones |
| **Firefox** | 2017 · Firefox 57 | `ftp.mozilla.org`, every release ever shipped | old builds trust only the certificate authorities they shipped with, so EngineShelf turns on the OS trust store for them — without that, a 2019 Firefox rejects most of today's HTTPS |
| **Edge** | 2021 in a container · about six months natively on macOS and Windows | the Linux package pool, and Microsoft's enterprise feed | the mac and Windows downloads carry a per-file GUID that cannot be constructed, so natively only what the feed still lists can be fetched. The pool has kept every Linux build since 2021, which is what [the Docker edition](#docker-edition) uses — `./engineshelf-docker.sh start edge:95` is the only way to open one that old |
| **WebKit** | 2021 | Playwright's build CDN | builds are deleted over time, and for older OS releases a different revision is pinned — so a version can still exist for Linux while no macOS archive of it was ever published. When that happens the container is the way in |

<sub>Edge is Chromium underneath, so it is not a second engine — what it adds is Edge's own
Tracking Prevention defaults and a build that matches the WebView2 runtime Windows kiosks
ship. Firefox is the only other full desktop engine there is. WebKit is an engine without a
browser around it; see the note further up.</sub>

| Era | Versions | What changes here |
|---|---|---|
| **2017–2018** | `60` `65` `70` | Hard floors for very old WebViews. |
| **2019–2020** | `74` `76` `80` | No flexbox `gap`; optional chaining arrives in 80. |
| **2020–2021** | `85` `90` | Flexbox `gap`, `aspect-ratio`, `:is()`. |
| **2021–2022** | `95` `100` `105` | Container queries and `:has()` arrive in 105. |
| **2023** | `110` `115` `120` | `dvh`, CSS nesting, view transitions, `subgrid`. |
| **2024** | `125` `130` | Near-current — the control when you are bisecting. |

Those are the hand-picked ones, each chosen because something interesting lands there.
Newer milestones are added on the same spacing as Chrome releases them — run
`./engineshelf.sh catalog` for what your machine can actually launch today.

<details>
<summary><b>Running a version that is not on the shelf</b></summary>

<br>

Pass the revision straight to the CLI — `./engineshelf.sh run 638880`. To find the branch
base position for a milestone:

```bash
curl -s "https://chromiumdash.appspot.com/fetch_milestones?mstone=74" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['chromium_main_branch_position'])"
# 638880
```

Then `./engineshelf.sh run 638880`. Not every commit position is archived; if that exact
one was never built for your platform, the tool says so — try one a few commits later.

**Older than 60 is not a limit we chose.** The snapshot bucket does hold builds going back
to 2011, and you are welcome to pass one of those revisions — but three separate walls sit
just below M60, and none of them can be worked around from here:

- macOS builds from that era are **32-bit i386**. macOS dropped 32-bit support in Catalina
  and Rosetta 2 only translates x86_64, so they cannot start at all — `bad CPU type in
  executable`, not a bug you can fix.
- The `Win_x64` bucket has nothing before roughly r389148 (~M52). Only 32-bit `Win` goes
  further back.
- chromiumdash has no branch position below **M59**, so a milestone number cannot be
  resolved to a revision automatically — you would have to know the revision yourself.

Linux is the one platform where the old builds are still 64-bit, and even there Chromium
below ~M64 wants `libgconf-2.so.4`, which modern distributions no longer ship. The Docker
image fetches it from the Debian archive, so those milestones do run in a container.

`catalog.tsv` pins one *verified* build per milestone per platform, because the nearest
archived build is sometimes tens of commits away from the branch point. Regenerate it
against the live archive any time:

```bash
python3 tools/refresh-catalog.py           # rewrite catalog.tsv
python3 tools/refresh-catalog.py --check   # verify without writing
```

The historical milestones are hand-picked and live in `ANCHORS`; past the end of that list
the script extends itself on the same five-milestone spacing up to whatever Chrome has
stable, so a new release does not need the file edited. Add an out-of-band milestone by
putting it in `ANCHORS` and rerunning.

</details>

---

## Keeping up with Chrome

Chrome branches a new milestone roughly every four weeks. Nothing here needs a new release
of EngineShelf for that to show up.

**On the command line.** Ask for any milestone. If it is not in `catalog.tsv`, the archive
is asked instead — the branch point from chromiumdash, then the nearest revision the
snapshot bucket actually built — and the answer is written to
`~/.engineshelf/catalog.cache.tsv`. That file is read *before* the shipped catalog, so
the newest answer always wins:

```bash
./engineshelf.sh run 152        # never heard of it? looked up once, then cached
./engineshelf.sh catalog        # also picks up anything released since your build
```

A resolved milestone never expires: a branch point does not move, and the snapshot bucket
only ever grows. The cache carries no TTL, and only "which milestone is stable right now"
is re-checked, once a day. Offline, the last answer stands — the cache and the shipped
catalog are both still there, and every milestone you have used before still launches.
The one thing that can go stale is a revision the bucket later drops; if a download 404s,
that row is forgotten and the next run re-resolves it.

The cache lives under your home rather than beside `catalog.tsv` on purpose: the shipped
catalog is often on a read-only volume — inside `EngineShelf.app`, for one.

**In the manager.** Same cache, same precedence. It asks the CLI to refresh in the
background at startup, so the list fills in without blocking the page.

**On the landing page.** It renders the milestones it shipped with, then asks the same
public sources and remembers the result in `localStorage`. A fetch that fails, is blocked,
or is simply offline changes nothing on screen.

**In the repository.** A weekly workflow reruns `tools/refresh-catalog.py` and
`tools/sync-landing.py` and commits the result. That is an optimisation, not the mechanism:
it keeps the copy everyone downloads current, so a fresh install starts from a recent
catalogue instead of resolving its way there.

Nothing in the prose — here, on the site, or in the page metadata — names a count or a
version range. Those are the sentences that quietly go wrong four weeks later, and there
is no number worth writing down that the tool cannot show you itself.

---

## It really is a browser

Address bar, tabs, bookmarks, history, downloads, DevTools — all there, and each version
keeps its own profile between launches. Visit anything you like.

Do bear in mind that the old ones really are old. Sites built for a modern engine may refuse
to load, render strangely, or nag you to upgrade. That is the browser being honest, not the
tool misbehaving.

**Every version gets its own profile**, and not for tidiness: Chromium writes a version
number into a profile and **refuses to open one written by a newer build**. A shared
profile would break the moment you went back a version. So logging into a test environment
in 74 leaves 120 untouched, and neither goes near your everyday browser.

> [!IMPORTANT]
> **Point it at a production build, not your dev server.** Vite, Next.js and friends ship
> your source untranspiled and skip the CSS-fallback step, so an old engine chokes on the
> dev server even when your shipped build is perfectly fine. A blank page on
> `localhost:3000` usually means *"the dev server is modern"*, not *"my code is broken"*.
> Build the site the way you deploy it, serve the output, and open **that**.

---

## For terminal people

The manager is a front end for the CLI — both do the same things, so they cannot drift apart.

```bash
./engineshelf.sh catalog                    # the whole shelf, all four engines
./engineshelf.sh list                       # what is installed, with disk usage
./engineshelf.sh run 74                     # a bare number is Chromium
./engineshelf.sh run firefox:115            # any engine, by name
./engineshelf.sh run edge:151               # a bare major is enough
./engineshelf.sh run webkit:26.5            # or a Playwright revision: webkit:2336
./engineshelf.sh run firefox:esr            # whichever ESR is current
./engineshelf.sh run 120 localhost:4173     # launch 120 on a URL
./engineshelf.sh run 638880                 # a raw Chromium snapshot revision
./engineshelf.sh install firefox:128        # download without launching
./engineshelf.sh remove edge:151            # delete a downloaded browser
./engineshelf.sh clean webkit:26.5          # reset that version's profile
./engineshelf.sh doctor                     # check dependencies
./engineshelf.sh gui                        # open the manager
```

Every command takes the same selector: `engine:version`, or a bare number for Chromium.
Firefox and Edge take a bare major (`firefox:115`) or an exact build (`edge:151.0.4129.107`);
WebKit takes a Safari version (`webkit:26.5`) or the Playwright revision that pins it exactly
(`webkit:2336`), which is what `catalog` prints, because several builds call themselves 26.5.
For Chromium alone a bare number is a milestone (`74`) or a snapshot revision (`638880`) —
milestones are small and revisions are six digits or more, so there is nothing to
disambiguate.

Flags for `run`: `--size 1280x800`, `--gpu` / `--no-gpu`, `--no-restart`, and anything after
`--` is passed to the browser. Windows runs the same commands through `.\engineshelf.ps1`.

---

## Docker edition

Runs the **Linux x86_64** build in a container and shows its desktop in a tab of your normal
browser, over noVNC. All four engines, same commands as the native launcher:

```bash
./engineshelf-docker.sh start 74           # build if needed, run, open the desktop
./engineshelf-docker.sh start firefox:52
./engineshelf-docker.sh start edge:95      # only route to an Edge this old, on any host
./engineshelf-docker.sh start webkit:16.4
./engineshelf-docker.sh build 74           # build the image and stop there
./engineshelf-docker.sh stop 74
./engineshelf-docker.sh logs 74
./engineshelf-docker.sh rebuild 74         # rebuild the image from scratch
./engineshelf-docker.sh list               # containers and images
./engineshelf-docker.sh purge 74           # delete that version's image
```

**Every version on the shelf, not just the catalogued ones.** Only about twenty Chromium
milestones carry a hand-verified row, and the container used to refuse everything else with
*"No Linux x86_64 build of Chromium 88 in the catalog"* — while the native launcher had always
asked the archive for exactly that. It now asks the same question about the Linux build, keeps
the answer in `~/.engineshelf/catalog.cache.tsv`, and the manager offers the container on every
Chromium row from then on. The other three engines were never limited this way: their downloads
are resolved against each vendor's index on both sides already.

It is worth being clear about when this earns its gigabyte, because it is different per engine:

| | Why a container |
|---|---|
| **Chromium** | It never touches Rosetta, so on Apple Silicon it sidesteps both crashes under [Stability](#good-to-know) — the profiler one and the startup abort that stops the oldest milestones reaching a window at all. |
| **Edge** | **The only route to an old one.** The enterprise feed that serves mac and Windows holds about six months; the Linux apt pool has kept every build since 2021. Natively, `edge:95` cannot be had at any price. |
| **WebKit** | Playwright stopped publishing macOS archives for the older revisions, and never published some at all. The Linux ones are still there. |
| **Firefox** | The least necessary — Firefox installs natively everywhere. Reach for it when a 2017 build will not start against a 2026 OS, or when you want the Linux rendering rather than your own. |

Each version gets its own image, container, profile volume and port, so several can run side
by side. Windows uses `.\engineshelf-docker.ps1` with the same commands.

<details>
<summary><b>What to expect from it</b></summary>

<br>

- **Copy and paste** work across the tab in both directions: your usual shortcut pastes into
  the container, and anything copied inside it lands on your own clipboard. On a Mac that
  means Cmd-C, Cmd-V and Cmd-X, which the desktop in there would otherwise never see.
- **Reaching your machine.** Inside the container, `localhost` is the container. Use
  **`http://host.docker.internal:4173`** to reach a server running on your own machine.
- **On Apple Silicon** the container is emulated, so it is noticeably slower than the native
  launcher. Fine for a careful pass over a screen, tiring for a long session.
- **Viewport.** The browser fills the virtual screen (1440×900 by default; change `SCREEN`
  in the `SCREEN` line of that engine's Dockerfile), and the Chromium-family warning
  infobars are suppressed so they do not eat viewport height and skew a layout check.
- **First start builds an image** for that version — several minutes under x86 emulation.
  After that the launcher reuses it.
- **The desktop is published on `127.0.0.1` only.** It has no password and a real browser
  attached to it, so it is not offered to the rest of the network.
- **In the manager** a version running in a container gets the same running dot as a native
  one, its image size shows on the row and in the Disk read-out, and the row's Stop button
  stops the container. The green `Docker` marker is a link back to its desktop tab.

**Docker is optional**, and the native launcher is what most people should use. If you do
want it, the launcher never installs anything behind your back:

- **Installed but not running** → it starts it for you (Colima, `systemctl`, the engine in
  your WSL distro, or a Docker Desktop you installed yourself) and waits up to 90 seconds.
- **Not installed at all** → it prints the exact command, says how big the download is, and
  asks `[y/N]`. Answer `n` and it stops without touching anything.

| OS | The offer | What that is |
|---|---|---|
| macOS | `brew install colima docker` | Colima and the `docker` CLI. Needs Homebrew. |
| Linux | `curl -fsSL https://get.docker.com \| sudo sh` | Docker Engine and the CLI. Needs sudo. |
| Windows | `winget install -e --id Docker.DockerCLI` | The CLI only — it still needs an engine. |

**Docker Desktop is never installed for you.** Every offer above is a CLI and an engine and
nothing more. Desktop is over a gigabyte, wants administrator rights and usually a reboot,
and its licence is only free for personal use, education and small companies. If you have
chosen to install it yourself, `doctor` will happily *start* it when the daemon is down; it
just will not put it there.

On Windows the CLI alone has no engine behind it; the usual route is WSL 2 (`wsl --install`,
then `curl -fsSL https://get.docker.com | sudo sh` inside the distro) and either working in
that distro or having `dockerd` listen on `tcp://localhost:2375` so the Windows CLI can reach
it through `DOCKER_HOST`. Worth knowing first: on Windows the native launcher runs the
x86_64 builds directly, with no Rosetta anywhere in the picture, so the Docker edition buys
you nothing there. Use `.\engineshelf.ps1 run 74` instead.

</details>

---

## Good to know

<details>
<summary><b>Stability on Apple Silicon</b> — what to expect, and what the launcher does about it</summary>

<br>

**This only affects the older milestones.** Chromium publishes native arm64 macOS builds
from roughly M92 on, so **95 and later run natively** and behave like any other Mac app — the
manager draws those rows with a full blue screen mark.

**60 through 90 have no arm64 build**, so they run through Rosetta, and their screen mark is
half. Two failure modes come out of that:

**1. GPU process crash — fixed.** The Apple GPU driver cannot answer the browser's query for
the system memory size (`AGX: getSystemMemorySize(): Verification failed`), the GPU process
dies, and it takes the browser with it. Rosetta builds therefore run with `--disable-gpu`
(software rendering) by default, which removes those errors completely. Native arm64 and
Linux builds keep hardware acceleration. Override either way with `--gpu` / `--no-gpu`, or
the **Graphics** control in the manager.

**2. Stack-profiler crash — mitigated, not fixed.** Chromium's stack sampling profiler walks
thread stacks with libunwind, and under Rosetta that unwinder occasionally segfaults on a
synthesised x86 frame, killing the browser (`Received signal 11 SEGV_MAPERR`). An unbranded
Chromium build enables the profiler on a random ~80% of launches and there is no switch to
turn it off, so it cannot be fixed from the outside. Measured here on Chromium 74: 2 of 7
sessions died within 25 seconds of loading a heavy news site — call it a quarter to a third
of sessions on a heavy page, and much rarer on a light one.

So the launcher relaunches the browser and lets Chromium restore your tabs, up to 5 times:
`Chromium crashed after Ns — restarting and restoring your tabs`. Use `--no-restart` if you
would rather it stop and show the log. If the interruptions get in the way, use the **Docker
edition** — on the same site, the container survived 3 of 3 runs.

> Tried and rejected: `--disable-features=StackSamplingProfiler,SamplingProfilerReporting`
> looks like the obvious fix and makes things **much worse** — 4 crashes out of 4 runs versus
> 0 out of 4 without it. Do not add it back.

**3. Startup abort — not fixable, and it ends the milestone.** Some milestones no longer reach
a window at all. The browser process aborts in its first second with `malloc: *** error for
object 0x…: pointer being freed was not allocated`, in the helper process as well as the
browser: Chromium's allocator replaces the system malloc zones, and a build from 2019 does not
replace the ones this year's `libsystem_malloc` actually has. There is no switch — the shim is
installed before the command line is read. Measured on **Chromium 74, macOS 15.5, M4**: dead
in under a second on 9 launches out of 9, with the GPU on and off, sandbox on and off,
single-process, and with `MallocNanoZone=0`.

This is the same milestone the profiler measurement above was taken on, and back then it
started and ran for tens of seconds — so this is not a property of the build, it is where the
build and the OS have drifted apart, and the line will keep moving up the shelf as macOS moves
on.

Nothing can retry its way out of that, so the shelf stops trying. The first launch of **any**
engine that dies before its window records that version against this macOS major version in
`~/.engineshelf/arch-fallback.cache`, and from then on:

- the CLI names the cause, tries **once**, and points at the container instead of restarting
  five times into the same wall
- the manager marks the row `crashes on this macOS` and makes Docker the row's button, with
  *Launch natively anyway* — or *Download and launch natively* — still in the **···** menu
- a macOS upgrade clears the verdict, because the record is keyed by OS major — the question
  gets asked again rather than inherited

### When the vendor has stopped serving a version

A shelf row says a version was *released*. Whether it can still be *downloaded* is a different
question, and only the vendor can answer it:

| Engine | Measured here | Why |
|---|---|---|
| **Edge** | 34 of 39 shelf rows cannot be fetched on macOS | the enterprise feed is the only source for a mac or Windows Edge and keeps about six months. On **Windows** it is all of them: Microsoft ships only an MSI, whose payload is an installer stream rather than an archive |
| **WebKit** | 36 of 53 cannot be fetched | Playwright deletes the older macOS archives — the boundary here is r2051 (18.0) — and keeps the Linux ones |
| **Chromium** | 34 of 34 catalogued revisions still live | the snapshot archive keeps them, and an uncatalogued milestone is resolved against it on demand |
| **Firefox** | none missing | `ftp.mozilla.org` has kept every release Mozilla ever shipped |

Those rows used to be ordinary downloads that failed at the vendor, which is the worst place to
find out. The shelf now asks first, in the background, and never on the page's own request path:

- **Edge** takes one request — the feed lists exactly what it will serve — cached for six hours
- **WebKit** takes six, not fifty-three: Playwright deletes from the old end and never from the
  middle, so halving the shelf finds the boundary. Cached for three days
- both answers land in `~/.engineshelf/native.json`, and a row with no answer yet behaves exactly
  as it did before any of this — an unasked question is not a no

A row the vendor has dropped keeps its place on the shelf and **loses every native option**: no
Get, no *Download only*, no *Download and launch natively*. Its native mark goes grey
and its button is the container. A copy already on disk is untouched — that one still launches,
because it is already here.

**A row is removed from the list only when nothing anywhere can run it** — the vendor dropped it
*and* its engine has no container. All four engines have one, so today this removes nothing. It
is deliberately not "and Docker is not installed on this machine": that would hide seventy
versions from someone who has yet to set Docker up and hand them back when they do.

### What a row says, and what its button does

Each row carries up to two badges, because they answer two different questions and one badge
answering both was unreadable.

Every version can be run two ways, so every row carries **two marks** — a screen for the native
build, a cube for the container:

| Mark | States |
|---|---|
| **screen** (native) | **blue** it runs here · **half blue**, split down the middle, it runs but the container is the better bet · **grey** there is no native route at all |
| **cube** (Docker) | **green** there is a container for this version · **grey** there is not |

The cube is on or off and never half: a container either exists or it does not, and it runs the
same Linux build either way. Which of the two routes to *prefer* is the screen's business —
saying it twice, once per mark, made the pair read as a comparison of two unrelated things.

So a modern Chromium is *blue screen, green cube*: run it natively, the container is there if
you want it. Chromium 74 is *half screen, green cube*: it downloads and starts, and dies in its
first second, so take the container. An Edge the feed has dropped is *grey screen, green cube*:
nothing left to download, and the container has it.

Half is a hard vertical split rather than a tint: at 18px a tint is indistinguishable from full
colour on a dim screen, and the state has to be legible at a glance to be worth drawing.

**The rest of a row.** A date tag comes first — every row has one and most rows get picked by it,
because nobody hunts for "Chromium 88", they hunt for something from early 2021. Above it sits
the changelog, on one line, with a button to open the rest when there is more than fits; rows
with no changelog say `N/A`, which most of the shelf does, because nobody wrote one. The feature
pills that used to sit beside the date are gone: they were lifted out of the changelog printed
directly above them and said the same thing twice.

**Sizes.** Two right-aligned lines, each marked with the glyph its route uses and in its colour —
a blue screen for the native build, a green cube for the container image. The words "Native" and
"Docker" were there first, in a column with a fixed width and `overflow: hidden`, so the second
line came out as *er 898 MB*. The column is sized by what is in it now: the next unit up will be
longer again.

Nothing beside them is text. Everything a row used to spell out — the architecture, *crashes on this macOS*, *no longer
downloadable*, *no build for this host*, *Docker run recommended* — is a sentence in the mark's
tooltip, which is the page's own tooltip
rather than a `title`: a title waits about a second, cannot be wrapped or styled, and on a shelf
where the marks are the only words left that second is the whole answer. Each mark carries the
same sentence as its `aria-label`, so a screen reader gets what the eye gets.

**Sizes read in one place.** A version on disk twice — the native build and the container image
— has two lines in the right-hand column, one each, rather than a size in the column and another
inside a tag. What used to be on that top line was the version, which only Chromium ever had a
different one of; it reads under the name now, where the other three engines have always put
theirs, and Chromium's snapshot revision moved into that line's tooltip. Recommending one thing and
offering another asks someone to read a badge, work out what it means, and then reject the
button in front of them. It appears on three kinds of row:

| Row | Why |
|---|---|
| no build for this host | there is nothing to launch natively |
| the vendor no longer serves it | there is nothing left to download |
| already watched crash here | it starts and dies, every time |
| any x86_64 build on Apple Silicon | it does run, translated — and translation is where every failure this shelf knows about lives |

There are two ways to run a version and each has the same three states, so each has the same
three buttons — colour included. **Accent means "this runs now"**: a row with a multi-minute
image build in front of it does not wear it, any more than an undownloaded native row wears it
on Get.

| State | Native | Docker |
|---|---|---|
| nothing on disk | ⤓ **Get** | ⬢ **Get** |
| on disk | ▶ **Launch** | ⬢ **Launch** |
| fetch it, run it later | *Download only* (**···** menu) | *Get the container only* (**···** menu) |

Same words on both sides, and the cube carries the difference. They used to read *Get* against
*Get & launch in Docker* — one button four times the width of the other, on rows sitting
directly above each other.

`Get the container only` is `./engineshelf-docker.sh build <version>` — the image built and
nothing started, so the eight minutes happen when it suits rather than in front of someone who
wanted a browser.

**Translation is the line.** Every x86_64 build on an Apple Silicon machine gets the half mark
and the container button — 63 rows here: Chromium 60–90, and Firefox 51–83, whose mac package is
universal only from 84 on. Both failure modes under [Stability](#good-to-know) are translation
failures, and the startup abort that kills the oldest Chromium is a 2019 allocator meeting this
year's `libsystem_malloc`, which is a macOS problem the Linux build in a container does not have.

Only Chromium's rate is measured — about a third of sessions on a heavy page — and its tooltip
says so with the number. Firefox's says the same translation path is there and stops, rather
than borrowing a figure that was never measured for it.

Edge and WebKit say nothing about architecture before a download, because nothing in the shelf
data settles which one they arrive as. All four engines still switch to Docker the moment one is
actually watched fail, whatever the architecture.

**Every version says what it brought.** The shelf's notes were twenty-odd hand-written lines on
curated Chromium milestones and nothing at all on the other 270 rows — which is fair, since no
vendor publishes a changelog a tool can read: Chrome has a milestone API, Mozilla and Apple
publish HTML, Playwright publishes nothing.

MDN's **browser-compat-data** answers for all four at once. It records, per web feature, the
first version of each browser to support it, so inverting it by version gives the question
someone browsing this shelf is actually asking: what can I test here that I could not test in
the version before. `tools/features.py` does that inversion and writes `features.tsv`, which
ships with the release — twenty megabytes of compat data resolved once, on a maintainer's
machine, so nothing here fetches it and the shelf works offline.

| Engine | Rows with data |
|---|---|
| Chromium | 92 / 92 |
| Firefox | 104 / 104 |
| Edge | 39 / 39 |
| WebKit | 25 / 53 — the 28 oldest are labelled by Playwright revision, with no Safari version for the data to be keyed on |

A hand-written note still wins where there is one: it says *why you would pick this version*,
which compat data cannot. Otherwise the row names as many features as the line holds, ordered so
that a CSS property comes before the fourteenth method on an obscure interface, and the **⤢**
button opens the full list. Rows with neither say `N/A`.

**Which is what makes the search box mean it.** Typing `aspect-ratio` finds Chromium 88 and
Firefox 89 — the two versions that were first to support it — because every name in the file is
in the haystack, not just the handful a row has room to print. The whole index is fetched **once**
from `/api/features` rather than carried in the state document: it describes releases that
already happened, so re-sending 146 KB of it every second a download is running would be 146 KB
an hour of nothing changing. Dropping it out of the state took that payload from 227 KB to
155 KB.

**Every Chromium milestone knows what it is called.** Twenty-one carry a hand-written version;
the other seventy had nothing under their name, because a milestone number is not a version and
inventing one is worse than a blank. One request each to the milestone dashboard fills them in,
in the background, cached as `V` rows in `~/.engineshelf/catalog.cache.tsv` — a name, with no
claim that a build has been found for this machine.

The Rosetta badge appears before a download too. Only about twenty Chromium milestones carry a
verified platform row, so the rest used to say nothing about Rosetta until they had been
installed; the shelf instead reads the boundary out of the catalog — the highest milestone
proven to have no arm64 build — and says so from the start. The few milestones between that
boundary and the first proven arm64 build stay unlabelled, because nobody has checked them.

**Intel Macs, Windows and Linux run x86_64 natively**, never go through the Rosetta unwinder,
and should not see the second or third failure mode at all.

</details>

<details>
<summary><b>Keeping disk under control</b> — each version is a separate 90–300 MB download</summary>

<br>

The **···** menu on any installed row offers:

| Action | Frees | Keeps |
|---|---|---|
| **Reset profile** | the profile | the browser |
| **Delete browser** | the browser | the profile, so reinstalling restores your session |
| **Delete browser and profile** | both | nothing |

From the command line:

```bash
./engineshelf.sh list                    # what is installed, and how big
./engineshelf.sh remove 74               # delete the browser, keep the profile
./engineshelf.sh remove 74 --with-profile
./engineshelf.sh clean 74                # reset just the profile
```

Docker images are the other place disk quietly disappears — around a gigabyte each. The
manager counts them in its Disk read-out and offers **Delete Docker image** in the row menu;
from a terminal:

```bash
./engineshelf-docker.sh list             # containers and images
./engineshelf-docker.sh purge 74         # remove that version's image
```

</details>

<details>
<summary><b>When something is missing</b> — the doctor, and what it will and will not install</summary>

<br>

EngineShelf needs very little, and says so up front rather than failing halfway through a
download.

```bash
./engineshelf.sh doctor         # what is installed, what is not, and why it matters
./engineshelf.sh doctor --fix   # offer to install each missing piece
./engineshelf.sh doctor --json  # the same report, for scripts
```

It never installs anything silently. For each missing piece it prints the exact command it
would run, what that will cost you, and waits for a yes:

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

The manager shows the same report under **System check**. It opens by itself only when
something EngineShelf cannot work without is missing — the recommended and optional ones
are counted on the header button instead of interrupting you; its **Install** buttons run the
same commands. Where a fix
needs administrator rights, macOS asks through the system password dialog; elsewhere the
manager says plainly that it needs a terminal rather than failing on `sudo: no tty present`.

The manager is written in Python, so it cannot be the thing that tells you Python is missing
— `gui.sh` checks first and offers the install before starting. Windows needs none of this:
PowerShell 5.1 ships with the OS and runs both the launcher and the manager, downloads go
through `Invoke-WebRequest` and archives through .NET. Only Docker is ever reported missing
there.

</details>

<details>
<summary><b>Where everything lives on disk</b></summary>

<br>

| Path | Contents |
|---|---|
| `~/.engineshelf/builds/<revision>/` | a downloaded browser |
| `~/.engineshelf/profiles/<revision>/` | that version's profile (cookies, logins, storage) |
| `~/.engineshelf/logs/<revision>.log` | that version's stderr from its last run |
| `~/.engineshelf/native.json` | when each background question was last asked, and what each vendor still serves for this host: the Edge versions its feed lists, and the oldest WebKit build with an archive for this macOS. Refreshed in the background, six hours for Edge and three days for WebKit. Delete it to make the shelf ask again. |
| `~/.engineshelf/arch-fallback.cache` | one line per macOS major version and version that started here and died before its window — a bare milestone for Chromium, `engine:id` for the other three. Written by the first such launch, read by the CLI and the manager so neither leads with a native launch again. Delete it to make the shelf ask again. |
| `~/.engineshelf/manager.json` | which port the running manager is on, so opening the app again finds it instead of starting a second one. Removed when it quits. |
| `~/.engineshelf/manager-window/` | the browser profile behind the manager's own window on Windows and Linux — a few tens of MB of browser plumbing, not something EngineShelf downloaded. Safe to delete when the manager is closed; it is rebuilt on the next start. The macOS app draws its own window and needs none of it. |
| `%USERPROFILE%\.engineshelf\` | the same, on Windows |
| docker volume `engineshelf-profile-<revision>` | the Docker edition's profile |

Set `ENGINESHELF_HOME` to put all of it somewhere else.

An existing `~/.chrome74` install from the single-version days is **adopted on first run**
rather than re-downloaded, and its profile becomes Chromium 74's. That happens only when the
home is the default one; if `ENGINESHELF_HOME` is set, the old directory is left alone.

</details>

<details>
<summary><b>Troubleshooting</b> — the handful of things that actually come up</summary>

<br>

**macOS — “EngineShelf.app cannot be opened because it is from an unidentified developer.”**
Right-click the app → **Open** → **Open**. Once. The app carries an ad-hoc signature, not a
paid developer one.

**macOS — the app bounces once and a permission alert appears.**
If the folder sits in `~/Documents`, `~/Desktop` or `~/Downloads`, macOS gates access to it.
Allow EngineShelf under **System Settings → Privacy & Security → Files and Folders**, or
move the folder somewhere unprotected. Running `./gui.sh` from Terminal is unaffected.

**Windows — SmartScreen or antivirus complains about the download.**
The launcher is `EngineShelf.bat`, a short script you can open in Notepad — there is no
compiled program to trust. Without a paid certificate a downloaded script can still draw a
“Run anyway?” prompt; click through it once. If a file feels stuck, unblock the folder:
`Get-ChildItem -Recurse | Unblock-File`. `.\engineshelf.ps1 run 74` skips the launcher
entirely.

**The manager will not start — “needs Python 3”.**
It offers to install it for you. To do it yourself: macOS `xcode-select --install`, Linux
`sudo apt install python3`. Or skip the manager: `./engineshelf.sh run 74`.

**macOS on Apple Silicon — an old version will not start.**
Milestones up to 90 run under Rosetta: `softwareupdate --install-rosetta`.

**Linux — extraction fails.** Install `unzip`: `sudo apt install unzip`.

**Linux — the desktop entry has no icon.** Desktop environments look icons up by name, so
copy it where they can find it:
`mkdir -p ~/.local/share/icons && cp assets/icon-512.png ~/.local/share/icons/engineshelf.png`

**The browser starts and immediately closes.** Check
`~/.engineshelf/logs/<revision>.log`. Three crashes in a row within 5 seconds each and the
launcher stops retrying, assuming the setup is broken rather than the random crash above.

**A revision is rejected as “not archived”.** Not every commit position is built. Pick one a
few commits later, or use a catalogued milestone.

**A proxy blocks the download.** The browsers come from
`https://commondatastorage.googleapis.com/chromium-browser-snapshots/`; the catalog tool also
reads `https://www.googleapis.com/storage/v1/` and `https://chromiumdash.appspot.com/`. Those
hosts must be reachable.

</details>

<details>
<summary><b>What is in the box</b> — the project layout, for anyone reading the source</summary>

<br>

```
EngineShelf.app                     double-click, opens the manager (macOS)
EngineShelf.bat                     double-click, opens the manager (Windows)
engineshelf.desktop                Linux desktop entry
gui.sh / gui.ps1                      start the manager
gui/index.html, app.js, styles.css    the manager page
gui/server.py                         manager backend, macOS/Linux (stdlib only)
gui/server.ps1                        manager backend, Windows (PowerShell only)
engineshelf.sh / .ps1              the launcher everything else drives
engineshelf-docker.sh / .ps1       Docker launcher, one image per version
lib/preflight.sh, preflight.ps1       dependency checks and the install offers,
                                      shared by the CLI, Docker and the manager
lib/engines.sh, engines.ps1           what each engine is: where its builds live,
                                      how to unpack one, how to launch it
catalog.tsv                           verified revisions per milestone per platform,
                                      plus the shelf itself - every release of every
                                      engine, with its date. The seed, not the last word
~/.engineshelf/catalog.cache.tsv   milestones resolved live since then; read first
features.tsv                          what each shelf version was first to support,
                                      inverted out of MDN browser-compat-data
tools/discover.py                     rebuild the shelf from each vendor's own index
tools/features.py                     regenerate features.tsv from compat data
tools/refresh-catalog.py              regenerate catalog.tsv from the archive
tools/sync-landing.py                 bring docs/index.html into step with catalog.tsv
tools/check-phases.mjs                assert the manager still understands what the
                                      CLI prints, for all four engines
docker/Dockerfile                     Chromium + Xvfb + fluxbox + x11vnc + noVNC
docker/Dockerfile.firefox             the same desktop around a Linux Firefox
docker/Dockerfile.edge                ...and around an Edge .deb from the pool
docker/Dockerfile.webkit              ...and around a Playwright WebKit
docker/entrypoint.sh                  brings up X and supervises the browser
docker/clipboard.js                   loaded into the noVNC page: bridges the
                                      container's clipboard and your own
docker/novnc-clipboard.sh             wires that file in at build time; one copy,
                                      shared by all four images
assets/icon.svg, icon-small.svg       icon sources: full detail, and reduced for
                                      small sizes where detail turns to mush
assets/icon.ico, icon-512.png         generated, for Windows and Linux
assets/banner.svg                     the README hero
assets/og-image.svg                   source for the social card
assets/screenshot-manager.png         the manager, as shown above
tools/make-icons.sh                   rebuild every raster icon from the SVGs
tools/make-og.sh                      re-render docs/assets/og-image.png
tools/make-screenshots.py             re-shoot the manager against a staged shelf,
                                      so the pictures cannot drift from the page
tools/build-app.sh                    compile and sign the macOS bundle launcher
tools/launcher/launcher.c             that launcher's source
```

The macOS launcher is a committed binary and Windows just runs `EngineShelf.bat`, so nothing
has to be built to use this. Zip the folder and hand it to someone — no clone needed.

`EngineShelf.app/Contents/MacOS/EngineShelf` is a universal binary. A `.app` cannot work
without a compiled executable, and a shell script will not do: when the project lives in a
folder macOS protects, a script-based bundle has its file access attributed to `/bin/bash`,
which macOS denies without ever prompting. All it does is `chdir` and hand over to `gui.sh`.

Windows uses `EngineShelf.bat` — no compiled launcher. It hands over to `gui.ps1` with
`-ExecutionPolicy Bypass`, so an unconfigured machine does not refuse the script, and because
it is a plain script rather than an unsigned `.exe`, SmartScreen has no binary to distrust. A
`.bat` cannot carry an icon, so the Windows release also ships `Create-Shortcut.ps1`, which
drops an icon'd shortcut on the Desktop and Start Menu when run once. Rebuild the macOS
launcher after editing its source:

```bash
tools/build-app.sh    # macOS bundle launcher, needs Xcode command line tools
```

</details>

---

## Where the project stands

**Verified end to end on macOS 26 (Apple Silicon):** catalog generation against the live
archive, the manager (install, launch, delete, reset, disk accounting, token auth),
downloading and launching a native arm64 build, per-version profile isolation, adoption of an
existing `~/.chrome74` install, and the macOS app bundle launching from a TCC-protected
folder. The app bundle is a universal binary with an explicit floor per slice — macOS 10.13
on Intel, 11.0 on Apple Silicon — so it loads on older systems, but nothing older than the
development machine has actually been booted and clicked through.

**Nothing on the Windows side has been run on Windows.** The Windows package ships no compiled
launcher — `EngineShelf.bat` hands straight to PowerShell. The scripts target PowerShell 5.1
(which ships with Windows 10/11) and have been reviewed, but if you are the first to try any
of it there, expect to find something. The manager's Windows backend deliberately speaks HTTP
over a plain `TcpListener` rather than `System.Net.HttpListener`, which would need a `netsh`
URL reservation or an elevated prompt.

**The per-version Docker images have not been built for every milestone.** The Dockerfile is
parameterised by revision and the Debian package list covers old and new builds — including
`libgconf`, which Debian dropped and the oldest milestones still link against — but a given
milestone may want a library the list does not have. The container's log says which one:
`./engineshelf-docker.sh logs <version>`.

Found something? [Open an issue](https://github.com/1m93/EngineShelf/issues) — Windows
reports especially welcome.

---

<p align="center">
  <img src="assets/icon-512.png" alt="" width="64" height="64"><br>
  <sub>Built by <a href="https://github.com/1m93">@1m93</a>. Firefox builds come from
  <a href="https://ftp.mozilla.org/pub/firefox/releases/">Mozilla</a>, Edge from
  <a href="https://packages.microsoft.com/repos/edge/">Microsoft</a>, WebKit from
  <a href="https://playwright.dev">Playwright</a>'s build CDN;<br>
  Chromium builds come from the
  <a href="https://commondatastorage.googleapis.com/chromium-browser-snapshots/index.html">Chromium snapshot archive</a>;<br>
  this project only downloads and launches them.</sub>
</p>
