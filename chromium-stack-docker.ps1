#
# ChromiumStack - Docker edition (Windows)
#
# Runs the Linux x86_64 build of a Chromium version inside a container and shows
# its desktop in a tab of your normal browser.
#
#   .\chromium-stack-docker.ps1 start 74     # build if needed, run, open the desktop
#   .\chromium-stack-docker.ps1 stop 74      # stop the container
#   .\chromium-stack-docker.ps1 logs 74      # follow its log
#   .\chromium-stack-docker.ps1 list         # what is running
#   .\chromium-stack-docker.ps1 rebuild 74   # rebuild the image from scratch
#
# Each version gets its own image, container, profile volume and port, so several
# can run side by side.
#
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Command = '',
    [Parameter(Position = 1)][string]$Selector = '',
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest = @()
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Catalog   = Join-Path $ScriptDir 'catalog.tsv'
. (Join-Path $ScriptDir 'lib\preflight.ps1')
$DockerDir = Join-Path $ScriptDir 'docker'
$BasePort  = 6080

function Write-Ok { param($m) Write-Host "OK $m" -ForegroundColor Green }
function Die      { param($m) Write-Host "X  $m" -ForegroundColor Red; exit 1 }

if (-not (Test-Path $Catalog)) { Die "Missing catalog: $Catalog" }

function Test-Docker {
    # Install and start live in lib/preflight.ps1 so the CLI, this script and
    # the manager all offer the same thing, in the same words, with the same
    # consent.
    $status = Get-PfStatus 'docker'
    if ($status -eq 'ok') { return }

    if ($status -eq 'missing') {
        Write-Host ""
        Write-Host "  The Docker edition needs Docker, which is not installed." -ForegroundColor White
        Write-Host "  The native launcher needs nothing: .\chromium-stack.ps1 run <version>" -ForegroundColor DarkGray
    }

    if (-not (Invoke-PfFix 'docker')) {
        Die "Docker is not available, so the Docker edition cannot run.
   Use the native launcher instead: .\chromium-stack.ps1 run <version>"
    }
}

# The container always runs the Linux x86_64 build, whatever this host is, so a
# selector naming a Windows revision still resolves to the right image.
function Resolve-DockerTarget {
    param([string]$Raw)
    if (-not $Raw) { Die "Which version? e.g. 74. Try: .\chromium-stack.ps1 catalog" }
    $token = $Raw -replace '^[MmRr]', ''
    if ($token -notmatch '^\d+$') { Die "Not a version or revision: $Raw" }

    $lines = Get-Content $Catalog
    $milestone = $null
    if ([int64]$token -lt 1000) {
        $milestone = $token
    } else {
        foreach ($line in $lines) {
            $f = $line -split "`t"
            if ($f[0] -eq 'B' -and $f[3] -eq $token) { $milestone = $f[1]; break }
        }
        if (-not $milestone) {
            # An uncatalogued revision: assume the caller means that exact build.
            return @{ Milestone = '?'; Version = "r$token"; Revision = $token }
        }
    }

    $version = $null; $revision = $null
    foreach ($line in $lines) {
        $f = $line -split "`t"
        if ($f[0] -eq 'V' -and $f[1] -eq $milestone) { $version = $f[2] }
        if ($f[0] -eq 'B' -and $f[1] -eq $milestone -and $f[2] -eq 'Linux_x64') { $revision = $f[3] }
    }
    if (-not $revision) { Die "No Linux x86_64 build of Chromium $milestone in the catalog." }
    if (-not $version) { $version = "r$revision" }
    return @{ Milestone = $milestone; Version = $version; Revision = $revision }
}

function Get-ImageName     { param($rev) "chromium-stack:$rev" }
function Get-ContainerName { param($rev) "chromium-stack-$rev" }
function Get-VolumeName    { param($rev) "chromium-stack-profile-$rev" }

# Ports are handed out per container; ask Docker what a running one actually got
# rather than recomputing and guessing wrong.
function Get-RunningPort {
    param($rev)
    $mapping = docker port (Get-ContainerName $rev) 6080 2>$null
    if (-not $mapping) { return $null }
    return ($mapping -split ':')[-1].Trim()
}

