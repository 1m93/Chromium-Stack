# Per-engine knowledge, kept apart from the launcher that drives it.
#
# EngineShelf started as a Chromium-only tool, and its identity for a build was
# the Chromium snapshot revision - a number that means nothing to Firefox, Edge
# or WebKit. Everything an engine differs in is answered here instead, by one
# function per question, so adding a fifth engine touches this file and the
# catalog, not the launcher.
#
# The questions, and who answers them:
#
#   engine_display     what to call it in output
#   engine_platforms   which host platforms it publishes, best first
#   engine_key         the on-disk name for one installed build
#   engine_binary      the executable inside an extracted build
#   engine_extract     how to get an archive onto disk
#   engine_launch_env  environment the browser needs to start
#   engine_launch_args the flags that give it its own profile and no updater
#
# Chromium's answers are the ones this tool already shipped, unchanged: its key
# is still the bare revision, so an existing ~/.engineshelf keeps working and
# nothing has to be re-downloaded.

# Four small things every function below leans on. Historically they came from
# whichever script sourced this file, which is an unwritten contract - and it
# broke the moment the container launcher needed to resolve a download too. A
# caller that already has its own, coloured versions keeps them: these only fill
# a gap, they never take over.
command -v info    >/dev/null 2>&1 || info() { printf '%s\n' "$*"; }
command -v warn    >/dev/null 2>&1 || warn() { printf '%s\n' "!  $*" >&2; }
command -v die     >/dev/null 2>&1 || die()  { printf '%s\n' "x  $*" >&2; exit 1; }
command -v net_get >/dev/null 2>&1 || net_get() { curl -fsS -m 30 "$1" 2>/dev/null || true; }

ENGINES="chromium firefox edge webkit"

engine_known() {
  case " $ENGINES " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

engine_display() {
  case "$1" in
    chromium) printf 'Chromium\n' ;;
    firefox)  printf 'Firefox\n' ;;
    edge)     printf 'Edge\n' ;;
    # Never "Safari". This is the engine Safari is built on, in a MiniBrowser
    # shell - no Safari UI, no ITP, no media stack. Calling it Safari would
    # invite bug reports against behaviour it cannot reproduce.
    webkit)   printf 'WebKit\n' ;;
    *)        printf '%s\n' "$1" ;;
  esac
}

# Host platforms in preference order. The names are each vendor's own, because
# they end up in URLs and catalog rows.
engine_platforms() {
  local engine="$1" os arch
  # The container launcher needs the Linux answer while running on a Mac, and it
  # needs it from here rather than rebuilding each vendor's URLs itself - that
  # duplication is how the two would come to disagree about where Firefox 115
  # lives. Set by engineshelf-docker.sh around one resolve, never by the CLI.
  if [ -n "${ENGINE_PLATFORM_OVERRIDE:-}" ]; then
    printf '%s\n' "$ENGINE_PLATFORM_OVERRIDE"
    return 0
  fi
  os="$(uname -s)"; arch="$(uname -m)"
  case "$engine:$os:$arch" in
    # Apple Silicon runs the native arm64 snapshot or the x86_64 one under
    # Rosetta, in that order.
    chromium:Darwin:arm64) printf 'Mac_Arm Mac\n' ;;
    chromium:Darwin:*)     printf 'Mac\n' ;;
    chromium:Linux:*)      printf 'Linux_x64\n' ;;

    # Mozilla ships one mac package, universal since 84 and x86_64 before it, so
    # there is nothing to choose between.
    firefox:Darwin:*)      printf 'mac\n' ;;
    firefox:Linux:*)       printf 'linux-x86_64\n' ;;

    # Edge's mac package is universal too.
    edge:Darwin:*)         printf 'Mac_Universal\n' ;;
    edge:Linux:*)          printf 'Linux_x64\n' ;;

    # Playwright builds webkit against a specific macOS SDK and publishes one
    # archive per macOS version, so the running system decides which.
    webkit:Darwin:arm64)   printf '%s\n' "$(webkit_mac_platforms arm64)" ;;
    webkit:Darwin:*)       printf '%s\n' "$(webkit_mac_platforms x64)" ;;
    # Measured against the CDN, not guessed: x86_64 archives carry no arch
    # suffix at all (webkit-ubuntu-24.04.zip), and only arm64 is spelled out.
    # "ubuntu-24.04-x64" - the obvious name - does not exist and never did.
    webkit:Linux:aarch64|webkit:Linux:arm64)
                           printf 'ubuntu-24.04-arm64 ubuntu-22.04-arm64\n' ;;
    webkit:Linux:*)        printf 'ubuntu-24.04 ubuntu-22.04 ubuntu-20.04\n' ;;
    *) return 1 ;;
  esac
}

