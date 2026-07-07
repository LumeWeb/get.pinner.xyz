# get.pinner.xyz

Installer scripts for the [Pinner CLI](https://github.com/LumeWeb/pinner-cli). Hosted on IPFS at [get.pinner.xyz](https://get.pinner.xyz).

## Quick Start

### Linux / macOS

```sh
curl -fsSL https://get.pinner.xyz | sh
```

### Windows (PowerShell)

```powershell
iex (irm https://get.pinner.xyz/install.ps1)
```

## Version Targeting

Install a specific version using `--version` (Linux/macOS) or `-Version` (Windows). Three forms are supported:

| Form | Example | Source |
|------|---------|--------|
| Semver | `0.2.0` or `v0.2.0` | GitHub Releases |
| Git hash | `abc1234` (7-40 hex chars) | CI snapshot artifacts via [nightly.link](https://nightly.link) |
| Branch name | `develop` | CI snapshot artifacts via [nightly.link](https://nightly.link) |

```sh
# Semver
curl -fsSL https://get.pinner.xyz | sh -s -- --version 0.2.0

# Git commit hash
curl -fsSL https://get.pinner.xyz | sh -s -- --version abc1234

# Branch name
curl -fsSL https://get.pinner.xyz | sh -s -- --version develop
```

```powershell
# Windows
iex (irm https://get.pinner.xyz/install.ps1) -Version 0.2.0
iex (irm https://get.pinner.xyz/install.ps1) -Version abc1234
iex (irm https://get.pinner.xyz/install.ps1) -Version develop
```

You can also set the `PINNER_VERSION` environment variable instead of the flag. The `--version` / `-Version` flag takes priority.

## Options

### Linux / macOS (`install.sh`)

| Flag | Description |
|------|-------------|
| `--system` | Install to `/usr/local/bin` (requires sudo if not writable) |
| `--bin-dir DIR` | Install to custom directory |
| `--arch ARCH` | Override detected architecture (`amd64` or `arm64`) |
| `--version VER` | Target version: semver, git hash, or branch name |
| `--no-pkg` | Skip package manager detection (Homebrew), use binary install |
| `--uninstall` | Remove pinner CLI |
| `--debug` | Enable verbose output |
| `-h, --help` | Show help |

### Windows (`install.ps1`)

| Flag | Description |
|------|-------------|
| `-System` | Install to Program Files (requires admin) |
| `-Version VER` | Target version: semver, git hash, or branch name |
| `-NoPkg` | Skip package manager detection (winget/scoop), use binary install |
| `-Uninstall` | Remove pinner CLI |
| `-CI` | Enable CI mode (also activated by `CI=true` env var) |
| `-Debug` | Enable verbose output |
| `-Help` | Show help |

## Package Manager Integration

When a package manager is available, the installer uses it instead of downloading a binary directly:

- **macOS**: Homebrew (`lumeweb/tap/pinner`)
- **Windows**: winget (`Pinner.Cli`) or Scoop
- **Linux**: Binary install (no package manager integration)

Use `--no-pkg` / `-NoPkg` to force direct binary installation.

## CI Mode

In CI environments (`CI=true`), the installer can use local package manager manifests instead of downloading from registries. This is useful for testing:

| Env Var | Purpose |
|---------|---------|
| `PINNER_WINGET_MANIFEST` | Path to local winget manifest directory |
| `PINNER_SCOOP_MANIFEST` | Path to local scoop manifest JSON file |
| `PINNER_BREW_TAP` | Path to local Homebrew tap repository |
| `PINNER_BREW_FORMULA` | Homebrew formula name (default: `lumeweb/tap/pinner`) |

## Environment Variables

| Variable | Description |
|----------|-------------|
| `PINNER_VERSION` | Override version (same as `--version`; semver, hash, or branch) |
| `PINNER_INSTALL` | Custom install directory (same as `--bin-dir`) |
| `CI` | Set to `true` or `1` to enable CI mode |

## Uninstall

```sh
curl -fsSL https://get.pinner.xyz | sh -s -- --uninstall
```

```powershell
iex (irm https://get.pinner.xyz/install.ps1) -Uninstall
```

## How Snapshot Builds Work

For git hash and branch version targets, the installer downloads CI snapshot artifacts built by [GoReleaser](https://goreleaser.com) in the [pinner-cli CI pipeline](https://github.com/LumeWeb/pinner-cli/actions). Downloads are served via [nightly.link](https://nightly.link), which provides public, no-auth access to GitHub Actions artifacts.

- **Branch**: Direct nightly.link URL, zero API calls needed
- **Git hash**: One GitHub API call to resolve the short SHA to a run ID, then nightly.link for download

The snapshot artifact is a ZIP containing GoReleaser archives for all platforms. The installer extracts the ZIP, finds the platform-specific archive inside, and installs the binary.

## License

[MIT](LICENSE)
