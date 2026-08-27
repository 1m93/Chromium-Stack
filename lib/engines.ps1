# Per-engine knowledge for the Windows launcher - the counterpart of
# lib/engines.sh, and it has to agree with it on the on-disk naming or the same
# directory means different things on different machines.
#
# What differs per engine, and who answers it:
#
#   Get-EngineDisplay      what to call it in output
#   Get-EnginePlatforms    which builds this host can run, best first
#   Get-EngineKey          the on-disk name for one installed build
#   Get-EngineBinary       the executable inside an extracted build
#   Get-EngineLaunchArgs   the flags that give it its own profile and no updater
#   Resolve-Engine         version name -> something downloadable
#
# Chromium's answers are the ones this tool already shipped, unchanged: its key
# is still the bare revision, so an existing home keeps working.
#
# Only one archive format matters here. Windows gets a plain zip from all three
# supported engines, which the launcher already knows how to unpack - the dmg,
# pkg, deb and tarball handling in lib/engines.sh has no Windows equivalent
# because no vendor ships those to Windows.

$EngineList = @('chromium', 'firefox', 'edge', 'webkit')

$MozReleases   = 'https://ftp.mozilla.org/pub/firefox/releases'
$MozCandidates = 'https://ftp.mozilla.org/pub/firefox/candidates'
$MozVersions   = 'https://product-details.mozilla.org/1.0/firefox_versions.json'
$WebKitCdn     = 'https://cdn.playwright.dev/dbazure/download/playwright/builds/webkit'

function Test-EngineKnown {
    param([string]$Engine)
    return ($EngineList -contains $Engine)
}

function Get-EngineDisplay {
    param([string]$Engine)
    switch ($Engine) {
        'chromium' { 'Chromium' }
        'firefox'  { 'Firefox' }
        'edge'     { 'Edge' }
        # Never "Safari". This is the engine Safari is built on, in a MiniBrowser
        # shell - no Safari interface, no tracking prevention, no media stack.
        'webkit'   { 'WebKit' }
        default    { $Engine }
    }
}

# Windows has one architecture worth publishing for, so unlike macOS there is
# nothing to choose between here - but the names still differ per vendor because
# they end up in URLs.
function Get-EnginePlatforms {
    param([string]$Engine)
    switch ($Engine) {
        'chromium' { @('Win_x64') }
        'firefox'  { @('win64') }
        'webkit'   { @('win64') }
        'edge'     { @() }
        default    { @() }
    }
}

# Chromium keeps the bare revision it has always used - renaming it would strand
# every build already on disk. Everything else is prefixed, because "115.0" alone
# would collide across engines the moment Edge reaches it.
function Get-EngineKey {
    param([string]$Engine, [string]$Id)
    if ($Engine -eq 'chromium') { return $Id }
    return "$Engine-$Id"
}

function Get-EngineOfBuildKey {
    param([string]$Key)
    foreach ($engine in $EngineList) {
        if ($engine -ne 'chromium' -and $Key.StartsWith("$engine-")) { return $engine }
    }
    return 'chromium'
}

# The executable inside an extracted build. Every path here was read out of the
# actual archive's index rather than assumed - the two that would have been wrong
# are noted where they are.
function Get-EngineBinary {
    param([string]$Engine, [string]$Dir, [string]$Root)
    switch ($Engine) {
        'chromium' { Join-Path $Dir "$Root\chrome.exe" }
        # The candidates zip unpacks into firefox\, not core\. core\ is the layout
        # inside the NSIS installer, which is a different download entirely.
        'firefox'  { Join-Path $Dir 'firefox\firefox.exe' }
        # The win64 archive has no pw_run script - it unpacks flat, with
        # Playwright.exe at the top, unlike the mac and Linux ones.
        'webkit'   { Join-Path $Dir 'Playwright.exe' }
        default    { $null }
    }
}

# Flags that give the build its own profile and stop it updating itself. Two
# families: Chromium's --long=value, and Firefox's -short value.
function Get-EngineLaunchArgs {
    param([string]$Engine, [string]$Profile)
    switch ($Engine) {
        'chromium' {
            @("--user-data-dir=$Profile", '--no-first-run', '--no-default-browser-check',
              '--disable-background-networking', '--disable-component-update',
              '--disable-features=TranslateUI')
        }
        'firefox' {
            # -no-remote and -new-instance together are what stop this launch
            # being handed to a Firefox the user already has open, which would
            # silently ignore the version they asked for.
            @('-profile', $Profile, '-no-remote', '-new-instance')
        }
        'webkit' {
            # The MiniBrowser shell takes no profile flag; its state lives beside
            # the bundle, which is per-build already.
            @()
        }
        default { @() }
    }
}

# Firefox trusts only the certificate authorities baked into the build it shipped
# with, so a 2019 build rejects most of today's web. Chromium asks the OS instead
# and never has this problem, which is why nothing like this existed before.
# Written into the profile because there is no flag for it.
function Set-EngineProfile {
    param([string]$Engine, [string]$Profile)
    if ($Engine -ne 'firefox') { return }
    $prefs = Join-Path $Profile 'user.js'
    if (Test-Path $prefs) { return }
    New-Item -ItemType Directory -Force -Path $Profile | Out-Null
    @'
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
'@ | Set-Content -Path $prefs -Encoding UTF8
}

# ---------- resolution ----------
# Turning "firefox:115" into something downloadable. Sets the same fields the
# Chromium resolver in the launcher sets, plus Url and Format.

