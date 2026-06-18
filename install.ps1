# Pinner CLI installer for Windows
# Usage: iex (irm https://get.pinner.xyz/install.ps1)
#        iex (irm https://get.pinner.xyz/install.ps1) -System
#        iex (irm https://get.pinner.xyz/install.ps1) -Uninstall

#Requires -Version 5.1

[CmdletBinding()]
param(
    [switch]$System,
    [switch]$Uninstall,
    [switch]$NoPkg,
    [switch]$CI,
    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Script:ProgramName = 'pinner'
$Script:ArchiveName = 'pinner-cli'
$Script:Repo = 'LumeWeb/pinner-cli'
$Script:BaseUrl = "https://github.com/$Script:Repo/releases/download"
$Script:VersionUrl = 'https://get.pinner.xyz/version'
$Script:WinGetPackageId = 'Pinner.Cli'
$Script:ScoopBucketUrl = 'https://github.com/LumeWeb/scoop-bucket'

$Script:IsCI = ($CI -or $env:CI -eq 'true' -or $env:CI -eq '1')

function Write-Info($Msg) { Write-Host "[info]  $Msg" -ForegroundColor Cyan }
function Write-Warn($Msg) { Write-Host "[warn]  $Msg" -ForegroundColor Yellow }
function Write-Err($Msg)  { Write-Host "[error] $Msg" -ForegroundColor Red }
function Write-Ok($Msg)   { Write-Host "[ok]    $Msg" -ForegroundColor Green }

function New-TempDir {
    try {
        $tmp = New-Item -Path $env:TEMP -Name "pinner-install-$(Get-Random)" -ItemType Directory -Force
        return $tmp.FullName
    } catch {
        Write-Err "Failed to create temp directory: $_"
        exit 1
    }
}

function try-winget-install {
    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) { return }

    if ($Script:IsCI -and $env:PINNER_WINGET_MANIFEST) {
        Write-Info "CI mode: installing from local manifest ($env:PINNER_WINGET_MANIFEST)..."
        try {
            winget.exe install --manifest $env:PINNER_WINGET_MANIFEST --accept-source-agreements --accept-package-agreements 2>$null
            if ($LASTEXITCODE -eq 0) {
                Write-Ok 'Installed via winget (manifest).'
                exit 0
            }
            Write-Warn "winget manifest install failed (exit code $LASTEXITCODE). Falling back..."
        } catch {
            Write-Warn "winget manifest install failed: $_. Falling back..."
        }
        return
    }

    Write-Info 'Found winget. Attempting package manager install...'
    try {
        winget.exe install --id $Script:WinGetPackageId --accept-source-agreements --accept-package-agreements 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Ok 'Installed via winget.'
            exit 0
        }
        if ($LASTEXITCODE -eq -1966105625) {
            Write-Ok 'Already installed via winget.'
            exit 0
        }
        Write-Warn "winget install failed (exit code $LASTEXITCODE). Falling back..."
    } catch {
        Write-Warn "winget install failed: $_. Falling back..."
    }
}

function try-scoop-install {
    if (-not (Get-Command scoop -ErrorAction SilentlyContinue)) { return }

    if ($Script:IsCI -and $env:PINNER_SCOOP_MANIFEST) {
        Write-Info "CI mode: installing from local manifest ($env:PINNER_SCOOP_MANIFEST)..."
        try {
            scoop install $env:PINNER_SCOOP_MANIFEST 2>$null
            if ($LASTEXITCODE -eq 0) {
                Write-Ok 'Installed via scoop (manifest).'
                exit 0
            }
            Write-Warn "scoop manifest install failed (exit code $LASTEXITCODE). Falling back..."
        } catch {
            Write-Warn "scoop manifest install failed: $_. Falling back..."
        }
        return
    }

    Write-Info 'Found scoop. Attempting package manager install...'
    try {
        scoop bucket add lumeweb $Script:ScoopBucketUrl 2>$null
        scoop install pinner 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Ok 'Installed via scoop.'
            exit 0
        }
        Write-Warn "scoop install failed (exit code $LASTEXITCODE). Falling back..."
    } catch {
        Write-Warn "scoop install failed: $_. Falling back..."
    }
}

# Constrained language mode check
if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
    Write-Err 'PowerShell is running in Constrained Language mode.'
    Write-Err 'This script requires Full Language mode to execute.'
    Write-Err 'Ensure the system is not in Device Guard or AppLocker enforcement.'
    exit 1
}