# Newest SDK first, then older ones: a build for macOS 14 runs on 15, but not
# the other way round.
webkit_mac_platforms() {
  local arch="$1" major suffix candidates=""
  major="$(sw_vers -productVersion 2>/dev/null | cut -d. -f1)"
  major="${major:-14}"
  [ "$arch" = "arm64" ] && suffix="-arm64" || suffix=""
  while [ "$major" -ge 13 ]; do
    candidates="$candidates mac-$major$suffix"
    major=$((major - 1))
  done
  printf '%s\n' "${candidates# }"
}

# The directory one build lives in, under builds/ and profiles/.
#
# Chromium keeps the bare revision it has always used - renaming it would strand
# every build already on disk for no gain. Everything else is prefixed, because
# "115.0" alone would collide across engines the moment Edge reaches it.
engine_key() {
  case "$1" in
    chromium) printf '%s\n' "$2" ;;
    *)        printf '%s-%s\n' "$1" "$2" ;;
  esac
}

engine_of_key() {
  case "$1" in
    firefox-*) printf 'firefox\n' ;;
    edge-*)    printf 'edge\n' ;;
    webkit-*)  printf 'webkit\n' ;;
    *)         printf 'chromium\n' ;;
  esac
}

# dir root platform -> the executable to run.
engine_binary() {
  local engine="$1" dir="$2" root="$3" platform="$4"
  case "$engine" in
    chromium)
      case "$platform" in
        Mac|Mac_Arm) printf '%s\n' "$dir/$root/Chromium.app/Contents/MacOS/Chromium" ;;
        *)           printf '%s\n' "$dir/$root/chrome" ;;
      esac ;;
    firefox)
      case "$platform" in
        mac) printf '%s\n' "$dir/Firefox.app/Contents/MacOS/firefox" ;;
        # Both the Linux tarball and the Windows candidates zip unpack into a
        # firefox/ directory. Checked against the archives, not assumed: core/ is
        # the layout inside the NSIS installer, which is a different download.
        linux*) printf '%s\n' "$dir/firefox/firefox" ;;
        *)      printf '%s\n' "$dir/firefox/firefox.exe" ;;
      esac ;;
    edge)
      case "$platform" in
        # The pkg declares install-location="/Applications", so the payload root
        # is what would land *in* Applications - the bundle itself, not a tree
        # starting at /. A .deb has no such field and is always laid out from /,
        # hence the two different shapes.
        Mac_Universal) printf '%s\n' "$dir/Microsoft Edge.app/Contents/MacOS/Microsoft Edge" ;;
        Linux_x64)     printf '%s\n' "$dir/opt/microsoft/msedge/msedge" ;;
        *)             printf '%s\n' "$dir/msedge.exe" ;;
      esac ;;
    webkit)
      case "$platform" in
        # pw_run.sh is the supported entry point on mac and Linux: it sets the
        # DYLD paths the bundle needs, and on Linux picks minibrowser-gtk out of
        # the archive. The win64 archive has no such script - it unpacks flat,
        # with Playwright.exe at the top - so there it is the executable itself.
        win*) printf '%s\n' "$dir/Playwright.exe" ;;
        *)    printf '%s\n' "$dir/pw_run.sh" ;;
      esac ;;
  esac
}

