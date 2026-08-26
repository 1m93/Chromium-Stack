#
# EngineShelf - dependency checks (Windows).
#
# Dot-sourced, never run directly:
#   . "$ScriptDir\lib\preflight.ps1"
#
# Mirrors lib/preflight.sh: same component ids, same status words, same JSON, so
# the manager renders Windows and macOS/Linux with one code path.
#
# Windows needs far less than the others. PowerShell 5.1 ships with the OS and
# runs both the launcher and the manager, downloads go through
# Invoke-WebRequest and archives through System.IO.Compression - so python3,
# curl, unzip and Rosetta are all reported "na" rather than pretended to matter.

function Test-Have { param([string]$Name) $null -ne (Get-Command $Name -ErrorAction SilentlyContinue) }

function Get-PfStatus {
    param([string]$Component)
    switch ($Component) {
        'docker' {
            if (-not (Test-Have docker)) { return 'missing' }
            docker info 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { return 'ok' } else { return 'inactive' }
        }
        default { return 'na' }
    }
}

function Get-PfLabel {
    param([string]$Component)
    switch ($Component) {
        'python3' { 'Python 3' }
        'curl'    { 'curl' }
        'unzip'   { 'unzip' }
        'docker'  { 'Docker' }
        'rosetta' { 'Rosetta 2' }
    }
}

function Get-PfNeed {
    param([string]$Component)
    switch ($Component) {
        'docker' { 'optional' }
        'curl'   { 'required' }
        'unzip'  { 'required' }
        default  { 'recommended' }
    }
}

function Get-PfWhy {
    param([string]$Component)
    switch ($Component) {
        'python3' { 'Not needed on Windows - the manager runs on PowerShell.' }
        'curl'    { 'Not needed on Windows - downloads use Invoke-WebRequest.' }
        'unzip'   { 'Not needed on Windows - archives are extracted by .NET.' }
        'rosetta' { 'Apple Silicon only.' }
        'docker'  { 'Only for the Docker edition, which runs the Linux build in a container.' }
    }
}

