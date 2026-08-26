#!/usr/bin/env python3
"""Build the shelf from each vendor's own live index. No version is hardcoded.

The old tools/refresh-catalog.py carried a MILESTONES list, which meant the shelf
only grew when somebody edited a Python file. Four engines make that untenable:
Firefox alone has shipped 158 majors. So nothing here names a version. Each
engine has an index its vendor publishes, every index carries release dates, and
the shelf is derived from those dates by one rule:

    one version per engine per year - the newest that shipped in that year.

That rule is what the year-matrix UI shows, and it stays correct forever without
anyone touching this file.

    python3 tools/discover.py                 # print the matrix
    python3 tools/discover.py --tsv           # emit catalog rows to stdout
    python3 tools/discover.py --write         # merge those rows into catalog.tsv
    python3 tools/discover.py --from 2017     # earliest year to include

Each engine degrades on its own: one vendor being unreachable costs that column,
not the run.
"""
import argparse
import concurrent.futures
import datetime
import json
import os
import re
import sys
import urllib.error
import urllib.request

# Endpoints only. Nothing below names a browser version.
DASH_SCHEDULE = "https://chromiumdash.appspot.com/fetch_milestone_schedule"
MOZ_HISTORY = ("https://product-details.mozilla.org/1.0/"
               "firefox_history_major_releases.json")
MOZ_CURRENT = "https://product-details.mozilla.org/1.0/firefox_versions.json"
EDGE_POOL = ("https://packages.microsoft.com/repos/edge/pool/main/m/"
             "microsoft-edge-stable/")
EDGE_API = "https://edgeupdates.microsoft.com/api/products?view=enterprise"
NPM_PLAYWRIGHT = "https://registry.npmjs.org/playwright-core"
UNPKG_BROWSERS = "https://unpkg.com/playwright-core@%s/browsers.json"
WEBKIT_CDN = ("https://cdn.playwright.dev/dbazure/download/playwright/builds/"
              "webkit/%s/webkit-%s.zip")

ENGINES = ("chromium", "firefox", "edge", "webkit")

MONTHS = {m: i + 1 for i, m in enumerate(
    ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
     "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"])}


def get(url, timeout=45):
    request = urllib.request.Request(url, headers={"User-Agent": "engineshelf"})
    with urllib.request.urlopen(request, timeout=timeout) as handle:
        return handle.read()


def get_json(url, timeout=45):
    return json.loads(get(url, timeout))


def by_year(releases):
    """Group the full shelf by year, newest first within each year.

    Discovery keeps every release it finds; picking one to show is a view, not a
    filter. An earlier cut of this file kept only one version per year and that
    quietly threw away the milestones the catalog exists for - Chromium 80 and
    84, where optional chaining and flexbox `gap` land. The matrix shows the
    first entry of a year and opens the rest on demand.
    """
    years = {}
    for release in releases:
        years.setdefault(release["year"], []).append(release)
    for bucket in years.values():
        bucket.sort(key=lambda r: r["sort"], reverse=True)
    return years


# --------------------------------------------------------------------------- #
# chromium - chromiumdash publishes the schedule, stable_date and all
# --------------------------------------------------------------------------- #

def chromium_schedule():
    """milestone -> stable date, from chromiumdash. Fetched once, used twice.

    chromiumdash answers for milestones that have only been *scheduled*, so a
    run in August is offered an October stable date. Anything not actually
    released yet is dropped here rather than in each caller.
    """
    current = get_json(DASH_SCHEDULE)["mstones"][0]["mstone"]
    first = 60                      # the oldest milestone the archive still has
    span = current - first + 3      # a little past current, then filtered below
    stones = get_json("%s?mstone=%d&n=%d" % (DASH_SCHEDULE, first, span))["mstones"]

    today = datetime.date.today().isoformat()
    schedule = {}
    for stone in stones:
        stable = stone.get("stable_date")
        if stable and stable[:10] <= today:
            schedule[int(stone["mstone"])] = stable[:10]
    return schedule


