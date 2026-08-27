#
# EngineShelf GUI backend (Windows).
#
# Serves the static page in this directory and the same small JSON API as
# gui/server.py. All real work - install, launch, remove, reset - is delegated to
# engineshelf.ps1, so the GUI and the command line cannot drift apart.
#
# This speaks HTTP over a raw TcpListener rather than System.Net.HttpListener on
# purpose: HttpListener needs a netsh URL ACL reservation or an elevated prompt,
# and this tool is not worth either. A TcpListener on a loopback high port needs
# no privileges at all.
#
# Bound to 127.0.0.1 and gated on a per-run token, so a web page you happen to
# have open cannot drive your browser installs.
#
# The manager is its own window, not a page that outlives you: closing it stops
# this server, the browsers it launched and the containers it brought up. See
# "lifetime" below for how the window and the server keep track of each other.
#
[CmdletBinding()]
param(
    [int]$Port = 7411,
    [switch]$NoOpen,       # start the server without opening anything
    [switch]$Tab,          # a tab in the default browser instead of a window
    [switch]$KeepAlive,    # keep serving after the window closes
    [switch]$New           # start another manager even if one is running
)

$ErrorActionPreference = 'Stop'

$Here    = Split-Path -Parent $MyInvocation.MyCommand.Path
$Project = Split-Path -Parent $Here
$Catalog = Join-Path $Project 'catalog.tsv'
$Cli       = Join-Path $Project 'engineshelf.ps1'
$DockerCli = Join-Path $Project 'engineshelf-docker.ps1'

if (-not (Test-Path $Cli)) { throw "Missing $Cli" }

$Token = [Convert]::ToBase64String([Guid]::NewGuid().ToByteArray()) -replace '[^A-Za-z0-9]', ''

if ($env:ENGINESHELF_HOME)   { $Root = $env:ENGINESHELF_HOME }
elseif ($env:BROWSERS_EMU_HOME) { $Root = $env:BROWSERS_EMU_HOME }
else                          { $Root = Join-Path $env:USERPROFILE '.engineshelf' }
$StateFile   = Join-Path $Root 'manager.json'
$CacheFile   = Join-Path $Root 'catalog.cache.tsv'
$BuildsDir   = Join-Path $Root 'builds'
$ProfilesDir = Join-Path $Root 'profiles'
$JobsDir     = Join-Path $Root 'jobs'
New-Item -ItemType Directory -Force -Path $JobsDir | Out-Null

. (Join-Path $Project 'lib\preflight.ps1')

$HostPlatform = 'Win_x64'

# ---------- catalog ----------
# Same precedence the CLI uses: the shipped catalog, then the runtime cache over
# the top of it. catalog.tsv freezes at the release; the cache holds whatever has
# been resolved against the live archive since.
function Read-Catalog {
    $versions = @{}
    $builds = @{}
    # $script: on purpose. Variable names here are case-insensitive, so a caller
    # holding a local $catalog - the parsed catalog, not the path - shadowed this
    # for the whole call chain. Read-Shelf below then handed Test-Path a
    # hashtable, silently parsed nothing, and the shelf came up empty on
    # Windows. Naming the scope is what makes that impossible rather than
    # something to remember.
    foreach ($path in @($script:Catalog, $script:CacheFile)) {
        if (-not (Test-Path $path)) { continue }
        foreach ($line in Get-Content $path) {
            if ($line -match '^\s*#' -or $line.Trim() -eq '') { continue }
            $f = $line -split "`t"
            if ($f[0] -eq 'V') {
                $note = ''
                if ($f.Count -gt 3) { $note = $f[3] }
                $versions[[int]$f[1]] = @{ milestone = [int]$f[1]; version = $f[2]; note = $note }
            } elseif ($f[0] -eq 'B') {
                $m = [int]$f[1]
                if (-not $builds.ContainsKey($m)) { $builds[$m] = @{} }
                $builds[$m][$f[2]] = @{ revision = [int]$f[3]; archive = $f[4]; root = $f[5] }
            }
        }
    }
    $ordered = New-Object System.Collections.ArrayList
    foreach ($m in ($versions.Keys | Sort-Object)) { [void]$ordered.Add($versions[$m]) }
    return @{ versions = $ordered; builds = $builds }
}