# format archive destination -> extracted, or non-zero.
#
# Five formats, because no two vendors agree: a snapshot zip, a dmg, a Debian
# package, an Apple installer package, and two tarballs.
engine_extract() {
  local format="$1" archive="$2" dir="$3"
  case "$format" in
    zip-ditto)
      # ditto preserves the symlinks and permissions inside a .app bundle; plain
      # unzip corrupts the framework and the browser will not start.
      ditto -x -k "$archive" "$dir" ;;
    zip)
      if command -v unzip >/dev/null 2>&1; then
        unzip -q "$archive" -d "$dir"
      elif command -v python3 >/dev/null 2>&1; then
        python3 -m zipfile -e "$archive" "$dir"
      else
        warn "Need 'unzip' or 'python3' to extract. Install one: sudo apt install unzip"
        return 1
      fi ;;
    dmg)
      extract_dmg "$archive" "$dir" ;;
    pkg)
      extract_pkg "$archive" "$dir" ;;
    deb)
      extract_deb "$archive" "$dir" ;;
    tar-xz)
      tar -xJf "$archive" -C "$dir" ;;
    tar-bz2)
      tar -xjf "$archive" -C "$dir" ;;
    *)
      warn "Unknown archive format: $format"
      return 1 ;;
  esac
}

# A dmg is a filesystem, not an archive: mount it read-only and nowhere the
# Finder will notice, copy the bundle out with ditto, unmount whatever happens.
extract_dmg() {
  local archive="$1" dir="$2" mount status=0
  mount="$(mktemp -d "${TMPDIR:-/tmp}/engineshelf-dmg.XXXXXX")" || return 1
  if ! hdiutil attach -nobrowse -readonly -noverify -quiet \
       -mountpoint "$mount" "$archive" >/dev/null 2>&1; then
    rmdir "$mount" 2>/dev/null || true
    warn "Could not mount $archive"
    return 1
  fi
  cp -R "$mount"/*.app "$dir/" 2>/dev/null || status=1
  hdiutil detach -quiet -force "$mount" >/dev/null 2>&1 || true
  rmdir "$mount" 2>/dev/null || true
  return "$status"
}

# An Apple installer package, unpacked without installing anything: the payload
# is taken and the package's own scripts are deliberately not run. For Edge
# those scripts are what register Microsoft AutoUpdate, which is exactly what a
# pinned, disposable build must not have.
extract_pkg() {
  local archive="$1" dir="$2" work
  work="$(mktemp -d "${TMPDIR:-/tmp}/engineshelf-pkg.XXXXXX")" || return 1
  rmdir "$work"
  if ! pkgutil --expand-full "$archive" "$work" >/dev/null 2>&1; then
    rm -rf "$work"
    warn "Could not expand $archive"
    return 1
  fi
  # --expand-full leaves each component's Payload already unpacked as a
  # directory; one of them holds the tree that would have been installed.
  local payload found=0
  for payload in "$work"/*/Payload "$work"/Payload; do
    [ -d "$payload" ] || continue
    (cd "$payload" && tar -cf - .) | (cd "$dir" && tar -xf -) || continue
    found=1
  done
  rm -rf "$work"
  [ "$found" -eq 1 ] || { warn "No payload found inside $archive"; return 1; }
}

# A Debian package is an ar archive holding data.tar.*; bsdtar on macOS reads the
# whole thing in one step, GNU tar needs ar first.
extract_deb() {
  local archive="$1" dir="$2" work data
  if command -v dpkg-deb >/dev/null 2>&1; then
    dpkg-deb -x "$archive" "$dir" && return 0
  fi
  work="$(mktemp -d "${TMPDIR:-/tmp}/engineshelf-deb.XXXXXX")" || return 1
  if ! (cd "$work" && ar x "$archive") >/dev/null 2>&1; then
    rm -rf "$work"; warn "Could not read $archive (need 'ar' or 'dpkg-deb')"; return 1
  fi
  for data in "$work"/data.tar.*; do
    [ -f "$data" ] || continue
    tar -xf "$data" -C "$dir" && { rm -rf "$work"; return 0; }
  done
  rm -rf "$work"
  warn "No data archive inside $archive"
  return 1
}

