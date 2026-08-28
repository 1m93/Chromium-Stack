#
# EngineShelf - Docker edition (Windows)
#
# Runs the Linux x86_64 build of a version inside a container and shows its
# desktop in a tab of your normal browser. All four engines.
#
#   .\engineshelf-docker.ps1 start 74         # build if needed, run, open it
#   .\engineshelf-docker.ps1 start edge:95    # the only route to an Edge this old
#   .\engineshelf-docker.ps1 start firefox:52
#   .\engineshelf-docker.ps1 start webkit:16.4
#   .\engineshelf-docker.ps1 stop 74          # stop the container
#   .\engineshelf-docker.ps1 logs 74          # follow its log
#   .\engineshelf-docker.ps1 list             # what is running
#   .\engineshelf-docker.ps1 rebuild 74       # rebuild the image from scratch
#   .\engineshelf-docker.ps1 clean 74         # reset its profile, keep the image
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
# The other half of the catalog: milestones resolved against the live archive.
$EngineShelfHome = if ($env:ENGINESHELF_HOME) { $env:ENGINESHELF_HOME }
                   elseif ($env:BROWSERS_EMU_HOME) { $env:BROWSERS_EMU_HOME }
                   else { Join-Path $env:USERPROFILE '.engineshelf' }
$CatalogCache = Join-Path $EngineShelfHome 'catalog.cache.tsv'
. (Join-Path $ScriptDir 'lib\preflight.ps1')
# Where Firefox's and Edge's Linux downloads are resolved from - the same code
# the native launcher runs, rather than a second copy of each vendor's URLs.
. (Join-Path $ScriptDir 'lib\engines.ps1')
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
        Write-Host "  The native launcher needs nothing: .\engineshelf.ps1 run <version>" -ForegroundColor DarkGray
    }

    if (-not (Invoke-PfFix 'docker')) {
        Die "Docker is not available, so the Docker edition cannot run.
   Use the native launcher instead: .\engineshelf.ps1 run <version>"
    }
}

# The container always runs the Linux x86_64 build, whatever this host is, so a
# selector naming a Windows revision still resolves to the right image.
function Resolve-DockerTarget {
    param([string]$Raw)
    if (-not $Raw) {
        Die "Which version? A bare number is Chromium: 74. Otherwise name the engine:
   firefox:52   edge:95   webkit:16.4   chromium:120
   Try: .\engineshelf.ps1 catalog"
    }

    $engine = 'chromium'; $token = $Raw
    if ($Raw.Contains(':')) {
        $parts = $Raw.Split(':', 2)
        $engine = $parts[0].ToLower(); $token = $parts[1]
    }
    if ($Engines -notcontains $engine) {
        Die "Unknown engine: $engine. Known: $($Engines -join ' ')"
    }
    if ($engine -ne 'chromium') { return Resolve-DockerOther $engine $token }

    $token = $token -replace '^[MmRr]', ''
    if ($token -notmatch '^\d+$') { Die "Not a Chromium version or revision: $Raw" }

    # Both halves of the catalog, cache first - the same precedence the native
    # launcher uses. Reading only the shipped file is what made a container look
    # impossible for every milestone nobody had catalogued by hand.
    $lines = @()
    if (Test-Path $CatalogCache) { $lines += Get-Content $CatalogCache }
    $lines += Get-Content $Catalog
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
            return @{
                Engine = 'chromium'; Milestone = '?'; Version = "r$token"
                Revision = $token; Key = $token; BuildId = "r$token"
                Dockerfile = 'Dockerfile'; BuildArgs = @("REVISION=$token")
            }
        }
    }

    $version = $null; $revision = $null
    foreach ($line in $lines) {
        $f = $line -split "`t"
        if ($f[0] -eq 'V' -and $f[1] -eq $milestone) { $version = $f[2] }
        if ($f[0] -eq 'B' -and $f[1] -eq $milestone -and $f[2] -eq 'Linux_x64') { $revision = $f[3] }
    }
    if (-not $revision) {
        # Only twenty-odd milestones carry a hand-verified row, and the native
        # launcher has always asked the archive for the rest. This asks the same
        # question about the Linux build instead of refusing.
        Write-Host "   Chromium $milestone has no catalogued Linux build - asking the archive..." -ForegroundColor DarkGray
        $revision = & (Join-Path $ScriptDir 'engineshelf.ps1') resolve-for Linux_x64 $milestone 2>$null
        if ($revision) {
            $revision = "$revision".Trim()
            if (Test-Path $CatalogCache) {
                foreach ($line in Get-Content $CatalogCache) {
                    $f = $line -split "`t"
                    if ($f[0] -eq 'V' -and $f[1] -eq $milestone) { $version = $f[2] }
                }
            }
        }
    }
    if (-not $revision) { Die @"
No Linux x86_64 build of Chromium $milestone is available. It is in neither the
   catalog nor the cache, and the archive could not be reached to look it up.
"@ }
    if (-not $version) { $version = "r$revision" }
    return @{
        Engine = 'chromium'; Milestone = $milestone; Version = $version
        Revision = $revision
        # Chromium's image, container and volume have always been named after the
        # bare revision, so that stays its key - renaming it would orphan every
        # image already built.
        Key = $revision; BuildId = "r$revision"
        Dockerfile = 'Dockerfile'; BuildArgs = @("REVISION=$revision")
    }
}