# Let the CLI discover and cache milestones released since this build. Delegated
# rather than reimplemented: `catalog` is the command that knows how to walk the
# archive. Failure is silent - the shipped catalog is still a complete answer.
function Update-CatalogCache {
    try {
        Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden `
            -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:Cli, 'catalog') | Out-Null
    } catch { }
}

function Get-DirSize {
    param($path)
    if (-not (Test-Path $path)) { return 0 }
    $sum = (Get-ChildItem -Path $path -Recurse -File -Force -ErrorAction SilentlyContinue |
            Measure-Object -Property Length -Sum).Sum
    if ($null -eq $sum) { return 0 }
    return [int64]$sum
}

# The names engineshelf-docker.ps1 gives the things it creates. The manager
# reads them back, which is the only way a version living in a container can look
# like one living on disk; renaming any of them means changing both files.
$ContainerPrefix = 'engineshelf-'
$ImageRepo       = 'engineshelf'
$VolumePrefix    = 'engineshelf-profile-'

# Probing Docker costs about a second and the page asks every four; the answer
# does not change that fast. Volume sizes cost a second on their own, so they
# get a longer window - a profile grows by megabytes over a session.
$script:DockerCache = @{ At = [datetime]::MinValue; Value = $null }
$script:VolumeCache = @{ At = [datetime]::MinValue; Value = $null }

function Convert-HumanBytes {
    # "10.13MB" -> bytes. Docker's own read-outs use decimal units.
    param([string]$Text)
    if ($Text -notmatch '^\s*([\d.]+)\s*([KMGT]?B)\s*$') { return 0 }
    $scale = @{ 'B' = 1; 'KB' = 1e3; 'MB' = 1e6; 'GB' = 1e9; 'TB' = 1e12 }[$Matches[2].ToUpper()]
    return [int64]([double]$Matches[1] * $scale)
}

function Get-PublishedPort {
    # "127.0.0.1:6081->6080/tcp" -> 6081. The launcher takes whichever port it
    # can get, so asking what a container published is the only way to know.
    param([string]$Mapping)
    foreach ($part in ($Mapping -split ',')) {
        if ($part -match ':(\d+)->6080/') { return [int]$Matches[1] }
    }
    return $null
}

function Get-DockerVolumeSizes {
    if ($script:VolumeCache.Value -and
        ((Get-Date) - $script:VolumeCache.At).TotalSeconds -lt 60) {
        return $script:VolumeCache.Value
    }
    $sizes = @{}
    try {
        $raw = docker system df -v --format '{{json .Volumes}}' 2>$null
        if ($LASTEXITCODE -eq 0 -and $raw) {
            foreach ($volume in (@($raw) -join '' | ConvertFrom-Json)) {
                if ($volume.Name -like "$VolumePrefix*") {
                    $sizes[$volume.Name.Substring($VolumePrefix.Length)] = Convert-HumanBytes $volume.Size
                }
            }
        }
    } catch { }
    $script:VolumeCache = @{ At = (Get-Date); Value = $sizes }
    return $sizes
}

function Get-DockerStatus {
    <#
      What Docker is holding for EngineShelf: images, their size, containers.

      Without this the shelf could say nothing true about a version that runs in
      a container - no size for an image costing a gigabyte, and no sign it was
      running at all, because the job that starts a container exits as soon as
      the desktop answers.
    #>
    if ($script:DockerCache.Value -and
        ((Get-Date) - $script:DockerCache.At).TotalSeconds -lt 10) {
        return $script:DockerCache.Value
    }

    $hasCli = $null -ne (Get-Command docker -ErrorAction SilentlyContinue)
    $running = $false
    $containers = @()
    $byRevision = @{}
    if ($hasCli) {
        docker info 2>&1 | Out-Null
        $running = ($LASTEXITCODE -eq 0)
    }

    function Get-Slot {
        param($Table, [string]$Revision)
        if (-not $Table.ContainsKey($Revision)) {
            $Table[$Revision] = @{ imageBytes = [int64]0; profileBytes = [int64]0
                                   state = $null; status = ''; port = $null }
        }
        return $Table[$Revision]
    }

    if ($running) {
        # One image per version, tagged with the revision it was built from.
        #
        # The size comes from `docker images`, rounded, and not from `image
        # inspect --format {{.Size}}`, which is exact and measures the wrong
        # thing. Against the containerd image store that field is the compressed
        # content size: two images inspected as 371 MB and 507 MB while `docker
        # images` and `docker system df` both said 1.49 GB and 1.96 GB. A gauge
        # that exists to show what is filling the disk cannot be off by four
        # times, so a rounded true number beats an exact wrong one.
        $rows = @(docker images $ImageRepo --format '{{.Tag}}|{{.Size}}' 2>$null)
        foreach ($row in $rows) {
            $parts = $row -split '\|'
            if ($parts.Count -lt 2 -or -not $parts[0] -or $parts[0] -eq '<none>') { continue }
            $slot = Get-Slot $byRevision $parts[0]
            $slot.imageBytes = Convert-HumanBytes $parts[1]
        }

        # One container per version, named engineshelf-<revision>. Stopped
        # ones are listed too: a container that exits the moment it starts is a
        # fault worth showing, not a row that quietly does nothing.
        $listing = @(docker ps -a --filter "name=$ContainerPrefix" `
                     --format '{{.Names}}|{{.State}}|{{.Status}}|{{.Ports}}' 2>$null)
        foreach ($line in $listing) {
            $parts = $line -split '\|'
            if ($parts.Count -lt 4 -or $parts[0] -notlike "$ContainerPrefix*") { continue }
            $revision = $parts[0].Substring($ContainerPrefix.Length)
            $slot = Get-Slot $byRevision $revision
            $slot.state = $parts[1]
            $slot.status = $parts[2]
            $slot.port = Get-PublishedPort $parts[3]
            if ($parts[1] -eq 'running') { $containers += $revision }
        }

        foreach ($entry in (Get-DockerVolumeSizes).GetEnumerator()) {
            (Get-Slot $byRevision $entry.Key).profileBytes = $entry.Value
        }
    }

    $imageBytes = [int64]0; $profileBytes = [int64]0
    foreach ($slot in $byRevision.Values) {
        $imageBytes += $slot.imageBytes
        $profileBytes += $slot.profileBytes
    }

    $value = @{
        cli = $hasCli; running = $running; containers = @($containers)
        supported = (Test-Path $DockerCli)
        byRevision = $byRevision
        imageBytes = $imageBytes
        profileBytes = $profileBytes
    }
    $script:DockerCache = @{ At = (Get-Date); Value = $value }
    return $value
}

# ---------- what the vendors still serve ----------
# A shelf row says a version was released. Whether it can still be downloaded is a
# different question, and rows for versions nobody can fetch any more were offered
# as ordinary downloads and failed at the vendor - the worst place to find out.
#
# Windows gets the two answers that cost nothing. Edge is the flat one: Microsoft
# ships only an MSI here, whose payload is an installer stream rather than an
# archive, so no Edge can be shelved natively on Windows at all - engineshelf.ps1
# says exactly that when asked. No feed request can change that answer, so none is
# made. WebKit's boundary does need asking, one revision at a time, and that
# search lives in the Python server, which has a thread to do it in. What it
# writes is read here, so a machine that has run both sees both answers.
$NativeFile = Join-Path $Root 'native.json'
$script:NativeRecord = $null

function Get-NativeRecord {
    if (-not (Test-Path $NativeFile)) { return $null }
    try { return (Get-Content $NativeFile -Raw | ConvertFrom-Json) } catch { return $null }
}

function Get-NativeAvailable {
    param([string]$Engine, [string]$Ident)
    # Not a probe and not a guess: Get-EnginePlatforms is where the CLI keeps the
    # list of platforms an engine publishes for this host, and for Edge on Windows
    # that list is empty.
    if ((Get-EnginePlatforms $Engine).Count -eq 0) { return $false }
    if ($Engine -eq 'webkit' -and $null -ne $script:NativeRecord -and
        $null -ne $script:NativeRecord.webkit) {
        $floor = $script:NativeRecord.webkit.floor
        if ($null -eq $floor) { return $false }
        $n = 0
        if ([int]::TryParse($Ident, [ref]$n)) { return ($n -ge [int]$floor) }
    }
    return $true
}

function Get-DockerRow {
    <#
      The Docker side of one shelf row, or $null if there is nothing to offer.

      A container always runs the Linux x86_64 build, so its revision is not the
      one this host installs natively - and comparing those two is exactly what
      used to hide a running container from the row it belonged to.
    #>
    param($Revision, $Status, $Selector = $null)
    if (-not $Status.supported) { return $null }
    # A revision of $null means "there is a container, but which Linux build it
    # runs has not been looked up yet" - the launcher asks the archive when the
    # button is pressed. Refusing to offer it until then is what kept the Docker
    # edition to the hand-catalogued milestones and nothing in between.
    if ($null -eq $Revision -and $null -eq $Selector) { return $null }
    $entry = if ($null -ne $Revision) { $Status.byRevision[[string]$Revision] } else { $null }
    if (-not $entry) { $entry = @{ imageBytes = 0; profileBytes = 0; state = $null; status = ''; port = $null } }
    return @{
        revision = $Revision
        # What to post back to run or stop this container. For Chromium that is
        # the Linux revision the image is built from; for WebKit the row's own
        # selector, which resolves to the same revision on both sides.
        selector = if ($null -ne $Selector) { $Selector } else { [string]$Revision }
        imageBytes = $entry.imageBytes
        profileBytes = $entry.profileBytes
        state = $entry.state
        status = $entry.status
        port = $entry.port
    }
}

function Get-LinuxRevision {
    # The revision a container would run for this milestone, if there is one.
    # Rows without a Linux x86_64 build cannot go in a container at all, and the
    # manager used to offer it anyway.
    param($Builds, $Milestone)
    if ($null -eq $Milestone) { return $null }
    if (-not $Builds.ContainsKey($Milestone)) { return $null }
    if (-not $Builds[$Milestone].ContainsKey('Linux_x64')) { return $null }
    return $Builds[$Milestone]['Linux_x64'].revision
}

function Get-MilestoneOf {
    # Which milestone a raw revision belongs to, on any platform.
    param($Builds, $Revision)
    foreach ($milestone in $Builds.Keys) {
        foreach ($build in $Builds[$milestone].Values) {
            if ($build.revision -eq $Revision) { return $milestone }
        }
    }
    return $null
}

function Get-DoctorReport {
    # The checks live in lib/preflight.ps1 so the CLI, the Docker launcher and
    # this page cannot disagree about what is missing or how to fix it.
    try {
        return Get-PfReport
    } catch {
        return [ordered]@{ os = 'windows'; arch = $env:PROCESSOR_ARCHITECTURE; components = @() }
    }
}

# ---------- engines ----------
# Kept in step with lib/engines.sh and gui/server.py. All three have to agree on
# the on-disk naming or the same directory means different things to each.
$Engines = @('chromium', 'firefox', 'edge', 'webkit')
$EngineNames = @{
    chromium = 'Chromium'; firefox = 'Firefox'; edge = 'Edge'; webkit = 'WebKit'
}

# Selectors reach the CLI as one argument, so there is no shell to inject into -
# but a bare "is it digits" was the whole guard before there was more than one
# engine. Versions are alphanumeric and dotted (115.0, 140.14.0esr, 26.5);
# nothing matching this can be a path, a switch, or a second word.
$SelectorPattern = '^(?:(?:chromium|firefox|edge|webkit):)?[0-9A-Za-z][0-9A-Za-z.]{0,31}$'

function Get-EngineOfKey {
    param([string]$key)
    foreach ($engine in $Engines) {
        if ($engine -ne 'chromium' -and $key.StartsWith("$engine-")) { return $engine }
    }
    return 'chromium'
}

function Get-SelectorLabel {
    param([string]$selector)
    $engine = 'chromium'; $version = $selector
    if ($selector.Contains(':')) {
        $parts = $selector.Split(':', 2)
        $engine = $parts[0]; $version = $parts[1]
    }
    $name = $EngineNames[$engine]
    if (-not $name) { $name = 'Chromium' }
    return "$name $version"
}

# The S rows: every release tools/discover.py found, per engine, with its date.
# Read apart from Read-Catalog because the two answer different questions - V and
# B rows are Chromium's snapshot bookkeeping; these are the shelf across all four
# engines, and only these carry a date to arrange years by.
function Read-Shelf {
    $shelf = @{}
    foreach ($engine in $Engines) { $shelf[$engine] = New-Object System.Collections.ArrayList }
    $seen = @{}
    # Scope named for the same reason as in Read-Catalog above.
    foreach ($path in @($script:Catalog, $script:CacheFile)) {
        if (-not (Test-Path $path)) { continue }
        foreach ($line in Get-Content $path) {
            if ($line -match '^\s*#' -or $line.Trim() -eq '') { continue }
            $f = $line -split "`t"
            if ($f[0] -ne 'S' -or $f.Count -lt 6) { continue }
            $engine = $f[1]
            if (-not $shelf.ContainsKey($engine)) { continue }
            $key = "$engine/$($f[3])"
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true
            [void]$shelf[$engine].Add(@{
                engine = $engine; year = [int]$f[2]; id = $f[3]
                label = $f[4]; date = $f[5]
            })
        }
    }
    foreach ($engine in $Engines) {
        $sorted = @($shelf[$engine] | Sort-Object -Property date -Descending)
        $shelf[$engine] = $sorted
    }
    return $shelf
}

