# Pinner CLI installer for Windows
# Usage: iex (irm https://get.pinner.xyz/install.ps1)
#        & ([scriptblock]::Create((irm https://get.pinner.xyz/install.ps1))) -System
#        & ([scriptblock]::Create((irm https://get.pinner.xyz/install.ps1))) -Uninstall

#Requires -Version 5.1

[CmdletBinding()]
param(
    [switch]$System,
    [switch]$Uninstall,
    [switch]$NoPkg,
    [switch]$CI,
    [string]$Version,
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

function Test-NewInstall {
    $configDir = Join-Path $env:USERPROFILE '.config\pinner'
    $configFile = Join-Path $configDir 'config.yaml'
    -not (Test-Path $configFile)
}

function Show-NextSteps {
    if (Get-Command $Script:ProgramName -ErrorAction SilentlyContinue) {
        if (Test-NewInstall) {
            Write-Info "First time? Run 'pinner setup' to configure authentication and settings."
        } else {
            Write-Info "Run 'pinner --help' to get started."
        }
    } else {
        Write-Info "Open a new terminal to use pinner."
        if (Test-NewInstall) {
            Write-Info "Then run 'pinner setup' for first-time configuration."
        }
    }
}

function New-TempDir {
    try {
        $tmp = New-Item -Path $env:TEMP -Name "pinner-install-$(Get-Random)" -ItemType Directory -Force
        return $tmp.FullName
    } catch {
        Write-Err "Failed to create temp directory: $_"
        exit 1
    }
}

function Invoke-PMInstall {
    param([string]$Name, [scriptblock]$Action, [string]$SuccessMsg, [string]$AlreadyInstalledMsg)
    try {
        & $Action
        if ($LASTEXITCODE -eq 0) { Write-Ok $SuccessMsg; Show-NextSteps; exit 0 }
        if ($AlreadyInstalledMsg -and $LASTEXITCODE -eq -1966105625) { Write-Ok $AlreadyInstalledMsg; Show-NextSteps; exit 0 }
        Write-Warn "$Name install failed (exit code $LASTEXITCODE). Falling back..."
    } catch {
        Write-Warn "$Name install failed: $_. Falling back..."
    }
}

function try-winget-install {
    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) { return }

    # CI mode: disable winget spinner and enable local manifests
    if ($Script:IsCI) {
        $wingetSettingsDir = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\LocalState'
        if (-not (Test-Path $wingetSettingsDir)) {
            $wingetSettingsDir = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Settings'
        }
        if (Test-Path $wingetSettingsDir) {
            $settingsFile = Join-Path $wingetSettingsDir 'settings.json'
            $wingetSettings = if (Test-Path $settingsFile) {
                try { Get-Content $settingsFile -Raw | ConvertFrom-Json -AsHashtable } catch { @{} }
            } else { @{} }
            if (-not $wingetSettings.ContainsKey('visual')) { $wingetSettings['visual'] = @{} }
            $wingetSettings['visual']['progressBar'] = 'disabled'
            $wingetSettings | ConvertTo-Json -Depth 10 | Out-File $settingsFile -Encoding UTF8 -ErrorAction SilentlyContinue
        }
        & winget.exe settings --enable LocalManifestFiles 2>$null
    }

    if ($Script:IsCI -and $env:PINNER_WINGET_MANIFEST) {
        Write-Info "CI mode: installing from local manifest ($env:PINNER_WINGET_MANIFEST)..."
        Invoke-PMInstall 'winget' { winget.exe install --manifest $env:PINNER_WINGET_MANIFEST --accept-source-agreements --accept-package-agreements --disable-interactivity } 'Installed via winget (manifest).'
        return
    }

    Write-Info 'Found winget. Attempting package manager install...'
    Invoke-PMInstall 'winget' { winget.exe install --id $Script:WinGetPackageId --accept-source-agreements --accept-package-agreements --disable-interactivity 2>$null } 'Installed via winget.' 'Already installed via winget.'
}