if ([Environment]::OSVersion.Platform -eq 'Win32NT') {
    if ([Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Warn 'Running as administrator. This is unnecessary for default install.'
    }
}

if ($Help) {
    Write-Host @'
Pinner CLI Installer

Usage:
  iex (irm https://get.pinner.xyz/install.ps1)
  iex (irm https://get.pinner.xyz/install.ps1) -System
  iex (irm https://get.pinner.xyz/install.ps1) -Uninstall

Flags:
  -System       Install to Program Files (requires admin)
  -Uninstall    Remove pinner CLI
  -NoPkg        Skip package manager detection (winget/scoop)
  -CI           Enable CI mode (also activated by CI=true env var)
  -Help         Show this help message
  -Debug        Enable verbose output

CI Mode Environment Variables:
  PINNER_WINGET_MANIFEST  Path to local winget manifest directory
  PINNER_SCOOP_MANIFEST   Path to local scoop manifest JSON file
'@
    exit 0
}

if ($DebugPreference -ne 'SilentlyContinue') { $VerbosePreference = 'Continue' }

function Get-Arch {
    if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { return 'arm64' }
    if ([Environment]::Is64BitOperatingSystem) { return 'amd64' }
    Write-Err '32-bit Windows is not supported.'
    exit 1
}

function Get-LatestVersion {
    try {
        $resp = Invoke-WebRequest -Uri $Script:VersionUrl -UseBasicParsing -TimeoutSec 30
        $ver = (($resp.Content -replace '\s', '') -replace '^v', '')
        if ($ver -match '^\d+\.\d+\.\d+') { return $ver }
    } catch {
        Write-Verbose "Version endpoint failed: $_"
    }
    try {
        $apiUrl = "https://api.github.com/repos/$Script:Repo/releases/latest"
        $resp = Invoke-WebRequest -Uri $apiUrl -UseBasicParsing -TimeoutSec 30
        $ver = ($resp.Content | ConvertFrom-Json).tag_name -replace '^v', ''
        if ($ver -match '^\d+\.\d+\.\d+') { return $ver }
    } catch {
        Write-Verbose "GitHub API fallback failed: $_"
    }
    Write-Err 'Could not determine the latest version.'
    exit 1
}

function Get-InstallDir {
    if ($System) { return "${env:ProgramFiles}\pinner" }
    return Join-Path $env:LOCALAPPDATA 'Programs\pinner'
}

function Add-ToPath($Dir) {
    $current = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (-not $current) {
        [Environment]::SetEnvironmentVariable('Path', $Dir, 'User')
        Write-Info "Added $Dir to user PATH."
        return
    }
    if ($current -split ';' | Where-Object { $_ -eq $Dir }) { return }
    $newPath = if ($current.EndsWith(';')) { "$current$Dir" } else { "$current;$Dir" }
    [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
    Write-Info "Added $Dir to user PATH."
}

function Remove-FromPath($Dir) {
    $current = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (-not $current) { return }
    $parts = $current -split ';' | Where-Object { $_ -ne $Dir -and $_ -ne '' }
    [Environment]::SetEnvironmentVariable('Path', ($parts -join ';'), 'User')
    Write-Info "Removed $Dir from user PATH."
}

# ── Uninstall ──────────────────────────────────────────────────────────────

if ($Uninstall) {
    $dir = Get-InstallDir
    $binary = Join-Path $dir "$Script:ProgramName.exe"
    if (Test-Path $binary) { Remove-Item $binary -Force; Write-Info "Removed $binary" }
    else { Write-Warn "$binary not found." }
    if ((Test-Path $dir) -and -not (Get-ChildItem $dir -Recurse)) { Remove-Item $dir -Force }
    Remove-FromPath $dir
    if ($PROFILE -and (Test-Path $PROFILE)) {
        $content = Get-Content $PROFILE -Raw
        $cleaned = $content -replace '(?m)^# Pinner CLI completions\r?\n.*?\r?\n', ''
        if ($cleaned -ne $content) { Set-Content $PROFILE $cleaned -NoNewline; Write-Info "Removed completions from $PROFILE" }
    }
    Write-Ok 'Pinner CLI has been uninstalled.'
    exit 0
}

# ── Main install ───────────────────────────────────────────────────────────

if (-not $NoPkg) {
    try-winget-install
    try-scoop-install
    Write-Info 'No supported package manager found. Falling back to binary download.'
}

$Arch = Get-Arch
$Version = Get-LatestVersion
$InstallDir = Get-InstallDir

Write-Info "Installing Pinner CLI v$Version for windows/$Arch"

$existingBinary = Join-Path $InstallDir "$Script:ProgramName.exe"
if (Test-Path $existingBinary) {
    try {
        $currentVer = & $existingBinary --version 2>$null | Select-Object -First 1
        if ($currentVer -match '\d+\.\d+\.\d+') { Write-Info "Upgrading from v$($Matches[0]) to v$Version" }
        else { Write-Info 'Replacing existing installation.' }
    } catch { Write-Info 'Replacing existing installation.' }
}

$archiveFileName = "$Script:ArchiveName`_$Version`_windows_$Arch.zip"
$archiveUrl = "$Script:BaseUrl/v$Version/$archiveFileName"
$checksumsUrl = "$Script:BaseUrl/v$Version/checksums.txt"

Write-Verbose "Checking connectivity to $archiveUrl"
try { Invoke-WebRequest -Uri $archiveUrl -Method Head -UseBasicParsing -TimeoutSec 15 | Out-Null }
catch {
    Write-Err "Cannot reach $archiveUrl"
    Write-Err 'Check your network connection and that the version/architecture is correct.'
    exit 1
}

$tmpDir = New-TempDir
try {
    $archivePath = Join-Path $tmpDir $archiveFileName
    $checksumsPath = Join-Path $tmpDir 'checksums.txt'

    Write-Info "Downloading $archiveFileName..."
    Invoke-WebRequest -Uri $archiveUrl -OutFile $archivePath -UseBasicParsing
    Write-Info 'Downloading checksums...'
    Invoke-WebRequest -Uri $checksumsUrl -OutFile $checksumsPath -UseBasicParsing

    Write-Info 'Verifying SHA256 checksum...'
    $checksums = Get-Content $checksumsPath -Raw
    $expectedLine = $checksums -split "`n" | Where-Object { $_ -match [regex]::Escape($archiveFileName) }
    if (-not $expectedLine) { Write-Err "Could not find checksum for $archiveFileName"; exit 1 }
    $expectedHash = ($expectedLine -split '\s+')[0].Trim()
    $actualHash = (Get-FileHash -Path $archivePath -Algorithm SHA256).Hash.ToLower()
    if ($expectedHash.ToLower() -ne $actualHash) {
        Write-Err 'SHA256 verification failed!'; Write-Err "  Expected: $expectedHash"; Write-Err "  Actual:   $actualHash"; exit 1
    }
    Write-Ok 'Checksum verified.'

    Write-Info 'Extracting...'
    $extractDir = Join-Path $tmpDir 'extract'
    Expand-Archive -Path $archivePath -DestinationPath $extractDir -Force

    $binary = Get-ChildItem -Path $extractDir -Filter "$Script:ProgramName.exe" -Recurse | Select-Object -First 1
    if (-not $binary) { $binary = Get-ChildItem -Path $extractDir -Filter $Script:ProgramName -Recurse | Select-Object -First 1 }
    if (-not $binary) { Write-Err "Could not find '$Script:ProgramName' binary in archive."; exit 1 }

    if (-not (Test-Path $InstallDir)) { New-Item -Path $InstallDir -ItemType Directory -Force | Out-Null }

    $dest = Join-Path $InstallDir $binary.Name
    Copy-Item $binary.FullName $dest -Force
    Unblock-File $dest -ErrorAction SilentlyContinue
    Write-Ok "Installed $Script:ProgramName to $dest"

    Add-ToPath $InstallDir
    $env:Path = if ($env:Path.EndsWith(';')) { "$env:Path$InstallDir" } else { "$env:Path;$InstallDir" }

    try {
        $compOutput = & $Script:ProgramName completion pwsh 2>$null
        if ($compOutput -and $PROFILE) {
            $profileDir = Split-Path $PROFILE -Parent
            if (-not (Test-Path $profileDir)) { New-Item -Path $profileDir -ItemType Directory -Force | Out-Null }
            $compHeader = '# Pinner CLI completions'
            if (-not (Test-Path $PROFILE) -or -not ((Get-Content $PROFILE -Raw -ErrorAction SilentlyContinue) -match [regex]::Escape($compHeader))) {
                "$compHeader`n$compOutput" | Out-File -Append $PROFILE -Encoding UTF8
                Write-Ok "Installed PowerShell completions to $PROFILE"
            }
        }
    } catch { Write-Verbose "Completions install skipped: $_" }

    Write-Host ''
    Write-Ok "Pinner CLI v$Version installed successfully!"
    Write-Info "Run 'pinner --help' to get started."
} finally {
    Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
}
