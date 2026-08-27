#!/usr/bin/env python3
"""websockify, with the noVNC files it serves marked uncacheable.

Every container serves its own copy of noVNC from the same origin: the desktop is
http://localhost:6080 whichever version, and whichever engine, is running behind
it. websockify sends no cache headers at all - what it does send is each file's
own mtime, and almost all of noVNC's files carry the date the Debian package was
built, 2021. With no Cache-Control to go on a browser falls back to a heuristic,
roughly a tenth of the file's age, so a 2021 file is fresh for years.

app/ui.js is the one exception, because novnc-clipboard.sh rewrites it at build
time and it comes out carrying today's date - fresh for minutes, then revalidated.
That asymmetry is the bug. Rebuild an image and the browser picks up the new
ui.js against a core/ pinned to whatever was cached the very first time any
container was opened, and noVNC dies on

    SyntaxError: The requested module '../core/util/browser.js'
                 does not provide an export named 'dragThreshold'

naming an export that is sitting right there in the file on disk. Two images with
different noVNC versions, or one image rebuilt across an upgrade, is all it takes.

no-store on every response settles it. The desktop is served off a loopback port
to one tab on the same machine, so there was never anything to be gained by
caching it.
"""

import sys

from websockify import websockifyserver
from websockify.websocketproxy import websockify_init

# Fail loudly at import rather than serve a cacheable desktop: if websockify's
# handler moves, the container stops instead of quietly going back to the bug.
_end_headers = websockifyserver.WebSockifyRequestHandler.end_headers


def end_headers(self):
    # Before the blank line that ends the block, which is what end_headers writes.
    self.send_header("Cache-Control", "no-store")
    _end_headers(self)


websockifyserver.WebSockifyRequestHandler.end_headers = end_headers

if __name__ == "__main__":
    sys.exit(websockify_init())