# Environment the browser needs, as NAME=VALUE lines. Only WebKit has any: its
# frameworks sit beside the app rather than in /System.
engine_launch_env() {
  case "$1" in
    webkit) printf 'DYLD_FRAMEWORK_PATH=%s\nDYLD_LIBRARY_PATH=%s\n' "$2" "$2" ;;
    *)      : ;;
  esac
}

# Flags that give the build its own profile and stop it updating itself, one per
# line. Two families: Chromium's --long=value, and Firefox's -short value.
engine_launch_args() {
  local engine="$1" profile="$2"
  case "$engine" in
    chromium|edge)
      printf -- '--user-data-dir=%s\n' "$profile"
      printf -- '--no-first-run\n--no-default-browser-check\n'
      printf -- '--disable-background-networking\n--disable-component-update\n'
      printf -- '--disable-features=TranslateUI\n' ;;
    firefox)
      # -no-remote and -new-instance together are what stop this launch being
      # handed to a Firefox the user already has open, which would silently
      # ignore the version they asked for.
      printf -- '-profile\n%s\n-no-remote\n-new-instance\n' "$profile" ;;
    webkit)
      # The MiniBrowser shell takes no profile flag; its state lives beside the
      # bundle, which is per-build already.
      : ;;
  esac
}

# Firefox trusts only the certificate authorities baked into the build it
# shipped with, so a 2019 build rejects most of today's web - the expired DST
# Root chain, then anything newer than its bundle. Chromium asks the OS instead
# and never has this problem, which is why nothing like this existed before.
#
# Written into the profile rather than passed as a flag, because there is no
# flag for it.
engine_prepare_profile() {
  local engine="$1" profile="$2" prefs
  [ "$engine" = "firefox" ] || return 0
  prefs="$profile/user.js"
  [ -f "$prefs" ] && return 0
  mkdir -p "$profile" || return 0
  cat > "$prefs" <<'PREFS'
// Written by EngineShelf. Delete this file to get the build's own defaults back.

// Trust the certificates the operating system trusts, instead of only the ones
// this build shipped with. Without it an old Firefox cannot open most of the
// modern web: it has never heard of the roots issued since it was built.
user_pref("security.enterprise_roots.enabled", true);

// A pinned build that updates itself is not a pinned build.
user_pref("app.update.enabled", false);
user_pref("app.update.auto", false);
user_pref("app.update.service.enabled", false);

// Nothing here should phone home; this is a browser opened to look at one page.
user_pref("datareporting.healthreport.uploadEnabled", false);
user_pref("datareporting.policy.dataSubmissionEnabled", false);
user_pref("toolkit.telemetry.enabled", false);
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("browser.startup.homepage_override.mstone", "ignore");
PREFS
}

# ---------- resolution ----------
# Turning "edge:151" into something downloadable. Each vendor publishes an index
# and none of them agree on what it looks like, so there is one of these per
# engine. They set the same SEL_* variables the Chromium resolver in the launcher
# sets, and are called through resolve_engine.

EDGE_API="https://edgeupdates.microsoft.com/api/products?view=enterprise"
EDGE_POOL="https://packages.microsoft.com/repos/edge/pool/main/m/microsoft-edge-stable"
MOZ_RELEASES="https://ftp.mozilla.org/pub/firefox/releases"
MOZ_VERSIONS="https://product-details.mozilla.org/1.0/firefox_versions.json"
WEBKIT_CDN="https://cdn.playwright.dev/dbazure/download/playwright/builds/webkit"

