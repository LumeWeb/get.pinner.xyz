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

# --- Download / extraction progress ------------------------------------------
#
# Interactive archives show a live determinate progress bar. Invoke-WebRequest
# renders one natively, so we only force $ProgressPreference on globally; for
# extraction we drive Write-Progress per archive entry. Every progress helper
# accepts a -ProgressSink scriptblock (defaults to Write-Progress) so CI can
# inject a recording sink and assert the bar advances start -> end in steps.
$ProgressPreference = 'Continue'

function Expand-ArchiveWithProgress {
    # Extract a ZIP to a directory, reporting per-entry progress. A determinate
    # bar (current entry / total entries) is better than zero feedback, and the
    # -ProgressSink hook keeps it unit-testable in non-interactive CI.
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$DestinationPath,
        [scriptblock]$ProgressSink = {
            param($id, $activity, $current, $total)
            Write-Progress -Id $id -Activity $activity `
                -PercentComplete ([int][math]::Round(100 * $current / $total))
        }
    )
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    $id = Get-Random -Maximum 10000
    $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $total = $zip.Entries.Count
        $count = 0
        foreach ($entry in $zip.Entries) {
            # Reject Zip-Slip / path-traversal entries (CA5389): a crafted
            # archive can name an entry `..\..\evil` to write outside the
            # destination, which .NET's ZipFile.ExtractToDirectory blocks and a
            # raw entry-name extraction would not. Resolve each entry under the
            # destination root and refuse anything that escapes it.
            $dest = [System.IO.Path]::GetFullPath((Join-Path $DestinationPath $entry.FullName))
            $dirChar = [System.IO.Path]::DirectorySeparatorChar
            $root = ([System.IO.Path]::GetFullPath($DestinationPath)).TrimEnd($dirChar) + $dirChar
            if (-not $dest.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "Archive entry '$($entry.FullName)' escapes the destination directory"
            }
            $parent = Split-Path $dest -Parent
            if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
            if ($entry.Name) {
                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $dest, $true)
            }
            $count++
            if ($total -gt 0) { & $ProgressSink $id 'Extracting' $count $total }
        }
    } finally {
        $zip.Dispose()
    }
}

function Test-NewInstall {
    $configDir = Join-Path $env:USERPROFILE '.config\pinner'
    $configFile = Join-Path $configDir 'config.yaml'
    -not (Test-Path $configFile)
}

# --- Cross-method location scanner --------------------------------------------
#
# pinner can be installed by several methods, each placing the binary in a
# DIFFERENT location (winget, scoop, binary at %LOCALAPPDATA%\Programs\pinner,
# or system at %ProgramFiles%\pinner). Historically each method only detected
# its OWN location, so a cross-method upgrade (e.g. scoop -> binary) left two
# pinner binaries on PATH with one silently shadowing the other.
#
# Get-PinnerLocations() is the DRY primitive: it enumerates EVERY known install
# location regardless of which method created it, returning one object per hit:
#   Method   : binary|system|winget|scoop  (how it is managed)
#   Location : directory containing the binary ('' if not resolvable, e.g. winget)
#   Version  : parsed from `pinner --version` (may be empty)
#   OnPath   : $true if <Location> is on the user's PATH
#
# Locations are scanned in PATH-precedence order so the FIRST hit is the one
# that currently wins on PATH (the "effective" current install).
function Get-PinnerLocations {
    $pathList = @()
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($userPath) { $pathList += $userPath -split ';' }
    if ($env:Path) { $pathList += $env:Path -split ';' }

    $results = @()

    # binary (default per-user)
    $locBinary = Join-Path $env:LOCALAPPDATA 'Programs\pinner'
    $bin = Join-Path $locBinary "$Script:ProgramName.exe"
    if (Test-Path $bin) {
        $v = Get-PinnerVersion $bin
        $on = $false; if ($pathList -contains $locBinary) { $on = $true }
        $results += [pscustomobject]@{ Method = 'binary'; Location = $locBinary; Version = $v; OnPath = $on }
    }

    # system (%ProgramFiles%\pinner)
    $locSys = Join-Path $env:ProgramFiles 'pinner'
    $binSys = Join-Path $locSys "$Script:ProgramName.exe"
    if (Test-Path $binSys) {
        $v = Get-PinnerVersion $binSys
        $on = $false; if ($pathList -contains $locSys) { $on = $true }
        $results += [pscustomobject]@{ Method = 'system'; Location = $locSys; Version = $v; OnPath = $on }
    }

    # scoop (shim at ~\scoop\shims)
    $shims = Join-Path $env:USERPROFILE 'scoop\shims'
    $shimBin = Join-Path $shims "$Script:ProgramName.exe"
    if ((Get-Command scoop -ErrorAction SilentlyContinue) -and (Test-Path $shimBin)) {
        $v = Get-PinnerVersion $shimBin
        $on = $false; if ($pathList -contains $shims) { $on = $true }
        $results += [pscustomobject]@{ Method = 'scoop'; Location = $shims; Version = $v; OnPath = $on }
    }

    # winget (location not resolvable from metadata; flag by package presence)
    if (Get-Command winget.exe -ErrorAction SilentlyContinue) {
        $wg = winget list --id $Script:WinGetPackageId --accept-source-agreements 2>$null | Out-String
        if ($wg -match [regex]::Escape($Script:WinGetPackageId)) {
            $results += [pscustomobject]@{ Method = 'winget'; Location = ''; Version = 'unknown'; OnPath = $true }
        }
    }

    return $results
}

# Read a normalized version (X.Y.Z or empty) out of a pinner binary.
function Get-PinnerVersion {
    param([string]$Bin)
    try {
        $out = & $Bin --version 2>$null | Select-Object -First 1
        if ($out -match '\d+\.\d+\.\d+') { return $Matches[0] }
    } catch { }
    return ''
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
        if ($LASTEXITCODE -eq 0) {
            # New install is confirmed present; record that this run resolved to
            # this package manager, so reconcile keeps the matching PM install.
            $Script:PkgSucceeded = $true
            if ($Name -eq 'winget') { $Script:ResolvedToWinget = $true }
            # Reconcile against ONLY the location this method actually landed
            # in, so a differing-method install at any other location (e.g. a
            # direct binary at Get-InstallDir when scoop succeeds) is removed
            # and cannot shadow the fresh PM install.
            $pmTargets = @()
            if ($Name -eq 'scoop') { $pmTargets = @(Join-Path $env:USERPROFILE 'scoop\shims') }
            Invoke-PinnerReconcile -TargetDirs $pmTargets
            Write-Ok $SuccessMsg; Show-NextSteps; exit 0
        }
        if ($AlreadyInstalledMsg -and $LASTEXITCODE -eq -1966105625) {
            # winget reports the package is already installed and manages it;
            # this run resolved to winget, so keep the winget install. Reconcile
            # now so a previously installed binary from another method does not
            # keep shadowing the winget-managed binary on PATH.
            if ($Name -eq 'winget') {
                $Script:ResolvedToWinget = $true
                Invoke-PinnerReconcile -TargetDirs @()
            }
            Write-Ok $AlreadyInstalledMsg; Show-NextSteps; exit 0
        }
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
    Expand-ArchiveWithProgress -Path $outerZip -DestinationPath $artifactDir

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

# Remove a plain binary install at an arbitrary directory: drop the exe and
# (if now empty) the directory. Removes the PATH entry. Preserves user config
# (~\.config\pinner) unconditionally.
function Remove-PinnerBinary {
    param([string]$Dir, [switch]$SkipCompletions)
    $bin = Join-Path $Dir "$Script:ProgramName.exe"
    if (Test-Path $bin) { Remove-Item $bin -Force; Write-Info "Removed $bin" }
    else { Write-Warn "$bin not found." }
    if ((Test-Path $Dir) -and -not (Get-ChildItem $Dir -Recurse)) { Remove-Item $Dir -Force }
    Remove-FromPath $Dir
    if (-not $SkipCompletions) { Remove-Completions }
}

# Strip the Pinner CLI completions block from the PowerShell $PROFILE, if present.
function Remove-Completions {
    if ($PROFILE -and (Test-Path $PROFILE)) {
        $content = Get-Content $PROFILE -Raw
        $cleaned = $content -replace '(?m)^# Pinner CLI completions\r?\n.*?\r?\n', ''
        if ($cleaned -ne $content) { Set-Content $PROFILE $cleaned -NoNewline; Write-Info "Removed completions from $PROFILE" }
    }
}

# winget-managed install: proper `winget uninstall`. Winget does not expose its
# binary dir cleanly (its install Location is unresolvable), so if `winget
# uninstall` fails there is no reliable way to identify which on-disk binary
# belongs to the winget package. We therefore do NOT guess and delete an
# arbitrary binary/system install (that could be an unrelated legitimate pinner
# install); instead we warn and leave the winget install in place.
function Remove-PinnerWinget {
    param([switch]$SkipCompletions)
    if (Get-Command winget.exe -ErrorAction SilentlyContinue) {
        winget uninstall --id $Script:WinGetPackageId --accept-source-agreements --accept-package-agreements --disable-interactivity 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Info "Uninstalled via winget ($Script:WinGetPackageId)."; return }
        Write-Warn "winget uninstall failed and no winget binary location is resolvable; leaving the winget install in place."
    }
}

# scoop-managed install: proper `scoop uninstall`, falling back to binary removal.
function Remove-PinnerScoop {
    if (Get-Command scoop -ErrorAction SilentlyContinue) {
        scoop uninstall pinner 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Info 'Uninstalled via scoop.'; return }
        Write-Warn 'scoop uninstall failed. Removing binary directly.'
    }
    # The scoop shims dir is shared by every scoop-installed app (it holds the
    # shim .exe + the single PATH entry that resolves them all). Never run
    # Remove-PinnerBinary here: it would strip the shims PATH entry (breaking
    # every other scoop app) and wipe the profile completions block. Instead,
    # remove only the pinner shim(s).
    $shims = Join-Path $env:USERPROFILE 'scoop\shims'
    $pinnerShim = Join-Path $shims "$Script:ProgramName.exe"
    if (Test-Path $pinnerShim) { Remove-Item $pinnerShim -Force; Write-Info "Removed $pinnerShim" }
    else { Write-Warn "$pinnerShim not found." }
}