def discover_chromium(schedule):
    return [{"year": int(date[:4]), "sort": date, "id": str(m),
             "label": str(m), "date": date}
            for m, date in schedule.items()]


# --------------------------------------------------------------------------- #
# firefox - product-details is Mozilla's own release index
# --------------------------------------------------------------------------- #

def discover_firefox(schedule):
    history = get_json(MOZ_HISTORY)
    # ESRs are what a shelf actually wants: they are the versions real fleets sit
    # on for years. Which versions are ESR is itself fetched, never assumed.
    esr = set()
    try:
        for key, value in get_json(MOZ_CURRENT).items():
            if key.startswith("FIREFOX_ESR") and value:
                esr.add(value.split(".")[0])
    except (urllib.error.URLError, ValueError, OSError):
        pass

    releases = []
    for version, date in history.items():
        if not date:
            continue
        major = version.split(".")[0]
        releases.append({
            "year": int(date[:4]), "sort": date, "id": version,
            "label": major, "date": date, "esr": major in esr,
        })
    return releases


# --------------------------------------------------------------------------- #
# edge - the apt pool carries dates and constructible URLs; the enterprise API
# carries the mac and Windows GUIDs that cannot be constructed at all
# --------------------------------------------------------------------------- #

def discover_edge(schedule):
    """Edge's own dates cannot be trusted, so Chromium's are used instead.

    The apt pool prints an mtime, not a release date: the Edge 95 debs are
    stamped 18-Jan-2023 because that is when the mirror last touched them, and
    95 actually shipped in late 2021. Believing the listing collapsed three
    years of shelf into one row.

    Edge N is branched from Chromium N and ships within days of it, so the
    Chromium schedule - which is a real, published release calendar - dates the
    Edge shelf correctly. Versions whose milestone predates the schedule are
    dropped rather than guessed at.
    """
    body = get(EDGE_POOL).decode("utf8", "replace")
    # The pool lists every patch; a milestone is the unit worth shelving, so the
    # highest patch of each one stands for it.
    best = {}
    for version in set(re.findall(
            r"microsoft-edge-stable_([0-9.]+)-1_amd64\.deb", body)):
        milestone = int(version.split(".", 1)[0])
        key = [int(part) for part in version.split(".")]
        if milestone not in best or key > best[milestone][0]:
            best[milestone] = (key, version)
    releases = []
    for milestone, (_, version) in best.items():
        date = schedule.get(milestone)
        if not date:
            continue
        releases.append({"year": int(date[:4]), "sort": milestone, "id": version,
                         "label": str(milestone), "date": date})
    return releases


# --------------------------------------------------------------------------- #
# webkit - npm dates the playwright releases, and each one names its webkit
# --------------------------------------------------------------------------- #

def discover_webkit(schedule):
    """One probe per playwright minor, then deduplicated by webkit revision.

    Nothing publishes "which webkit builds exist" - the only index is each
    playwright release naming the one it pins. Asking all 171 releases would be
    171 requests for maybe 40 distinct builds, so one release per minor is
    probed (playwright ships a minor about monthly, which is also roughly how
    often the pin moves) and duplicate revisions collapse.
    """
    meta = get_json(NPM_PLAYWRIGHT)
    times = meta["time"]
    stable = [v for v in meta["versions"] if "-" not in v and v in times]

    # Highest patch of each minor, which is the one that got fixes.
    newest_minor = {}
    for version in stable:
        parts = version.split(".")
        if len(parts) < 2:
            continue
        try:
            key = [int(part) for part in parts]
        except ValueError:
            continue
        minor = (parts[0], parts[1])
        if minor not in newest_minor or key > newest_minor[minor][0]:
            newest_minor[minor] = (key, version)
    probes = sorted((v for _, v in newest_minor.values()),
                    key=lambda v: times[v])

    def pin(version):
        try:
            data = get_json(UNPKG_BROWSERS % version, timeout=30)
        except (urllib.error.URLError, ValueError, OSError):
            return None
        for browser in data.get("browsers", []):
            if browser.get("name") == "webkit":
                return version, browser
        return None

    seen, releases = set(), []
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        for found in pool.map(pin, probes):
            if not found:
                continue
            version, browser = found
            revision = str(browser.get("revision"))
            if revision in seen:
                continue
            seen.add(revision)
            date = times[version][:10]
            releases.append({
                "year": int(date[:4]), "sort": date, "id": revision,
                # browserVersion only appears from playwright ~1.29 (2023) on.
                # Older builds get the revision, which is what identifies them
                # in the download URL anyway - honest, if less friendly.
                "label": browser.get("browserVersion") or ("r" + revision),
                "date": date, "via": "playwright " + version,
            })

    releases.sort(key=lambda r: r["sort"])
    floor = webkit_floor(releases)
    if floor:
        dropped = len(releases) - len(floor)
        if dropped:
            print("webkit: %d of %d builds are no longer published, dropped"
                  % (dropped, len(releases)), file=sys.stderr)
        return floor
    return releases


