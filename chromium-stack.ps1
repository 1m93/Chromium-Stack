#
# ChromiumStack - run an old Chromium engine on a modern machine (Windows)
#
# PowerShell 5.1+, which ships with Windows 10/11. Downloads a pinned Chromium
# build once, then launches it as an ordinary desktop browser with its own
# profile. Any milestone in catalog.tsv works, as does any raw revision from the
# Chromium snapshot archive.
#
#   .\chromium-stack.ps1 catalog                    # versions available here
#   .\chromium-stack.ps1 run 74                     # install if needed, launch
#   .\chromium-stack.ps1 run 120 localhost:4173     # launch 120 on a URL
#   .\chromium-stack.ps1 list                       # what is installed, how big
#   .\chromium-stack.ps1 remove 74                  # free the disk space
#
# The GUI (.\gui.ps1) drives this same script, so both agree by construction.
#
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Command = '',
    [Parameter(Position = 1)][string]$Selector = '',
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest = @()
)

$ErrorActionPreference = 'Stop'
# Invoke-WebRequest is ~20x slower with the progress bar on large downloads.
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Catalog   = Join-Path $ScriptDir 'catalog.tsv'
. (Join-Path $ScriptDir 'lib\preflight.ps1')
$BaseUrl   = 'https://commondatastorage.googleapis.com/chromium-browser-snapshots'
$ListApi   = 'https://www.googleapis.com/storage/v1/b/chromium-browser-snapshots/o'

# BROWSERS_EMU_HOME is what this tool was called before; still honoured so an
# existing setup does not break on a rename.
$RootIsDefault = $false
if ($env:CHROMIUM_STACK_HOME) {
    $Root = $env:CHROMIUM_STACK_HOME
} elseif ($env:BROWSERS_EMU_HOME) {
    $Root = $env:BROWSERS_EMU_HOME
} else {
    $Root = Join-Path $env:USERPROFILE '.chromium-stack'
    $RootIsDefault = $true
}
$BuildsDir   = Join-Path $Root 'builds'
$ProfilesDir = Join-Path $Root 'profiles'
$LogsDir     = Join-Path $Root 'logs'

function Write-Info { param($m) Write-Host $m }
function Write-Warn { param($m) Write-Host "!  $m" -ForegroundColor Yellow }
function Write-Ok   { param($m) Write-Host "OK $m" -ForegroundColor Green }
function Die        { param($m) Write-Host "X  $m" -ForegroundColor Red; exit 1 }

# This tool used to be called browsers-emu and kept the same layout under
# .browsers-emu. Nothing inside changed, so moving the directory across is the
# whole migration - and it has to happen before the new root is created empty.
$previousRoot = Join-Path $env:USERPROFILE '.browsers-emu'
if ($RootIsDefault -and (Test-Path $previousRoot) -and -not (Test-Path $Root)) {
    try {
        Move-Item -Path $previousRoot -Destination $Root
        Write-Host "Moved your existing browsers into $Root (renamed from browsers-emu)."
    } catch { }
}

foreach ($dir in @($Root, $BuildsDir, $ProfilesDir, $LogsDir)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
}

# ---------- catalog ----------
# catalog.tsv is two record types:
#   V <milestone> <version> <note>
#   B <milestone> <platform> <revision> <archive> <root>
if (-not (Test-Path $Catalog)) { Die "Missing catalog: $Catalog" }

$CatalogVersions = @{}
$CatalogBuilds   = @{}
$CatalogOrder    = New-Object System.Collections.ArrayList
foreach ($line in Get-Content $Catalog) {
    if ($line -match '^\s*#' -or $line.Trim() -eq '') { continue }
    $f = $line -split "`t"
    if ($f[0] -eq 'V') {
        $m = [int]$f[1]
        $note = ''
        if ($f.Count -gt 3) { $note = $f[3] }
        $CatalogVersions[$m] = @{ Version = $f[2]; Note = $note }
        [void]$CatalogOrder.Add($m)
    } elseif ($f[0] -eq 'B') {
        $m = [int]$f[1]
        if (-not $CatalogBuilds.ContainsKey($m)) { $CatalogBuilds[$m] = @{} }
        $CatalogBuilds[$m][$f[2]] = @{ Revision = $f[3]; Archive = $f[4]; Root = $f[5] }
    }
}

