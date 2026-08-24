#
# ChromiumStack - open the graphical manager (Windows)
#
# Starts a small local web server and opens it in your normal browser. Nothing is
# installed and nothing listens outside this machine: the server binds to
# 127.0.0.1 and every request has to carry a token generated for this run.
#
#   .\gui.ps1              # open the manager
#   .\gui.ps1 -Port 8080   # use a specific port
#   .\gui.ps1 -NoOpen      # start it but do not open a browser tab
#
[CmdletBinding()]
param(
    [int]$Port = 7411,
    [switch]$NoOpen
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
& (Join-Path $ScriptDir 'gui\server.ps1') -Port $Port -NoOpen:$NoOpen