# Dispatch an uninstall for a single detected method.
function Remove-PinnerMethod {
    param([string]$Method, [string]$Location, [switch]$SkipCompletions)
    switch ($Method) {
        'binary' { Remove-PinnerBinary -Dir $Location -SkipCompletions:$SkipCompletions }
        'system' { Remove-PinnerBinary -Dir $Location -SkipCompletions:$SkipCompletions }
        'winget' { Remove-PinnerWinget -SkipCompletions:$SkipCompletions }
        'scoop'  { Remove-PinnerScoop }
        default  { Write-Warn "Unknown install method '$Method'; preserving install." }
    }
}

# Public -Uninstall: remove EVERY detected install method so no pinner binary
# is left floating on PATH. Config is always preserved.
function Invoke-PinnerUninstall {
    $foundAny = $false
    foreach ($inst in Get-PinnerLocations) {
        Write-Info "Uninstalling pinner installed via '$($inst.Method)' at $($inst.Location)"
        Remove-PinnerMethod -Method $inst.Method -Location $inst.Location
        $foundAny = $true
    }
    # Fall back to the default dir so -Uninstall stays valid for custom installs.
    if (-not $foundAny) {
        $dir = Get-InstallDir
        if (Test-Path (Join-Path $dir "$Script:ProgramName.exe")) {
            Write-Info "Uninstalling pinner from default dir $dir"
            Remove-PinnerBinary -Dir $dir
        }
    }
    Write-Ok 'Pinner CLI has been uninstalled.'
    exit 0
}

