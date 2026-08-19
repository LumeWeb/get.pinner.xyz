#!/bin/sh
# shellcheck shell=dash
set -eu

# Pinner CLI installer
# Usage: curl -fsSL https://get.pinner.xyz | sh
#        curl -fsSL https://get.pinner.xyz | sh -s -- --system
#        curl -fsSL https://get.pinner.xyz | sh -s -- --bin-dir /usr/local/bin

PROGRAM_NAME="pinner"
ARCHIVE_NAME="pinner-cli"
REPO="LumeWeb/pinner-cli"
BASE_URL="https://github.com/${REPO}/releases/download"
VERSION_URL="https://get.pinner.xyz/version"

# --- Shell compatibility guard -----------------------------------------------

if [ -n "${ZSH_VERSION+x}" ]; then
    echo "Error: Running with zsh is not supported. Please use sh." >&2
    exit 1
elif [ -n "${BASH_VERSION+x}" ] && [ -z "${POSIXLY_CORRECT+x}" ]; then
    echo "Warning: Running with non-POSIX bash may cause issues. Please use sh." >&2
fi

# --- Globals -----------------------------------------------------------------

INSTALL_DIR=""
OPT_SYSTEM=0
OPT_ARCH=""
OPT_BASE_URL=""
OPT_UNINSTALL=0
OPT_DEBUG=0
OPT_NO_PKG=0
OPT_VERSION=""
DETECTED_SHELL=""
RC_FILE=""

# GitHub Actions API for snapshot artifacts (commit hash / branch downloads)
ACTIONS_API="https://api.github.com/repos/${REPO}/actions"
ARTIFACT_NAME="pinner-cli-snapshot"
WORKFLOW_FILE="go.yml"

# Directory of this script (for CI local version file fallback)
SCRIPT_DIR="$(cd "$(dirname "$0")" 2> /dev/null && pwd || echo .)"

BREW_PACKAGE="lumeweb/tap/pinner"

# CI mode env vars (read once at startup, like PINNER_VERSION/PINNER_INSTALL)
PINNER_BREW_TAP="${PINNER_BREW_TAP:-}"
PINNER_BREW_FORMULA="${PINNER_BREW_FORMULA:-$BREW_PACKAGE}"

# --- Helper functions --------------------------------------------------------

info() {
    printf '\033[1;34m[info]\033[0m  %s\n' "$1" >&2
}

warn() {
    printf '\033[1;33m[warn]\033[0m  %s\n' "$1" >&2
}

error() {
    printf '\033[1;31m[error]\033[0m %s\n' "$1" >&2
}

completed() {
    printf '\033[1;32m[ok]\033[0m    %s\n' "$1" >&2
}

need_cmd() {
    if ! check_cmd "$1"; then
        error "Required command '$1' not found. Please install it and try again."
        exit 1
    fi
}

check_cmd() {
    command -v "$1" > /dev/null 2>&1
}

ensure() {
    if ! "$@"; then
        error "Command failed: $*"
        exit 1
    fi
}

ignore() {
    "$@" 2> /dev/null || true
}

# --- Download abstraction ----------------------------------------------------

curl_is_snap() {
    _curl_path="$(command -v curl 2> /dev/null || true)"
    case "${_curl_path}" in
        /snap/*) return 0 ;;
        *) return 1 ;;
    esac
}

# Emit TLS-restricting curl flags ONLY for https URLs. `--proto =https` blocks
# plain-HTTP downloads, so applying it unconditionally would break legitimate
# `--base-url` overrides to a local or internal HTTP mirror.
curl_tls_flags() {
    case "$1" in
        https://*) ;;
        *) return 0 ;;
    esac
    if curl --proto =https --tlsv1.2 --help > /dev/null 2>&1; then
        printf '%s' "--proto =https --tlsv1.2"
    fi
}

download() {
    _url="$1"
    _file="$2"

    case "$_url" in
        https://*) ;;
        *)
            # Plaintext downloads are refused by default: with an http mirror,
            # a MITM can substitute BOTH the archive and its checksum, so the
            # SHA256 check provides no integrity. Only an explicit ALLOW_HTTP=1
            # opt-in permits a non-https mirror; the operator then accepts that
            # integrity relies on checksum verification against that mirror.
            if [ "${ALLOW_HTTP:-0}" != 1 ]; then
                error "Refusing plaintext download from $_url; set ALLOW_HTTP=1 to permit an http mirror."
                return 1
            fi
            warn "Downloading over plaintext HTTP (non-https base-url). Integrity relies on checksum verification against the same mirror."
            ;;
    esac

    if check_cmd curl && ! curl_is_snap; then
        # shellcheck disable=SC2046
        curl --fail --silent --location $(curl_tls_flags "$_url") --connect-timeout 30 --max-time 300 --output "$_file" "$_url"
    elif check_cmd wget; then
        wget --quiet --timeout=30 --output-document="$_file" "$_url"
    elif check_cmd fetch; then
        fetch --quiet --timeout=30 --output="$_file" "$_url"
    else
        error "No download tool found. Install curl, wget, or fetch."
        exit 1
    fi
}

download_or_fail() {
    if ! download "$1" "$2"; then
        error "Download failed: $1"
        error "Check your network connection and that the version/architecture is correct."
        exit 1
    fi
}

download_or_warn() {
    if ! download "$1" "$2"; then
        return 1
    fi
    return 0
}

# --- Platform detection ------------------------------------------------------

detect_platform() {
    _os="$(uname -s | tr '[:upper:]' '[:lower:]')"
    case "$_os" in
        linux)  printf '%s' "linux" ;;
        darwin) printf '%s' "darwin" ;;
        msys_nt*|cygwin_nt*|mingw*)
            error "Windows is not supported. Use install.ps1 instead."
            exit 1
            ;;
        *)
            error "Unsupported operating system: $_os"
            exit 1
            ;;
    esac
}

detect_arch() {
    _arch="$(uname -m)"
    case "$_arch" in
        x86_64|x64|amd64)  printf '%s' "amd64" ;;
        aarch64|arm64)      printf '%s' "arm64" ;;
        *)
            error "Unsupported architecture: $_arch"
            exit 1
            ;;
    esac
}

# Rosetta 2 detection: if running under x86_64 emulation on Apple Silicon
detect_rosetta() {
    if [ "$(uname -s)" = "Darwin" ] && [ "$(uname -m)" = "x86_64" ]; then
        if (sysctl hw.optional.arm64 2> /dev/null || true) | grep -q ': 1'; then
            printf '%s' "arm64"
            return 0
        fi
    fi
    printf '%s' ""
}

check_32bit() {
    _bits="$(getconf LONG_BIT 2> /dev/null || true)"
    if [ "$_bits" = "32" ]; then
        error "32-bit systems are not supported."
        exit 1
    fi
}

# --- Version detection -------------------------------------------------------

fetch_url() {
    if check_cmd curl; then
        curl -fsSL "$1" 2> /dev/null || true
    elif check_cmd wget; then
        wget -qO- "$1" 2> /dev/null || true
    fi
}

clean_version() {
    printf '%s' "$1" | sed 's/^v//' | tr -d '[:space:]'
}

get_latest_version() {
    _ver=""

    # CI mode: read from local version file (avoids network dependency)
    if [ -n "${CI:-}" ] && [ -f "${SCRIPT_DIR:-.}/version" ]; then
        _ver="$(cat "${SCRIPT_DIR:-.}/version" 2> /dev/null || true)"
    fi

    # Primary: version endpoint
    if [ -z "$_ver" ]; then
        _ver="$(fetch_url "$VERSION_URL")"
    fi
    _ver="$(clean_version "$_ver")"

    # Fallback: GitHub API
    if [ -z "$_ver" ]; then
        _api_url="https://api.github.com/repos/${REPO}/releases/latest"
        _ver="$(fetch_url "$_api_url" | grep '"tag_name"' | head -n1 | sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\(.*\)".*/\1/')"
        _ver="$(clean_version "$_ver")"
    fi

    if [ -z "$_ver" ]; then
        error "Could not determine the latest version."
        exit 1
    fi

    printf '%s' "$_ver"
}