# Every installed build keyed by its directory name, whatever the engine. The
# directory name is the identity the CLI writes and the one Docker tags its
# images with, so one lookup answers "is it on disk" for all four engines. It
# replaced a numeric, Chromium-only version of the same walk.
function Get-InstalledByKey {
    $result = @{}
    if (-not (Test-Path $BuildsDir)) { return $result }
    foreach ($dir in Get-ChildItem -Path $BuildsDir -Directory -ErrorAction SilentlyContinue) {
        if (-not (Test-Path (Join-Path $dir.FullName '.complete'))) { continue }
        $meta = @{}
        $metaPath = Join-Path $dir.FullName '.meta'
        if (Test-Path $metaPath) {
            foreach ($line in Get-Content $metaPath) {
                if ($line -match "^([A-Z_]+)='(.*)'$") { $meta[$Matches[1]] = $Matches[2] }
            }
        }
        $engine = $meta['META_ENGINE']
        if (-not $engine) { $engine = Get-EngineOfKey $dir.Name }
        $version = $meta['META_VERSION']; if (-not $version) { $version = $dir.Name }
        $platform = $meta['META_PLATFORM']; if (-not $platform) { $platform = '?' }
        $result[$dir.Name] = @{
            key          = $dir.Name
            engine       = $engine
            version      = $version
            platformDir  = $platform
            installedAt  = $meta['META_INSTALLED']
            sizeBytes    = Get-DirSize $dir.FullName
            profileBytes = Get-DirSize (Join-Path $ProfilesDir $dir.Name)
        }
    }
    return $result
}

# One release, in the shape the list draws. Built from the S rows, which is where
# the whole shelf lives, plus everything needed to act on a row: the platform a
# build would come from, the Docker side, the curated note where there is one.
function Get-ShelfRow {
    param($engine, $release, $installed, $builds, $notes, $docker)

    $ident = $release.id
    $row = @{
        engine = $engine
        id = $ident
        label = $release.label
        year = $release.year
        date = $release.date
        note = ''
        milestone = $null
        revision = $null
        docker = $null
        native = $true
        # The macOS side fills this from the record engineshelf.sh keeps of
        # builds that started here and died. Windows has no Rosetta and no
        # arch-fallback cache to read, so the field exists to keep the page's
        # two servers answering the same shape and is always false.
        knownBad = $false
        # Whether the vendor will still hand this over, which is not the same
        # question as whether it would run. See Get-NativeAvailable.
        nativeAvailable = $true
    }

    if ($engine -eq 'chromium') {
        $m = [int]$ident
        $row.milestone = $m
        # Only a couple of dozen milestones carry a hand-written note naming the
        # features that land there. The rest are shelf stock: real releases with
        # nothing to say beyond when they shipped.
        if ($notes.ContainsKey($m)) {
            $row.note = $notes[$m].note
            $row.version = $notes[$m].version
        } else {
            $row.version = $release.label
        }
        # Addressed by milestone rather than by the Linux revision: for most of
        # the shelf that revision is not resolved yet, and the launcher takes
        # either.
        $row.docker = Get-DockerRow (Get-LinuxRevision $builds $m) $docker ([string]$m)
        $has = $builds.ContainsKey($m)
        if ($has -and $builds[$m].ContainsKey($HostPlatform)) {
            $row.revision = $builds[$m][$HostPlatform].revision
            $row.platformDir = $HostPlatform
            $row.supported = $true
            # The revision is what a Chromium build directory has always been
            # named and what the launcher has always been given, so it stays both
            # the key and the selector.
            $row.key = [string]$row.revision
            $row.selector = [string]$row.revision
        } else {
            $row.platformDir = $null
            # Unknown is not unavailable. B rows exist only for the catalogued
            # milestones; every other one is resolved against the live archive on
            # first launch, so no B row means no key yet - not no build. Only rows
            # for this operating system's own platform count as an answer: a Linux
            # row cached so the container knows which build to run says nothing
            # about Windows, and read as evidence it said the opposite.
            # Which, on Windows, is always true here: Win_x64 is the only
            # platform this OS could use, and reaching this branch already means
            # there is no row for it. Python has two Mac platforms to weigh and
            # so has a real test to make.
            $row.supported = $true
            $row.key = $null
            $row.selector = [string]$m
        }
    } else {
        $row.version = $ident
        $row.key = "$engine-$ident"
        # The id, not the label: two WebKit builds are both called 26.5 and only
        # the id says which one this is.
        $row.selector = "$engine`:$ident"
        # Which platform a build comes from is settled against the vendor's own
        # index at launch time, so until then there is nothing honest to print.
        $row.platformDir = $null
        $row.supported = $true
        $row.nativeAvailable = Get-NativeAvailable $engine $ident
        # All four engines have a container now, and for these three its image
        # is tagged with the same key the build directory uses - so the row can
        # see it without a second lookup. Chromium is the exception above: its
        # container runs a Linux revision this host never installs.
        $row.docker = Get-DockerRow $row.key $docker $row.selector
    }

    $local = $null
    if ($row.key -and $installed.ContainsKey($row.key)) { $local = $installed[$row.key] }
    $row.installed = ($null -ne $local)
    $row.sizeBytes = if ($local) { $local.sizeBytes } else { 0 }
    $row.profileBytes = if ($local) { $local.profileBytes } else { 0 }
    $row.installedAt = if ($local) { $local.installedAt } else { '' }
    # Once it is downloaded the platform is no longer a guess.
    if ($local -and $local.platformDir -and $local.platformDir -ne '?') {
        $row.platformDir = $local.platformDir
    }
    return $row
}

