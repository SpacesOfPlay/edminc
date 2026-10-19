# edminc installer for Windows.
#   powershell -c "irm minc.dev/edminc/install.ps1 | iex"
#
# Installs edminc into ~\.edminc and adds it to the user PATH. The
# editor's command is `edmc`. Also run by edmc_update.ps1 to update in
# place, and by `minc build install` to place a local build the same
# way (via EDMINC_DIR).
#
# Options (environment variables):
#   EDMINC_INSTALL   install dir           (default: %USERPROFILE%\.edminc)
#   EDMINC_VERSION   pin a release tag, e.g. v0.1.0   (default: latest)
#   EDMINC_REPO      GitHub release repo   (default: SpacesOfPlay/edminc)
#   EDMINC_ZIP       install from a local zip instead of downloading
#   EDMINC_DIR       install from a local directory, already laid out
#   EDMINC_FORCE     1 = reinstall even if already up to date
#   EDMINC_NO_PATH   1 = don't touch PATH

# Options also arrive as parameters, which is how `minc build install`
# hands over a staged local build. Piped through iex there are none.
param([string]$From = "", [switch]$NoPath)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if ($From)   { $env:EDMINC_DIR = $From }
if ($NoPath) { $env:EDMINC_NO_PATH = '1' }
[Net.ServicePointManager]::SecurityProtocol = `
    [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

function Say($msg)  { Write-Host $msg }
function Ok($msg)   { Write-Host $msg -ForegroundColor Green }
function Warn($msg) { Write-Host "WARNING: $msg" -ForegroundColor Yellow }
function Fail($msg) { Write-Host "ERROR: $msg" -ForegroundColor Red; exit 1 }

# Run edmc and capture stdout+stderr as plain text. Windows PowerShell turns
# a native command's stderr into error records, which 'Stop' would make fatal
# - so drop the preference in a child scope and unwrap the records.
function Invoke-Edmc($exe, [string[]]$edmcArgs) {
    & {
        $ErrorActionPreference = 'Continue'
        (& $exe @edmcArgs 2>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { $_ }
        } | Out-String).Trim()
    }
}

# User-scope PATH, dropping stale entries that carry another edmc.exe. Runs on
# every install path - including "already up to date", where a previous run may
# have placed the files but never reached this step.
function Set-EdmincPath {
    if ($env:EDMINC_NO_PATH -eq '1') {
        Say "Skipping PATH setup (EDMINC_NO_PATH=1). Binary: $EdmcExe"
        return
    }
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $paths = @()
    if ($userPath) { $paths = $userPath -split ';' | Where-Object { $_ } }
    $kept = @()
    foreach ($p in $paths) {
        if ($p -eq $InstallDir) { continue }
        if (Test-Path (Join-Path $p 'edmc.exe')) { continue }
        $kept += $p
    }
    if ($paths.Count -eq ($kept.Count + 1) -and $paths[0] -eq $InstallDir) {
        Say "PATH already configured: $InstallDir"
    } else {
        Say "Added to PATH: $InstallDir"
    }
    [Environment]::SetEnvironmentVariable('Path', ((@($InstallDir) + $kept) -join ';'), 'User')
    $env:Path = "$InstallDir;$env:Path"
}

$Repo       = if ($env:EDMINC_REPO)    { $env:EDMINC_REPO }    else { 'SpacesOfPlay/edminc' }
$InstallDir = if ($env:EDMINC_INSTALL) { $env:EDMINC_INSTALL } else { Join-Path $env:USERPROFILE '.edminc' }
$Asset      = 'edminc-windows-x64.zip'
$EdmcExe    = Join-Path $InstallDir 'edmc.exe'

# --- Platform check ---

$arch = $env:PROCESSOR_ARCHITECTURE
if ($env:PROCESSOR_ARCHITEW6432) { $arch = $env:PROCESSOR_ARCHITEW6432 }
if ($arch -ne 'AMD64') {
    Fail "unsupported architecture '$arch' - edminc ships for x64 Windows only."
}

# --- Resolve version ---

function Get-LatestTag($repo) {
    # releases/latest answers with a redirect to .../releases/tag/<tag>.
    $req = [System.Net.HttpWebRequest]::Create("https://github.com/$repo/releases/latest")
    $req.AllowAutoRedirect = $false
    $req.UserAgent = 'edminc-install'
    try {
        $resp = $req.GetResponse()
        try { $loc = $resp.Headers['Location'] } finally { $resp.Close() }
    } catch {
        Fail "could not reach github.com to resolve the latest release ($_)"
    }
    if (-not $loc -or $loc -notmatch '/tag/([^/]+)/?$') {
        Fail "no published release found at github.com/$repo"
    }
    return $Matches[1]
}

$LocalZip = $env:EDMINC_ZIP
$LocalDir = $env:EDMINC_DIR
$Tag = $null
if ($LocalDir) {
    if (-not (Test-Path $LocalDir)) { Fail "EDMINC_DIR not found: $LocalDir" }
    Say "Installing edminc from $LocalDir to $InstallDir"
} elseif ($LocalZip) {
    if (-not (Test-Path $LocalZip)) { Fail "EDMINC_ZIP not found: $LocalZip" }
    Say "Installing edminc from $LocalZip to $InstallDir"
} else {
    $Tag = if ($env:EDMINC_VERSION) { $env:EDMINC_VERSION } else { Get-LatestTag $Repo }
    Say "Installing edminc $Tag to $InstallDir"
}

# --- Already up to date? ---
#
# --version is answered before the editor opens anything, so this costs
# no window.

if ($Tag -and $env:EDMINC_FORCE -ne '1' -and (Test-Path $EdmcExe)) {
    $cur = Invoke-Edmc $EdmcExe @('--version')
    if ($cur -match 'edminc\s+(\d+\.\d+\.\d+)' -and ("v" + $Matches[1]) -eq $Tag) {
        Ok "edminc $Tag is already installed and up to date."
        Set-EdmincPath
        exit 0
    }
}

# --- Download + verify ---

$Tmp = Join-Path $env:TEMP ("edminc-install-" + [IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Path $Tmp -Force | Out-Null

$Payload = $null
if ($LocalDir) {
    $Payload = (Resolve-Path $LocalDir).Path
} else {
    $ZipPath = $LocalZip
    if (-not $ZipPath) {
        $base = "https://github.com/$Repo/releases/download/$Tag"
        $ZipPath = Join-Path $Tmp $Asset
        Say "Downloading $Asset..."
        try {
            Invoke-WebRequest -UseBasicParsing -Uri "$base/$Asset" -OutFile $ZipPath
        } catch {
            Fail "download failed: $base/$Asset ($_)"
        }
        $sums = Join-Path $Tmp 'SHASUMS256.txt'
        $haveSums = $true
        try { Invoke-WebRequest -UseBasicParsing -Uri "$base/SHASUMS256.txt" -OutFile $sums }
        catch {
            $haveSums = $false
            Warn "SHASUMS256.txt not available for this release - skipping checksum verification."
        }
        if ($haveSums) {
            $line = (Get-Content $sums) | Where-Object { $_ -match ("\s+" + [regex]::Escape($Asset) + "$") }
            if (-not $line) { Fail "$Asset not listed in SHASUMS256.txt" }
            $expected = ($line -split '\s+')[0].ToLower()
            $actual = (Get-FileHash $ZipPath -Algorithm SHA256).Hash.ToLower()
            if ($actual -ne $expected) {
                Fail "checksum mismatch for $Asset (expected $expected, got $actual)"
            }
            Say "Checksum OK."
        }
    }

    try { Unblock-File $ZipPath -ErrorAction SilentlyContinue } catch {}
    $Extract = Join-Path $Tmp 'x'
    Expand-Archive -Path $ZipPath -DestinationPath $Extract -Force

    # Payload sits at the extract root or inside one wrapping folder.
    if (Test-Path (Join-Path $Extract 'edmc.exe')) {
        $Payload = $Extract
    } else {
        foreach ($d in Get-ChildItem $Extract -Directory) {
            if (Test-Path (Join-Path $d.FullName 'edmc.exe')) { $Payload = $d.FullName; break }
        }
    }
    if (-not $Payload) { Fail "edmc.exe not found inside the archive." }
}

if (-not (Test-Path (Join-Path $Payload 'edmc.exe'))) { Fail "edmc.exe not found in $Payload" }

# --- Install (rename-then-replace: a running exe blocks delete, not rename) ---

if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
}

Get-ChildItem (Join-Path $InstallDir '*.old') -ErrorAction SilentlyContinue |
    Remove-Item -Force -ErrorAction SilentlyContinue

$t = $EdmcExe
if (Test-Path $t) {
    try { Remove-Item $t -Force }
    catch {
        # Running right now - move it aside; it goes on the next run.
        Rename-Item $t "edmc.exe.$(Get-Random).old" -Force
    }
}
$t = Join-Path $InstallDir 'assets'
if (Test-Path $t) {
    try { Remove-Item $t -Recurse -Force }
    catch { Warn "could not fully clear $t - stale files may remain." }
}

Copy-Item -Path (Join-Path $Payload '*') -Destination $InstallDir -Recurse -Force
Get-ChildItem $InstallDir -Recurse -File -ErrorAction SilentlyContinue |
    Unblock-File -ErrorAction SilentlyContinue

if (-not (Test-Path $EdmcExe)) { Fail "installed edmc.exe is missing." }
$verOut = Invoke-Edmc $EdmcExe @('--version')
if (-not $verOut) { Fail "installed edmc.exe failed to run." }

Remove-Item $Tmp -Recurse -Force -ErrorAction SilentlyContinue

# --- PATH ---

Set-EdmincPath

# --- Done ---

Say ""
Ok "$verOut installed to $InstallDir"
Say ""
Say "Open a NEW terminal, then:"
Say "  edmc            # open the editor"
Say "  edmc <folder>   # open a project"
Say ""
Say "Update any time:  edmc_update"