# --- Version type detection ---------------------------------------------------

# Returns 0 if the argument looks like a git commit hash (7-40 hex chars)
is_git_hash() {
    case "$1" in
        *[!0-9a-fA-F]*) return 1 ;;
    esac
    _len="${#1}"
    [ "$_len" -ge 7 ] && [ "$_len" -le 40 ]
}

# Returns 0 if the argument looks like a semantic version (e.g. 0.2.0, v1.2.3)
is_semver() {
    case "$1" in
        v*) _v="${1#v}" ;;
        *)  _v="$1" ;;
    esac
    case "$_v" in
        [0-9]*.[0-9]*.[0-9]*) return 0 ;;
        *) return 1 ;;
    esac
}

# --- Snapshot artifact download (for git hash / branch targets) ----------------

# nightly.link provides public, no-auth download links for GitHub Actions artifacts.
# URL formats:
#   Branch:  https://nightly.link/<owner>/<repo>/workflows/<workflow>/<branch>/<artifact>.zip
#   Run ID:  https://nightly.link/<owner>/<repo>/actions/runs/<run_id>/<artifact>.zip
NIGHTLY_LINK="https://nightly.link"

# Fetch JSON from the GitHub Actions API (still needed to resolve run IDs for hashes)
gh_api() {
    _url="$1"
    fetch_url "$_url"
}

# Resolve a short git hash to a full 40-char SHA via the GitHub commits API.
# Prints the full SHA, or empty on failure.
resolve_full_sha() {
    _short="$1"
    gh_api "https://api.github.com/repos/${REPO}/commits/${_short}" \
        | grep '"sha"' | head -n1 \
        | sed 's/.*"sha"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/'
}

# Find a successful workflow run ID for a given commit SHA.
# Uses the Actions API (head_sha requires full 40-char SHA).
# Prints the run ID, or empty on failure.
find_run_by_sha() {
    _sha="$1"
    _json="$(gh_api "${ACTIONS_API}/runs?per_page=10&head_sha=${_sha}&status=success")"
    printf '%s' "$_json" | grep '"id"' | head -n1 | sed 's/[^0-9]//g'
}

# Build the nightly.link download URL for a given ref (hash or branch).
# Prints the URL.
build_snapshot_url() {
    _ref="$1"
    if is_git_hash "$_ref"; then
        # Resolve short hashes to full 40-char SHA
        if [ "${#_ref}" -lt 40 ]; then
            _full="$(resolve_full_sha "$_ref")"
            if [ -z "$_full" ]; then
                error "Could not resolve commit hash '${_ref}'."
                exit 1
            fi
            _ref="$_full"
        fi
        _run_id="$(find_run_by_sha "$_ref")"
        if [ -z "$_run_id" ]; then
            error "No successful CI run found for commit '${_ref}'."
            error "Ensure a push to develop or PR has completed with artifacts."
            exit 1
        fi
        info "Found workflow run #${_run_id}"
        printf '%s' "${NIGHTLY_LINK}/${REPO}/actions/runs/${_run_id}/${ARTIFACT_NAME}.zip"
    else
        # Branch name — construct nightly.link URL directly
        printf '%s' "${NIGHTLY_LINK}/${REPO}/workflows/${WORKFLOW_FILE}/${_ref}/${ARTIFACT_NAME}.zip"
    fi
}

# Download and extract a snapshot artifact for the current platform/arch.
# Prints the path of the extracted inner archive.
download_snapshot_artifact() {
    _ref="$1"
    _tmpdir="$2"

    info "Looking up CI snapshot for ${_ref}..."
    _url="$(build_snapshot_url "$_ref")"

    # Download via nightly.link — no auth required
    _outer_zip="${_tmpdir}/snapshot-artifact.zip"
    info "Downloading snapshot artifact..."
    if check_cmd curl && ! curl_is_snap; then
        # shellcheck disable=SC2046
        curl --fail --silent --location $(curl_tls_flags "$_url") \
            --connect-timeout 30 --max-time 300 \
            --output "$_outer_zip" "$_url"
    elif check_cmd wget; then
        wget --quiet --timeout=30 \
            --output-document="$_outer_zip" "$_url"
    else
        error "No download tool found (curl or wget required)."
        exit 1
    fi

    # Extract outer ZIP (contains the dist/ directory from GoReleaser)
    info "Extracting artifact..."
    if check_cmd unzip; then
        unzip -q -o "$_outer_zip" -d "${_tmpdir}/artifact"
    elif check_cmd python3; then
        python3 -c "import zipfile; zipfile.ZipFile('$_outer_zip').extractall('${_tmpdir}/artifact')"
    else
        error "Cannot extract ZIP: install unzip or python3."
        exit 1
    fi

    # Find the inner archive for our platform/arch
    _inner_pattern="${ARCHIVE_NAME}_*_$(detect_platform)_${ARCH}"
    _inner_archive=""
    for _ext in tar.gz zip; do
        _found="$(find "${_tmpdir}/artifact" -name "${_inner_pattern}.${_ext}" -type f 2>/dev/null | head -n1)"
        if [ -n "$_found" ]; then
            _inner_archive="$_found"
            break
        fi
    done

    if [ -z "$_inner_archive" ]; then
        error "No archive found for $(detect_platform)/${ARCH} in snapshot artifact."
        error "Expected: ${ARCHIVE_NAME}_*_$(detect_platform)_${ARCH}.tar.gz or .zip"
        exit 1
    fi

    printf '%s' "$_inner_archive"
}