# Windows-on-ARM runs the x64 build through the OS emulation layer, so there is
# only ever one platform to choose here.
$HostPlatform = 'Win_x64'

function Get-BuildDir   { param($rev) Join-Path $BuildsDir $rev }
function Get-ProfileDir { param($rev) Join-Path $ProfilesDir $rev }
function Get-LogFile    { param($rev) Join-Path $LogsDir "$rev.log" }
function Test-Installed { param($rev) Test-Path (Join-Path (Get-BuildDir $rev) '.complete') }

function Get-Meta {
    param($rev)
    $path = Join-Path (Get-BuildDir $rev) '.meta'
    $meta = @{}
    if (Test-Path $path) {
        foreach ($line in Get-Content $path) {
            if ($line -match "^([A-Z_]+)='(.*)'$") { $meta[$Matches[1]] = $Matches[2] }
        }
    }
    return $meta
}

function Write-Meta {
    param($rev, $milestone, $version, $platform, $archive, $root)
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $body = @(
        "META_MILESTONE='$milestone'",
        "META_VERSION='$version'",
        "META_PLATFORM='$platform'",
        "META_ARCHIVE='$archive'",
        "META_ROOT='$root'",
        "META_INSTALLED='$stamp'"
    ) -join "`n"
    # The Python backend parses this file too, so keep it LF and quoted.
    [IO.File]::WriteAllText((Join-Path (Get-BuildDir $rev) '.meta'), $body + "`n")
}

# ---------- selector resolution ----------
# A selector is a milestone (74, M74) or a raw archive revision (638880).
# Milestones are small and revisions are six digits or more, so the split needs
# no extra syntax from the user.
function Resolve-Selector {
    param([string]$Raw)
    if (-not $Raw) { Die "Which version? e.g. 74, or a revision like 638880. Try: .\chromium-stack.ps1 catalog" }
    $token = $Raw -replace '^[MmRr]', ''
    if ($token -notmatch '^\d+$') { Die "Not a version or revision: $Raw" }

    if ([int64]$token -lt 1000) {
        $m = [int]$token
        if (-not $CatalogVersions.ContainsKey($m)) { Die "Chromium $m is not in the catalog. Try: .\chromium-stack.ps1 catalog" }
        if (-not ($CatalogBuilds.ContainsKey($m) -and $CatalogBuilds[$m].ContainsKey($HostPlatform))) {
            Die "No $HostPlatform build of Chromium $m in the catalog."
        }
        $b = $CatalogBuilds[$m][$HostPlatform]
        return @{ Milestone = "$m"; Version = $CatalogVersions[$m].Version; Platform = $HostPlatform
                  Revision = $b.Revision; Archive = $b.Archive; Root = $b.Root }
    }

    # Already installed: the recorded metadata answers without a network call.
    $meta = Get-Meta $token
    if ($meta.Count -gt 0) {
        return @{ Milestone = $meta['META_MILESTONE']; Version = $meta['META_VERSION']
                  Platform = $meta['META_PLATFORM']; Revision = $token
                  Archive = $meta['META_ARCHIVE']; Root = $meta['META_ROOT'] }
    }

    # A catalogued revision for this platform.
    foreach ($m in $CatalogOrder) {
        if ($CatalogBuilds.ContainsKey($m) -and $CatalogBuilds[$m].ContainsKey($HostPlatform)) {
            $b = $CatalogBuilds[$m][$HostPlatform]
            if ($b.Revision -eq $token) {
                return @{ Milestone = "$m"; Version = $CatalogVersions[$m].Version; Platform = $HostPlatform
                          Revision = $token; Archive = $b.Archive; Root = $b.Root }
            }
        }
    }

    # Unknown revision: believe the archive rather than guessing a filename.
    try {
        $listing = Invoke-RestMethod -Uri "${ListApi}?delimiter=/&prefix=${HostPlatform}/${token}/" -TimeoutSec 30
        $names = @()
        if ($listing.items) { $names = $listing.items | ForEach-Object { ($_.name -split '/')[-1] } }
    } catch {
        Die "Could not reach the Chromium snapshot archive to check revision $token."
    }
    foreach ($candidate in @('chrome-win.zip', 'chrome-win32.zip')) {
        if ($names -contains $candidate) {
            return @{ Milestone = '?'; Version = "r$token"; Platform = $HostPlatform
                      Revision = $token; Archive = $candidate; Root = ($candidate -replace '\.zip$', '') }
        }
    }
    Die "Revision $token is not archived for $HostPlatform. Pick a nearby position, or a catalogued version: .\chromium-stack.ps1 catalog"
}