# Does this URL exist? Used where a vendor changed archive format partway through
# a range, or prunes old builds, and only the server knows.
#
# -L matters more than it looks: Playwright's CDN answers 307 and puts the real
# verdict behind the redirect, so without following it every URL looks present -
# including revisions that were deleted years ago.
net_exists() {
  curl -fsSIL -m 25 -o /dev/null "$1" 2>/dev/null
}

resolve_engine() {
  local engine="$1" token="$2"
  case "$engine" in
    firefox) resolve_firefox "$token" ;;
    edge)    resolve_edge "$token" ;;
    webkit)  resolve_webkit "$token" ;;
    *)       die "No resolver for $engine." ;;
  esac
  [ -n "$SEL_URL" ] || die "Could not resolve $engine:$token."
  # The key is built from SEL_ID, not from SEL_VERSION: the two are the same for
  # Firefox and Edge, but a WebKit version name is not unique - 26.5 covers two
  # different builds - and two builds sharing one directory would have them
  # overwrite each other. Identity is the id; the version is what to print.
  [ -n "${SEL_ID:-}" ] || SEL_ID="$SEL_VERSION"
  SEL_KEY="$(engine_key "$engine" "$SEL_ID")"
}

# ---------- firefox ----------
# Every release Mozilla has ever shipped is still on ftp.mozilla.org under a
# predictable path, so nothing has to be looked up except which tarball format a
# given year used - and, on Windows, which candidate build shipped.
resolve_firefox() {
  local token="$1" version platform
  platform="$(engine_platforms firefox)" || die "Firefox has no build for this machine."
  SEL_PLATFORM="$platform"

  case "$token" in
    *esr|*ESR)
      # ESR is the version fleets actually sit on for years, and which one is
      # current changes - so it is fetched, never assumed.
      # A bare "esr" means whichever line is current.
      version="$(resolve_firefox_esr "${token%[eE][sS][rR]}")" \
        || die "Could not find the ESR release for $token."
      ;;
    *[!0-9]*) version="$token" ;;         # a full version, taken as given
    *)        version="$token.0" ;;       # a bare major: 115 -> 115.0
  esac
  SEL_VERSION="$version"

  case "$platform" in
    mac)
      # The filename really does contain a space.
      SEL_URL="$MOZ_RELEASES/$version/mac/en-US/Firefox%20$version.dmg"
      SEL_FORMAT="dmg" ;;
    linux-x86_64)
      # Mozilla moved from bzip2 to xz partway through; the server decides.
      SEL_URL="$MOZ_RELEASES/$version/linux-x86_64/en-US/firefox-$version.tar.xz"
      SEL_FORMAT="tar-xz"
      if ! net_exists "$SEL_URL"; then
        SEL_URL="$MOZ_RELEASES/$version/linux-x86_64/en-US/firefox-$version.tar.bz2"
        SEL_FORMAT="tar-bz2"
      fi ;;
    *)
      # releases/ only has an installer for Windows; the plain zip lives in the
      # candidates tree, under whichever build number shipped.
      resolve_firefox_win_zip "$version" || die "\
No Windows zip found for Firefox $version.
   Mozilla publishes it under candidates/, and only the build that shipped."
      SEL_FORMAT="zip" ;;
  esac
  net_exists "$SEL_URL" || die "\
Firefox $version has no $platform build at ftp.mozilla.org.
   Check the version exists: $MOZ_RELEASES/"
}

resolve_firefox_esr() {
  local major="$1" body key found
  body="$(net_get "$MOZ_VERSIONS")" || return 1
  # FIREFOX_ESR is the current line, FIREFOX_ESR115 and friends the older ones.
  # Every value is checked against the major asked for, because which key holds
  # which line moves as new ESRs ship.
  if [ -z "$major" ]; then
    printf '%s' "$body" | tr ',' '\n' \
      | sed -n 's/.*"FIREFOX_ESR"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
      | head -1 | grep . && return 0
    return 1
  fi
  for key in "FIREFOX_ESR$major" FIREFOX_ESR FIREFOX_ESR_NEXT; do
    # Assigned from a substitution, not read from a pipe: a `return` inside a
    # piped while loop runs in a subshell and cannot leave this function.
    found="$(printf '%s' "$body" | tr ',' '\n' \
             | sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" \
             | head -1)"
    case "$found" in
      "$major".*) printf '%s\n' "$found"; return 0 ;;
    esac
  done
  return 1
}

