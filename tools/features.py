#!/usr/bin/env python3
"""What each version on the shelf brought, from MDN's browser-compat-data.

The shelf's notes used to be twenty-odd hand-written lines on curated Chromium
milestones - "aspect-ratio and :is() (88) available" - and nothing at all for the
other 270 rows. Which is fair: nobody was going to hand-write 290 changelogs, and
no vendor publishes one this tool can read. Chrome has a milestone API, Mozilla
and Apple publish HTML pages, Playwright publishes nothing.

browser-compat-data is the one source that answers for all four engines at once.
It records, per web feature, the first version of each browser that supported it -
so inverting it by version gives exactly the question a person browsing this shelf
is asking: what can I test in this one that I could not test in the one before.

    python3 tools/features.py                    # print what would be written
    python3 tools/features.py --write            # write features.tsv
    python3 tools/features.py --bcd path.json    # use a copy already downloaded
    python3 tools/features.py --names 12         # cap the names per version

Run after tools/discover.py, because it only emits rows for versions the shelf
actually has. The output ships with the release: 20 MB of compat data resolved
once here, so no machine ever fetches it and the shelf works offline.
"""
import argparse
import json
import os
import re
import sys
import urllib.request
from collections import defaultdict

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CATALOG = os.path.join(ROOT, "catalog.tsv")
FEATURES = os.path.join(ROOT, "features.tsv")
BCD_URL = "https://unpkg.com/@mdn/browser-compat-data/data.json"

# Which BCD browser answers for which engine on this shelf. WebKit's rows are
# labelled by the Safari version they shipped in, which is the key BCD uses.
BROWSER = {"chromium": "chrome", "firefox": "firefox",
           "edge": "edge", "webkit": "safari"}

# The surfaces someone picks a browser version to test, best first. The order is
# what decides which features get named when there are more than fit: a CSS
# property lands in the note ahead of the fourteenth method on an obscure API.
ROOTS = ("css", "html", "javascript", "svg", "mathml", "webassembly",
         "api", "http")


def walk(node, path):
    """Every (path, __compat) pair under a BCD subtree."""
    if not isinstance(node, dict):
        return
    if "__compat" in node:
        yield path, node["__compat"]
    for key, value in node.items():
        if key in ("__compat", "__meta"):
            continue
        yield from walk(value, path + [key])


def spell(name):
    """BCD names sub-features in snake_case - spread_in_object_literals - which is
    a source identifier rather than something to read in a sentence."""
    return name.replace("_", " ") if "_" in name and name.islower() else name


def identity(path):
    """(rank, name) - the thing a person would call this, and how notable it is.

    One name per feature rather than one per value: css.properties.clip-path.path
    is still clip-path, and without this a note about Chromium 88 would read
    "auto, none, manual" - the values of three properties - instead of naming the
    properties.
    """
    if path[:2] == ["css", "properties"] and len(path) > 2:
        return 0, path[2]
    if path[:2] == ["css", "selectors"] and len(path) > 2:
        return 0, ":" + path[2]
    if path[:2] == ["css", "at-rules"] and len(path) > 2:
        return 0, "@" + path[2]
    if path[:2] == ["css", "types"] and len(path) > 2:
        return 1, path[2] + "()"
    if path[:2] == ["html", "elements"] and len(path) > 2:
        return 0, "<%s>" % path[2]
    if path[:2] == ["html", "global_attributes"] and len(path) > 2:
        return 1, "%s attribute" % path[2]
    if path[:2] == ["javascript", "builtins"] and len(path) > 2:
        return 0, ".".join(path[2:4]) if len(path) > 3 else path[2]
    if path[0] == "javascript" and len(path) > 2:
        return 1, spell(path[-1])
    # The interface, never the member. api.DOMMatrix has a compat entry per
    # property, and naming members put "DOMMatrix.a, DOMMatrix.b, DOMMatrix.c,
    # DOMMatrix.d" in a note with room for fourteen things.
    if path[0] == "api" and len(path) > 1:
        return 2, path[1]
    return 3, spell(path[-1])