function Get-BinaryPath {
    param($rev, $root)
    Join-Path (Get-BuildDir $rev) "$root\chrome.exe"
}

# ---------- migration ----------
# The single-version layout was .chrome74\<revision>\ plus one shared profile.
# Adopt it once so an existing install is not re-downloaded. Only ever runs
# against the default root: an overridden home belongs to a different setup.
function Invoke-Migration {
    if (-not $RootIsDefault) { return }
    $legacy = Join-Path $env:USERPROFILE '.chrome74'
    if (-not (Test-Path $legacy)) { return }
    if (Test-Path (Join-Path $Root '.migrated')) { return }

    foreach ($dir in Get-ChildItem -Path $legacy -Directory -ErrorAction SilentlyContinue) {
        if ($dir.Name -notmatch '^\d+$') { continue }
        if (-not (Test-Path (Join-Path $dir.FullName '.complete'))) { continue }
        $target = Join-Path $BuildsDir $dir.Name
        if (Test-Path $target) { continue }
        try { Move-Item -Path $dir.FullName -Destination $target } catch { continue }

        $m = '?'; $version = "r$($dir.Name)"
        foreach ($ms in $CatalogOrder) {
            if ($CatalogBuilds.ContainsKey($ms) -and $CatalogBuilds[$ms].ContainsKey($HostPlatform) `
                -and $CatalogBuilds[$ms][$HostPlatform].Revision -eq $dir.Name) {
                $m = "$ms"; $version = $CatalogVersions[$ms].Version; break
            }
        }
        $root = 'chrome-win'
        if (-not (Test-Path (Join-Path $target 'chrome-win'))) { $root = 'chrome-win32' }
        Write-Meta $dir.Name $m $version $HostPlatform "$root.zip" $root
        Write-Info "Adopted the existing Chromium install (r$($dir.Name)) - not re-downloading."

        $legacyProfile = Join-Path $legacy 'profile'
        $targetProfile = Join-Path $ProfilesDir $dir.Name
        if ((Test-Path $legacyProfile) -and -not (Test-Path $targetProfile)) {
            try { Move-Item -Path $legacyProfile -Destination $targetProfile } catch { }
        }
    }
    New-Item -ItemType File -Force -Path (Join-Path $Root '.migrated') | Out-Null
}

# ---------- install ----------
function Install-Build {
    param($sel)
    $rev = $sel.Revision
    if (Test-Installed $rev) { return }

    $dir = Get-BuildDir $rev
    Write-Info ""
    Write-Info "Downloading Chromium $($sel.Version) ($($sel.Platform) r$rev, one time only)"
    Write-Info "-> $dir"
    Write-Info "   ~150-300 MB, this can take a few minutes..."
    Write-Info ""

    if (Test-Path $dir) { Remove-Item -Recurse -Force $dir }
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $zip = Join-Path $Root ".download-$rev.zip"

    try {
        Invoke-WebRequest -Uri "$BaseUrl/$($sel.Platform)/$rev/$($sel.Archive)" -OutFile $zip
    } catch {
        Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue
        Remove-Item -Force $zip -ErrorAction SilentlyContinue
        Die "Download failed: $($_.Exception.Message)"
    }

    Write-Info "Extracting..."
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $dir)
    } catch {
        Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue
        Remove-Item -Force $zip -ErrorAction SilentlyContinue
        Die "Extraction failed: $($_.Exception.Message)"
    }
    Remove-Item -Force $zip

    $binary = Get-BinaryPath $rev $sel.Root
    if (-not (Test-Path $binary)) {
        Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue
        Die "Expected browser binary missing: $binary"
    }

    Write-Meta $rev $sel.Milestone $sel.Version $sel.Platform $sel.Archive $sel.Root
    New-Item -ItemType File -Force -Path (Join-Path $dir '.complete') | Out-Null
    Write-Ok "Chromium $($sel.Version) ready."
}

function Get-DirSize {
    param($path)
    if (-not (Test-Path $path)) { return 0 }
    $sum = (Get-ChildItem -Path $path -Recurse -File -Force -ErrorAction SilentlyContinue |
            Measure-Object -Property Length -Sum).Sum
    if ($null -eq $sum) { return 0 }
    return [int64]$sum
}

# ---------- commands ----------
function Invoke-Catalog {
    Write-Host ""
    Write-Host "Available Chromium versions (host: $HostPlatform)" -ForegroundColor White
    Write-Host ""
    foreach ($m in $CatalogOrder) {
        $version = $CatalogVersions[$m].Version
        if (-not ($CatalogBuilds.ContainsKey($m) -and $CatalogBuilds[$m].ContainsKey($HostPlatform))) {
            Write-Host ("  {0,-6} {1,-16} no build for this host" -f $m, $version) -ForegroundColor DarkGray
            continue
        }
        $rev = $CatalogBuilds[$m][$HostPlatform].Revision
        if (Test-Installed $rev) { $state = 'installed'; $colour = 'Green' }
        else { $state = 'not installed'; $colour = 'DarkGray' }
        Write-Host ("  {0,-6} {1,-16} r{2,-9} " -f $m, $version, $rev) -NoNewline
        Write-Host $state -ForegroundColor $colour
    }
    Write-Host ""
    Write-Host "Install and run:  .\chromium-stack.ps1 run <version>" -ForegroundColor DarkGray
}

function Invoke-List {
    Write-Host ""
    Write-Host "Installed browsers ($Root)" -ForegroundColor White
    Write-Host ""
    $total = 0
    $any = $false
    foreach ($dir in Get-ChildItem -Path $BuildsDir -Directory -ErrorAction SilentlyContinue) {
        if ($dir.Name -notmatch '^\d+$') { continue }
        if (-not (Test-Installed $dir.Name)) { continue }
        $any = $true
        $meta = Get-Meta $dir.Name
        $size = Get-DirSize $dir.FullName
        $prof = Get-DirSize (Get-ProfileDir $dir.Name)
        $total += $size + $prof
        $version = $meta['META_VERSION']; if (-not $version) { $version = "r$($dir.Name)" }
        Write-Host ("  {0,-16} r{1,-9} {2,7:N0} MB browser {3,7:N0} MB profile" -f `
            $version, $dir.Name, ($size / 1MB), ($prof / 1MB))
    }
    if (-not $any) {
        Write-Host "  Nothing installed yet. See: .\chromium-stack.ps1 catalog" -ForegroundColor DarkGray
        Write-Host ""
        return
    }
    Write-Host ""
    Write-Host ("  Total: {0:N0} MB" -f ($total / 1MB)) -ForegroundColor DarkGray
    Write-Host "  Remove one with: .\chromium-stack.ps1 remove <version|revision>" -ForegroundColor DarkGray
}

function Invoke-Run {
    param($sel, $rest)

    $url = ''; $windowSize = ''; $useGpu = $null; $autoRestart = $true; $extra = @()
    $i = 0
    while ($i -lt $rest.Count) {
        $a = [string]$rest[$i]
        switch -Regex ($a) {
            '^-{1,2}gpu$'        { $useGpu = $true;  $i++; break }
            '^-{1,2}no-gpu$'     { $useGpu = $false; $i++; break }
            '^-{1,2}no-restart$' { $autoRestart = $false; $i++; break }
            '^-{1,2}size$'       { $windowSize = [string]$rest[$i + 1]; $i += 2; break }
            '^--$'               { if ($i + 1 -lt $rest.Count) { $extra += $rest[($i + 1)..($rest.Count - 1)] }
                                   $i = $rest.Count; break }
            '^-'                 { Die "Unknown option: $a" }
            default              { $url = $a; $i++ }
        }
    }

    Install-Build $sel

    $binary     = Get-BinaryPath $sel.Revision $sel.Root
    $profileDir = Get-ProfileDir $sel.Revision
    $log        = Get-LogFile $sel.Revision
    New-Item -ItemType Directory -Force -Path $profileDir | Out-Null

    # Bare host:port typed by hand - be forgiving.
    if ($url -ne '' -and $url -notmatch '^(https?|file|data)://' -and $url -notmatch '^about:') {
        $url = "http://$url"
    }

    $chromeArgs = @(
        "--user-data-dir=$profileDir",
        '--no-first-run',
        '--no-default-browser-check',
        '--disable-background-networking',   # the 2019 update pinger is long dead
        '--disable-component-update',
        '--disable-features=TranslateUI'
    )
    # Old GPU drivers are a common crash source when a years-old browser meets a
    # current driver. Software rendering costs a little speed and removes it.
    if ($useGpu -ne $true) { $chromeArgs += '--disable-gpu' }
    if ($windowSize -ne '') { $chromeArgs += "--window-size=$($windowSize -replace 'x', ',')" }
    $chromeArgs += $extra

    Write-Host ""
    Write-Host "  > Chromium $($sel.Version) (r$($sel.Revision), $($sel.Platform))" -ForegroundColor Green
    if ($url -ne '') { Write-Host "  > $url" }
    Write-Host "  Profile: $profileDir" -ForegroundColor DarkGray
    Write-Host "  Log: $log" -ForegroundColor DarkGray
    Write-Host ""

    # Start-Process joins -ArgumentList with plain spaces and does not quote, so
    # any argument containing a space (a profile path under "C:\Users\Some Name")
    # would arrive at Chromium split into pieces.
    function Quote-Args { param($items) $items | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } } }

    $attempt = 0; $fastCrashes = 0
    $launchArgs = $chromeArgs
    if ($url -ne '') { $launchArgs = $chromeArgs + $url }

    while ($true) {
        $started = Get-Date
        $proc = Start-Process -FilePath $binary -ArgumentList (Quote-Args $launchArgs) -Wait -PassThru
        $status = $proc.ExitCode
        if ($status -eq 0) { break }   # user closed the window

        $ran = [int]((Get-Date) - $started).TotalSeconds
        if (-not $autoRestart) { Write-Warn "Chromium exited with status $status after ${ran}s."; exit $status }

        $attempt++
        # A fast crash still deserves a retry, but three in a row means the setup
        # itself is broken and looping would only spin.
        if ($ran -lt 5) { $fastCrashes++ } else { $fastCrashes = 0 }
        if ($fastCrashes -ge 3 -or $attempt -gt 5) {
            Write-Warn "Chromium crashed after ${ran}s (status $status), giving up after $attempt attempt(s)."
            exit $status
        }
        Write-Warn "Chromium crashed after ${ran}s - restarting and restoring your tabs ($attempt/5)."
        $launchArgs = $chromeArgs + '--restore-last-session'
    }
}

