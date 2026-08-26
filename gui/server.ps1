#
# ChromiumStack GUI backend (Windows).
#
# Serves the static page in this directory and the same small JSON API as
# gui/server.py. All real work - install, launch, remove, reset - is delegated to
# chromium-stack.ps1, so the GUI and the command line cannot drift apart.
#
# This speaks HTTP over a raw TcpListener rather than System.Net.HttpListener on
# purpose: HttpListener needs a netsh URL ACL reservation or an elevated prompt,
# and this tool is not worth either. A TcpListener on a loopback high port needs
# no privileges at all.
#
# Bound to 127.0.0.1 and gated on a per-run token, so a web page you happen to
# have open cannot drive your browser installs.
#
[CmdletBinding()]
param(
    [int]$Port = 7411,
    [switch]$NoOpen
)

$ErrorActionPreference = 'Stop'

$Here    = Split-Path -Parent $MyInvocation.MyCommand.Path
$Project = Split-Path -Parent $Here
$Catalog = Join-Path $Project 'catalog.tsv'
$Cli       = Join-Path $Project 'chromium-stack.ps1'
$DockerCli = Join-Path $Project 'chromium-stack-docker.ps1'

if (-not (Test-Path $Cli)) { throw "Missing $Cli" }

$Token = [Convert]::ToBase64String([Guid]::NewGuid().ToByteArray()) -replace '[^A-Za-z0-9]', ''

if ($env:CHROMIUM_STACK_HOME)   { $Root = $env:CHROMIUM_STACK_HOME }
elseif ($env:BROWSERS_EMU_HOME) { $Root = $env:BROWSERS_EMU_HOME }
else                          { $Root = Join-Path $env:USERPROFILE '.chromium-stack' }
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
    foreach ($path in @($Catalog, $CacheFile)) {
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
            -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Cli, 'catalog') | Out-Null
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

function Get-InstalledBuilds {
    $result = @{}
    if (-not (Test-Path $BuildsDir)) { return $result }
    foreach ($dir in Get-ChildItem -Path $BuildsDir -Directory -ErrorAction SilentlyContinue) {
        if ($dir.Name -notmatch '^\d+$') { continue }
        if (-not (Test-Path (Join-Path $dir.FullName '.complete'))) { continue }
        $meta = @{}
        $metaPath = Join-Path $dir.FullName '.meta'
        if (Test-Path $metaPath) {
            foreach ($line in Get-Content $metaPath) {
                if ($line -match "^([A-Z_]+)='(.*)'$") { $meta[$Matches[1]] = $Matches[2] }
            }
        }
        $version = $meta['META_VERSION']; if (-not $version) { $version = "r$($dir.Name)" }
        $platform = $meta['META_PLATFORM']; if (-not $platform) { $platform = '?' }
        $milestone = $meta['META_MILESTONE']; if (-not $milestone) { $milestone = '?' }
        $result[[int]$dir.Name] = @{
            revision     = [int]$dir.Name
            version      = $version
            platformDir  = $platform
            milestone    = $milestone
            installedAt  = $meta['META_INSTALLED']
            sizeBytes    = Get-DirSize $dir.FullName
            profileBytes = Get-DirSize (Join-Path $ProfilesDir $dir.Name)
        }
    }
    return $result
}

