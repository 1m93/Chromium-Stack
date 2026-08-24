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
| `ChromiumStack-<ver>-macOS.dmg` | A single `ChromiumStack.app`, everything sealed inside it | Open the DMG, drag the app to **Applications**, double-click |
| `ChromiumStack-<ver>-macOS.zip` | The same `.app`, zipped | Unzip, double-click |
| `ChromiumStack-<ver>-Windows.zip` | `ChromiumStack.exe` + a readable `.bat`, with the real scripts tucked into `app\` | Unzip, double-click the `.exe` |
| `ChromiumStack-<ver>-Linux.tar.gz` | A `chromium-stack/` folder with a `./ChromiumStack` launcher | Extract, run `./ChromiumStack` |
| `SHA256SUMS.txt` | Checksums for every file above | `shasum -c SHA256SUMS.txt` |

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

## Publishing for easy download

Upload the whole `dist/` folder to a GitHub Release so people get one link:

```bash
gh release create v2.0 dist/ChromiumStack-* dist/SHA256SUMS.txt \
  --title "ChromiumStack 2.0" \
  --notes "macOS (.dmg/.zip), Windows (.zip), Linux (.tar.gz). Verify with SHA256SUMS.txt."
```

## Rebuilding the launchers

The release reuses the committed launcher binaries. Rebuild them only after
editing their C sources:

```bash
tools/build-app.sh    # macOS  (needs Xcode command line tools)
tools/build-exe.sh    # Windows (needs mingw-w64: brew install mingw-w64)
tools/make-icons.sh   # icons, after changing the SVGs
```
