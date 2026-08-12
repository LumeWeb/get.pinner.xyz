# AGENTS.md

Technical reference for AI agents working on this repository.

## Repository Purpose

This repo hosts the installer scripts for [Pinner CLI](https://github.com/LumeWeb/pinner-cli). The scripts are deployed to IPFS and served at `get.pinner.xyz`. The domain itself is pinned via the LumeWeb Pinner infrastructure.

## Repository Layout

```
.
├── install.sh              # POSIX sh installer (Linux/macOS)
├── install.ps1             # PowerShell installer (Windows)
├── version                 # Latest release version string (e.g. "0.2.0")
├── README.md               # User-facing documentation
├── LICENSE
├── .github/workflows/
│   ├── deploy.yml          # Deploys install scripts to IPFS via Pinner
│   ├── update-version.yml  # Updates `version` file on pinner-cli releases
│   └── validate.yml        # CI: shellcheck, PSScriptAnalyzer, install tests
└── tests/
    └── fixtures/
        ├── homebrew-tap/   # Local Homebrew tap fixture for CI
        ├── scoop-manifest/ # Local Scoop manifest fixture for CI
        └── winget-manifest/ # Local winget manifest fixtures for CI
```

## Architecture

### Install Flow (install.sh)

1. **Parse flags** (`--system`, `--bin-dir`, `--arch`, `--version`, `--no-pkg`, `--uninstall`, `--debug`)
2. **Detect platform** via `uname -s` / `uname -m`
3. **Resolve version**:
   - `--version` flag > `PINNER_VERSION` env var > fetch from `get.pinner.xyz/version`
   - Version type detection: semver → GitHub Releases, git hash → CI snapshots, branch name → CI snapshots
4. **Package manager detection** (unless `--no-pkg` or version is a snapshot):
   - macOS: Homebrew
   - Linux: dpkg (`pinner-cli_<ver>_<arch>.deb`), then rpm (`pinner-cli_<ver>_<arch>.rpm`); both built by the `nfpms` block in `pinner-cli/.goreleaser.yaml` and published to every release.
5. **Cross-method reconciliation**: `scan_pinner_locations()` enumerates every existing `pinner` install regardless of method; `reconcile_install <targets>` removes any install that a different method placed at a non-target location, so exactly one binary exists on PATH after a method change.
6. **Binary install path**:
   - Semver: download from `github.com/LumeWeb/pinner-cli/releases/download/v<ver>/`
   - Snapshot: download via nightly.link, extract outer ZIP, find platform archive, extract, install
7. **Install** to `~/.local/bin` (or `--bin-dir` / `--system`)

### Install Flow (install.ps1)

Same flow but with Windows package managers:

1-3. Same as install.sh (flags: `-System`, `-Version`, `-NoPkg`, `-Uninstall`, `-CI`, `-Debug`)
4. Package manager detection: winget → scoop (unless `-NoPkg` or snapshot version)
5. Cross-method reconciliation via `Invoke-PinnerReconcile` (same behavior as the shell step)
6. Binary install to `$LOCALAPPDATA\Programs\pinner` (or `-System` for Program Files)

### Cross-Method Location Scan & Reconcile

Pinner can be installed by several methods, each placing the binary in a DIFFERENT location:
- nix: Homebrew → `$(brew --prefix)/bin`; dpkg/rpm → `/usr/bin` (package `pinner-cli`); binary → `~/.local/bin` (default), `/usr/local/bin` (`--system`), or `--bin-dir`
- Windows: winget; scoop → `~\scoop\shims`; binary → `%LOCALAPPDATA%\Programs\pinner` (or `%ProgramFiles%\pinner` with `-System`)

`scan_pinner_locations()` (sh) / `Get-PinnerLocations()` (PS) is the DRY primitive: it enumerates every known location regardless of which method created it, returning one record per hit (`method|location|version|on_path`). `uninstall_method` / `Remove-PinnerMethod` dispatch removal by method (proper package-manager uninstall with a binary-removal fallback). The reconcile step removes any existing install that a different method placed at a location other than this run's target(s), preventing PATH shadowing. User config (`~/.config/pinner`) is always preserved.

**Self-test hook:** `PINNER_SELF_TEST=1` (sh) / `$env:PINNER_SELF_TEST='1'` (PS) runs only the location scanner and exits before any network/install work, enabling isolated CI unit tests.

### Version Resolution

```
is_semver(ver)  →  GitHub Releases
is_git_hash(ver) → nightly.link (CI snapshot by run ID)
else (branch)   → nightly.link (CI snapshot by workflow/branch)
```

**Semver detection**: matches `^\d+\.\d+\.\d+` (with optional leading `v`).
**Git hash detection**: matches `^[0-9a-fA-F]{7,40}$`.

### Snapshot Download (nightly.link)

For git hash / branch versions, the installer constructs nightly.link URLs:

- **Branch**: `https://nightly.link/LumeWeb/pinner-cli/workflows/go.yml/<branch>/pinner-cli-snapshot.zip`
- **Run ID**: `https://nightly.link/LumeWeb/pinner-cli/actions/runs/<run_id>/pinner-cli-snapshot.zip`

For git hashes, one GitHub API call resolves the short SHA to a full 40-char SHA, then another finds the workflow run ID by `head_sha`. The nightly.link URL is then constructed with that run ID.

The artifact ZIP contains GoReleaser archives for all platforms:
```
pinner-cli_<version>_linux_amd64.tar.gz
pinner-cli_<version>_linux_arm64.tar.gz
pinner-cli_<version>_darwin_amd64.tar.gz
pinner-cli_<version>_darwin_arm64.tar.gz
pinner-cli_<version>_windows_amd64.zip
pinner-cli_<version>_windows_arm64.zip
```

The installer extracts the outer ZIP, finds the platform-specific archive, extracts that, and installs the binary.

### CI Mode

When `CI=true`, the install scripts use local package manager manifests instead of downloading from registries. This is controlled by env vars:
- `PINNER_WINGET_MANIFEST` — path to winget manifest directory
- `PINNER_SCOOP_MANIFEST` — path to scoop manifest JSON
- `PINNER_BREW_TAP` — path to local Homebrew tap git repo

## CI Workflows

### `validate.yml`

Runs on PRs and pushes to `develop`. Jobs:
- **lint**: shellcheck on `install.sh`, PSScriptAnalyzer on `install.ps1`
- **test-linux**: Binary install on Ubuntu/Alpine/Debian containers
- **test-macos-homebrew**: Homebrew install path using local tap fixture
- **test-macos-binary**: Binary install via `--no-pkg`
- **test-windows-binary**: Binary install on Windows
- **test-windows-winget**: winget manifest fixture path
- **test-windows-scoop**: scoop manifest fixture path (winget forced to fail)
- **test-windows-multi-pm**: Both winget + scoop manifest fixtures
- **test-windows-routing**: `-NoPkg` and `CI=1` env var routing
- **test-sh-routing**: Homebrew not attempted on Linux, `--no-pkg` routing, `PINNER_VERSION` env var
- **test-version-targeting**: Semver/hash/branch routing and flag priority

### `deploy.yml`

Runs on push to `develop` (when `install.sh`, `install.ps1`, `version`, or `deploy.yml` changes). Copies files to `dist/` and deploys to IPFS via `lumeweb/pinner-deploy-action`.

Key detail: `install.sh` is also copied to `dist/index.html` so that `get.pinner.xyz` (the root URL) serves the shell installer when fetched with `curl`.

### `update-version.yml`

Triggered by `repository_dispatch` event `pinner-cli-release` (fired by pinner-cli's release workflow) or manual dispatch. Strips leading `v` from the version tag, writes it to the `version` file, and pushes.

## Key Constants

| Constant | Value | Used For |
|----------|-------|----------|
| `REPO` | `LumeWeb/pinner-cli` | GitHub API, release URLs |
| `ARCHIVE_NAME` | `pinner-cli` | GoReleaser archive prefix |
| `ARTIFACT_NAME` | `pinner-cli-snapshot` | CI artifact name |
| `WORKFLOW_FILE` | `go.yml` | nightly.link workflow path |
| `BASE_URL` | `https://github.com/LumeWeb/pinner-cli/releases/download` | Semver release downloads |
| `VERSION_URL` | `https://get.pinner.xyz/version` | Latest version endpoint |

## Dependencies

- **pinner-cli**: The CLI being installed. Repo at `LumeWeb/pinner-cli`.
- **nightly.link**: Public proxy for GitHub Actions artifact downloads. No auth required.
- **GoReleaser**: Used in pinner-cli CI to build snapshot artifacts. Config at `LumeWeb/pinner-cli/.goreleaser.yaml`.
- **pinner-deploy-action**: LumeWeb's GitHub Action for deploying to IPFS via Pinner.

## Coding Conventions

- `install.sh` targets POSIX `sh` (not bash). Tested with `shellcheck -s sh`.
- `install.ps1` targets PowerShell 5.1+ (Windows Server 2016+). Linted with PSScriptAnalyzer.
- No external dependencies beyond `curl` or `wget` (shell) and `Invoke-WebRequest` (PowerShell).
- Use `info()`, `warn()`, `error()` helpers in shell for consistent output.
- Use `Write-Info`, `Write-Err` in PowerShell.
- All functions use `_` prefix for local variables in shell to avoid collisions.
- Version detection functions: `is_semver()`, `is_git_hash()` (shell) / `Test-Semver`, `Test-GitHash` (PowerShell).

## Testing

CI tests are in `validate.yml`. To test locally:

```sh
# Shell lint
shellcheck -s sh install.sh

# Shell install (dry run with debug)
sh install.sh --debug --no-pkg --version 0.2.0

# PowerShell lint (if pwsh available)
pwsh -Command "Invoke-ScriptAnalyzer -Path install.ps1 -Severity Error"
```

The version targeting tests verify routing logic (semver → Releases, hash → snapshots, branch → snapshots) without requiring actual artifact downloads.