<#
  The other three engines.

  WebKit is addressed by Playwright revision, which is platform-independent, so
  it only has to be looked up in the shelf. Firefox and Edge are addressed by
  version and need a download URL, which is resolved through lib/engines.ps1
  with the platform forced to Linux - the same code and the same pool listing the
  native launcher uses, so the two cannot disagree about which file is version 114.

  Worth saying plainly why Edge is here: the enterprise feed that serves mac and
  Windows holds about six months, so natively this host cannot reach Edge 114 or
  95 at any price. The Linux apt pool has kept every .deb since 2021. For an old
  Edge this image is not an alternative, it is the only route.
#>
function Resolve-DockerOther {
    param([string]$engine, [string]$token)

    if ($engine -eq 'webkit') {
        $revision = $null
        if ($token -match '^\d+$' -and [int64]$token -ge 1000) {
            $revision = $token
        } else {
            foreach ($line in Get-Content $Catalog) {
                $f = $line -split "`t"
                if ($f[0] -eq 'S' -and $f[1] -eq 'webkit' -and ($f[4] -eq $token -or $f[3] -eq $token)) {
                    $revision = $f[3]
                }
            }
        }
        if (-not $revision) {
            Die "No WebKit build known as $token.
   WebKit versions come from the shelf. Refresh it with:
       python3 tools/discover.py --write"
        }
        $label = "r$revision"
        foreach ($line in Get-Content $Catalog) {
            $f = $line -split "`t"
            if ($f[0] -eq 'S' -and $f[1] -eq 'webkit' -and $f[3] -eq $revision) { $label = $f[4] }
        }
        return @{
            Engine = 'webkit'; Milestone = '?'; Version = $label; Revision = $revision
            Key = "webkit-$revision"; BuildId = "r$revision"
            Dockerfile = 'Dockerfile.webkit'
            BuildArgs = @("REVISION=$revision", 'WEBKIT_PLATFORM=ubuntu-22.04')
        }
    }

    $sel = if ($engine -eq 'firefox') { Resolve-FirefoxLinux $token } else { Resolve-EdgeLinux $token }
    $prefix = if ($engine -eq 'firefox') { 'FIREFOX' } else { 'EDGE' }
    return @{
        Engine = $engine; Milestone = '?'; Version = $sel.Version; Revision = ''
        Key = "$engine-$($sel.Version)"; BuildId = $sel.Version
        Dockerfile = "Dockerfile.$engine"
        BuildArgs = @("${prefix}_URL=$($sel.Url)", "${prefix}_VERSION=$($sel.Version)")
    }
}