# --- SHA256 verification -----------------------------------------------------

compute_sha256() {
    _file="$1"
    if check_cmd sha256sum; then
        sha256sum "$_file" | cut -d' ' -f1
    elif check_cmd shasum; then
        shasum -a 256 "$_file" | cut -d' ' -f1
    else
        error "No SHA256 tool found. Install sha256sum or shasum."
        exit 1
    fi
}

verify_checksum() {
    _archive="$1"
    _checksums="$2"
    _expected="$(grep "${ARCHIVE_NAME}_${VERSION}_${PLATFORM}_${ARCH}.tar.gz" "$_checksums" | cut -d' ' -f1)"

    if [ -z "$_expected" ]; then
        error "Could not find checksum for ${ARCHIVE_NAME}_${VERSION}_${PLATFORM}_${ARCH}.tar.gz"
        exit 1
    fi

    _actual="$(compute_sha256 "$_archive")"

    if [ "$_expected" != "$_actual" ]; then
        error "SHA256 verification failed!"
        error "  Expected: $_expected"
        error "  Actual:   $_actual"
        rm -f "$_archive"
        exit 1
    fi
}

# --- Install directory -------------------------------------------------------

default_install_dir() {
    printf '%s' "${HOME}/.local/bin"
}

resolve_install_dir() {
    if [ -n "$INSTALL_DIR" ]; then
        printf '%s' "$INSTALL_DIR"
    elif [ -n "${PINNER_INSTALL:-}" ]; then
        printf '%s' "$PINNER_INSTALL"
    elif [ "$OPT_SYSTEM" = 1 ]; then
        printf '%s' "/usr/local/bin"
    else
        default_install_dir
    fi
}

test_writable() {
    _dir="$1"
    if [ ! -d "$_dir" ]; then
        return 1
    fi
    _test_file="${_dir}/.pinner_install_test_$$"
    if touch "$_test_file" 2> /dev/null; then
        rm -f "$_test_file"
        return 0
    else
        return 1
    fi
}

elevate_priv() {
    if [ "$(id -u)" = 0 ]; then
        # Already root
        return 0
    fi
    if check_cmd sudo && sudo -v 2> /dev/null; then
        return 0
    fi
    error "Install directory is not writable and sudo is not available."
    error "Try: sh install.sh --bin-dir ~/bin  or  mkdir -p ~/.local/bin"
    exit 1
}

# --- PATH configuration ------------------------------------------------------

detect_shell() {
    _shell="$(printf '%s' "${SHELL:-}" | sed 's|.*/||')"
    case "$_shell" in
        bash)  printf '%s' "bash" ;;
        zsh)   printf '%s' "zsh" ;;
        fish)  printf '%s' "fish" ;;
        *)     printf '%s' "bash" ;;
    esac
}

detect_rc_file() {
    _shell="$1"
    case "$_shell" in
        bash)  printf '%s' "${HOME}/.bashrc" ;;
        zsh)   printf '%s' "${HOME}/.zshrc" ;;
        fish)  printf '%s' "${HOME}/.config/fish/config.fish" ;;
        *)     printf '%s' "${HOME}/.bashrc" ;;
    esac
}

configure_path() {
    _dir="$1"
    _shell="$2"
    _rc="$3"

    # Check if already in PATH
    case ":${PATH}:" in
        *":${_dir}:"*) return 0 ;;
    esac

    # Check if already in RC file
    if [ -f "$_rc" ] && grep -q "$_dir" "$_rc" 2> /dev/null; then
        return 0
    fi

    # Create RC file if needed
    if [ ! -f "$_rc" ]; then
        _rc_dir="$(dirname "$_rc")"
        mkdir -p "$_rc_dir" 2> /dev/null || true
    fi

    case "$_shell" in
        fish)
            _line="set -gx PATH $_dir \$PATH"
            ;;
        *)
            _line="export PATH=\"${_dir}:\$PATH\""
            ;;
    esac

    printf '\n%s\n' "$_line" >> "$_rc"
    info "Added $_dir to PATH in $_rc"
    info "Run 'source $_rc' or start a new shell to update your PATH."
}

# --- Shell completions -------------------------------------------------------

install_completions() {
    _extract_dir="$1"
    _shell="$2"
    _completions_dir="${_extract_dir}/completions"

    if [ ! -d "$_completions_dir" ]; then
        warn "No completions directory found in archive."
        return 0
    fi

    case "$_shell" in
        bash)
            _dest="${HOME}/.local/share/bash-completion/completions/${PROGRAM_NAME}"
            _src="${_completions_dir}/${PROGRAM_NAME}.bash"
            ;;
        zsh)
            _dest="${HOME}/.local/share/zsh/site-functions/_${PROGRAM_NAME}"
            _src="${_completions_dir}/${PROGRAM_NAME}.zsh"
            ;;
        fish)
            _dest="${HOME}/.local/share/fish/vendor_completions.d/${PROGRAM_NAME}.fish"
            _src="${_completions_dir}/${PROGRAM_NAME}.fish"
            ;;
        *)
            return 0
            ;;
    esac

    if [ ! -f "$_src" ]; then
        warn "Completion file not found: $_src"
        return 0
    fi

    _dest_dir="$(dirname "$_dest")"
    mkdir -p "$_dest_dir" 2> /dev/null || true

    if [ -w "$_dest_dir" ]; then
        cp "$_src" "$_dest"
        completed "Installed $_shell completions to $_dest"
    else
        warn "Cannot write to $_dest_dir. Skipping completions."
    fi
}

# --- Uninstall ---------------------------------------------------------------

