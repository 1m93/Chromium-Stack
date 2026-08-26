# Building releases

`tools/release.sh` turns the repo into clean, self-contained, obfuscated
downloads under `dist/` — one artifact per OS plus a checksum file.

```bash
tools/release.sh                 # build everything this machine can
tools/release.sh --version 2.1   # stamp a version into the file names
tools/release.sh --no-obfuscate  # readable source, for debugging a build
tools/release.sh --ps-heavy      # heavy-obfuscate PowerShell too (see below)
```

## What it produces

| File | What it is | How the user opens it |
|---|---|---|
| `ChromiumStack-<ver>-macOS.zip` | A single self-contained `ChromiumStack.app`, everything sealed inside it | Unzip, double-click (optionally drag to **Applications**) |
| `ChromiumStack-<ver>-Windows.zip` | `ChromiumStack.bat` + `Create-Shortcut.ps1` + `icon.ico`, with the real scripts tucked into `app\` | Unzip, double-click `ChromiumStack.bat` |
| `ChromiumStack-<ver>-Linux.tar.gz` | A `chromium-stack/` folder with a `./ChromiumStack` launcher | Extract, run `./ChromiumStack` |
| `SHA256SUMS.txt` | Checksums for every file above | `shasum -c SHA256SUMS.txt` |

Each artifact also carries a short **`HOW TO OPEN.txt`** with the open steps for
that OS and how to get past the first-run security prompt (Gatekeeper on macOS,
SmartScreen/Unblock on Windows).

Each artifact stands alone — the launcher finds the scripts *inside* the
package, so there is no loose folder of files to keep together. The repo layout
still works too (double-click `ChromiumStack.app` in the checkout); the macOS
launcher tries its own `Contents/Resources` first and the sibling folder second.

## Obfuscation — what it does and does not do

These are interpreted scripts, so the interpreter always needs the source.
Encoding it stops casual reading and makes the shipped file unpleasant to pick
apart, but a determined reader can always decode it. **This is deterrence, not
protection.** See the header of `tools/obfuscate.sh` for the details.

- **bash** (`*.sh`) — body gzip+base64'd behind `eval`; the comment header is
  kept so self-locating and the docker help text still work. *Tested.*
- **Python** (`server.py`) — body zlib+base64'd behind `exec`, version
  independent (a `.pyc` would break across Python versions). *Tested.*
- **web** (`*.js/*.css/*.html`) — comments and indentation stripped, newlines
  kept so JavaScript stays valid. *Tested (bracket-balance checked).*
- **PowerShell** (`*.ps1`) — **light by default**: comments and blank lines
  stripped, every statement intact. `--ps-heavy` switches to an encoded
  scriptblock wrapper. The heavy path is written but **untested** on the build
  machine (no PowerShell there); verify it on Windows before shipping.

## Windows SmartScreen — why the release no longer ships an `.exe`

The Windows package used to lead with `ChromiumStack.exe`, a tiny compiled
launcher that only carried the icon and then ran `powershell -ExecutionPolicy
Bypass -File gui.ps1`. That is precisely the shape SmartScreen and Defender
distrust: an **unsigned** binary (no paid Authenticode certificate) with no
download reputation, whose one job is to spawn PowerShell — a generic loader
pattern. On a fresh machine it produced *“Windows protected your PC.”*

So the release now ships **`ChromiumStack.bat`** as the entry point and no `.exe`
at all. A `.bat` is a short, readable script rather than a PE binary, so it never
triggers the unsigned-executable reputation check. It keeps the release honest
too — there is nothing compiled to trust. What we do to keep the remaining noise
down, all free:

- **No icon on the `.bat` itself** — a batch file cannot carry one. The package
  includes `icon.ico` and **`Create-Shortcut.ps1`**, which the user runs once to
  drop an icon'd shortcut on the Desktop and Start Menu. That shortcut is created
  locally, so it never carries a Mark-of-the-Web and never trips SmartScreen.
- **Never ship `--ps-heavy`.** base64-encoded PowerShell is the strongest
  antivirus trigger there is; the light default ships readable, unflagged
  scripts. `release.sh` prints a warning if you pass `--ps-heavy`.
- **Publish `SHA256SUMS.txt`** so anyone (including a false-positive reviewer)
  can verify the exact bytes.
- Tell users, in the README, to **Unblock** the extracted folder
  (`Get-ChildItem -Recurse | Unblock-File`) if a downloaded file feels stuck.

If you ever want a signed, icon-bearing `.exe` back, you would reintroduce a
small Windows launcher (the old one lived in `tools/launcher/`, cross-compiled
with mingw-w64), sign it with `signtool sign /fd sha256 /tr <timestamp-url> /td
sha256 ...` — an **EV** certificate earns SmartScreen trust immediately, an
**OV** one clears Defender heuristics but still needs download reputation to
accrue — and add a copy step back into `build_windows` in `release.sh`. Genuine
false positives can be reported to Microsoft at
<https://www.microsoft.com/wdsi/filesubmission>.

## Publishing for easy download

Upload the whole `dist/` folder to a GitHub Release so people get one link:

```bash
gh release create v2.0 dist/ChromiumStack-* dist/SHA256SUMS.txt \
  --title "ChromiumStack 2.0" \
  --notes "macOS (.zip), Windows (.zip), Linux (.tar.gz). Verify with SHA256SUMS.txt."
```

## Rebuilding the launchers

The release reuses the committed launcher binaries. Rebuild them only after
editing their C sources:

```bash
tools/build-app.sh    # macOS  (needs Xcode command line tools)
tools/make-icons.sh   # icons, after changing the SVGs
```

The Windows package no longer ships a compiled launcher — it uses
`ChromiumStack.bat` (see the SmartScreen note above), so there is nothing to
rebuild there.
