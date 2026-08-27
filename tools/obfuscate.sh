#!/usr/bin/env bash
#
# EngineShelf code-obfuscation helpers.
#
# Sourced by tools/release.sh. Every function rewrites a *staged copy* of a file
# in place - never a source file in the repo.
#
# What "obfuscate" can and cannot mean here: these are interpreted scripts, so
# the interpreter always needs the source. Encoding it stops casual reading and
# makes the shipped file unpleasant to pick apart, but a determined reader can
# always decode it. This is deterrence, not protection.
#
# Techniques by language:
#   bash        gzip+base64 the body, run it through `eval`. The leading comment
#               header is kept verbatim, because engineshelf-docker.sh prints
#               its own header as help, and because ${BASH_SOURCE[0]} still
#               resolves to the wrapper under eval, so SCRIPT_DIR keeps working.
#   python      zlib+base64 the body, run it through exec() with __file__ set, so
#               modules that locate siblings via __file__ keep working. Version
#               independent, unlike a .pyc.
#   powershell  light by default (strip comments + blanks); --ps-heavy switches
#               to a gzip+base64 scriptblock wrapper. The heavy path is written
#               but UNTESTED on a machine without PowerShell.
#   web         html/css/js get comments and indentation stripped. Newlines are
#               kept so JavaScript automatic-semicolon-insertion cannot break.
#
set -euo pipefail

# ---- helpers -------------------------------------------------------------- #

# Line number of the first line that is not blank and not a comment. Used to
# split a shebang+header block off from the executable body. Prints the body
# start line (1-based); prints 1 if the file opens with code.
_body_start() {
  awk '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    { print NR; exit }
  ' "$1"
}

# ---- bash ----------------------------------------------------------------- #

obf_bash() {
  local file="$1" start payload header body
  start="$(_body_start "$file")"
  [ -n "$start" ] || start=1
  header="$(sed -n "1,$((start - 1))p" "$file")"
  body="$(sed -n "${start},\$p" "$file")"
  payload="$(printf '%s\n' "$body" | gzip -9 -c | base64 | tr -d '\n')"

  {
    if [ "$start" -gt 1 ]; then printf '%s\n' "$header"; else echo '#!/usr/bin/env bash'; fi
    printf '%s\n' 'eval "$(printf %s '"'"''"$payload"''"'"' | base64 -d | gzip -d)"'
  } > "$file"
}

# ---- python --------------------------------------------------------------- #

obf_py() {
  local file="$1" start header
  start="$(_body_start "$file")"
  [ -n "$start" ] || start=1
  # Keep the shebang line only; a module docstring is part of the body so it is
  # encoded away with everything else.
  header="$(sed -n '1p' "$file" | grep -E '^#!' || true)"

  ROOT_PY_START="$start" python3 - "$file" <<'PY'
import base64, os, sys, zlib
path = sys.argv[1]
start = int(os.environ["ROOT_PY_START"])
with open(path) as fh:
    lines = fh.readlines()
shebang = lines[0] if lines and lines[0].startswith("#!") else "#!/usr/bin/env python3\n"
body = "".join(lines[start - 1:])
blob = base64.b64encode(zlib.compress(body.encode(), 9)).decode()
wrapper = (
    shebang
    + "import base64,zlib\n"
    + "exec(compile(zlib.decompress(base64.b64decode(\n"
    + f"    '{blob}'\n"
    + ")).decode(),__file__,'exec'),{'__name__':'__main__','__file__':__file__})\n"
)
with open(path, "w") as fh:
    fh.write(wrapper)
PY
}

# ---- powershell (light) --------------------------------------------------- #

obf_ps1_light() {
  local file="$1"
  # Drop full-line comments and blank lines, and trim leading indentation.
  # Conservative: leaves param()/CmdletBinding and every statement intact.
  # Block comments <# ... #> are dropped whole - removing only the '#'-leading
  # lines inside them would strip the closing '#>' and orphan the opener.
  awk '
    { line = $0 }
    { sub(/^[[:space:]]+/, "", line) }
    inblock {
      if (line ~ /#>/) { inblock = 0 }
      next
    }
    line ~ /^<#/ {
      if (line !~ /#>/) { inblock = 1 }
      next
    }
    line ~ /^#/ { next }
    line == ""  { next }
    { print line }
  ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
}

# ---- powershell (heavy, UNTESTED here) ------------------------------------ #
#
# Keeps the entry param()/CmdletBinding block as real code so command-line
# argument binding still works, then runs the rest as a scriptblock that
# receives the same bound parameters. $MyInvocation.MyCommand.Path is rewritten
# to a global the wrapper fills in, so Split-Path self-location keeps working.
#
obf_ps1_heavy() {
  local file="$1" payload param_end header body
  # Find the end of a leading param(...) block, if any, by paren-balancing from
  # the first line that contains 'param('. Everything up to and including that
  # line's matching ')' stays in the wrapper.
  param_end="$(
    awk '
      BEGIN { depth = 0; inparam = 0 }
      {
        line = $0
        if (!inparam && tolower(line) ~ /param[[:space:]]*\(/) { inparam = 1 }
        if (inparam) {
          n = gsub(/\(/, "(", line); m = gsub(/\)/, ")", line)
          depth += n - m
          if (depth <= 0) { print NR; exit }
        }
      }
    ' "$file"
  )"
  header="$(sed -n '1,'"${param_end:-0}"'p' "$file")"
  if [ -n "$param_end" ]; then
    body="$(sed -n "$((param_end + 1)),\$p" "$file")"
  else
    body="$(cat "$file")"
    header=""
  fi
  # Self-location: make the body read a global the wrapper sets.
  body="$(printf '%s\n' "$body" | sed 's/\$MyInvocation\.MyCommand\.Path/\$Global:__CS_SELF/g')"
  payload="$(printf '%s\n' "$body" | gzip -9 -c | base64 | tr -d '\n')"

  {
    [ -n "$header" ] && printf '%s\n' "$header"
    cat <<'PSW'
$Global:__CS_SELF = $PSCommandPath
$__cs_bytes = [System.Convert]::FromBase64String(@'
PSW
    printf '%s\n' "$payload"
    cat <<'PSW'
'@)
$__cs_in  = New-Object System.IO.MemoryStream(,$__cs_bytes)
$__cs_gz  = New-Object System.IO.Compression.GzipStream($__cs_in, [System.IO.Compression.CompressionMode]::Decompress)
$__cs_out = New-Object System.IO.StreamReader($__cs_gz)
$__cs_code = $__cs_out.ReadToEnd()
$__cs_sb = [ScriptBlock]::Create($__cs_code)
& $__cs_sb @PSBoundParameters @args
PSW
  } > "$file"
}

# ---- web assets ----------------------------------------------------------- #

min_web() {
  local file="$1"
  case "$file" in
    *.css|*.html)
      # Strip /* */ comments; drop blank lines and indentation. Newlines kept.
      perl -0pe 's{/\*.*?\*/}{}gs' "$file" \
        | sed 's/^[[:space:]]*//; /^$/d' > "$file.tmp" && mv "$file.tmp" "$file"
      ;;
    *.js)
      # Strip /* */ block comments and whole-line // comments; keep newlines so
      # automatic-semicolon-insertion cannot merge statements. URL-ish // inside
      # strings is left alone by only removing lines whose first token is //.
      perl -0pe 's{/\*.*?\*/}{}gs' "$file" \
        | sed 's/^[[:space:]]*//; /^\/\//d; /^$/d' > "$file.tmp" && mv "$file.tmp" "$file"
      ;;
  esac
}