# Remove a plain binary install at an arbitrary directory: drop the binary,
# remove shell completions, and strip any PATH entry for that directory.
# Preserves user config (~/.config/pinner) unconditionally.
# $4 = skip_completions (1 to NOT touch completion files). Used by reconcile:
# the fresh install wrote user-level completions moments ago, so removing a
# differing-method binary must not delete them.
# $5 = elevate (1 to force-elevate removal of a system-dir binary, e.g. on the
# explicit --uninstall path; 0 to tolerate unprivileged removal failure, as
# during reconcile, so a non-root user never aborts a successful install over a
# stale shadowing binary).
# Returns 0 if no differing-method binary remains, 1 if one could not be removed
# (a leftover that may shadow the new install).
uninstall_binary() {
    _dir="$1"
    _shell="$2"
    _rc="$3"
    _skip_completions="${4:-0}"
    _elevate="${5:-0}"
    _binary="${_dir}/${PROGRAM_NAME}"
    _removed=0

    if [ -f "$_binary" ]; then
        case "$_dir" in
            /usr/bin|/usr/local/bin)
                # System dir: removing requires privileges. Unlike elevate_priv
                # (which exits the whole script when sudo is unavailable), the
                # uninstall path must stay non-fatal: a single unremovable
                # system binary must not abort the run and strand every other
                # method install on PATH. Check privileges and leave a clear
                # warning when they are missing.
                if [ "$(id -u)" = 0 ] || { check_cmd sudo && sudo -n true 2> /dev/null; }; then
                    sudo rm -f "$_binary"
                else
                    warn "No privileges to remove $_binary; leaving it in place (may shadow the new install)."
                fi
                ;;
            *)
                rm -f "$_binary"
                ;;
        esac
        if [ -f "$_binary" ]; then
            # Removal did not complete (no privileges).
            _removed=0
        else
            info "Removed $_binary"
            _removed=1
        fi
    else
        warn "$_binary not found."
        _removed=1
    fi

    # Only remove completions when this binary actually owns them. System/PM
    # dirs (/usr/bin, /usr/local/bin) manage their own completions, and during
    # reconcile the new install has already written the user-level files.
    if [ "$_skip_completions" != 1 ]; then
        case "$_dir" in
            /usr/bin|/usr/local/bin) : ;;  # pkg-managed: leave completions alone
            *)
                case "$_shell" in
                    bash)
                        rm -f "${HOME}/.local/share/bash-completion/completions/${PROGRAM_NAME}"
                        ;;
                    zsh)
                        rm -f "${HOME}/.local/share/zsh/site-functions/_${PROGRAM_NAME}"
                        ;;
                    fish)
                        rm -f "${HOME}/.local/share/fish/vendor_completions.d/${PROGRAM_NAME}.fish"
                        ;;
                esac
                ;;
        esac
    fi

    # Never edit PATH entries for system dirs. /usr/bin and /usr/local/bin are
    # provisioned by the OS (via /etc/profile, /etc/environment, etc.), not the
    # user shell rc file. Grepping them there would match any line containing
    # the substring and strip unrelated PATH components (e.g. /usr/local/bin
    # or /bin) from the user's rc.
    case "$_dir" in
        /usr/bin|/usr/local/bin)
            : # system PATH dirs: leave user rc untouched
            ;;
        *)
            if [ -f "$_rc" ]; then
                _tmp_rc="$(mktemp)"
                grep -v "$_dir" "$_rc" > "$_tmp_rc" 2> /dev/null || true
                if ! cmp -s "$_rc" "$_tmp_rc"; then
                    mv "$_tmp_rc" "$_rc"
                    info "Removed PATH entry from $_rc"
                else
                    rm -f "$_tmp_rc"
                fi
            fi
            ;;
    esac

    # Return 0 when no differing-method binary remains, 1 when one was left in
    # place (could not be removed). reconcile_install uses this to flag a
    # leftover that may shadow the new install.
    [ "$_removed" = 1 ]
}

# Return 0 if the given path is an OS-standard system directory that the
# installer must never delete wholesale (it merely manages the pinner file
# within it). Used to gate dir-removal and PATH-editing so /usr/bin and
# /usr/local/bin are never rmdir-ed or stripped less carefully than the OS
# expects.
is_system_dir() {
    case "$1" in
        /usr/bin|/usr/local/bin) return 0 ;;
        *) return 1 ;;
    esac
}

# Remove an empty install directory if it no longer contains anything.
uninstall_cleanup_dir() {
    _dir="$1"
    if [ -d "$_dir" ] && [ -z "$(ls -A "$_dir" 2> /dev/null || true)" ]; then
        rmdir "$_dir" 2> /dev/null || true
    fi
}

# Homebrew-managed install: proper `brew uninstall`, falling back to file
# removal if Homebrew is absent or the uninstall fails.
# $2 = skip_completions (forwarded to uninstall_binary so a cross-method
# reconcile never deletes the fresh install's user completions).
uninstall_brew() {
    _loc="$1"
    _skip="${2:-0}"
    if check_cmd brew && brew uninstall "$PINNER_BREW_FORMULA" 2> /dev/null; then
        info "Uninstalled via Homebrew ($PINNER_BREW_FORMULA)."
        return 0
    else
        warn "brew uninstall failed/absent. Removing binary directly."
        uninstall_binary "$_loc" "$DETECTED_SHELL" "$RC_FILE" "$_skip"
        _rc="$?"
        # Only remove the now-empty dir for a user location; never rmdir an
        # OS-standard system dir (e.g. /usr/local/bin) that other installs and
        # the OS expect to exist.
        if ! is_system_dir "$_loc"; then
            uninstall_cleanup_dir "$_loc"
        fi
        return "$_rc"
    fi
}

# Remove a potentially root-owned system binary if the runtime user may act.
# Returns 0 when the binary is gone, 1 when it is still present (no privileges
# or removal failed). Non-interactive only: an install-time reconcile must never
# block on a sudo password prompt mid-install. Written to take the path as an
# argument and act directly (rather than returning a command prefix to splice)
# because callers run under a newline-only IFS during reconcile, where word
# splitting a "rm -f" prefix would treat it as a single bogus command name.
rm_system_binary() {
    _bin="$1"
    if [ "$(id -u)" = 0 ]; then
        rm -f "$_bin"
    elif check_cmd sudo && sudo -n true 2> /dev/null; then
        sudo rm -f "$_bin"
    else
        return 1
    fi
    [ ! -e "$_bin" ]
}

# dpkg-managed install (package pinner-cli -> /usr/bin).
# $1 = elevate (1 on the explicit --uninstall path; 0 for reconcile). Behavior
# is driven by actual runtime privilege either way: when the package-manager
# removal fails (e.g. stale package record) and the user may act, the leftover
# binary is removed directly. A non-privileged user cannot remove a root-owned
# /usr/bin binary, so reconcile stays non-fatal and reports a leftover.
uninstall_dpkg() {
    _loc="/usr/bin"
    _elevate="${1:-0}"
    _ok=0
    if check_cmd dpkg; then
        if [ "$(id -u)" = 0 ]; then
            dpkg -r pinner-cli 2> /dev/null && _ok=1
        elif check_cmd sudo && { [ "$_elevate" = 1 ] || sudo -n true 2> /dev/null; }; then
            # Explicit --uninstall may prompt for sudo; a reconcile must not
            # block on a password prompt mid-install, so it requires non-interactive.
            sudo dpkg -r pinner-cli 2> /dev/null && _ok=1
        fi
    fi
    if [ "$_ok" = 1 ]; then
        info "Uninstalled via dpkg (pinner-cli)."
        return 0
    fi
    # Package-manager removal failed (or its record is stale). If the runtime
    # user may act and a binary is left behind, remove it directly.
    if [ -f "$_loc/$PROGRAM_NAME" ]; then
        if rm_system_binary "$_loc/$PROGRAM_NAME"; then
            info "dpkg uninstall failed/absent. Removing binary directly."
            return 0
        fi
        warn "No privileges to remove /usr/bin/$PROGRAM_NAME; leaving it in place (may shadow the new install)."
        return 1
    fi
    return 0
}