function try-scoop-install {
    if (-not (Get-Command scoop -ErrorAction SilentlyContinue)) { return }

    if ($Script:IsCI -and $env:PINNER_SCOOP_MANIFEST) {
        Write-Info "CI mode: installing from local manifest ($env:PINNER_SCOOP_MANIFEST)..."
        Invoke-PMInstall 'scoop' { scoop install $env:PINNER_SCOOP_MANIFEST } 'Installed via scoop (manifest).'
        return
    }

    Write-Info 'Found scoop. Attempting package manager install...'
    Invoke-PMInstall 'scoop' { scoop bucket add lumeweb $Script:ScoopBucketUrl 2>$null; scoop install pinner 2>$null } 'Installed via scoop.'
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
  & ([scriptblock]::Create((irm https://get.pinner.xyz/install.ps1))) -System
  & ([scriptblock]::Create((irm https://get.pinner.xyz/install.ps1))) -Uninstall

Flags:
  -System       Install to Program Files (requires admin)
  -Uninstall    Remove pinner CLI
  -NoPkg        Skip package manager detection (winget/scoop)
  -Version VER  Target version: semver (0.2.0), git hash (abc1234), or branch (develop)
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

# ── Version type detection ──────────────────────────────────────────────────

function Test-GitHash {
    param([string]$Ver)
    if ($Ver -match '^[0-9a-fA-F]{7,40}$') { return $true }
    return $false
}

function Test-SemVer {
    param([string]$Ver)
    $cleaned = $Ver -replace '^v', ''
    if ($cleaned -match '^\d+\.\d+\.\d+') { return $true }
    return $false
}

# ── Snapshot artifact download (for git hash / branch targets) ───────────────

$Script:ActionsApi = "https://api.github.com/repos/$Script:Repo/actions"
$Script:ArtifactName = 'pinner-cli-snapshot'
$Script:NightlyLink = 'https://nightly.link'
$Script:WorkflowFile = 'go.yml'

function Resolve-FullSha {
    param([string]$ShortSha)
    try {
        $url = "https://api.github.com/repos/$Script:Repo/commits/$ShortSha"
        $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 30 -Headers @{ 'Accept' = 'application/vnd.github+json' }
        $sha = ($resp.Content | ConvertFrom-Json).sha
        if ($sha) { return $sha }
    } catch { }
    return $null
}

function Find-RunBySha {
    param([string]$Sha)
    try {
        $url = "$Script:ActionsApi/runs?per_page=10&head_sha=$Sha&status=success"
        $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 30 -Headers @{ 'Accept' = 'application/vnd.github+json' }
        $runs = ($resp.Content | ConvertFrom-Json).workflow_runs
        if ($runs) { return $runs[0].id }
    } catch { }
    return $null
}

function Build-SnapshotUrl {
    param([string]$Ref)
    if (Test-GitHash -Ver $Ref) {
        # Resolve short hashes to full 40-char SHA
        if ($Ref.Length -lt 40) {
            $full = Resolve-FullSha -ShortSha $Ref
            if (-not $full) {
                Write-Err "Could not resolve commit hash '$Ref'."
                exit 1
            }
            $Ref = $full
        }
        $runId = Find-RunBySha -Sha $Ref
        if (-not $runId) {
            Write-Err "No successful CI run found for commit '$Ref'."
            Write-Err 'Ensure a push to develop or PR has completed with artifacts.'
            exit 1
        }
        Write-Info "Found workflow run #$runId"
        return "$Script:NightlyLink/$Script:Repo/actions/runs/$runId/$Script:ArtifactName.zip"
    } else {
        # Branch name — construct nightly.link URL directly
        return "$Script:NightlyLink/$Script:Repo/workflows/$Script:WorkflowFile/$Ref/$Script:ArtifactName.zip"
    }
}

function Download-SnapshotArtifact {
    param([string]$Ref, [string]$TmpDir, [string]$Arch)

    Write-Info "Looking up CI snapshot for $Ref..."
    $url = Build-SnapshotUrl -Ref $Ref

    # Download via nightly.link — no auth required
    $outerZip = Join-Path $TmpDir 'snapshot-artifact.zip'
    Write-Info 'Downloading snapshot artifact...'
    try {
        Invoke-WebRequest -Uri $url -OutFile $outerZip -UseBasicParsing -TimeoutSec 300
    } catch {
        Write-Err "Failed to download artifact: $_"
        exit 1
    }

    # Extract outer ZIP (contains dist/ directory from GoReleaser)
    Write-Info 'Extracting artifact...'
    $artifactDir = Join-Path $TmpDir 'artifact'
    Expand-Archive -Path $outerZip -DestinationPath $artifactDir -Force

    # Find the inner archive for windows / current arch
    $pattern = "$($Script:ArchiveName)_*_windows_$Arch"
    $innerArchive = Get-ChildItem -Path $artifactDir -Recurse -Filter "$pattern.zip" | Select-Object -First 1
    if (-not $innerArchive) {
        Write-Err "No archive found for windows/$Arch in snapshot artifact."
        Write-Err "Expected: $pattern.zip"
        exit 1
    }

    return $innerArchive.FullName
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

# Version resolution: -Version flag > PINNER_VERSION env > latest endpoint
$requestedVersion = if ($Version) { $Version } elseif ($env:PINNER_VERSION) { $env:PINNER_VERSION } else { $null }
$useSnapshot = $false

if ($requestedVersion) {
    if (Test-SemVer -Ver $requestedVersion) {
        $resolvedVersion = $requestedVersion -replace '^v', ''
    } elseif (Test-GitHash -Ver $requestedVersion) {
        $resolvedVersion = $requestedVersion
        $useSnapshot = $true
    } else {
        # Treat as branch name
        $resolvedVersion = $requestedVersion
        $useSnapshot = $true
    }
} else {
    $resolvedVersion = Get-LatestVersion
}

# Skip package manager install for snapshot builds
if (-not $useSnapshot -and -not $NoPkg) {
    try-winget-install
    try-scoop-install
    Write-Info 'No supported package manager found. Falling back to binary download.'
}

$Arch = Get-Arch
$Version = $resolvedVersion
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

$tmpDir = New-TempDir
try {
    if ($useSnapshot) {
        # Download snapshot artifact from GitHub Actions API
        $archivePath = Download-SnapshotArtifact -Ref $Version -TmpDir $tmpDir -Arch $Arch
        $archiveFileName = Split-Path $archivePath -Leaf
        Write-Info "Downloaded $archiveFileName"
    } else {
        # Download from GitHub Releases
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
    }

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
                $compText = $compOutput -join "`n"
                $existing = if (Test-Path $PROFILE) { Get-Content $PROFILE -Raw -ErrorAction SilentlyContinue } else { '' }
                if ($existing -and -not $existing.EndsWith("`n")) { $existing += "`n" }
                "$existing$compHeader`n$compText`n" | Out-File $PROFILE -Encoding UTF8
                Write-Ok "Installed PowerShell completions to $PROFILE"
            }
        }
    } catch { Write-Verbose "Completions install skipped: $_" }

    Write-Host ''
    Write-Ok "Pinner CLI v$Version installed successfully!"
    Show-NextSteps
} finally {
    Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
}