if ($Uninstall) {
    Invoke-PinnerUninstall
}

# ── Main install ───────────────────────────────────────────────────────────

# Cross-method reconciliation: remove any existing pinner install that a
# different method placed at a location other than this run's target(s), so
# only ONE `pinner` is ever on PATH (no shadowing on method change). User
# config is always preserved.
#
# $TargetDirs = array of locations this run may install into.
function Invoke-PinnerReconcile {
    param([string[]]$TargetDirs)
    foreach ($inst in @(Get-PinnerLocations)) {
        # Winget has no resolvable Location. Only remove an existing winget
        # install when this run did NOT actually resolve to winget (a
        # cross-method change, e.g. winget install failed and we fell back to
        # binary). When this run succeeded via winget (in-place upgrade), keep
        # the winget install.
        if ($inst.Method -eq 'winget') {
            if ($Script:ResolvedToWinget) { continue }
            # Skip completions: a cross-method change to a fresh install just
            # wrote the profile block; removing the old winget binary must not
            # delete it.
            Remove-PinnerWinget -SkipCompletions
            continue
        }
        if (-not $inst.Location) { continue }
        if ($TargetDirs -contains $inst.Location) { continue }
        Write-Warn "Removing existing pinner installed via '$($inst.Method)' at $($inst.Location) (target for this run differs)."
        Write-Info 'User config will be preserved.'
        # Skip completion removal: the fresh install wrote the '# Pinner CLI
        # completions' block moments ago, so reconciling away a differing-method
        # binary must not delete it.
        Remove-PinnerMethod -Method $inst.Method -Location $inst.Location -SkipCompletions
    }
    # Detection-only native calls above may have left a non-zero $LASTEXITCODE
    # (e.g. `winget list` in a CI container without a working source). Clear it
    # so the installer and any CI wrapper exit cleanly on success.
    $global:LASTEXITCODE = 0
}