# rpm-managed install (package pinner-cli -> /usr/bin).
# $1 = elevate (1 on the explicit --uninstall path; 0 for reconcile). Same
# privilege-driven direct-removal fallback as uninstall_dpkg: a stale rpm
# record left after a dpkg removal (or on a dpkg-based host) must not leave a
# shadowing /usr/bin/pinner behind when the user can act.
uninstall_rpm() {
    _loc="/usr/bin"
    _elevate="${1:-0}"
    _ok=0
    if check_cmd rpm; then
        if [ "$(id -u)" = 0 ]; then
            rpm -e pinner-cli 2> /dev/null && _ok=1
        elif check_cmd sudo && { [ "$_elevate" = 1 ] || sudo -n true 2> /dev/null; }; then
            # Explicit --uninstall may prompt for sudo; a reconcile must not
            # block on a password prompt mid-install, so it requires non-interactive.
            sudo rpm -e pinner-cli 2> /dev/null && _ok=1
        fi
    fi
    if [ "$_ok" = 1 ]; then
        info "Uninstalled via rpm (pinner-cli)."
        return 0
    fi
    # Package-manager removal failed (or its record is stale). If the runtime
    # user may act and a binary is left behind, remove it directly.
    if [ -f "$_loc/$PROGRAM_NAME" ]; then
        if rm_system_binary "$_loc/$PROGRAM_NAME"; then
            info "rpm uninstall failed/absent. Removing binary directly."
            return 0
        fi
        warn "No privileges to remove /usr/bin/$PROGRAM_NAME; leaving it in place (may shadow the new install)."
        return 1
    fi
    return 0
}

# Dispatch an uninstall for a single detected method+location.
# $3 = skip_completions (1 when called from reconcile, so the fresh install's
# user-level completions are never removed).
# $4 = elevate (1 to force-elevate system-dir removal on explicit --uninstall;
# 0 for reconcile, which tolerates unprivileged removal failure).
# Returns 0 if no differing-method binary remains, 1 if a leftover remains.
uninstall_method() {
    _method="$1"
    _loc="$2"
    _skip="${3:-0}"
    _elevate="${4:-0}"
    case "$_method" in
        binary|system)
            uninstall_binary "$_loc" "$DETECTED_SHELL" "$RC_FILE" "$_skip" "$_elevate"
            _rc="$?"
            # Only remove the now-empty install directory for USER locations.
            # /usr/bin and /usr/local/bin are OS-standard system directories the
            # install/remove logic refuses to touch elsewhere: rmdir-ing them
            # would delete a directory other installs/uninstalls expect to exist.
            if ! is_system_dir "$_loc"; then
                uninstall_cleanup_dir "$_loc"
            fi
            return "$_rc"
            ;;
        brew)
            uninstall_brew "$_loc" "$_skip"
            ;;
        dpkg)
            uninstall_dpkg "$_elevate"
            ;;
        rpm)
            uninstall_rpm "$_elevate"
            ;;
        *)
            warn "Unknown install method '$_method'; preserving install at $_loc."
            ;;
    esac
}

# Public `--uninstall` entry: remove EVERY detected install method so no
# pinner binary is left floating on PATH. Config is always preserved.
uninstall() {
    _default_dir="$1"
    _shell="$2"
    _rc="$3"

    # Set globals used by uninstall dispatch.
    DETECTED_SHELL="$_shell"
    RC_FILE="$_rc"

    _found_any=0
    _scanned="$(scan_pinner_locations 2> /dev/null || true)"
    if [ -n "$_scanned" ]; then
        _oifs="$IFS"; IFS='
'
        for _line in $_scanned; do
            IFS='|' read -r _m _l _v _on <<EOF
$_line
EOF
            [ -z "$_m" ] && continue
            info "Uninstalling pinner installed via '$_m' at ${_l:-<unknown>}"
            uninstall_method "$_m" "$_l" 0 1 || true
            _found_any=1
        done
        IFS="$_oifs"
    fi

    # If scanner found nothing attributable, still attempt the default dir so the
    # script remains a valid uninstaller even for unusual/custom installs.
    if [ "$_found_any" = 0 ] && [ -x "${_default_dir}/${PROGRAM_NAME}" ]; then
        info "Uninstalling pinner from default dir $_default_dir"
        uninstall_binary "$_default_dir" "$_shell" "$_rc" || true
        # Only remove the now-empty dir for a user location; never rmdir an
        # OS-standard system dir (e.g. /usr/local/bin) expected to exist.
        if ! is_system_dir "$_default_dir"; then
            uninstall_cleanup_dir "$_default_dir"
        fi
    fi

    completed "Pinner CLI has been uninstalled."
    exit 0
}

# --- Flag parsing ------------------------------------------------------------

usage() {
    cat <<EOF
Pinner CLI Installer

Usage:
  curl -fsSL https://get.pinner.xyz | sh -s -- [flags]

Flags:
  --system           Install to /usr/local/bin (requires sudo if not writable)
  --bin-dir DIR      Install to custom directory
  --arch ARCH        Override detected architecture (amd64 or arm64)
  --version VER      Target version: semver (0.2.0), git hash (abc1234), or branch (develop)
  --base-url URL     Override download base URL (for testing)
  --no-pkg           Skip package manager detection (use binary install)
  --uninstall        Remove pinner CLI
  --debug            Enable verbose output
  -h, --help         Show this help message

Environment Variables:
  PINNER_INSTALL     Custom install directory (same as --bin-dir)
  PINNER_VERSION     Override version (same as --version; semver, hash, or branch)
  PINNER_BREW_TAP    Local path to a Homebrew tap directory (CI mode)
  PINNER_BREW_FORMULA  Override brew formula name (default: lumeweb/tap/pinner)

Examples:
  curl -fsSL https://get.pinner.xyz | sh
  curl -fsSL https://get.pinner.xyz | sh -s -- --system
  curl -fsSL https://get.pinner.xyz | sh -s -- --bin-dir ~/bin
  curl -fsSL https://get.pinner.xyz | sh -s -- --arch arm64
  curl -fsSL https://get.pinner.xyz | sh -s -- --version 0.2.0
  curl -fsSL https://get.pinner.xyz | sh -s -- --version abc1234
  curl -fsSL https://get.pinner.xyz | sh -s -- --version develop
EOF
}