function Test-UrlExists {
    param([string]$Url)
    try {
        $null = Invoke-WebRequest -Uri $Url -Method Head -TimeoutSec 25 -UseBasicParsing
        return $true
    } catch { return $false }
}

function Resolve-Engine {
    param([string]$Engine, [string]$Token)
    switch ($Engine) {
        'firefox' { return Resolve-EngineFirefox $Token }
        'webkit'  { return Resolve-EngineWebKit $Token }
        'edge'    { return Resolve-EngineEdge $Token }
        default   { Die "No resolver for $Engine." }
    }
}

# Every release Mozilla has ever shipped is still on ftp.mozilla.org. Windows is
# the awkward one: releases/ carries only an installer, and the plain zip lives
# in the candidates tree under whichever build number shipped.
function Resolve-EngineFirefox {
    param([string]$Token)
    $version = $Token
    if ($Token -match '^(?<major>\d*)[eE][sS][rR]$') {
        # Which version is the current ESR changes, so it is fetched, never
        # assumed. ESR is what real fleets sit on for years.
        $version = Resolve-FirefoxEsr $Matches['major']
        if (-not $version) { Die "Could not find the ESR release for $Token." }
    } elseif ($Token -match '^\d+$') {
        $version = "$Token.0"          # a bare major: 115 -> 115.0
    }

    # Candidate builds are numbered from 1 and the last one is what shipped. The
    # directory index names them all, so one request settles it - probing build9
    # downwards cost eight round trips to find that 115.0 shipped as build2.
    $url = $null
    $builds = @()
    try {
        $index = Invoke-WebRequest -Uri "$MozCandidates/$version-candidates/" `
                     -TimeoutSec 30 -UseBasicParsing
        $builds = @([regex]::Matches([string]$index.Content, 'build(\d+)') |
                    ForEach-Object { [int]$_.Groups[1].Value } | Sort-Object -Unique -Descending)
    } catch { }
    foreach ($build in $builds) {
        $candidate = "$MozCandidates/$version-candidates/build$build/win64/en-US/firefox-$version.zip"
        if (Test-UrlExists $candidate) { $url = $candidate; break }
    }
    if (-not $url) {
        Die @"
No Windows zip found for Firefox $version.
   Mozilla publishes it under candidates/, and only for the build that shipped.
   Check the version exists: $MozReleases/
"@
    }
    return @{ Engine = 'firefox'; Id = $version; Version = $version
              Platform = 'win64'; Url = $url; Format = 'zip'; Root = '' }
}

function Resolve-FirefoxEsr {
    param([string]$Major)
    try {
        $data = Invoke-RestMethod -Uri $MozVersions -TimeoutSec 30
    } catch { return $null }
    if (-not $Major) { return [string]$data.FIREFOX_ESR }
    # Every value is checked against the major asked for, because which key holds
    # which line moves as new ESRs ship.
    foreach ($key in @("FIREFOX_ESR$Major", 'FIREFOX_ESR', 'FIREFOX_ESR_NEXT')) {
        $value = [string]$data.$key
        if ($value -and $value.StartsWith("$Major.")) { return $value }
    }
    return $null
}

# Nothing publishes "which webkit builds exist"; the only index is each
# Playwright release naming the revision it pins, which is why that map lives in
# the catalog. A revision given directly needs no map.
function Resolve-EngineWebKit {
    param([string]$Token)
    $revision = $null
    if ($Token -match '^\d+$' -and [int64]$Token -ge 1000) {
        $revision = $Token
    } else {
        $revision = Get-ShelfIdForLabel 'webkit' $Token
    }
    if (-not $revision) {
        Die @"
No WebKit build known as $Token.
   WebKit versions come from the shelf, which tools/discover.py builds from the
   Playwright releases that pin each build. Refresh it with:
       python3 tools/discover.py --write
"@
    }
    $url = "$WebKitCdn/$revision/webkit-win64.zip"
    if (-not (Test-UrlExists $url)) {
        Die @"
No WebKit r$revision build for Windows.
   Playwright deletes old builds from its CDN and it is the only source, so a
   version that has been pruned cannot be recovered.
"@
    }
    $label = Get-ShelfLabelForId 'webkit' $revision
    if (-not $label) { $label = "r$revision" }
    return @{ Engine = 'webkit'; Id = $revision; Version = $label
              Platform = 'win64'; Url = $url; Format = 'zip'; Root = '' }
}

# Measured, not assumed: for Windows, Microsoft publishes only an MSI, and that
# MSI carries its payload as an embedded binary stream driven by a custom action -
# there is no CAB and no 7z inside it to unpack. So there is nothing that can be
# turned into a portable directory the way the macOS pkg and the Linux deb can.
#
# Which matters less here than it looks, because Edge is already installed on
# every Windows machine, and Edge is Chromium underneath.
function Resolve-EngineEdge {
    param([string]$Token)
    Die @"
Edge cannot be shelved on Windows.
   Microsoft ships only an MSI here, and its payload is an embedded stream an
   installer unpacks - not an archive, so there is nothing to extract into a
   pinned, disposable directory. The macOS and Linux downloads are archives and
   do work.
   For engine testing, chromium:$Token is the same Blink build. For Edge's own
   behaviour - Tracking Prevention, WebView2 parity - use the Edge already
   installed on this machine.
"@
}