# The names chromium-stack-docker.ps1 gives the things it creates. The manager
# reads them back, which is the only way a version living in a container can look
# like one living on disk; renaming any of them means changing both files.
$ContainerPrefix = 'chromium-stack-'
$ImageRepo       = 'chromium-stack'
$VolumePrefix    = 'chromium-stack-profile-'

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
      What Docker is holding for ChromiumStack: images, their size, containers.

      Without this the shelf could say nothing true about a version that runs in
      a container - no size for an image costing a gigabyte, and no sign it was
      running at all, because the job that starts a container exits as soon as
      the desktop answers.
    #>
    if ($script:DockerCache.Value -and
        ((Get-Date) - $script:DockerCache.At).TotalSeconds -lt 10) {
        return $script:DockerCache.Value
    }

    $cli = $null -ne (Get-Command docker -ErrorAction SilentlyContinue)
    $running = $false
    $containers = @()
    $byRevision = @{}
    if ($cli) {
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
        # One image per version, tagged with the revision it was built from. The
        # tag list is cheap; the exact byte count needs an inspect, because
        # `docker images` only prints a rounded decimal string.
        $tags = @(docker images $ImageRepo --format '{{.Tag}}' 2>$null |
                  Where-Object { $_ -and $_ -ne '<none>' })
        if ($tags.Count) {
            $refs = @($tags | ForEach-Object { "${ImageRepo}:$_" })
            $sizes = @(docker image inspect --format '{{.Size}}' @refs 2>$null)
            for ($i = 0; $i -lt $tags.Count -and $i -lt $sizes.Count; $i++) {
                $slot = Get-Slot $byRevision $tags[$i]
                $slot.imageBytes = [int64]$sizes[$i]
            }
        }

        # One container per version, named chromium-stack-<revision>. Stopped
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
        cli = $cli; running = $running; containers = @($containers)
        supported = (Test-Path $DockerCli)
        byRevision = $byRevision
        imageBytes = $imageBytes
        profileBytes = $profileBytes
    }
    $script:DockerCache = @{ At = (Get-Date); Value = $value }
    return $value
}