parse_flags() {
    while [ $# -gt 0 ]; do
        _flag="$1"
        case "$_flag" in
            --system)
                OPT_SYSTEM=1
                ;;
            --bin-dir)
                shift
                INSTALL_DIR="${1:?--bin-dir requires a directory argument}"
                ;;
            --bin-dir=*)
                INSTALL_DIR="${_flag#--bin-dir=}"
                ;;
            --arch)
                shift
                OPT_ARCH="${1:?--arch requires an architecture argument}"
                ;;
            --arch=*)
                OPT_ARCH="${_flag#--arch=}"
                ;;
            --version)
                shift
                OPT_VERSION="${1:?--version requires a version argument}"
                ;;
            --version=*)
                OPT_VERSION="${_flag#--version=}"
                ;;
            --base-url)
                shift
                OPT_BASE_URL="${1:?--base-url requires a URL argument}"
                ;;
            --base-url=*)
                OPT_BASE_URL="${_flag#--base-url=}"
                ;;
            --uninstall)
                OPT_UNINSTALL=1
                ;;
            --no-pkg)
                OPT_NO_PKG=1
                ;;
            --debug)
                OPT_DEBUG=1
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                error "Unknown flag: $_flag"
                usage >&2
                exit 1
                ;;
        esac
        shift
    done
}

# --- Edge case detection -----------------------------------------------------

detect_wsl() {
    if [ -f /proc/version ]; then
        case "$(cat /proc/version 2> /dev/null)" in
            *microsoft*|*Microsoft*)
                info "Detected Windows Subsystem for Linux (WSL). Installing Linux binary."
                ;;
        esac
    fi
}

detect_root() {
    if [ "$(id -u)" = 0 ]; then
        warn "Running as root. This is unnecessary for default install to ~/.local/bin."
    fi
}

detect_existing() {
    _dir="$1"
    _existing="${_dir}/${PROGRAM_NAME}"
    if [ -x "$_existing" ]; then
        _current_ver="$("$_existing" --version 2> /dev/null | head -n1 | sed 's/^[^0-9]*\([0-9][0-9.]*\).*/\1/' || true)"
        if [ -n "$_current_ver" ]; then
            info "Upgrading from v$_current_ver to ${VERSION_LABEL}"
        else
            info "Replacing existing installation in $_dir"
        fi
    fi
}

# --- Cross-method location scanner -------------------------------------------
#
# pinner can be installed by several methods, each placing the binary in a
# DIFFERENT location (brew -> brew --prefix/bin, dpkg/rpm -> /usr/bin,
# binary -> ~/.local/bin (default), /usr/local/bin (--system), or --bin-dir).
# Historically each method only detected its OWN location, so a cross-method
# upgrade (e.g. brew -> binary) left two `pinner` binaries on PATH with one
# silently shadowing the other.
#
# scan_pinner_locations() is the DRY primitive: it enumerates EVERY known
# install location regardless of which method created it, reporting each hit.
# Output format (one line per existing install):
#     <method>|<location>|<version>|on_path
#   method  : binary|system|brew|dpkg|rpm   (how it is managed)
#   location: directory containing the binary ("" if not resolvable, e.g. dpkg)
#   version : parsed from `pinner --version` (may be empty if unparseable)
#   on_path : 1 if <location> is on the user's PATH, else 0
#
# Locations are scanned in PATH-precedence order so the FIRST hit is the one
# that currently wins on PATH (the "effective" current install).

# Returns 0 if directory $1 appears in the user's PATH.
dir_on_path() {
    _probe="$1"
    _oifs="$IFS"
    IFS=':'
    for _p in $PATH; do
        if [ -n "$_p" ] && [ "$_p" = "$_probe" ]; then
            IFS="$_oifs"
            return 0
        fi
    done
    IFS="$_oifs"
    return 1
}

# Read the version out of a pinner binary, normalized to X.Y.Z (or empty).
probe_version() {
    _bin="$1"
    "$_bin" --version 2> /dev/null | head -n1 | sed 's/^[^0-9]*\([0-9][0-9.]*\).*/\1/'
}

# Emit one scanner line for a binary install at a given method+location.
# Returns 0 only if the binary exists.
scan_binary_slot() {
    _method="$1"
    _loc="$2"
    [ -x "$_loc/${PROGRAM_NAME}" ] || return 1
    _v="$(probe_version "$_loc/${PROGRAM_NAME}")"
    _on=0
    dir_on_path "$_loc" && _on=1
    printf '%s|%s|%s|%s\n' "$_method" "$_loc" "$_v" "$_on"
    return 0
}

scan_pinner_locations() {
    # binary (default per-user)
    scan_binary_slot binary "${HOME}/.local/bin" || true
    # system (/usr/local/bin)
    scan_binary_slot system /usr/local/bin || true
    # Homebrew
    if check_cmd brew; then
        _brew_prefix="$(brew --prefix 2> /dev/null || true)"
        if [ -n "$_brew_prefix" ]; then
            scan_binary_slot brew "${_brew_prefix}/bin" || true
        fi
    fi
    # dpkg (package pinner-cli -> /usr/bin)
    if check_cmd dpkg && dpkg -l pinner-cli 2> /dev/null | grep -q '^ii'; then
        printf '%s|%s|%s|%s\n' dpkg /usr/bin "$(probe_version /usr/bin/pinner 2>/dev/null)" "$(dir_on_path /usr/bin && printf 1 || printf 0)"
    fi
    # rpm (package pinner-cli -> /usr/bin)
    if check_cmd rpm && rpm -q pinner-cli 2> /dev/null | grep -q 'pinner-cli'; then
        printf '%s|%s|%s|%s\n' rpm /usr/bin "$(probe_version /usr/bin/pinner 2>/dev/null)" "$(dir_on_path /usr/bin && printf 1 || printf 0)"
    fi
}

# Remove any existing pinner install that a DIFFERENT method placed at a
# location other than the one(s) this run will target. This prevents two
# `pinner` binaries floating on PATH (one silently shadowing the other) when
# the resolved install method changes (e.g. brew -> binary). User config
# (~/.config/pinner) and completions for the surviving target are preserved;
# only the differing-method binary and its PATH entry are removed.
#
# $1 = newline-separated list of locations this run may install into.
# Returns 0 if reconciliation fully cleaned up differing-method installs, or 1
# if one or more could not be removed (a leftover that may shadow the new
# install). A non-zero return is NON-FATAL: the new install already succeeded,
# so the caller reports success but surfaces the leftover to the user.
reconcile_install() {
    _target_dirs="$1"
    _scanned="$(scan_pinner_locations 2> /dev/null || true)"
    [ -z "$_scanned" ] && return 0

    _leftover=0
    _oifs="$IFS"; IFS='
'
    for _line in $_scanned; do
        IFS='|' read -r _m _l _v _on <<EOF
$_line
EOF
        [ -z "$_m" ] || [ -z "$_l" ] && continue

        # Skip if this install is at one of our target locations (in-place upgrade).
        _is_target=0
        _t_ifs="$IFS"; IFS='
'
        for _t in $_target_dirs; do
            [ -n "$_t" ] && [ "$_t" = "$_l" ] && _is_target=1
        done
        IFS="$_t_ifs"
        [ "$_is_target" = 1 ] && continue

        # Different-method install elsewhere on PATH -> remove it.
        warn "Removing existing pinner installed via '$_m' at $_l (target for this run differs)."
        info "User config (~/.config/pinner) will be preserved."
        # Skip completion removal: the fresh install wrote user-level
        # completions moments ago, so a reconciling removal must not delete them.
        if ! uninstall_method "$_m" "$_l" 1; then
            _leftover=1
        fi
    done
    IFS="$_oifs"

    if [ "$_leftover" = 1 ]; then
        # Non-fatal: the fresh install is in place and working, but an older
        # binary we could not remove (e.g. no privileges) may still shadow it.
        error "Reconciliation could not remove one or more existing pinner binaries; an older install may still shadow the new one on PATH."
        error "Re-run this installer with sudo/root, or remove the stale binary manually, so only the new pinner remains."
    fi
    return "$_leftover"
}