function Get-State {
    $cat = Read-Catalog
    $docker = Get-DockerStatus
    # Keyed by directory name rather than by revision, which is what lets one
    # lookup serve all four engines.
    $everything = Get-InstalledByKey
    $notes = @{}
    foreach ($entry in $cat.versions) { $notes[$entry.milestone] = $entry }

    # The list used to be the V rows and nothing else - twenty-one curated
    # Chromium milestones - so it showed Chromium alone while the S rows beside it
    # showed four engines. Same shelf, same rows, one source.
    $shelf = Read-Shelf
    # Read once per state build, not once per row: 288 rows would otherwise open
    # the same small file 288 times.
    $script:NativeRecord = Get-NativeRecord
    $rows = New-Object System.Collections.ArrayList
    foreach ($engine in $Engines) {
        foreach ($release in $shelf[$engine]) {
            [void]$rows.Add((Get-ShelfRow $engine $release $everything $cat.builds $notes $docker))
        }
    }
    # Nothing anywhere can run this version: the vendor stopped serving it and its
    # engine has no container either. A row that cannot be acted on at all is not
    # information, it is a dead entry in a list of 288.
    #
    # Deliberately not "and Docker is not installed on this machine": that would
    # hide rows from someone who has yet to set Docker up and hand them back when
    # they do, a shelf that changes size for reasons nobody can see. All four
    # engines have a container, so this removes nothing today.
    $rows = @($rows | Where-Object { $_.nativeAvailable -or ($_.engine -in $Engines) })

    # Newest first across engines. A release date is the only ordering four
    # numbering schemes share; the page re-sorts, this just makes the default sane.
    $rows = @($rows | Sort-Object -Property { $_.date } -Descending)

    # Builds sitting in the builds directory that no shelf row claims: added by
    # raw revision, or left behind by a release that has since dropped off a
    # vendor's index. A container for a Chromium one still runs the Linux build of
    # whatever milestone it belongs to, so it is looked up the same way the
    # launcher looks it up.
    $claimed = @{}
    foreach ($row in $rows) { if ($row.key) { $claimed[$row.key] = $true } }

    $extra = New-Object System.Collections.ArrayList
    foreach ($key in ($everything.Keys | Sort-Object)) {
        if ($claimed.ContainsKey($key)) { continue }
        $info = $everything[$key]
        $row = $info.Clone()
        $row.note = 'Installed by revision.'
        $row.supported = $true
        $row.native = $true
        $row.knownBad = $false
        $row.nativeAvailable = $true
        $row.installed = $true
        $row.docker = $null
        $row.milestone = $null
        $row.revision = $null
        $row.label = $info.version
        $row.year = $null
        $row.date = ''
        $engine = $info.engine
        if ($engine -eq 'chromium' -and $key -match '^\d+$') {
            $row.id = $key
            $row.revision = [int]$key
            $row.selector = $key
            $milestone = Get-MilestoneOf $cat.builds ([int]$key)
            $dockerRev = if ($null -ne $milestone) {
                Get-LinuxRevision $cat.builds $milestone
            } else { [int]$key }
            $row.docker = Get-DockerRow $dockerRev $docker
        } else {
            $row.id = $key.Substring($engine.Length + 1)
            $row.selector = "$engine`:$($row.id)"
            $row.docker = Get-DockerRow $key $docker $row.selector
        }
        [void]$extra.Add($row)
    }

    # Summed over every engine, not over the rows above: those are Chromium's
    # catalogue, so a gauge built from them reported a 2.2 GB directory as 589 MB
    # the moment anything other than Chromium was installed.
    $everything = Get-InstalledByKey
    $browserBytes = 0
    $profileBytes = 0
    foreach ($info in $everything.Values) {
        $browserBytes += $info.sizeBytes
        $profileBytes += $info.profileBytes
    }
    $total = $browserBytes + $profileBytes

    return @{
        root = $Root
        os = 'windows'
        arch = $env:PROCESSOR_ARCHITECTURE
        hostPlatforms = @($HostPlatform)
        versions = $rows
        extra = $extra
        # @() for the same reason the jobs list has it: a returned collection
        # unrolls, and the page needs a list even when there is one row.
        engines = @(foreach ($e in $Engines) { @{ id = $e; name = $EngineNames[$e] } })
        installedCount = $everything.Count
        browserBytes = $browserBytes
        profileBytes = $profileBytes
        totalBytes = $total
        # Images and profile volumes are the other place gigabytes go, and they
        # are invisible from the file tree the rest of this reads.
        dockerBytes = ($docker.imageBytes + $docker.profileBytes)
        docker = $docker
        doctor = Get-DoctorReport
        # @() is not decoration. Returning a collection from a function unrolls it,
        # so with no jobs running this arrives as $null and with one as a bare
        # object - and the page, which expects a list, breaks on both.
        jobs = @(Get-JobSummary)
    }
}

# ---------- jobs ----------
# Each job is a child powershell running engineshelf.ps1 with its output
# redirected to a file, so the HTTP loop never blocks on a long download or on a
# browser window that stays open for an hour.
$script:Jobs = @{}
$script:NextJob = 1