def webkit_floor(releases):
    """Drop the WebKit builds Playwright has deleted from its CDN.

    Playwright prunes old builds, so most of the history it names is no longer
    downloadable - measured, the shelf reaches back about two years, not to 2020.
    Listing a version that cannot be fetched is worse than not listing it: the
    matrix would offer cells that fail on click.

    Availability is monotonic - everything above the oldest surviving build
    survives too - so a binary search finds the floor in about six requests
    instead of one per release. That matters: probing all of them gets the CDN to
    start refusing connections, which reads as "nothing is available".
    """
    if not releases:
        return releases
    if not webkit_available(releases[-1]):
        return []                          # even the newest is gone; say nothing

    low, high = 0, len(releases) - 1       # low unknown, high known-good
    while low < high:
        middle = (low + high) // 2
        if webkit_available(releases[middle]):
            high = middle
        else:
            low = middle + 1
    return releases[low:]


def webkit_available(release):
    """Is this build still on the CDN?

    Pruning is per revision, not per platform: Playwright removes the whole
    directory, so one platform answering 200 proves the build is alive and there
    is no need to enumerate the rest. The mac archives are named after the macOS
    version they were built against and so change every year, but the Ubuntu ones
    have kept the same names throughout - which makes them the cheap probe.

    The names carry no arch suffix for x86_64: it is webkit-ubuntu-22.04.zip, not
    -x64. The obvious spelling answers 400 for every revision, which would have
    made every build look pruned.
    """
    for name in ("ubuntu-22.04", "ubuntu-20.04"):
        url = WEBKIT_CDN % (release["id"], name)
        request = urllib.request.Request(url, method="HEAD")
        try:
            with urllib.request.urlopen(request, timeout=25) as answer:
                if answer.status == 200:
                    return True
        except urllib.error.HTTPError:
            continue
        except (urllib.error.URLError, OSError):
            # A refused connection is not a missing file. Treating it as one
            # would quietly empty the shelf, which is the failure that looks
            # most like success.
            return True
    return False


DISCOVER = {
    "chromium": discover_chromium,
    "firefox": discover_firefox,
    "edge": discover_edge,
    "webkit": discover_webkit,
}


CATALOG = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                       "catalog.tsv")


