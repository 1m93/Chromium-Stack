#!/usr/bin/env python3
"""Regenerate catalog.tsv from the Chromium snapshot archive.

For each milestone it asks chromiumdash for the branch base position, then finds
the first revision at or after that position which is actually archived for each
platform — not every position is built, and the gap is sometimes tens of commits.
The archive listing is authoritative, so a revision written here is one that has
been confirmed to exist.

    python3 tools/refresh-catalog.py            # rewrite catalog.tsv
    python3 tools/refresh-catalog.py --check    # verify without writing

Notes are editorial and live in NOTES below; add a milestone to MILESTONES and
rerun to extend the catalog.
"""
import argparse
import json
import os
import sys
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor

LIST_API = "https://www.googleapis.com/storage/v1/b/chromium-browser-snapshots/o"
CATALOG = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "catalog.tsv")

# Hand-picked history: each of these was chosen because something interesting
# lands there, and the note below says what. Past the end of the list the catalog
# extends itself on the same five-milestone spacing up to whatever is stable now,
# so a new Chrome release does not need this file edited.
#
# 60 is the floor for three independent reasons: Mac builds below it are 32-bit
# i386 and cannot start on any macOS since Catalina, the Win_x64 bucket has
# nothing before ~r389148, and chromiumdash has no branch position below 59. That
# floor is quoted in the README and in the landing page copy - move it here and
# those want updating too.
ANCHORS = [60, 65, 70, 74, 76, 80, 85, 90, 95, 100, 105, 110, 115, 120, 125, 130]
STEP = 5
CFT_STABLE = "https://googlechromelabs.github.io/chrome-for-testing/last-known-good-versions.json"

# Snapshot platform directory -> archives to accept, best first. Windows switched
# from chrome-win32.zip to chrome-win.zip partway through the range.
PLATFORMS = {
    "Mac":       ["chrome-mac.zip"],
    "Mac_Arm":   ["chrome-mac.zip"],
    "Linux_x64": ["chrome-linux.zip"],
    "Win_x64":   ["chrome-win.zip", "chrome-win32.zip"],
}

NOTES = {
    60:  "2017. Pre-Grid-everywhere era; a hard floor for very old WebViews.",
    65:  "2018. Before flexbox `gap`, before optional chaining.",
    70:  "2018. Common floor for Android 9-era System WebView.",
    74:  "2019. No flexbox `gap` (84), `aspect-ratio`/`:is()` (88), optional chaining (80).",
    76:  "2019. Adds prefers-color-scheme; still no flexbox `gap`.",
    80:  "2020. Optional chaining and nullish coalescing land here.",
    85:  "2020. First catalogued build with flexbox `gap` (landed in 84).",
    90:  "2021. `aspect-ratio` and `:is()` (88) available.",
    95:  "2021. First catalogued milestone with native Apple Silicon builds.",
    100: "2022. Three-digit UA string - useful for UA-parsing regressions.",
    105: "2022. Container queries and `:has()` land here.",
    110: "2023. `dvh`/`svh` viewport units (108) available.",
    115: "2023. CSS nesting (112) and view transitions (111) available.",
    120: "2023. `subgrid` (117) and `text-wrap: balance` (114) available.",
    125: "2024. Recent baseline for comparison against the old builds.",
    130: "2024. Near-current engine - use it as the control when bisecting a bug.",
}

# A milestone whose nearest archived build is further away than this is treated as
# unavailable rather than silently pinning something from a different milestone.
MAX_DRIFT = 3000


def generated_note(year):
    """Note for a milestone added after the hand-written ones ran out.

    Deliberately plain: an editorial note is a claim about what changed in the
    engine, and inventing one automatically would be inventing the claim too.
    """
    return f"{year}. Added automatically as Chrome released it.".lstrip(". ")


def fetch_json(url, attempts=4):
    """GET and decode, retrying transient failures.

    Sixteen workers open sixteen TLS connections at once and Google occasionally
    drops one mid-handshake. Unattended, that would fail a whole run over a fault
    that clears on the next try.
    """
    for attempt in range(attempts):
        try:
            with urllib.request.urlopen(url, timeout=30) as response:
                return json.load(response)
        except Exception:
            if attempt == attempts - 1:
                raise
            time.sleep(1.5 * (attempt + 1))


def milestone_info(milestone):
    data = fetch_json(f"https://chromiumdash.appspot.com/fetch_milestones?mstone={milestone}")[0]
    return data["chromium_main_branch_position"], data["chromium_branch"]


def branch_year(milestone):
    """Calendar year the milestone branched, for the generated note."""
    try:
        schedule = fetch_json(
            f"https://chromiumdash.appspot.com/fetch_milestone_schedule?mstone={milestone}"
        )["mstones"][0]
        return str(schedule["branch_point"])[:4]
    except (OSError, KeyError, IndexError, ValueError):
        return ""