function Start-Job2 {
    param([string]$Kind, [string]$Revision, [string[]]$CliArgs, [string]$Label, [string]$Script = $null)
    if (-not $Script) { $Script = $script:Cli }

    $id = [string]$script:NextJob
    $script:NextJob++
    $out = Join-Path $JobsDir "$id.out"
    $err = Join-Path $JobsDir "$id.err"
    '' | Set-Content -Path $out
    '' | Set-Content -Path $err

    $psArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Script) + $CliArgs
    $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $psArgs `
        -WorkingDirectory $Project -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $out -RedirectStandardError $err

    $script:Jobs[$id] = @{
        id = $id; kind = $Kind; revision = $Revision; label = $Label
        proc = $proc; out = $out; err = $err; stopping = $false
    }
    return $id
}

function Stop-Job2 {
    # taskkill /T is what reaches the browser: Stop-Process would only end the
    # wrapper powershell, and killing the browser alone would trip the launcher's
    # crash-restart loop and reopen it.
    param([string]$Id)
    if (-not $script:Jobs.ContainsKey($Id)) { return $false }
    $job = $script:Jobs[$Id]
    if ($job.proc.HasExited) { return $false }
    $job.stopping = $true
    & taskkill.exe /PID $job.proc.Id /T /F 2>&1 | Out-Null
    return $true
}

# The whole point is reading a file while the job is still writing to it, and on
# Windows that dictates the share mode: [IO.File]::ReadAllText asks for
# FileShare.Read, which a live writer denies outright. Every poll of a running job
# came back as an IOException, the request answered 400, and the page - which used
# to swallow that - sat at "running..." with an empty log until the job ended.
function Read-JobFile {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return '' }
    try {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read,
                                  [IO.FileShare]::ReadWrite)
        try {
            $reader = New-Object IO.StreamReader($stream)
            $text = $reader.ReadToEnd()
            $reader.Dispose()
            if ($text) { return $text }
            return ''
        } finally { $stream.Dispose() }
    } catch {
        # A log that cannot be read is not worth failing the whole request over:
        # the status still tells the page whether the job is alive.
        return ''
    }
}

function Get-JobRecord {
    param([string]$Id)
    if (-not $script:Jobs.ContainsKey($Id)) { return $null }
    $job = $script:Jobs[$Id]
    $text = ''
    foreach ($file in @($job.out, $job.err)) {
        $chunk = Read-JobFile $file
        if ($chunk) { $text += $chunk }
    }
    $exited = $job.proc.HasExited
    $code = $null
    $status = 'running'
    if ($exited -and -not $job.settled) {
        # A finished job has usually just changed what Docker holds, and the page
        # asks for the state again the moment it sees the job end. Once per job:
        # this is read on every poll, including polls of a job that ended long ago.
        $job.settled = $true
        $script:DockerCache.Value = $null
        $script:VolumeCache.Value = $null
    }
    if ($exited) {
        $code = $job.proc.ExitCode
        if ($job.stopping) { $status = 'stopped' }
        elseif ($code -eq 0) { $status = 'done' }
        else { $status = 'error' }
    }
    return @{ id = $job.id; kind = $job.kind; revision = $job.revision; label = $job.label
              status = $status; code = $code; output = $text }
}

# Callers must wrap this in @(): see Get-State. PowerShell unrolls the collection
# on the way out, which turns "no jobs" into $null.
function Get-JobsRevision {
    <#
      What a window needs in order to know it has missed something.

      Two windows onto one manager each poll on their own four-second clock, so
      a download started in one took up to four seconds to appear in the other.
      This rides along on the heartbeat instead - it changes exactly when a job
      appears, finishes or is stopped. Progress is not in here: that is what the
      faster refresh while something is running is for.
    #>
    $parts = @()
    foreach ($id in ($script:Jobs.Keys | Sort-Object)) {
        $job = $script:Jobs[$id]
        $state = if ($job.stopping) { 'stopping' }
                 elseif ($job.proc.HasExited) { 'ended' }
                 else { 'running' }
        $parts += "${id}:$state"
    }
    return ($parts -join ',')
}

function Get-JobSummary {
    $running = New-Object System.Collections.ArrayList
    foreach ($id in @($script:Jobs.Keys)) {
        $job = $script:Jobs[$id]
        if (-not $job.proc.HasExited) {
            [void]$running.Add(@{ id = $job.id; kind = $job.kind; revision = $job.revision
                                  label = $job.label; status = 'running' })
        }
    }
    return $running
}

# ---------- http ----------
# Depth 12, not 8: a row nests docker -> byRevision -> entry and the doctor report
# nests further, and at 8 the innermost values serialise as type names.
function ConvertTo-Json2 { param($obj) $obj | ConvertTo-Json -Depth 12 -Compress }

function Send-Response {
    param($Stream, [int]$Status, [string]$ContentType, [byte[]]$Body)
    $reason = @{ 200 = 'OK'; 400 = 'Bad Request'; 403 = 'Forbidden'; 404 = 'Not Found' }[$Status]
    if (-not $reason) { $reason = 'OK' }
    $head = "HTTP/1.1 $Status $reason`r`n" +
            "Content-Type: $ContentType`r`n" +
            "Content-Length: $($Body.Length)`r`n" +
            "Cache-Control: no-store`r`n" +
            "Connection: close`r`n`r`n"
    $headBytes = [Text.Encoding]::ASCII.GetBytes($head)
    $Stream.Write($headBytes, 0, $headBytes.Length)
    if ($Body.Length -gt 0) { $Stream.Write($Body, 0, $Body.Length) }
    $Stream.Flush()
}

function Send-Json {
    param($Stream, $Object, [int]$Status = 200)
    Send-Response $Stream $Status 'application/json' ([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json2 $Object)))
}

$MimeTypes = @{ '.html' = 'text/html; charset=utf-8'; '.css' = 'text/css; charset=utf-8'
                '.js' = 'text/javascript; charset=utf-8'; '.json' = 'application/json'
                '.svg' = 'image/svg+xml'; '.ico' = 'image/x-icon' }

function Send-Static {
    param($Stream, [string]$PathPart)
    $name = if ($PathPart -eq '/') { 'index.html' } else { $PathPart.TrimStart('/') }
    $target = [IO.Path]::GetFullPath((Join-Path $Here $name))
    if (-not $target.StartsWith($Here, [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path $target -PathType Leaf)) {
        Send-Response $Stream 404 'text/plain' ([Text.Encoding]::ASCII.GetBytes('not found'))
        return
    }
    $kind = $MimeTypes[[IO.Path]::GetExtension($target).ToLower()]
    if (-not $kind) { $kind = 'application/octet-stream' }
    Send-Response $Stream 200 $kind ([IO.File]::ReadAllBytes($target))
}

function Read-Request {
    param($Stream)
    # Read until the end of the headers, then take exactly Content-Length bytes.
    # Mixing a StreamReader with raw reads here would swallow part of the body.
    $buffer = New-Object byte[] 8192
    $data = New-Object System.Collections.Generic.List[byte]
    $headerEnd = -1
    while ($headerEnd -lt 0) {
        $read = $Stream.Read($buffer, 0, $buffer.Length)
        if ($read -le 0) { return $null }
        for ($i = 0; $i -lt $read; $i++) { $data.Add($buffer[$i]) }
        $text = [Text.Encoding]::ASCII.GetString($data.ToArray())
        $headerEnd = $text.IndexOf("`r`n`r`n")
        if ($data.Count -gt 65536) { return $null }
    }

    $all = $data.ToArray()
    $headerText = [Text.Encoding]::ASCII.GetString($all, 0, $headerEnd)
    $lines = $headerText -split "`r`n"
    $requestLine = $lines[0] -split ' '
    $headers = @{}
    foreach ($line in $lines[1..($lines.Count - 1)]) {
        $idx = $line.IndexOf(':')
        if ($idx -gt 0) { $headers[$line.Substring(0, $idx).Trim().ToLower()] = $line.Substring($idx + 1).Trim() }
    }

    $bodyStart = $headerEnd + 4
    $length = 0
    if ($headers.ContainsKey('content-length')) { $length = [int]$headers['content-length'] }
    $body = New-Object System.Collections.Generic.List[byte]
    for ($i = $bodyStart; $i -lt $all.Length; $i++) { $body.Add($all[$i]) }
    while ($body.Count -lt $length) {
        $read = $Stream.Read($buffer, 0, [Math]::Min($buffer.Length, $length - $body.Count))
        if ($read -le 0) { break }
        for ($i = 0; $i -lt $read; $i++) { $body.Add($buffer[$i]) }
    }

    return @{
        method  = $requestLine[0]
        path    = $requestLine[1]
        headers = $headers
        body    = [Text.Encoding]::UTF8.GetString($body.ToArray())
    }
}

function Test-Authorised {
    param($Request)
    # Loopback binding alone does not stop a page in your browser from POSTing
    # here, so every API call has to carry the token generated for this run.
    #
    # A call that gets through is also proof the window is still open, which is
    # what keeps the manager alive - see "lifetime" below.
    $hostHeader = ''
    if ($Request.headers.ContainsKey('host')) { $hostHeader = ($Request.headers['host'] -split ':')[0] }
    if ($hostHeader -ne '127.0.0.1' -and $hostHeader -ne 'localhost') { return $false }
    if (-not $Request.headers.ContainsKey('x-engineshelf-token')) { return $false }
    if ($Request.headers['x-engineshelf-token'] -cne $Token) { return $false }
    $script:LastSeen = Get-Date
    return $true
}

function Get-Body {
    param($Request)
    if (-not $Request.body) { return @{} }
    try { return $Request.body | ConvertFrom-Json } catch { return @{} }
}

function Get-Field {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    return $prop.Value
}

# ---------- lifetime ----------
#
# The manager used to be a tab you closed and a server you forgot about, still
# holding a port and still parenting every browser it had launched. Now the
# window is the app: when it goes, everything it started goes with it.
#
# Two things can say the window is gone, and both are needed. The browser process
# hosting it exits - immediate and certain, but only when we own that process.
# And the page stops asking: any authorised request counts as a heartbeat, so a
# tab in someone's own browser is covered too, at the cost of a grace period long
# enough that a reload does not read as a goodbye.

# Long enough to ride out a reload, a sleeping laptop's first second back, or a
# slow render; short enough that closing the window does not leave a stray server
# holding the port.
$GraceSeconds = 12

$script:LastSeen   = $null     # last authorised request from a page
$script:Shell      = $null     # the browser process hosting the window, if ours
$script:AutoQuit   = $true     # quit when the window is gone
$script:QuitReason = $null     # set by the watchdog, read by the serve loop

function Find-AppBrowser {
    <#
      A Chromium-family browser to host the manager's own window.

      Only Chromium-family: --app is what turns a tab into a window with no
      address bar and no session of its own, and nothing else understands it.
      Without one the manager opens as an ordinary tab instead.
    #>
    if ($env:CHROMIUM_STACK_APP_BROWSER) {
        if (Test-Path $env:CHROMIUM_STACK_APP_BROWSER) { return $env:CHROMIUM_STACK_APP_BROWSER }
        return $null
    }
    $candidates = @()
    foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA)) {
        if (-not $base) { continue }
        $candidates += Join-Path $base 'Google\Chrome\Application\chrome.exe'
        $candidates += Join-Path $base 'Microsoft\Edge\Application\msedge.exe'
        $candidates += Join-Path $base 'Chromium\Application\chrome.exe'
        $candidates += Join-Path $base 'BraveSoftware\Brave-Browser\Application\brave.exe'
    }
    foreach ($path in $candidates) {
        if ($path -and (Test-Path $path -PathType Leaf)) { return $path }
    }
    return $null
}

function Open-AppWindow {
    <#
      Open the manager in a window of its own; return the process behind it.

      The separate profile directory is not tidiness. Pointed at the browser's
      normal profile, the window is handed to the copy of Chrome already running
      and that process exits immediately - taking away the one signal that says
      for certain when the window has closed. It also keeps a manager window out
      of the user's own session, history and extensions.
    #>
    param([string]$Url)
    $browser = Find-AppBrowser
    if (-not $browser) { return $null }
    $argv = @(
        "--app=$Url"
        "--user-data-dir=$(Join-Path $Root 'manager-window')"
        '--no-first-run'
        '--no-default-browser-check'
        '--window-size=1440,920'
        # A window showing one local page needs none of this, and an update check
        # or a restore-pages prompt in it would be pure noise.
        '--disable-background-networking'
        '--disable-component-update'
        '--disable-features=Translate'
    )
    try {
        return Start-Process -FilePath $browser -ArgumentList $argv -PassThru
    } catch {
        return $null
    }
}

function Stop-Containers {
    <#
      Stop and remove the containers this project runs, if any are up.

      Named the way engineshelf-docker.ps1 names them, and stopped the way it
      stops them: SIGTERM first, because killed outright the browser inside
      leaves a lock in its profile volume that breaks the next start.
    #>
    $names = @(docker ps --filter "name=$ContainerPrefix" --format '{{.Names}}' 2>$null |
               Where-Object { $_ -like "$ContainerPrefix*" })
    if (-not $names.Count) { return }
    $plural = if ($names.Count -gt 1) { 's' } else { '' }
    Write-Host "  Stopping $($names.Count) Docker container$plural..."
    docker stop -t 10 @names 2>&1 | Out-Null
    docker rm -f @names 2>&1 | Out-Null
}

function Clear-CutOff {
    <#
      Clear up after downloads the shutdown interrupted.

      engineshelf.ps1 removes both of these itself when a download fails, but
      a job killed outright never reaches that code - and closing the window is
      now an ordinary way for a download to end, so an 80 MB orphan every time is
      not acceptable. The archive cannot be resumed either: it is fetched whole.

      Only revisions this process was working on. Another manager may be running
      against the same directory, and its download is not ours to delete.
    #>
    param([string[]]$Revisions)
    foreach ($revision in $Revisions) {
        # A job is keyed by selector and a build directory by key, and for the
        # three non-Chromium engines those differ by one character: the launcher
        # downloads webkit:2336 into builds\webkit-2336.
        $key = ([string]$revision).Replace(':', '-')
        $partial = Join-Path $Root ".download-$key.zip"
        if (Test-Path $partial) { Remove-Item $partial -Force -ErrorAction SilentlyContinue }
        $build = Join-Path $BuildsDir $key
        # Absent .complete, this is a half-unpacked build that nothing will use.
        if ((Test-Path $build) -and -not (Test-Path (Join-Path $build '.complete'))) {
            Remove-Item $build -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Stop-Everything {
    <#
      Every browser and every job this manager started, closed.

      Jobs are killed with taskkill /T, which is what brings a launched browser
      down along with the launcher watching it.
    #>
    $running = @(Get-JobSummary)
    $cutOff = @()
    if ($running.Count) {
        $plural = if ($running.Count -gt 1) { 's' } else { '' }
        Write-Host "  Stopping $($running.Count) running job$plural..."
        foreach ($job in $running) {
            if ($job.kind -eq 'install' -or $job.kind -eq 'launch') { $cutOff += [string]$job.revision }
            Stop-Job2 ([string]$job.id) | Out-Null
        }
        # Let the kill land before clearing up after what it interrupted.
        Start-Sleep -Milliseconds 600
    }
    Clear-CutOff $cutOff
    Stop-Containers

    if ($script:Shell -and -not $script:Shell.HasExited) {
        # Quitting from the page, so the window is still there to close.
        try { $script:Shell.CloseMainWindow() | Out-Null } catch { }
    }
}

# ---------- routing ----------
function Invoke-Route {
    param($Stream, $Request)

    $path = ($Request.path -split '\?')[0]

    if ($Request.method -eq 'GET') {
        if ($path -eq '/api/alive') {
            # Before the token check on purpose, and not a heartbeat: this is
            # another launch asking whether it should be a manager at all.
            # The root matters: two managers pointed at two different home
            # directories are two different shelves, and neither should stand
            # aside for the other.
            Send-Json $Stream @{
                engineshelf = $true; pid = $PID; port = $Port
                url = "http://127.0.0.1:$Port/"; root = $Root
            }
            return
        }

        if ($path -eq '/api/token') { Send-Json $Stream @{ token = $Token }; return }

        if ($path -eq '/api/ping') {
            # Test-Authorised has already noted the time; the body is only so the
            # page can tell whether closing it will end the session.
            if (-not (Test-Authorised $Request)) { Send-Json $Stream @{ error = 'unauthorised' } 403; return }
            Send-Json $Stream @{
                autoQuit = $script:AutoQuit; grace = $GraceSeconds
                revision = (Get-JobsRevision)
            }
            return
        }

        if ($path -eq '/api/state') {
            if (-not (Test-Authorised $Request)) { Send-Json $Stream @{ error = 'unauthorised' } 403; return }
            Send-Json $Stream (Get-State); return
        }
        if ($path -like '/api/job/*') {
            if (-not (Test-Authorised $Request)) { Send-Json $Stream @{ error = 'unauthorised' } 403; return }
            $job = Get-JobRecord (($path -split '/')[-1])
            if ($job) { Send-Json $Stream $job } else { Send-Json $Stream @{ error = 'no such job' } 404 }
            return
        }
        Send-Static $Stream $path
        return
    }

    if ($Request.method -ne 'POST') {
        Send-Json $Stream @{ error = 'no such endpoint' } 404
        return
    }

    if (-not (Test-Authorised $Request)) { Send-Json $Stream @{ error = 'unauthorised' } 403; return }

    $body = Get-Body $Request

    if ($path -eq '/api/doctor') {
        Send-Json $Stream (Get-DoctorReport); return
    }

    if ($path -eq '/api/doctor-install') {
        $component = [string](Get-Field $body 'component')
        if ($component -notmatch '^[a-z0-9]+$') { Send-Json $Stream @{ error = 'bad component' } 400; return }
        $id = Start-Job2 'doctor' $component @('doctor', '--install', $component, '--yes') "Installing $component"
        Send-Json $Stream @{ job = $id }; return
    }

    if ($path -eq '/api/stop') {
        $jobId = [string](Get-Field $body 'job')
        # Read before the kill: only a job that was running is worth clearing
        # up after, and afterwards there is nothing left to ask.
        $job = $null
        if ($script:Jobs.ContainsKey($jobId)) { $job = $script:Jobs[$jobId] }
        $stopped = Stop-Job2 $jobId
        # Cancelling a download is now a button rather than only a side effect of
        # quitting, so it gets the same clear-up: the archive is fetched whole and
        # cannot be resumed, and a part-unpacked build directory is dead weight.
        # A launch that had already opened the browser keeps everything -
        # .complete is what says so.
        if ($stopped -and $job -and ($job.kind -eq 'install' -or $job.kind -eq 'launch')) {
            Start-Sleep -Milliseconds 250
            Clear-CutOff @([string]$job.revision)
        }
        Send-Json $Stream @{ stopped = $stopped }; return
    }

    $selector = [string](Get-Field $body 'selector')
    if ($selector -notmatch $SelectorPattern) { Send-Json $Stream @{ error = 'bad selector' } 400; return }
    $label = Get-SelectorLabel $selector

    switch ($path) {
        '/api/install' {
            $id = Start-Job2 'install' $selector @('install', $selector) "Installing $label"
            Send-Json $Stream @{ job = $id }; return
        }
        '/api/launch' {
            $cliArgs = @('run', $selector)
            $url = [string](Get-Field $body 'url')
            if ($url) { $cliArgs += $url }
            $size = [string](Get-Field $body 'size')
            if ($size) { $cliArgs += @('--size', $size) }
            $gpu = Get-Field $body 'gpu'
            if ($gpu -eq $true) { $cliArgs += '--gpu' } elseif ($gpu -eq $false) { $cliArgs += '--no-gpu' }
            $id = Start-Job2 'launch' $selector $cliArgs $label
            Send-Json $Stream @{ job = $id }; return
        }
        '/api/remove' {
            $cliArgs = @('remove', $selector)
            if (Get-Field $body 'withProfile') { $cliArgs += '--with-profile' }
            $id = Start-Job2 'remove' $selector $cliArgs "Removing $label"
            Send-Json $Stream @{ job = $id }; return
        }
        '/api/clean' {
            $id = Start-Job2 'clean' $selector @('clean', $selector) "Resetting profile $label"
            Send-Json $Stream @{ job = $id }; return
        }
        '/api/docker' {
            $action = [string](Get-Field $body 'action')
            if (-not $action) { $action = 'start' }
            if (@('start', 'build', 'stop', 'rebuild', 'purge') -notcontains $action) {
                Send-Json $Stream @{ error = 'bad action' } 400; return
            }
            # Every engine has a container. An unknown one still gets refused
            # here rather than in a job log nobody has open.
            $dockerEngine = if ($selector.Contains(':')) { $selector.Split(':', 2)[0] } else { 'chromium' }
            if ($Engines -notcontains $dockerEngine) {
                Send-Json $Stream @{ error = "Unknown engine: $dockerEngine" } 400
                return
            }
            $cliArgs = @($action, $selector)
            # An image is a gigabyte, so removing one has to be possible from the
            # shelf; otherwise the only way to get that disk back is raw docker.
            if ($action -eq 'purge' -and (Get-Field $body 'withProfile')) {
                $cliArgs += '--with-profile'
            }
            $id = Start-Job2 'docker' $selector $cliArgs "Docker $action $selector" $DockerCli
            Send-Json $Stream @{ job = $id }; return
        }
        default { Send-Json $Stream @{ error = 'no such endpoint' } 404; return }
    }
}

# ---------- one manager at a time ----------
#
# Opening the app again while it is running used to start a second manager: a
# second server on the next free port, and a second window - which the copy of
# Chrome already running takes over, so the process this one was watching exits
# immediately. That reads as "the window was closed", and the new manager quits
# a second after starting, stopping the containers the first one was running on
# its way out. The window it opened is left pointing at a server that is gone.
#
# So a launch asks first, and if a manager answers, this one opens that
# manager's window again and gets out of the way.

function Get-AliveManager {
    <#
      The manager answering on this port, or $null.

      Unauthenticated on purpose: this is how a launch finds out that another
      one is already here, before there is any way for it to have been handed a
      token. It says nothing that connecting to the port would not already say.
    #>
    param([int]$Candidate)
    try {
        $answer = Invoke-RestMethod -Uri "http://127.0.0.1:$Candidate/api/alive" `
                                    -TimeoutSec 2 -ErrorAction Stop
    } catch {
        # Refused, timed out, or something else entirely listening there.
        return $null
    }
    if ($answer -and $answer.engineshelf) { return $answer }
    return $null
}