function Get-DockerRow {
    <#
      The Docker side of one shelf row, or $null if there is nothing to offer.

      A container always runs the Linux x86_64 build, so its revision is not the
      one this host installs natively - and comparing those two is exactly what
      used to hide a running container from the row it belonged to.
    #>
    param($Revision, $Status)
    if ($null -eq $Revision -or -not $Status.supported) { return $null }
    $entry = $Status.byRevision[[string]$Revision]
    if (-not $entry) { $entry = @{ imageBytes = 0; profileBytes = 0; state = $null; status = ''; port = $null } }
    return @{
        revision = $Revision
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

function Get-State {
    $catalog = Read-Catalog
    $installed = Get-InstalledBuilds
    $docker = Get-DockerStatus
    $rows = New-Object System.Collections.ArrayList
    $catalogued = @{}

    foreach ($entry in $catalog.versions) {
        $m = $entry.milestone
        $row = @{ milestone = $m; version = $entry.version; note = $entry.note; native = $true }
        $row.docker = Get-DockerRow (Get-LinuxRevision $catalog.builds $m) $docker
        if ($catalog.builds.ContainsKey($m) -and $catalog.builds[$m].ContainsKey($HostPlatform)) {
            $b = $catalog.builds[$m][$HostPlatform]
            $row.platformDir = $HostPlatform
            $row.supported = $true
            $row.revision = $b.revision
            $catalogued[$b.revision] = $true
            if ($installed.ContainsKey($b.revision)) {
                $local = $installed[$b.revision]
                $row.installed = $true
                $row.sizeBytes = $local.sizeBytes
                $row.profileBytes = $local.profileBytes
                $row.installedAt = $local.installedAt
            } else {
                $row.installed = $false; $row.sizeBytes = 0; $row.profileBytes = 0; $row.installedAt = ''
            }
        } else {
            $row.platformDir = $null; $row.supported = $false; $row.revision = $null
            $row.installed = $false; $row.sizeBytes = 0; $row.profileBytes = 0; $row.installedAt = ''
        }
        [void]$rows.Add($row)
    }

    # Builds installed by raw revision that no catalogue row claims. A container
    # for one of these still runs the Linux build of whatever milestone it
    # belongs to, so it is looked up the same way the launcher looks it up.
    $extra = New-Object System.Collections.ArrayList
    foreach ($rev in ($installed.Keys | Sort-Object)) {
        if ($catalogued.ContainsKey($rev)) { continue }
        $row = $installed[$rev].Clone()
        $row.note = 'Installed by revision.'
        $row.supported = $true
        $row.native = $true
        $row.installed = $true
        $milestone = Get-MilestoneOf $catalog.builds $rev
        $dockerRev = if ($null -ne $milestone) { Get-LinuxRevision $catalog.builds $milestone } else { $rev }
        $row.docker = Get-DockerRow $dockerRev $docker
        [void]$extra.Add($row)
    }

    $total = 0
    foreach ($info in $installed.Values) { $total += $info.sizeBytes + $info.profileBytes }

    return @{
        root = $Root
        os = 'windows'
        arch = $env:PROCESSOR_ARCHITECTURE
        hostPlatforms = @($HostPlatform)
        versions = $rows
        extra = $extra
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
# Each job is a child powershell running chromium-stack.ps1 with its output
# redirected to a file, so the HTTP loop never blocks on a long download or on a
# browser window that stays open for an hour.
$script:Jobs = @{}
$script:NextJob = 1

function Start-Job2 {
    param([string]$Kind, [string]$Revision, [string[]]$CliArgs, [string]$Label, [string]$Script = $null)
    if (-not $Script) { $Script = $Cli }

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
function ConvertTo-Json2 { param($obj) $obj | ConvertTo-Json -Depth 8 -Compress }

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
    $hostHeader = ''
    if ($Request.headers.ContainsKey('host')) { $hostHeader = ($Request.headers['host'] -split ':')[0] }
    if ($hostHeader -ne '127.0.0.1' -and $hostHeader -ne 'localhost') { return $false }
    if (-not $Request.headers.ContainsKey('x-chromiumstack-token')) { return $false }
    return $Request.headers['x-chromiumstack-token'] -ceq $Token
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

# ---------- routing ----------
function Invoke-Route {
    param($Stream, $Request)

    $path = ($Request.path -split '\?')[0]

    if ($Request.method -eq 'GET') {
        if ($path -eq '/api/token') { Send-Json $Stream @{ token = $Token }; return }

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
        Send-Json $Stream @{ stopped = (Stop-Job2 $jobId) }; return
    }

    $selector = [string](Get-Field $body 'selector')
    if ($selector -notmatch '^\d+$') { Send-Json $Stream @{ error = 'bad selector' } 400; return }

    switch ($path) {
        '/api/install' {
            $id = Start-Job2 'install' $selector @('install', $selector) "Installing Chromium $selector"
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
            $id = Start-Job2 'launch' $selector $cliArgs "Chromium $selector"
            Send-Json $Stream @{ job = $id }; return
        }
        '/api/remove' {
            $cliArgs = @('remove', $selector)
            if (Get-Field $body 'withProfile') { $cliArgs += '--with-profile' }
            $id = Start-Job2 'remove' $selector $cliArgs "Removing $selector"
            Send-Json $Stream @{ job = $id }; return
        }
        '/api/clean' {
            $id = Start-Job2 'clean' $selector @('clean', $selector) "Resetting profile $selector"
            Send-Json $Stream @{ job = $id }; return
        }
        '/api/docker' {
            $action = [string](Get-Field $body 'action')
            if (-not $action) { $action = 'start' }
            if (@('start', 'stop', 'rebuild', 'purge') -notcontains $action) {
                Send-Json $Stream @{ error = 'bad action' } 400; return
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
Write-Host ""
Write-Host "  ChromiumStack manager  ->  $url"
Write-Host "  Files: $Root"
Write-Host "  Press Ctrl-C to stop the manager (running browsers stay open)."
Write-Host ""

# Off the startup path: it talks to the network, and the page is perfectly usable
# from the shipped catalog while it runs. The next refresh picks up what it found.
Update-CatalogCache

if (-not $NoOpen) { Start-Process $url | Out-Null }

try {
    while ($true) {
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
    Write-Host ""
    Write-Host "  Manager stopped."
}
