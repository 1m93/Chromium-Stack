#
# Put a ChromiumStack shortcut on the Desktop and in the Start Menu, so the
# manager can be opened without going to the project folder first.
#
# It points at ChromiumStack.exe, which carries its own icon. If that has not
# been built (tools/build-exe.sh, from macOS or Linux) the shortcut falls back to
# calling gui.ps1 through PowerShell and borrows assets\icon.ico instead.
#
#   powershell -ExecutionPolicy Bypass -File tools\install-shortcut.ps1
#   powershell -ExecutionPolicy Bypass -File tools\install-shortcut.ps1 -Remove
#
[CmdletBinding()]
param([switch]$Remove)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$Icon = Join-Path $Root 'assets\icon.ico'
$Gui  = Join-Path $Root 'gui.ps1'
$Exe  = Join-Path $Root 'ChromiumStack.exe'

$targets = @(
    (Join-Path ([Environment]::GetFolderPath('Desktop')) 'chromium-stack.lnk'),
    (Join-Path ([Environment]::GetFolderPath('StartMenu')) 'Programs\chromium-stack.lnk')
)

if ($Remove) {
    foreach ($path in $targets) {
        if (Test-Path $path) { Remove-Item $path -Force; Write-Host "removed $path" }
    }
    return
}

$useExe = Test-Path $Exe
if (-not $useExe -and -not (Test-Path $Icon)) {
    throw "Missing both $Exe and $Icon - build the exe with tools/build-exe.sh, or the icons with tools/make-icons.sh."
}

$shell = New-Object -ComObject WScript.Shell
foreach ($path in $targets) {
    $parent = Split-Path -Parent $path
    if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    $link = $shell.CreateShortcut($path)
    if ($useExe) {
        # The exe already knows how to find gui.ps1 next to itself, and its icon
        # is compiled in, so the shortcut needs to say nothing about either.
        $link.TargetPath   = $Exe
        $link.IconLocation = "$Exe,0"
    } else {
        # -WindowStyle Hidden keeps the console out of the way: the UI is the page it opens.
        $link.TargetPath   = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
        $link.Arguments    = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Gui`""
        $link.IconLocation = "$Icon,0"
    }
    $link.WorkingDirectory = $Root
    $link.Description      = 'Install, launch and manage old Chromium engines'
    $link.Save()
    Write-Host "created $path"
}