def milestones():
    """The anchors, then every STEP-th milestone up to the current stable.

    Falls back to the anchors alone when the stable channel cannot be reached, so
    an offline run still rewrites a valid catalog rather than truncating one.
    """
    try:
        stable = int(fetch_json(CFT_STABLE)["channels"]["Stable"]["version"].split(".")[0])
    except (OSError, KeyError, ValueError):
        print("could not reach the stable channel; using the anchors alone", file=sys.stderr)
        return list(ANCHORS)
    extended = list(ANCHORS)
    for milestone in range(ANCHORS[-1] // STEP * STEP + STEP, stable + 1, STEP):
        extended.append(milestone)
    if stable not in extended:
        extended.append(stable)
    return sorted(set(extended))


def nearest_revision(platform, target):
    """First archived revision >= target for this platform, or None.

    The bucket also holds ancient short revision folders (Linux_x64/97277), and
    GCS lists lexicographically, so "97277" sorts after "972766". Restricting to
    the target's digit count keeps the comparison numeric.
    """
    width = len(str(target))
    low, high = f"{platform}/{target}", f"{platform}/{'9' * width}"
    for _ in range(6):
        data = fetch_json(
            f"{LIST_API}?delimiter=/&prefix={platform}/"
            f"&startOffset={low}&endOffset={high}&maxResults=200"
        )
        prefixes = data.get("prefixes") or []
        if not prefixes:
            return None
        found = [
            int(token)
            for token in (p.rstrip("/").rsplit("/", 1)[-1] for p in prefixes)
            if token.isdigit() and len(token) == width and int(token) >= target
        ]
        if found:
            revision = min(found)
            return revision if revision - target < MAX_DRIFT else None
        low = prefixes[-1].rstrip("/")
    return None


def archive_at(platform, revision):
    data = fetch_json(f"{LIST_API}?delimiter=/&prefix={platform}/{revision}/")
    names = {item["name"].rsplit("/", 1)[-1] for item in data.get("items", [])}
    for candidate in PLATFORMS[platform]:
        if candidate in names:
            return candidate
    return None


def resolve(job):
    milestone, platform, position = job
    revision = nearest_revision(platform, position)
    if revision is None:
        return milestone, platform, None
    archive = archive_at(platform, revision)
    if archive is None:
        return milestone, platform, None
    return milestone, platform, (revision, archive)


def build_rows():
    selected = milestones()
    generated = [m for m in selected if m not in NOTES]

    with ThreadPoolExecutor(max_workers=8) as pool:
        info = dict(zip(selected, pool.map(milestone_info, selected)))
        years = dict(zip(generated, pool.map(branch_year, generated)))

    jobs = [(m, p, info[m][0]) for m in selected for p in PLATFORMS]
    builds = {m: {} for m in selected}
    with ThreadPoolExecutor(max_workers=16) as pool:
        for milestone, platform, result in pool.map(resolve, jobs):
            builds[milestone][platform] = result

    lines = [
        "# EngineShelf catalog - generated by tools/refresh-catalog.py, do not hand-edit.",
        "# V<TAB>milestone<TAB>version<TAB>note",
        "# B<TAB>milestone<TAB>platform<TAB>revision<TAB>archive<TAB>root",
    ]
    for milestone in selected:
        position, branch = info[milestone]
        version = f"{milestone}.0.{branch}.0"
        note = NOTES.get(milestone) or generated_note(years.get(milestone, ""))
        lines.append(f"V\t{milestone}\t{version}\t{note}")
        for platform in PLATFORMS:
            result = builds[milestone].get(platform)
            if not result:
                continue
            revision, archive = result
            root = archive[:-4]          # chrome-win.zip -> chrome-win, the zip's only top folder
            lines.append(f"B\t{milestone}\t{platform}\t{revision}\t{archive}\t{root}")
    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true", help="compare against catalog.tsv, do not write")
    args = parser.parse_args()

    text = build_rows()
    if args.check:
        current = open(CATALOG).read() if os.path.exists(CATALOG) else ""
        if current == text:
            print("catalog.tsv is up to date")
            return 0
        print("catalog.tsv differs from the archive", file=sys.stderr)
        return 1
    with open(CATALOG, "w") as handle:
        handle.write(text)
    builds = sum(1 for line in text.splitlines() if line.startswith("B\t"))
    versions = sum(1 for line in text.splitlines() if line.startswith("V\t"))
    print(f"wrote {CATALOG}: {versions} milestones, {builds} builds")
    return 0


if __name__ == "__main__":
    sys.exit(main())