# Check if this is a first-time install (no config file exists yet)
is_new_install() {
    _config_dir="${HOME}/.config/pinner"
    [ ! -f "${_config_dir}/config.yaml" ]
}

# Show post-install next-steps guidance
show_next_steps() {
    if check_cmd "$PROGRAM_NAME"; then
        if is_new_install; then
            printf '\n'
            info "First time? Run 'pinner setup' to configure authentication and settings."
        else
            info "Run 'pinner --help' to get started."
        fi
    else
        printf '\n'
        info "Run 'source ${RC_FILE}' or start a new shell to use pinner."
        if is_new_install; then
            info "Then run 'pinner setup' for first-time configuration."
        fi
    fi
}

# --- Package manager install -------------------------------------------------

try_homebrew_install() {
    if [ "$(id -u)" = 0 ]; then
        return 1
    fi
    if ! check_cmd brew; then
        return 1
    fi
    info "Detected Homebrew. Installing via brew..."
    if [ -n "$PINNER_BREW_TAP" ] && [ -d "$PINNER_BREW_TAP" ]; then
        if ! brew tap lumeweb/tap "$PINNER_BREW_TAP"; then
            warn "brew tap (local) failed. Falling back to binary install."
            return 1
        fi
    else
        if ! brew tap lumeweb/tap; then
            warn "brew tap failed. Falling back to binary install."
            return 1
        fi
    fi
    if brew list "$PINNER_BREW_FORMULA" 2>/dev/null; then
        info "$PINNER_BREW_FORMULA is already installed via Homebrew."
        completed "Pinner CLI installed via Homebrew."
        show_next_steps
        return 0
    fi
    if ! brew install "$PINNER_BREW_FORMULA"; then
        warn "brew install failed. Falling back to binary install."
        return 1
    fi
    completed "Pinner CLI installed via Homebrew."
    show_next_steps
    return 0
}

try_pkg_install() {
    _pm_cmd="$1"
    _ext="$2"
    _install_cmd="$3"
    _install_arg="$4"

    if ! check_cmd "$_pm_cmd"; then
        return 1
    fi
    if [ "$(id -u)" != 0 ] && ! check_cmd sudo; then
        return 1
    fi
    info "Detected $_pm_cmd. Installing .${_ext} package..."
    _pkg_name="${ARCHIVE_NAME}_${VERSION}_${PLATFORM}_${ARCH}.${_ext}"
    _pkg_url="${OPT_BASE_URL:-${BASE_URL}}/v${VERSION}/${_pkg_name}"
    _pkg_file="${_tmpdir}/${_pkg_name}"
    if ! download_or_warn "$_pkg_url" "$_pkg_file"; then
        warn "$_ext package download failed. Falling back to binary install."
        return 1
    fi
    if [ "$(id -u)" = 0 ]; then
        if ! "$_install_cmd" "$_install_arg" "$_pkg_file" 2> /dev/null; then
            warn "$_pm_cmd install failed. Falling back to binary install."
            return 1
        fi
    else
        if ! sudo "$_install_cmd" "$_install_arg" "$_pkg_file" 2> /dev/null; then
            warn "$_pm_cmd install failed. Falling back to binary install."
            return 1
        fi
    fi
    completed "Pinner CLI installed via $_pm_cmd."
    show_next_steps
    return 0
}

try_dpkg_install() {
    try_pkg_install dpkg deb dpkg "-i"
}

try_rpm_install() {
    try_pkg_install rpm rpm rpm "-i"
}

# --- Main --------------------------------------------------------------------