def load_bcd(where):
    if where:
        with open(where) as handle:
            return json.load(handle)
    with urllib.request.urlopen(BCD_URL, timeout=180) as response:
        return json.loads(response.read().decode())


def invert(data):
    """browser -> version string -> {name: rank}."""
    per = defaultdict(lambda: defaultdict(dict))
    wanted = set(BROWSER.values())
    for root in ROOTS:
        for path, compat in walk(data.get(root, {}), [root]):
            support = compat.get("support") or {}
            for browser in wanted:
                entry = support.get(browser)
                if isinstance(entry, list):
                    entry = entry[0] if entry else None
                if not isinstance(entry, dict):
                    continue
                added = entry.get("version_added")
                # True means "supported, nobody recorded since when", and a
                # preview version is not a release. Both are useless here.
                if not isinstance(added, str) or not re.match(r"^\d", added):
                    continue
                rank, name = identity(path)
                slot = per[browser][added]
                if name not in slot or rank < slot[name]:
                    slot[name] = rank
    return per


def shelf_rows():
    """(engine, id, label) for every row on the shelf."""
    out = []
    with open(CATALOG) as handle:
        for line in handle:
            parts = line.rstrip("\n").split("\t")
            if len(parts) >= 6 and parts[0] == "S":
                out.append((parts[1], parts[3], parts[4]))
    return out


def bcd_key(engine, ident, label):
    """The BCD version string for a shelf row, or None.

    Four engines number four ways and only one of them matches BCD as it stands:
    Chromium's milestone is the Chrome version, Firefox's id carries a .0 BCD does
    not use, Edge's id is a full four-part build, and WebKit's id is a Playwright
    revision whose label is the Safari version BCD keys on.
    """
    if engine == "chromium":
        return ident if ident.isdigit() else None
    if engine == "firefox":
        head = ident.split(".")[0]
        return head if head.isdigit() else None
    if engine == "edge":
        head = ident.split(".")[0]
        return head if head.isdigit() else None
    if engine == "webkit":
        return label if re.match(r"^\d", label or "") else None
    return None


def build(per, names_wanted):
    rows, missing = [], []
    for engine, ident, label in shelf_rows():
        key = bcd_key(engine, ident, label)
        slot = per.get(BROWSER[engine], {}).get(key or "")
        if not slot:
            missing.append("%s %s" % (engine, label or ident))
            continue
        ordered = sorted(slot, key=lambda name: (slot[name], name.lower()))
        rows.append((engine, ident, len(slot),
                     ordered[:names_wanted] if names_wanted else ordered))
    return rows, missing


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bcd", help="a data.json already downloaded")
    # Every name, by default. Capping was tried at fourteen and the file came out
    # at 56 KB against 146 KB for all of it - which bought nothing and cost the
    # search box the other two thirds of what it could have matched.
    parser.add_argument("--names", type=int, default=0,
                        help="cap the names per version; 0 for all of them")
    parser.add_argument("--write", action="store_true")
    args = parser.parse_args()

    per = invert(load_bcd(args.bcd))
    rows, missing = build(per, args.names)

    lines = ["# EngineShelf - what each shelf version brought, from MDN "
             "browser-compat-data.",
             "# Written by tools/features.py. F <engine> <id> <count> "
             "<name>|<name>|...",
             "# Ordered by how notable each one is, so a row that has room for "
             "six names shows the",
             "# six worth showing. The count is there for the rows a cap has "
             "trimmed."]
    for engine, ident, count, names in rows:
        lines.append("F\t%s\t%s\t%d\t%s" % (engine, ident, count, "|".join(names)))
    body = "\n".join(lines) + "\n"

    if args.write:
        with open(FEATURES, "w") as handle:
            handle.write(body)
        print("wrote %s: %d versions, %d bytes" % (FEATURES, len(rows), len(body)))
    else:
        print(body[:1200])
        print("... %d versions, %d bytes" % (len(rows), len(body)))
    if missing:
        print("no compat data for %d shelf rows: %s"
              % (len(missing), ", ".join(missing[:8])), file=sys.stderr)


if __name__ == "__main__":
    main()