function Get-RunningManager {
    param([int]$Preferred)
    $state = $null
    if (Test-Path $StateFile) {
        try { $state = Get-Content $StateFile -Raw | ConvertFrom-Json } catch { $state = $null }
    }
    $ports = @()
    if ($state -and $state.port) { $ports += [int]$state.port }
    # The file can be missing - deleted, or never written by a manager that had
    # nowhere to write it - and the default port is where one would be anyway.
    foreach ($candidate in @($Preferred, 7411)) {
        if ($ports -notcontains $candidate) { $ports += $candidate }
    }
    foreach ($candidate in $ports) {
        $found = Get-AliveManager $candidate
        if ($found -and (-not $found.root -or $found.root -eq $Root)) { return $found }
    }
    # A manager a second old has claimed its port and written its file but is
    # not answering yet: it runs the CLI once before it starts serving. Two
    # quick presses on the app icon land exactly there, so a live process
    # holding the port it claimed counts as one.
    if ($state -and $state.pid -and $state.port -and $state.pid -ne $PID) {
        $live = Get-Process -Id ([int]$state.pid) -ErrorAction SilentlyContinue
        if ($live) {
            try {
                $probe = New-Object Net.Sockets.TcpClient
                $probe.Connect('127.0.0.1', [int]$state.port)
                $probe.Close()
                return $state
            } catch { }
        }
    }
    return $null
}