# Internal self-test hook: PINNER_SELF_TEST=1 runs only the location scanner
# (no network, no install) so CI can unit-test cross-method detection.
if ($env:PINNER_SELF_TEST -eq '1') {
    Get-PinnerLocations | ForEach-Object { "{0}|{1}|{2}|{3}" -f $_.Method, $_.Location, $_.Version, $_.OnPath }
    exit 0
}

# Version resolution: -Version flag > PINNER_VERSION env > latest endpoint
$requestedVersion = if ($Version) { $Version } elseif ($env:PINNER_VERSION) { $env:PINNER_VERSION } else { $null }
$useSnapshot = $false

if ($requestedVersion) {
    if (Test-SemVer -Ver $requestedVersion) {
        $resolvedVersion = $requestedVersion -replace '^v', ''
        $versionLabel = "v$resolvedVersion"
    } elseif (Test-GitHash -Ver $requestedVersion) {
        $resolvedVersion = $requestedVersion
        $useSnapshot = $true
        $versionLabel = "commit $resolvedVersion"
    } else {
        # Treat as branch name
        $resolvedVersion = $requestedVersion
        $useSnapshot = $true
        $versionLabel = "branch $resolvedVersion"
    }
} else {
    $resolvedVersion = Get-LatestVersion
    $versionLabel = "v$resolvedVersion"
}

$usePkg = (-not $useSnapshot -and -not $NoPkg)
# Track whether a package manager actually succeeded this run and, specifically,
# whether it resolved to winget. Reconcile uses these (not the static $usePkg)
# so a PM that failed and fell back to a binary install is treated as
# cross-method and removed, preventing a stale winget install from shadowing
# the freshly installed binary.
$Script:PkgSucceeded = $false
$Script:ResolvedToWinget = $false

# Cross-method reconciliation target for the DIRECT BINARY path. Reconcile is
# DEFERRED until after a successful install (see Invoke-PMInstall and the binary
# path below), so a failed download or install never leaves the user without a
# working pinner. The target is scoped to the single directory the binary
# actually lands in (Get-InstallDir); a differing-method install at any other
# location is removed so it cannot shadow the fresh binary. The PM success path
# computes its own scoped target separately (see Invoke-PMInstall).
$BinaryTarget = @(Get-InstallDir)
# NOTE: Invoke-PinnerReconcile is intentionally NOT called here. It runs only
# after a successful install, so we never tear down an existing working pinner
# before its replacement is confirmed present.

# Skip package manager install for snapshot builds
if ($usePkg) {
    try-winget-install
    try-scoop-install
    Write-Info 'No supported package manager found. Falling back to binary download.'
}

$Arch = Get-Arch
$Version = $resolvedVersion
$InstallDir = Get-InstallDir

Write-Info "Installing Pinner CLI $versionLabel for windows/$Arch"

$existingBinary = Join-Path $InstallDir "$Script:ProgramName.exe"
if (Test-Path $existingBinary) {
    try {
        $currentVer = & $existingBinary --version 2>$null | Select-Object -First 1
        if ($currentVer -match '\d+\.\d+\.\d+') { Write-Info "Upgrading from v$($Matches[0]) to $versionLabel" }
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
    Expand-ArchiveWithProgress -Path $archivePath -DestinationPath $extractDir

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
    # New binary is confirmed present; remove any existing install that a
    # different method placed at a non-target location (deferred to here so a
    # failed download or extract never tears down an existing working pinner).
    Invoke-PinnerReconcile -TargetDirs $BinaryTarget
    Write-Ok "Pinner CLI $versionLabel installed successfully!"
    Show-NextSteps
    exit 0
} finally {
    Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
}