<#
  Firefox's Linux tarball.

  lib/engines.ps1 cannot answer this: it only ever builds the Windows URL,
  because Windows is the only host it runs on. The container is Linux whatever
  the host is, so the Linux URL has to be built here - the same two candidates
  lib/engines.sh tries, in the same order. Mozilla moved from bzip2 to xz partway
  through and the server is what decides which one exists.
#>
function Resolve-FirefoxLinux {
    param([string]$Token)
    $version = $Token
    if ($Token -match '^(?<major>\d*)[eE][sS][rR]$') {
        $version = Resolve-FirefoxEsr $Matches['major']
        if (-not $version) { Die "Could not find the ESR release for $Token." }
    } elseif ($Token -match '^\d+$') {
        $version = "$Token.0"          # a bare major: 115 -> 115.0
    }
    foreach ($ext in @('tar.xz', 'tar.bz2')) {
        $url = "$MozReleases/$version/linux-x86_64/en-US/firefox-$version.$ext"
        if (Test-UrlExists $url) { return @{ Version = $version; Url = $url } }
    }
    Die "No Linux build of Firefox $version at ftp.mozilla.org.
   Check the version exists: $MozReleases/"
}

<#
  Edge's Linux .deb, from the apt pool.

  This is the whole reason an Edge container exists. Microsoft's enterprise feed
  serves mac and Windows, holds about six months, and gates every file behind a
  per-file GUID - so lib/engines.ps1 refuses Edge outright, correctly, because
  nothing on Windows can be shelved. The pool has kept every .deb since 2021 at a
  URL that can be constructed, so this is the only route to an old Edge from any
  host.