if (-not $New) {
    # Opening the app again is how someone asks for the window back, not for a
    # second manager - and a second one cannot work anyway: the window it opens
    # belongs to the browser process the first one is already watching.
    $already = Get-RunningManager $Port
    if ($already) {
        $there = if ($already.url) { [string]$already.url } else { "http://127.0.0.1:$($already.port)/" }
        Write-Host ""
        Write-Host "  EngineShelf is already running  ->  $there"
        if ($NoOpen) {
            Write-Host "  Left as it is; that manager is still serving."
        } elseif (-not $Tab -and (Open-AppWindow $there)) {
            Write-Host "  Opened its window again."
        } else {
            Start-Process $there | Out-Null
            Write-Host "  Opened it in a tab."
        }
        Write-Host ""
        exit 0
    }
}

# ---------- serve ----------
$listener = $null
for ($candidate = $Port; $candidate -lt $Port + 40; $candidate++) {
    try {
        $listener = New-Object System.Net.Sockets.TcpListener([Net.IPAddress]::Loopback, $candidate)
        $listener.Start()
        $Port = $candidate
        break
    } catch {
        $listener = $null
    }
}
if (-not $listener) { throw "No free port between $Port and $($Port + 40)" }

$url = "http://127.0.0.1:$Port/"

# Written before the window opens, so a second launch a moment later finds this
# one rather than racing it onto the next port. Best effort: a manager that
# cannot write it still runs, the next one just has to find it by port.
try {
    @{ pid = $PID; port = $Port; url = $url } | ConvertTo-Json |
        Set-Content -Path $StateFile -Encoding UTF8
} catch { }