function Invoke-Doctor {
    param([string[]]$Options)

    if ($Options -contains '--json') {
        Get-PfReport | ConvertTo-Json -Depth 6 -Compress
        return
    }

    if ($Options -contains '--install') {
        $index = [array]::IndexOf($Options, '--install')
        $component = $Options[$index + 1]
        if (-not $component) { Die "Which component? e.g. --install docker" }
        if ($PfComponents -notcontains $component) {
            Die "Unknown component: $component (one of: $($PfComponents -join ', '))"
        }
        $null = Invoke-PfFix $component -AssumeYes:($Options -contains '--yes' -or $Options -contains '-y')
        return
    }

    $problems = Show-PfReport
    if (-not $problems) { return }

    foreach ($c in $problems) {
        Write-Host "  $($c.label) - $($c.why)" -ForegroundColor DarkGray
    }
    Write-Host ""

    if ($Options -notcontains '--fix') {
        Write-Host "  Offer to install the missing pieces:  .\chromium-stack.ps1 doctor --fix" -ForegroundColor DarkGray
        Write-Host ""
        return
    }
    foreach ($c in $problems) {
        $null = Invoke-PfFix $c.id -AssumeYes:($Options -contains '--yes' -or $Options -contains '-y')
    }
}

function Show-Usage {
    Write-Host ""
    Write-Host "ChromiumStack - run an old Chromium engine on a modern machine" -ForegroundColor White
    Write-Host ""
    Write-Host "  .\chromium-stack.ps1 <command> [args]"
    Write-Host ""
    Write-Host "  catalog                 List the Chromium versions available for this host"
    Write-Host "  list                    List what is installed, with disk usage"
    Write-Host "  run <version> [url]     Install if needed, then launch"
    Write-Host "  install <version>       Download without launching"
    Write-Host "  remove <version>        Delete a downloaded browser"
    Write-Host "        --with-profile    ...and its profile"
    Write-Host "  clean <version>         Reset a version's profile (cookies, logins)"
    Write-Host "  doctor                  Check that everything this needs is installed"
    Write-Host "        --fix             ...and offer to install what is missing"
    Write-Host "  gui                     Open the graphical manager"
    Write-Host ""
    Write-Host "  <version> is a milestone (74) or a snapshot revision (638880)."
    Write-Host ""
    Write-Host "  Options for run:  --size WxH   --gpu / --no-gpu   --no-restart"
    Write-Host ""
    Write-Host "  Each version keeps its own profile, so a newer build never upgrades a"
    Write-Host "  profile out from under an older one."
    Write-Host ""
    Write-Host "  Files live in $Root (override with CHROMIUM_STACK_HOME)."
    Write-Host ""
}