# Candidate builds are numbered from 1 and the last one is what shipped. The
# directory index names them all, so one request settles it rather than probing
# build9 downwards - which cost eight round trips to learn that 115.0 shipped as
# build2.
resolve_firefox_win_zip() {
  local version="$1" base build url
  base="https://ftp.mozilla.org/pub/firefox/candidates/$version-candidates"
  for build in $(net_get "$base/" | grep -o 'build[0-9]*' | sed 's/build//' \
                 | sort -un | sort -rn); do
    url="$base/build$build/win64/en-US/firefox-$version.zip"
    if net_exists "$url"; then
      SEL_URL="$url"
      return 0
    fi
  done
  return 1
}

# ---------- edge ----------
# Two indexes, and which one is usable decides how far back this engine reaches.
# On Linux the apt pool's URLs are built from the version alone and it keeps
# years. On mac and Windows every download carries a random GUID, so only what
# the enterprise API still lists can be fetched at all - about six months.
resolve_edge() {
  local token="$1" platform
  platform="$(engine_platforms edge)" || die "Edge has no build for this machine."
  SEL_PLATFORM="$platform"

  case "$platform" in
    Linux_x64)
      SEL_VERSION="$(resolve_edge_pool_version "$token")" || die "\
No Edge build for $token in the package pool.
   It keeps roughly milestone 114 and up; see: $EDGE_POOL/"
      SEL_URL="$EDGE_POOL/microsoft-edge-stable_${SEL_VERSION}-1_amd64.deb"
      SEL_FORMAT="deb" ;;
    *)
      resolve_edge_api "$token" "$platform" || die "\
Edge $token is not in Microsoft's enterprise feed.
   That feed is the only source for mac and Windows, and it holds about six
   months: its download URLs carry a per-file GUID that cannot be constructed.
   Currently offered: $(edge_api_versions "$platform" | tr '\n' ' ')"
      ;;
  esac
}

# Highest patch of the milestone, or the exact version if one was given.
resolve_edge_pool_version() {
  local token="$1" listing
  listing="$(net_get "$EDGE_POOL/")" || return 1
  printf '%s' "$listing" \
    | grep -o 'microsoft-edge-stable_[0-9.]*-1_amd64\.deb' \
    | sed 's/microsoft-edge-stable_//; s/-1_amd64\.deb//' \
    | sort -u \
    | awk -F. -v t="$token" '
        # A bare milestone matches on the first field; anything with a dot has
        # to match exactly.
        (index(t, ".") == 0 && $1 == t) || ($0 == t) { print }' \
    | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n \
    | tail -1 | grep . || return 1
}

edge_api_json() {
  [ -n "${EDGE_API_CACHE:-}" ] || EDGE_API_CACHE="$(net_get "$EDGE_API")"
  printf '%s' "$EDGE_API_CACHE"
}

edge_api_versions() {
  edge_api_json | python3 -c '
import json, sys
platform = sys.argv[1]
want = {"Mac_Universal": ("MacOS", "universal"), "Win_x64": ("Windows", "x64")}[platform]
data = json.load(sys.stdin)
stable = next((p for p in data if p.get("Product") == "Stable"), {})
seen = set()
for release in stable.get("Releases") or []:
    if (release.get("Platform"), release.get("Architecture")) == want:
        seen.add(release.get("ProductVersion"))
for version in sorted(seen, key=lambda v: [int(p) for p in v.split(".")]):
    print(version)
' "$1" 2>/dev/null
}