function Get-FreePort {
    $used = @()
    $listeners = [Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()
    foreach ($listener in $listeners) { $used += $listener.Port }
    for ($port = $BasePort; $port -lt $BasePort + 60; $port++) {
        if ($used -notcontains $port) { return $port }
    }
    Die "No free port between $BasePort and $($BasePort + 60)."
}

function Invoke-Start {
    param($target, [bool]$ForceBuild)
    Test-Docker

    $image     = Get-ImageName $target.Revision
    $container = Get-ContainerName $target.Revision
    $volume    = Get-VolumeName $target.Revision

    $running = docker ps --format '{{.Names}}' 2>$null
    if ($running -contains $container) {
        $port = Get-RunningPort $target.Revision
        $url = "http://localhost:$port/vnc.html?autoconnect=1&resize=scale"
        Write-Host ""
        Write-Host "  > Chromium $($target.Version) is already running  $url" -ForegroundColor Green
        Start-Process $url | Out-Null
        return
    }
    docker rm -f $container 2>&1 | Out-Null

    Write-Host ""
    Write-Host "  Chromium $($target.Version) in Docker (Linux_x64 r$($target.Revision))" -ForegroundColor White
    Write-Host ""

    # Build only when the image is missing or a rebuild was asked for: a
    # from-scratch build is a multi-minute wait.
    $haveImage = $true
    docker image inspect $image 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { $haveImage = $false }

    if ($ForceBuild) {
        Write-Host "  Rebuilding the image from scratch..." -ForegroundColor DarkGray
        docker build --no-cache --platform linux/amd64 --build-arg "REVISION=$($target.Revision)" -t $image $DockerDir
        if ($LASTEXITCODE -ne 0) { Die "Image build failed." }
    } elseif (-not $haveImage) {
        Write-Host "  First run for this version: building the image. Several minutes, once." -ForegroundColor DarkGray
        docker build --platform linux/amd64 --build-arg "REVISION=$($target.Revision)" -t $image $DockerDir
        if ($LASTEXITCODE -ne 0) { Die "Image build failed." }
    }

    $port = Get-FreePort
    docker run -d --name $container --platform linux/amd64 `
        -p "${port}:6080" -v "${volume}:/data" `
        --add-host 'host.docker.internal:host-gateway' --shm-size=1g $image | Out-Null
    if ($LASTEXITCODE -ne 0) { Die "Could not start the container." }

    $url = "http://localhost:$port/vnc.html?autoconnect=1&resize=scale"
    Write-Host "  Waiting for the desktop" -NoNewline
    $ok = $false
    for ($i = 0; $i -lt 60; $i++) {
        try {
            Invoke-WebRequest -Uri "http://localhost:$port/vnc.html" -TimeoutSec 2 -UseBasicParsing | Out-Null
            $ok = $true
            break
        } catch { }
        $alive = docker ps --format '{{.Names}}' 2>$null
        if ($alive -notcontains $container) {
            Write-Host ""
            docker logs --tail 20 $container
            Die "The container exited while starting."
        }
        Write-Host "." -NoNewline
        Start-Sleep -Seconds 1
    }
    Write-Host ""
    if (-not $ok) { Die "No answer on port $port. Check: .\chromium-stack-docker.ps1 logs $($target.Revision)" }

    Write-Host ""
    Write-Host "  > $url" -ForegroundColor Green
    Write-Host "  To reach a dev server on this machine, type" -ForegroundColor DarkGray
    Write-Host "  http://host.docker.internal:4173 in the Chromium address bar." -ForegroundColor DarkGray
    Write-Host "  Stop it with: .\chromium-stack-docker.ps1 stop $($target.Milestone)" -ForegroundColor DarkGray
    Write-Host ""
    Start-Process $url | Out-Null
}

switch -Regex ($Command) {
    '^(start|up)$' { Invoke-Start (Resolve-DockerTarget $Selector) $false; break }
    '^rebuild$'    { Invoke-Start (Resolve-DockerTarget $Selector) $true; break }
    '^(stop|down)$' {
        $target = Resolve-DockerTarget $Selector
        Test-Docker
        docker rm -f (Get-ContainerName $target.Revision) 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Ok "Stopped Chromium $($target.Version)." }
        else { Write-Host "Chromium $($target.Version) was not running." -ForegroundColor DarkGray }
        break
    }
    '^logs$' {
        $target = Resolve-DockerTarget $Selector
        Test-Docker
        docker logs -f (Get-ContainerName $target.Revision)
        break
    }
    '^(list|ls|ps)$' {
        Test-Docker
        Write-Host ""
        Write-Host "Containers" -ForegroundColor White
        docker ps -a --filter 'name=chromium-stack-' --format '  {{.Names}}`t{{.Status}}`t{{.Ports}}'
        Write-Host ""
        Write-Host "Images" -ForegroundColor White
        docker images 'chromium-stack' --format '  {{.Repository}}:{{.Tag}}`t{{.Size}}'
        Write-Host ""
        break
    }
    '^purge$' {
        $target = Resolve-DockerTarget $Selector
        Test-Docker
        docker rm -f (Get-ContainerName $target.Revision) 2>&1 | Out-Null
        docker rmi -f (Get-ImageName $target.Revision) 2>&1 | Out-Null
        if ($Rest -contains '--with-profile') {
            docker volume rm -f (Get-VolumeName $target.Revision) 2>&1 | Out-Null
        }
        Write-Ok "Removed the Docker image for Chromium $($target.Version)."
        break
    }
    default {
        Write-Host ""
        Write-Host "ChromiumStack - Docker edition (Windows)" -ForegroundColor White
        Write-Host ""
        Write-Host "  .\chromium-stack-docker.ps1 start <version>"
        Write-Host "  .\chromium-stack-docker.ps1 stop <version>"
        Write-Host "  .\chromium-stack-docker.ps1 logs <version>"
        Write-Host "  .\chromium-stack-docker.ps1 rebuild <version>"
        Write-Host "  .\chromium-stack-docker.ps1 purge <version> [--with-profile]"
        Write-Host "  .\chromium-stack-docker.ps1 list"
        Write-Host ""
    }
}