# Nothing was opened, so there is no window whose closing could mean anything;
# this is the shape a script or a remote session asks for, and it waits.
$script:AutoQuit = -not ($KeepAlive -or $NoOpen)

if (-not $NoOpen -and -not $Tab) { $script:Shell = Open-AppWindow $url }
elseif (-not $NoOpen)            { Start-Process $url | Out-Null }

Write-Host ""
Write-Host "  EngineShelf manager  ->  $url"
Write-Host "  Files: $Root"
if ($script:Shell) {
    Write-Host "  Closing the window quits the manager, the browsers it opened"
    Write-Host "  and any Docker containers it started."
} elseif (-not $script:AutoQuit) {
    Write-Host "  Press Ctrl-C to stop the manager."
} else {
    # No window of our own: the page's heartbeat is the only thing that can say
    # it is still there, so say what silence will be taken to mean.
    Write-Host "  Opened as a browser tab. Closing it quits the manager, the"
    Write-Host "  browsers it opened and any containers it started, ${GraceSeconds}s later."
}
Write-Host "  Ctrl-C does the same."
Write-Host ""

# Off the startup path: it talks to the network, and the page is perfectly usable
# from the shipped catalog while it runs. The next refresh picks up what it found.
Update-CatalogCache

# Pending() instead of a blocking accept, so the watchdog below gets a turn: this
# loop is the only thread there is.
$lastTick = Get-Date
try {
    while (-not $script:QuitReason) {
        if (-not $listener.Pending()) {
            Start-Sleep -Milliseconds 120
            $now = Get-Date
            if (($now - $lastTick).TotalSeconds -lt 1) { continue }
            $slept = ($now - $lastTick).TotalSeconds
            $lastTick = $now
            # A second that took much longer than a second means the machine was
            # suspended, not that the window closed - and on wake the page has
            # had no chance to say anything yet. Without this, shutting a laptop
            # lid for a minute took the manager and everything it was running.
            if ($slept -gt 5) { $script:LastSeen = $now; continue }
            if (-not $script:AutoQuit) { continue }
            if ($script:Shell) {
                # We own the window, so its process ending is the signal - and
                # the only one. A window that is covered by another app is
                # occluded, and Chrome throttles a page it cannot see until the
                # heartbeat below stops arriving. The manager read that as a
                # window that had closed and quit while its own window was
                # sitting there, taking the browsers and containers with it.
                if ($script:Shell.HasExited) {
                    $script:QuitReason = 'the manager window was closed'
                }
            } elseif ($script:LastSeen -and
                      ((Get-Date) - $script:LastSeen).TotalSeconds -gt $GraceSeconds) {
                # Nothing has connected yet ($LastSeen still null) means the
                # browser may still be starting, and a manager that quit before
                # its own window opened would be a fine joke.
                $script:QuitReason = 'the manager page stopped answering'
            }
            continue
        }
        $client = $listener.AcceptTcpClient()
        $stream = $client.GetStream()
        try {
            $request = Read-Request $stream
            if ($request) { Invoke-Route $stream $request }
        } catch {
            try { Send-Json $stream @{ error = $_.Exception.Message } 400 } catch { }
        } finally {
            $stream.Close()
            $client.Close()
        }
    }
} finally {
    $listener.Stop()
    if (-not $script:QuitReason) { $script:QuitReason = 'Ctrl-C' }
    Write-Host ""
    Write-Host "  Closing ($script:QuitReason)."
    Stop-Everything
    # Only if it is still ours: a manager that started over a stale file has
    # already been replaced there by the one that took the port.
    try {
        $mine = Get-Content $StateFile -Raw | ConvertFrom-Json
        if ($mine.pid -eq $PID) { Remove-Item $StateFile -Force -ErrorAction SilentlyContinue }
    } catch { }
    Write-Host "  Manager stopped."
}