function Get-PfFix {
    param([string]$Component, [string]$Status)
    if ($Component -ne 'docker') { return '' }
    if ($Status -eq 'inactive') {
        # Start whatever is already on the machine. Nothing new is pulled in here,
        # so Docker Desktop is fair game if the user chose to install it.
        $desktop = Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'
        if (Test-Path $desktop) { return "Start `"$desktop`"" }
        if (Test-Have wsl) { return 'wsl -e sudo service docker start' }
        return ''
    }
    # The docker CLI on its own - never Docker Desktop. Desktop is over a GB, wants
    # admin rights and a reboot, and its licence is only free for small companies;
    # this tool asks for none of that on the other platforms and will not here.
    # The engine the CLI talks to is a separate decision - see Get-PfNote.
    if (Test-Have winget) { return 'winget install -e --id Docker.DockerCLI' }
    return ''
}

function Get-PfNote {
    param([string]$Component, [string]$Status)
    if ($Component -ne 'docker') { return '' }
    if ($Status -eq 'inactive') { return 'Starts what is already installed. Nothing is downloaded.' }
    return 'The docker CLI only, about 50 MB - not Docker Desktop. It still needs an engine to talk to: Docker Engine inside a WSL 2 distro (wsl --install).'
}

$PfComponents = @('curl', 'unzip', 'python3', 'rosetta', 'docker')

function Get-PfReport {
    $components = foreach ($id in $PfComponents) {
        $status = Get-PfStatus $id
        [ordered]@{
            id = $id; label = (Get-PfLabel $id); status = $status
            need = (Get-PfNeed $id); why = (Get-PfWhy $id)
            fix = (Get-PfFix $id $status); note = (Get-PfNote $id $status)
        }
    }
    return [ordered]@{
        os = 'windows'
        arch = $env:PROCESSOR_ARCHITECTURE
        components = @($components)
    }
}

function Show-PfReport {
    $report = Get-PfReport
    Write-Host ""
    Write-Host "System check (Windows $($report.arch))" -ForegroundColor White
    Write-Host ""
    $problems = @()
    foreach ($c in $report.components) {
        switch ($c.status) {
            'ok'       { $word = 'ok';          $colour = 'Green' }
            'missing'  { $word = 'missing';     $colour = 'Red';    $problems += $c }
            'inactive' { $word = 'not running'; $colour = 'Yellow'; $problems += $c }
            default    { $word = 'not needed';  $colour = 'DarkGray' }
        }
        Write-Host ("  {0,-11} " -f $c.label) -NoNewline
        Write-Host ("{0,-13}" -f $word) -ForegroundColor $colour -NoNewline
        Write-Host " $($c.need)" -ForegroundColor DarkGray
    }
    Write-Host ""
    if (-not $problems) {
        Write-Host "  Everything EngineShelf needs is present." -ForegroundColor Green
        Write-Host ""
    }
    return $problems
}

# Prints exactly what it would run, asks, then runs it. Never installs silently.
function Invoke-PfFix {
    param([string]$Component, [switch]$AssumeYes)

    $status = Get-PfStatus $Component
    if ($status -eq 'ok') { Write-Host "  $(Get-PfLabel $Component) is already there." -ForegroundColor Green; return $true }
    if ($status -eq 'na') { Write-Host "  $(Get-PfLabel $Component) is not needed on this machine."; return $true }

    $command = Get-PfFix $Component $status
    if (-not $command) {
        Write-Host "X  $(Get-PfLabel $Component) cannot be installed automatically here." -ForegroundColor Red
        if ($Component -eq 'docker') {
            Write-Host "   Install the CLI:  winget install -e --id Docker.DockerCLI"
            Write-Host "   Then an engine for it to talk to: Docker Engine inside a WSL 2 distro."
            Write-Host "   The native launcher needs none of this:  .\engineshelf.ps1 run 74"
        }
        return $false
    }

    Write-Host ""
    Write-Host "  $(Get-PfLabel $Component) - $(Get-PfWhy $Component)" -ForegroundColor White
    Write-Host "  This will run:"
    Write-Host "    $command" -ForegroundColor DarkGray
    $note = Get-PfNote $Component $status
    if ($note) { Write-Host "  $note" -ForegroundColor DarkGray }
    Write-Host ""

    if (-not $AssumeYes) {
        # The manager runs this with no console attached, so there is nobody to
        # answer; say so instead of blocking on a prompt nobody will see.
        if ([Environment]::UserInteractive -eq $false) {
            Write-Host "!  Cannot ask for confirmation without a console." -ForegroundColor Yellow
            Write-Host "   Run it yourself, or: .\engineshelf.ps1 doctor --fix"
            return $false
        }
        $answer = Read-Host "  Run it now? [y/N]"
        if ($answer -notmatch '^[yY]') { Write-Host "  Nothing was installed."; return $false }
    }

    try {
        Invoke-Expression $command
    } catch {
        Write-Host "X  That command did not complete: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }

    # Only worth waiting for a daemon that something just started; installing the
    # CLI on its own leaves nothing to wait for.
    if ($Component -eq 'docker' -and $status -eq 'inactive') {
        Write-Host "  Waiting for the Docker daemon" -NoNewline
        for ($i = 0; $i -lt 90; $i++) {
            docker info 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { break }
            Write-Host "." -NoNewline
            Start-Sleep -Seconds 1
        }
        Write-Host ""
    }

    # The CLI is installed but has no engine yet. If there is something that can
    # be started, offer that now instead of making the user ask twice. Once only.
    if ($Component -eq 'docker' -and $status -eq 'missing' -and -not $script:PfDockerChained) {
        if ((Get-PfStatus 'docker') -eq 'inactive' -and (Get-PfFix 'docker' 'inactive')) {
            $script:PfDockerChained = $true
            return (Invoke-PfFix -Component docker -AssumeYes:$AssumeYes)
        }
    }

    if ((Get-PfStatus $Component) -eq 'ok') {
        Write-Host "  $(Get-PfLabel $Component) is ready." -ForegroundColor Green
        return $true
    }
    Write-Host "!  $(Get-PfLabel $Component) still is not usable." -ForegroundColor Yellow
    return $false
}