#>
function Resolve-EdgeLinux {
    param([string]$Token)
    $pool = 'https://packages.microsoft.com/repos/edge/pool/main/m/microsoft-edge-stable'
    try {
        $index = Invoke-WebRequest -Uri "$pool/" -TimeoutSec 30 -UseBasicParsing
    } catch {
        Die "Could not read Microsoft's package pool: $($_.Exception.Message)"
    }
    $found = @([regex]::Matches([string]$index.Content,
                 'microsoft-edge-stable_([0-9.]+)-1_amd64\.deb') |
               ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    # A bare milestone matches on the first field; anything with a dot has to
    # match exactly. Newest wins, compared field by field rather than as text.
    $wanted = @($found | Where-Object {
        if ($Token.Contains('.')) { $_ -eq $Token } else { ($_ -split '\.')[0] -eq $Token }
    } | Sort-Object { [version]$_ })
    if ($wanted.Count -eq 0) {
        Die "Edge $Token is not in Microsoft's Linux package pool.
   It lists $($found.Count) builds. See $pool/"
    }
    $version = $wanted[-1]
    return @{ Version = $version; Url = "$pool/microsoft-edge-stable_$version-1_amd64.deb" }
}

# What to call this engine in a sentence.
function Get-DockerLabel {
    param($engine)
    $name = $EngineNames[$engine]
    if ($name) { return $name }
    return 'Chromium'
}

# One build, however many --build-arg this engine needs.
function Invoke-Build {
    param($target, [string]$image, [string[]]$extra)
    $argv = @('build') + $extra + @('--platform', 'linux/amd64',
        '-f', (Join-Path $DockerDir $target.Dockerfile))
    foreach ($a in $target.BuildArgs) { $argv += @('--build-arg', $a) }
    $argv += @('-t', $image, $DockerDir)
    & docker @argv
}

# These three names are the whole contract between this script and the manager:
# gui/server.ps1 reads them back to show which versions have an image, how much
# disk it costs and which containers are up, so a rename here has to happen
# there too (grep ContainerPrefix).
function Get-ImageName     { param($rev) "engineshelf:$rev" }
function Get-ContainerName { param($rev) "engineshelf-$rev" }
function Get-VolumeName    { param($rev) "engineshelf-profile-$rev" }

# Ports are handed out per container; ask Docker what a running one actually got
# rather than recomputing and guessing wrong.
function Get-RunningPort {
    param($rev)
    $mapping = docker port (Get-ContainerName $rev) 6080 2>$null
    if (-not $mapping) { return $null }
    return ($mapping -split ':')[-1].Trim()
}

# --screen WxH, pulled out of the arguments wherever it sits so the commands
# below keep reading plain positional selectors.
#
# The virtual screen has been 1440x900 since the first image, baked into the
# Dockerfile, and every desktop is shown scaled to fit the browser tab: on a
# display of any other shape that leaves bars down the sides, and on a bigger one
# the whole desktop is rendered smaller than the window showing it. The
# framebuffer cannot be resized once Xvfb is up, so the size is settled here.
function Resolve-Screen {
    param([string]$Value)
    if (-not $Value) { return $null }
    if ($Value -notmatch 'x[0-9]+$' -or ($Value -split 'x').Count -lt 3) {
        if ($Value -match '^\d+x\d+$') { $Value = "${Value}x24" }
    }
    if ($Value -notmatch '^\d{3,4}x\d{3,4}x(16|24|32)$') {
        Die "Screen must be WIDTHxHEIGHT, e.g. 1920x1080 (got: $Value)"
    }
    return $Value
}

function Get-FreePort {
    param([int]$From = 0)
    if ($From -lt $BasePort) { $From = $BasePort }
    $used = @()
    $listeners = [Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()
    foreach ($listener in $listeners) { $used += $listener.Port }
    for ($port = $From; $port -lt $BasePort + 60; $port++) {
        if ($used -notcontains $port) { return $port }
    }
    Die "No free port between $BasePort and $($BasePort + 60)."
}

# Published on the loopback address only. The desktop in there has no password
# and a real browser attached to it, and the rest of EngineShelf is careful to
# stay off the network; a plain -p put it in front of everyone on the wifi.
#
# Between choosing a port and binding it another container can take it, and that
# is exactly what happens when two versions are started together: both saw 6080
# free, the second lost the race and reported "Could not start the container".
# Docker is the only thing that can answer for certain, so a refused binding
# moves up a port and tries again instead of ending the launch.
function Start-Container {
    param($Image, $Container, $Volume)
    $floor = $BasePort
    for ($attempt = 0; $attempt -lt 6; $attempt++) {
        $port = Get-FreePort $floor
        # No device passthrough here on purpose: Docker Desktop on Windows runs
        # this in a Linux VM with no USB behind it, so there is no camera to
        # hand over and the image stands a fake one in. INSECURE_ORIGINS is the
        # one thing worth forwarding - it names a dev-server origin the browser
        # in there should treat as secure, for the ports the image does not
        # already list.
        $extra = @()
        if ($env:INSECURE_ORIGINS) { $extra = @('-e', "INSECURE_ORIGINS=$($env:INSECURE_ORIGINS)") }
        # The virtual screen, when one was asked for. Unset means the image's own
        # default, which is what every container built so far has run.
        if ($script:ScreenArg) { $extra += @('-e', "SCREEN=$($script:ScreenArg)") }
        $output = docker run -d --name $Container --platform linux/amd64 `
            -p "127.0.0.1:${port}:6080" -v "${Volume}:/data" `
            --add-host 'host.docker.internal:host-gateway' --shm-size=1g @extra $Image 2>&1
        if ($LASTEXITCODE -eq 0) { return $port }
        # A named container that failed to start still exists, and the next
        # attempt cannot reuse the name until it is gone.
        docker rm -f $Container 2>&1 | Out-Null
        $text = ($output | Out-String)
        if ($text -match 'already allocated|address already in use|Bind for') {
            $floor = $port + 1
        } else {
            Write-Host $text
            return $null
        }
    }
    Write-Host "  Every port tried was taken by something else."
    return $null
}

function Invoke-ImageOnly {
    <#
      Build the image and stop there. The native side has always been able to
      download without launching - a shelf you fill now and use later - and this
      is that, for the container: the multi-minute build happens when it suits,
      not in front of someone waiting for a browser.
    #>
    param($target, [bool]$ForceBuild)
    Test-Docker
    $image = Get-ImageName $target.Key

    Write-Host ""
    Write-Host "  $(Get-DockerLabel $target.Engine) $($target.Version) in Docker (image only)" -ForegroundColor White
    Write-Host ""
    if (-not $ForceBuild) {
        docker image inspect $image 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Ok "The image is already built. Run it with: .\engineshelf-docker.ps1 start $Selector"
            return
        }
    }
    if ($ForceBuild) {
        Write-Host "  Rebuilding the image from scratch. Several minutes." -ForegroundColor DarkGray
        Invoke-Build $target $image @('--no-cache')
    } else {
        Write-Host "  Building the image. Several minutes, once." -ForegroundColor DarkGray
        Invoke-Build $target $image @()
    }
    Write-Host ""
    Write-Ok "Built. Nothing is running: start $Selector opens it."
}

function Invoke-Start {
    param($target, [bool]$ForceBuild)
    Test-Docker

    $image     = Get-ImageName $target.Key
    $container = Get-ContainerName $target.Key
    $volume    = Get-VolumeName $target.Key

    $running = docker ps --format '{{.Names}}' 2>$null
    if ($running -contains $container) {
        $port = Get-RunningPort $target.Key
        $url = "http://localhost:$port/vnc.html?autoconnect=1&resize=scale"
        Write-Host ""
        Write-Host "  > $(Get-DockerLabel $target.Engine) $($target.Version) is already running  $url" -ForegroundColor Green
        Start-Process $url | Out-Null
        return
    }
    docker rm -f $container 2>&1 | Out-Null

    Write-Host ""
    Write-Host "  $(Get-DockerLabel $target.Engine) $($target.Version) in Docker (Linux x86_64 $($target.BuildId))" -ForegroundColor White
    Write-Host ""

    # Build only when the image is missing or a rebuild was asked for: a
    # from-scratch build is a multi-minute wait.
    $haveImage = $true
    docker image inspect $image 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { $haveImage = $false }

    if ($ForceBuild) {
        Write-Host "  Rebuilding the image from scratch..." -ForegroundColor DarkGray
        Invoke-Build $target $image @('--no-cache')
        if ($LASTEXITCODE -ne 0) { Die "Image build failed." }
    } elseif (-not $haveImage) {
        Write-Host "  First run for this version: building the image. Several minutes, once." -ForegroundColor DarkGray
        Invoke-Build $target $image @()
        if ($LASTEXITCODE -ne 0) { Die "Image build failed." }
    }

    $port = Start-Container $image $container $volume
    if (-not $port) { Die "Could not start the container." }

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
    if (-not $ok) { Die "No answer on port $port. Check: .\engineshelf-docker.ps1 logs $($target.Key)" }

    Write-Host ""
    Write-Host "  > $url" -ForegroundColor Green
    Write-Host "  Copy and paste work across the tab in both directions." -ForegroundColor DarkGray
    Write-Host "  To reach a dev server on this machine, type" -ForegroundColor DarkGray
    Write-Host "  http://host.docker.internal:4173 in the Chromium address bar." -ForegroundColor DarkGray
    Write-Host "  Stop it with: .\engineshelf-docker.ps1 stop $Selector" -ForegroundColor DarkGray
    Write-Host ""
    Start-Process $url | Out-Null
}

# The screen, read off the arguments before anything is dispatched. Either
# spelling, and the SCREEN environment variable as the fallback the shell
# launcher also honours.
$script:ScreenArg = Resolve-Screen $env:SCREEN
for ($i = 0; $i -lt $Rest.Count; $i++) {
    if ($Rest[$i] -eq '--screen' -and $i + 1 -lt $Rest.Count) {
        $script:ScreenArg = Resolve-Screen $Rest[$i + 1]
    } elseif ($Rest[$i] -like '--screen=*') {
        $script:ScreenArg = Resolve-Screen $Rest[$i].Substring(9)
    }
}

switch -Regex ($Command) {
    '^(start|up)$' { Invoke-Start (Resolve-DockerTarget $Selector) $false; break }
    '^(build|get)$' { Invoke-ImageOnly (Resolve-DockerTarget $Selector) $false; break }
    '^rebuild$'    { Invoke-Start (Resolve-DockerTarget $Selector) $true; break }
    '^(stop|down)$' {
        $target = Resolve-DockerTarget $Selector
        Test-Docker
        $container = Get-ContainerName $target.Key
        # SIGTERM before SIGKILL, so the browser inside gets to close its
        # profile. A container removed outright left a lock in the profile volume
        # that stopped the next start of this version dead; the entrypoint clears
        # a stale one now, but stopping politely is still the right way round.
        $live = docker ps --format '{{.Names}}' 2>$null
        if ($live -contains $container) {
            docker stop -t 12 $container 2>&1 | Out-Null
            docker rm -f $container 2>&1 | Out-Null
            Write-Ok "Stopped $(Get-DockerLabel $target.Engine) $($target.Version)."
        } else {
            docker rm -f $container 2>&1 | Out-Null
            Write-Host "$(Get-DockerLabel $target.Engine) $($target.Version) was not running." -ForegroundColor DarkGray
        }
        break
    }
    '^logs$' {
        $target = Resolve-DockerTarget $Selector
        Test-Docker
        docker logs -f (Get-ContainerName $target.Key)
        break
    }
    '^(list|ls|ps)$' {
        Test-Docker
        Write-Host ""
        Write-Host "Containers" -ForegroundColor White
        docker ps -a --filter 'name=engineshelf-' --format '  {{.Names}}`t{{.Status}}`t{{.Ports}}'
        Write-Host ""
        Write-Host "Images" -ForegroundColor White
        docker images 'engineshelf' --format '  {{.Repository}}:{{.Tag}}`t{{.Size}}'
        Write-Host ""
        break
    }
    '^clean$' {
        # The other side of `engineshelf.ps1 clean`: the profile goes, the image
        # stays. A volume in use cannot be removed and the container holding it
        # is this version's own, so that goes first.
        $target = Resolve-DockerTarget $Selector
        Test-Docker
        docker rm -f (Get-ContainerName $target.Key) 2>&1 | Out-Null
        docker volume rm -f (Get-VolumeName $target.Key) 2>&1 | Out-Null
        Write-Ok "Profile reset for $(Get-DockerLabel $target.Engine) $($target.Version) in Docker."
        break
    }
    '^purge$' {
        $target = Resolve-DockerTarget $Selector
        Test-Docker
        docker rm -f (Get-ContainerName $target.Key) 2>&1 | Out-Null
        docker rmi -f (Get-ImageName $target.Key) 2>&1 | Out-Null
        if ($Rest -contains '--with-profile') {
            docker volume rm -f (Get-VolumeName $target.Key) 2>&1 | Out-Null
        }
        Write-Ok "Removed the Docker image for $(Get-DockerLabel $target.Engine) $($target.Version)."
        break
    }
    default {
        Write-Host ""
        Write-Host "EngineShelf - Docker edition (Windows)" -ForegroundColor White
        Write-Host ""
        Write-Host "  .\engineshelf-docker.ps1 start <version>"
        Write-Host "  .\engineshelf-docker.ps1 stop <version>"
        Write-Host "  .\engineshelf-docker.ps1 logs <version>"
        Write-Host "  .\engineshelf-docker.ps1 rebuild <version>"
        Write-Host "  .\engineshelf-docker.ps1 clean <version>"
        Write-Host "  .\engineshelf-docker.ps1 purge <version> [--with-profile]"
        Write-Host "  .\engineshelf-docker.ps1 list"
        Write-Host ""
    }
}
