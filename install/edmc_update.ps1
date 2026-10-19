# Update edminc in place, by re-running the installer.
#   edmc_update [tag]
#
# Installed next to edmc.exe, so it is on PATH with it. Updates the copy
# it sits in, which is what makes a non-default EDMINC_INSTALL keep
# working.

param([string]$Tag = "")

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$url = if ($env:EDMINC_INSTALL_URL) { $env:EDMINC_INSTALL_URL } else { 'https://minc.dev/edminc/install.ps1' }

if ($Tag) { $env:EDMINC_VERSION = $Tag }
if (-not $env:EDMINC_INSTALL) {
    $env:EDMINC_INSTALL = Split-Path -Parent $MyInvocation.MyCommand.Path
}

Write-Host "Updating edminc in $($env:EDMINC_INSTALL)"
Invoke-RestMethod -UseBasicParsing $url | Invoke-Expression