resolve_edge_api() {
  local token="$1" platform="$2" answer
  command -v python3 >/dev/null 2>&1 || die "\
Reading Microsoft's enterprise feed needs Python 3 (it is JSON, and this is a
   shell script). Install it, or run the Linux build in Docker instead."
  answer="$(edge_api_json | python3 -c '
import json, sys
token, platform = sys.argv[1], sys.argv[2]
want = {"Mac_Universal": ("MacOS", "universal"), "Win_x64": ("Windows", "x64")}[platform]
formats = {"pkg": "pkg", "msi": "msi"}
data = json.load(sys.stdin)
stable = next((p for p in data if p.get("Product") == "Stable"), {})
best = None
for release in stable.get("Releases") or []:
    if (release.get("Platform"), release.get("Architecture")) != want:
        continue
    version = release.get("ProductVersion") or ""
    if not version:
        continue
    # A bare milestone matches the major; anything with a dot must match whole.
    if "." in token:
        if version != token:
            continue
    elif version.split(".")[0] != token:
        continue
    for artifact in release.get("Artifacts") or []:
        fmt = formats.get((artifact.get("ArtifactName") or "").lower())
        if not fmt or not artifact.get("Location"):
            continue
        key = [int(p) for p in version.split(".")]
        if best is None or key > best[0]:
            best = (key, version, fmt, artifact["Location"])
if best:
    print("%s\t%s\t%s" % (best[1], best[2], best[3]))
' "$token" "$platform" 2>/dev/null)"
  [ -n "$answer" ] || return 1
  SEL_VERSION="$(printf '%s' "$answer" | cut -f1)"
  SEL_FORMAT="$(printf '%s' "$answer" | cut -f2)"
  SEL_URL="$(printf '%s' "$answer" | cut -f3)"
}

# ---------- webkit ----------
# Nothing publishes "which webkit builds exist"; the only index is each
# Playwright release naming the revision it pins. Building that map costs one
# request per Playwright release, so it belongs in the catalog rather than in a
# launch - see tools/discover.py. A revision given directly needs no map.
resolve_webkit() {
  local token="$1" platform revision
  # A bare revision is taken as given; anything else is a published version name
  # like 18.2, which only the shelf can turn into a revision.
  case "$token" in
    ''|*[!0-9]*) revision="" ;;
    *)           [ "$token" -ge 1000 ] && revision="$token" || revision="" ;;
  esac
  if [ -z "$revision" ]; then
    revision="$(shelf_id_for_label webkit "$token")"
  fi
  [ -n "$revision" ] || die "\
No WebKit build known as $token.
   WebKit versions come from the shelf, which tools/discover.py builds from the
   Playwright releases that pin each build. Refresh it with:
       python3 tools/discover.py --write
   Known: $(shelf_labels webkit | sort -u | tr '\n' ' ')"

  # Playwright builds against a specific macOS SDK, so more than one archive can
  # fit this host; the first that exists wins.
  for platform in $(engine_platforms webkit); do
    if net_exists "$WEBKIT_CDN/$revision/webkit-$platform.zip"; then
      SEL_PLATFORM="$platform"
      # Show the published name when there is one; the revision is what the URL
      # needs, and what identifies the build on disk, not what anyone calls it.
      SEL_ID="$revision"
      SEL_VERSION="$(shelf_label_for_id webkit "$revision")"
      [ -n "$SEL_VERSION" ] || SEL_VERSION="r$revision"
      SEL_URL="$WEBKIT_CDN/$revision/webkit-$platform.zip"
      SEL_FORMAT="zip"
      return 0
    fi
  done
  die "\
No WebKit r$revision build for this system ($token).
   Two different things cause this, and neither can be worked around:
   Playwright deletes old builds from its CDN, and for older OS releases it pins
   a different revision entirely - so a build can still exist for Linux while no
   macOS archive of it was ever published. The CDN is the only source.
   Tried: $(engine_platforms webkit)"
}