def write_catalog(shelves, first_year, failed):
    """Replace the S rows in catalog.tsv, leaving every other row alone.

    The V and B rows are Chromium's, written by refresh-catalog.py and read by
    the launcher and the manager; nothing here may touch them. An engine that
    could not be reached keeps whatever rows it already had, because dropping a
    shelf on a failed request would look like the engine had stopped existing.
    """
    kept, replaced = [], set()
    reachable = {e for e in ENGINES if e not in {f.split(" ")[0] for f in failed}}
    if os.path.exists(CATALOG):
        with open(CATALOG) as handle:
            for line in handle:
                row = line.rstrip("\n")
                parts = row.split("\t")
                if parts[0] == "S" and len(parts) > 1 and parts[1] in reachable:
                    replaced.add(parts[1])
                    continue
                kept.append(row)
    while kept and not kept[-1].strip():
        kept.pop()

    rows = []
    for engine in ENGINES:
        if engine not in reachable:
            continue
        for release in sorted(shelves[engine], key=lambda r: r["sort"]):
            if release["year"] < first_year:
                continue
            rows.append("S\t%s\t%d\t%s\t%s\t%s"
                        % (engine, release["year"], release["id"],
                           release["label"], release["date"]))

    with open(CATALOG, "w") as handle:
        handle.write("\n".join(kept) + "\n")
        handle.write("# Shelf rows - generated by tools/discover.py, do not hand-edit.\n")
        handle.write("# S<TAB>engine<TAB>year<TAB>id<TAB>label<TAB>date\n")
        handle.write("\n".join(rows) + "\n")

    print("wrote %d shelf rows for %s" % (len(rows), ", ".join(sorted(reachable))))
    if failed:
        print("left alone (unreachable): %s" % ", ".join(failed), file=sys.stderr)
    return 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--from", dest="first_year", type=int, default=2017,
                        help="earliest year to show (default: 2017)")
    parser.add_argument("--tsv", action="store_true",
                        help="emit catalog rows instead of the matrix")
    parser.add_argument("--write", action="store_true",
                        help="merge the rows into catalog.tsv")
    args = parser.parse_args()

    # Chromium's release calendar dates two of the four shelves, so it is
    # fetched before the fan-out rather than inside it.
    try:
        schedule = chromium_schedule()
    except Exception as exc:
        print("chromiumdash không trả lời: %s" % exc, file=sys.stderr)
        return 1

    shelves, failed = {}, []
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        futures = {pool.submit(DISCOVER[e], schedule): e for e in ENGINES}
        for future in concurrent.futures.as_completed(futures):
            engine = futures[future]
            try:
                shelves[engine] = future.result()
            except Exception as exc:                  # one vendor, not the run
                shelves[engine] = {}
                failed.append("%s (%s)" % (engine, exc))

    grouped = {e: by_year(shelves[e]) for e in ENGINES}
    years = sorted({y for g in grouped.values() for y in g}, reverse=True)
    years = [y for y in years if y >= args.first_year]

    if args.write:
        return write_catalog(shelves, args.first_year, failed)

    if args.tsv:
        for engine in ENGINES:
            for release in sorted(shelves[engine], key=lambda r: r["sort"]):
                if release["year"] < args.first_year:
                    continue
                print("S\t%s\t%d\t%s\t%s\t%s"
                      % (engine, release["year"], release["id"],
                         release["label"], release["date"]))
        return 0 if len(failed) < len(ENGINES) else 1

    head = "%-6s" % "" + "".join("%-16s" % e.capitalize() for e in ENGINES)
    print(head)
    print("-" * len(head.rstrip()))
    for year in years:
        line = "%-6d" % year
        for engine in ENGINES:
            bucket = grouped[engine].get(year) or []
            if not bucket:
                cell = "\u00b7"
            else:
                cell = bucket[0]["label"]
                if bucket[0].get("esr"):
                    cell += " ESR"
                if len(bucket) > 1:
                    cell += "  +%d" % (len(bucket) - 1)
            line += "%-16s" % cell
        print(line)
    print()
    print("%d nam \u00b7 %s"
          % (len(years),
             " \u00b7 ".join("%s: %d ban"
                        % (e, len([r for r in shelves[e]
                                   if r["year"] >= args.first_year]))
                        for e in ENGINES)))
    print("(+N = so ban khac trong cung nam, mo bang cach bam vao o)")

    if failed:
        print("\nkhông lấy được: %s" % ", ".join(failed), file=sys.stderr)
    return 0 if len(failed) < len(ENGINES) else 1


if __name__ == "__main__":
    sys.exit(main())
