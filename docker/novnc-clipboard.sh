#!/bin/sh
# Wire clipboard.js into the noVNC page, at image build time.
#
# noVNC ships a clipboard side panel and nothing else: the host's Cmd-V or
# Ctrl-V is swallowed by the canvas, so text copied outside the tab could only
# get in by being pasted into that panel by hand. clipboard.js wires the two
# clipboards together; it needs the page's RFB object, which ui.js keeps inside
# an ES module, hence the one-line export onto window.
#
# One copy, four images. It was four copies of the same two sed lines, which is
# three chances for one of them to keep working while the others quietly stop
# patching anything - and a clipboard that does not work is not loud.
#
# Deliberately fails the build if noVNC's layout has moved: a silent no-op here
# ships an image whose paste does nothing, and nobody finds out until they try.
set -e

ui=/usr/share/novnc/app/ui.js
page=/usr/share/novnc/vnc.html

grep -q '^export default UI;' "$ui" || {
  echo "noVNC layout changed: no export in ui.js" >&2
  exit 1
}
grep -q 'src="app/ui.js"' "$page" || {
  echo "noVNC layout changed: no ui.js tag in vnc.html" >&2
  exit 1
}

sed -i 's|^export default UI;|window.UI = UI;   /* EngineShelf: app/clipboard.js needs the live RFB object */\nexport default UI;|' "$ui"
sed -i 's|<script type="module" crossorigin="anonymous" src="app/ui.js"></script>|&\n    <script src="app/clipboard.js" defer></script>|' "$page"

grep -q 'app/clipboard.js' "$page"