main() {
    parse_flags "$@"

    # Internal self-test hook: PINNER_SELF_TEST=1 runs only the location
    # scanner (no network, no install) so CI can unit-test cross-method
    # detection in isolation.
    if [ "${PINNER_SELF_TEST:-}" = 1 ]; then
        scan_pinner_locations
        exit 0
    fi

    if [ "$OPT_DEBUG" = 1 ]; then
        set -x
    fi

    # Prerequisites
    need_cmd uname
    need_cmd tar
    need_cmd mktemp
    need_cmd chmod
    need_cmd rm
    need_cmd mkdir
    need_cmd cat

    # Detect platform and architecture
    PLATFORM="$(detect_platform)"
    check_32bit

    ARCH="${OPT_ARCH:-$(detect_arch)}"

    # Rosetta 2 override
    if [ -z "$OPT_ARCH" ]; then
        _rosetta="$(detect_rosetta)"
        if [ -n "$_rosetta" ]; then
            ARCH="$_rosetta"
            info "Detected Apple Silicon under Rosetta 2. Using arm64."
        fi
    fi

    # Validate arch
    case "$ARCH" in
        amd64|arm64) ;;
        *)
            error "Invalid architecture: $ARCH. Must be amd64 or arm64."
            exit 1
            ;;
    esac

    # Resolve install directory
    _install_dir="$(resolve_install_dir)"
    DETECTED_SHELL="$(detect_shell)"
    RC_FILE="$(detect_rc_file "$DETECTED_SHELL")"

    # Handle uninstall
    if [ "$OPT_UNINSTALL" = 1 ]; then
        uninstall "$_install_dir" "$DETECTED_SHELL" "$RC_FILE"
    fi

    # Edge case detection
    detect_wsl
    detect_root

    # Version resolution: --version flag > PINNER_VERSION env > latest endpoint
    _requested_version="${OPT_VERSION:-${PINNER_VERSION:-}}"
    _use_snapshot=0

    if [ -n "$_requested_version" ]; then
        if is_semver "$_requested_version"; then
            VERSION="$(clean_version "$_requested_version")"
            VERSION_LABEL="v${VERSION}"
        elif is_git_hash "$_requested_version"; then
            VERSION="$_requested_version"
            _use_snapshot=1
            VERSION_LABEL="commit ${VERSION}"
        else
            # Treat as branch name
            VERSION="$_requested_version"
            _use_snapshot=1
            VERSION_LABEL="branch ${VERSION}"
        fi
    else
        VERSION="$(get_latest_version)"
        VERSION_LABEL="v${VERSION}"
    fi
    info "Installing Pinner CLI ${VERSION_LABEL} for ${PLATFORM}/${ARCH}"

    # Cross-method reconciliation is DEFERRED until after a successful install
    # (below), so a failed download or install never leaves the user without a
    # working pinner. The target set is the location the binary REALLY landed
    # in this run, determined per branch: a package manager install targets its
    # own dir only, and the binary fallback targets $_install_dir only. Using
    # the actual installed location (rather than an optimistic union of all
    # possible locations) means a stale earlier package-manager binary in a dir
    # we did NOT install into this run is reconciled away, so it cannot shadow
    # the freshly installed binary. reconcile_install may return non-zero when
    # a stale binary could not be removed (e.g. no privileges); that is
    # non-fatal and reported inside reconcile_install, so the call is guarded
    # against `set -e` and never aborts the (already successful) install.

    # Create temp directory early (needed for package manager downloads)
    _tmpdir="$(mktemp -d)"
    trap 'rm -rf "$_tmpdir"' EXIT

    # Skip package manager install for snapshot builds
    if [ "$_use_snapshot" = 0 ] && [ "$OPT_NO_PKG" = 0 ]; then
        if [ "$PLATFORM" = "darwin" ]; then
            if try_homebrew_install; then
                # Homebrew install confirmed present: only the brew bin dir is a
                # target this run. A stale binary elsewhere (incl. $_install_dir)
                # is reconciled away so it cannot shadow the brew install.
                _brew_prefix="$(brew --prefix 2> /dev/null || true)"
                if [ -n "$_brew_prefix" ]; then
                    reconcile_install "${_brew_prefix}/bin" || true
                fi
                exit 0
            fi
        elif [ "$PLATFORM" = "linux" ]; then
            if try_dpkg_install; then
                reconcile_install "/usr/bin" || true
                exit 0
            fi
            if try_rpm_install; then
                reconcile_install "/usr/bin" || true
                exit 0
            fi
        fi
    fi

    if [ "$_use_snapshot" = 1 ]; then
        # Download snapshot artifact from GitHub Actions API
        _archive="$(download_snapshot_artifact "$VERSION" "$_tmpdir")"
        _archive_name="$(basename "$_archive")"

        # No checksums verification for snapshot builds (no published checksums)
        info "Downloaded ${_archive_name}"
    else
        # Construct download URL for GitHub Releases
        _dl_base="${OPT_BASE_URL:-${BASE_URL}}"
        _archive_name="${ARCHIVE_NAME}_${VERSION}_${PLATFORM}_${ARCH}.tar.gz"
        _archive_url="${_dl_base}/v${VERSION}/${_archive_name}"
        _checksums_url="${_dl_base}/v${VERSION}/checksums.txt"

        _archive="${_tmpdir}/${_archive_name}"
        _checksums="${_tmpdir}/checksums.txt"

        info "Downloading ${_archive_name}..."
        download_or_fail "$_archive_url" "$_archive"

        if [ ! -f "$_archive" ]; then
            error "Download failed. File not found: $_archive"
            error "Check that version ${VERSION_LABEL} exists for ${PLATFORM}/${ARCH}."
            exit 1
        fi

        info "Downloading checksums..."
        download_or_fail "$_checksums_url" "$_checksums"

        # Verify SHA256
        info "Verifying SHA256 checksum..."
        verify_checksum "$_archive" "$_checksums"
        completed "Checksum verified."
    fi

    # Extract
    info "Extracting..."
    case "$_archive" in
        *.tar.gz)
            tar -xzf "$_archive" -C "$_tmpdir"
            ;;
        *.zip)
            _extract_dir="${_tmpdir}/extract"
            mkdir -p "$_extract_dir"
            if check_cmd unzip; then
                unzip -q -o "$_archive" -d "$_extract_dir"
            elif check_cmd python3; then
                python3 -c "import zipfile; zipfile.ZipFile('$_archive').extractall('$_extract_dir')"
            else
                error "Cannot extract ZIP: install unzip or python3."
                exit 1
            fi
            ;;
    esac

    # Find the binary
    _binary="${_tmpdir}/${PROGRAM_NAME}"
    if [ ! -f "$_binary" ]; then
        # Try with strip-components in case of nested directory
        _binary="$(find "$_tmpdir" -name "$PROGRAM_NAME" -type f 2> /dev/null | head -n1)"
    fi

    if [ ! -f "$_binary" ]; then
        error "Could not find '${PROGRAM_NAME}' binary in archive."
        exit 1
    fi

    # Make executable
    if ! chmod +x "$_binary" 2> /dev/null; then
        error "Cannot make binary executable. The filesystem may be mounted noexec."
        error "Try: sh install.sh --bin-dir ~/bin"
        exit 1
    fi

    # Ensure install directory exists
    if [ ! -d "$_install_dir" ]; then
        if [ "$(id -u)" = 0 ]; then
            mkdir -p "$_install_dir"
        elif test_writable "$(dirname "$_install_dir")"; then
            mkdir -p "$_install_dir"
        else
            elevate_priv
            sudo mkdir -p "$_install_dir"
        fi
    fi

    # Detect existing installation
    detect_existing "$_install_dir"

    # Install binary
    if [ "$(id -u)" = 0 ]; then
        mv "$_binary" "${_install_dir}/${PROGRAM_NAME}"
    elif test_writable "$_install_dir"; then
        mv "$_binary" "${_install_dir}/${PROGRAM_NAME}"
    else
        elevate_priv
        sudo mv "$_binary" "${_install_dir}/${PROGRAM_NAME}"
    fi

    completed "Installed ${PROGRAM_NAME} to ${_install_dir}/${PROGRAM_NAME}"

    # Install completions
    install_completions "$_tmpdir" "$DETECTED_SHELL"

    # Configure PATH
    configure_path "$_install_dir" "$DETECTED_SHELL" "$RC_FILE"

    # New binary is confirmed present at $_install_dir. Reconcile only that dir
    # (the location the binary really landed in) as a target, so any stale
    # differing-method install elsewhere on PATH — including an old package
    # manager binary in /usr/bin or brew-prefix/bin — is reconciled away and
    # cannot shadow the fresh binary. Deferred to here so a failed download or
    # extract never tears down an existing working pinner. Guarded against
    # `set -e`: a leftover we could not remove is non-fatal (reported inside),
    # and the install has already succeeded.
    reconcile_install "$_install_dir" || true

    # Success
    printf '\n'
    completed "Pinner CLI ${VERSION_LABEL} installed successfully!"
    show_next_steps
}

main "$@"
