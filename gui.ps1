#
# ChromiumStack - open the graphical manager (Windows)
#
# Starts a small local web server and opens it in a window of its own. Nothing is
# installed and nothing listens outside this machine: the server binds to
# 127.0.0.1 and every request has to carry a token generated for this run.
#
# Closing the window quits the manager, the browsers it launched and any Docker
# containers it started.
#
#   .\gui.ps1              # open the manager
#   .\gui.ps1 -Port 8080   # use a specific port
#   .\gui.ps1 -Tab         # a tab in your default browser instead of a window
#   .\gui.ps1 -NoOpen      # start it but open nothing
#   .\gui.ps1 -KeepAlive   # keep serving after the window closes
#
[CmdletBinding()]
param(
    [int]$Port = 7411,
    [switch]$NoOpen,
    [switch]$Tab,
    [switch]$KeepAlive
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
& (Join-Path $ScriptDir 'gui\server.ps1') -Port $Port -NoOpen:$NoOpen -Tab:$Tab -KeepAlive:$KeepAlive