Invoke-Migration

switch -Regex ($Command) {
    '^(catalog|versions)$' { Invoke-Catalog; break }
    '^(list|ls)$'          { Invoke-List; break }
    '^(run|launch)$'       { Invoke-Run (Resolve-Selector $Selector) $Rest; break }
    '^install$'            { Install-Build (Resolve-Selector $Selector); break }
    '^(remove|rm|uninstall)$' {
        $sel = Resolve-Selector $Selector
        $dir = Get-BuildDir $sel.Revision
        if (Test-Path $dir) {
            Remove-Item -Recurse -Force $dir
            Write-Ok "Removed Chromium $($sel.Version) (r$($sel.Revision))."
        } else {
            Write-Warn "Chromium $($sel.Version) (r$($sel.Revision)) was not installed."
        }
        if ($Rest -contains '--with-profile') {
            $p = Get-ProfileDir $sel.Revision
            if (Test-Path $p) { Remove-Item -Recurse -Force $p }
        }
        Remove-Item -Force (Get-LogFile $sel.Revision) -ErrorAction SilentlyContinue
        break
    }
    '^clean$' {
        $sel = Resolve-Selector $Selector
        $p = Get-ProfileDir $sel.Revision
        if (Test-Path $p) { Remove-Item -Recurse -Force $p }
        Write-Ok "Profile reset for Chromium $($sel.Version) (r$($sel.Revision))."
        break
    }
    '^(doctor|check)$'     { Invoke-Doctor (@($Selector) + $Rest | Where-Object { $_ }); break }
    '^gui$'                { & (Join-Path $ScriptDir 'gui.ps1') @Rest; break }
    '^(|-h|--help|help)$'  { Show-Usage; break }
    default                { Die "Unknown command: $Command (try --help)" }
}
