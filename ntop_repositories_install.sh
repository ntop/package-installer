#!/bin/sh
# ntop one-shot repository installer bootstrap
#
# Usage:
#   curl -fsSL https://packages.ntop.org/ntop_repositories_install.sh | sudo sh -s -- --dev
#   curl -fsSL https://packages.ntop.org/ntop_repositories_install.sh | sudo NTOP_CHANNEL=stable sh
#   curl -fsSL https://packages.ntop.org/ntop_repositories_install.sh | sh -s -- --dev
#   curl -fsSL https://packages.ntop.org/ntop_repositories_install.sh | sh -s -- --channel=stable
#
# What it does:
#   1. Detects the platform: Linux distribution/version, or FreeBSD family
#      (plain FreeBSD, pfSense, OPNsense) - and reports what it found
#   2. Detects whether the ntop repository is ALREADY configured, and for
#      which channel - if it's already configured for a DIFFERENT channel
#      than the one requested, this is reported explicitly and the existing
#      repo is left untouched (no double/conflicting configuration)
#   3. Requires the channel to be specified explicitly via --dev/--stable/
#      --channel=.../NTOP_CHANNEL - there is no default and no interactive
#      prompt; if none is given, the script prints a message and exits
#      without doing anything
#      -> on FreeBSD/pfSense/OPNsense only "dev" is published
#         (see https://packages.ntop.org/FreeBSD/); if "stable" was
#         requested there, this is reported and "dev" is used instead
#   4. Adds the correct repository for the detected platform:
#        - APT/YUM/DNF, following https://packages.ntop.org/ , on Linux
#        - pkg(8), following https://packages.ntop.org/FreeBSD/ , on
#          FreeBSD/pfSense/OPNsense
#      On EL10 (RHEL/Rocky/AlmaLinux/CentOS), redis is also installed via
#      remi, since it was dropped from EL10's own base repos upstream.
#   5. Prints a final message pointing the user at how to install whatever
#      packages they actually want (e.g. ntopng, nprobe) themselves.
#
# This script ONLY sets up the repository (and, where needed, a supporting
# dependency like redis) - it does not install, launch, or know anything
# about any particular ntop package or tool itself.
#
# This script handles Linux and the FreeBSD family (FreeBSD, pfSense,
# OPNsense). macOS, Windows and Docker still ship GUI/manual installers
# today (see https://packages.ntop.org/index.php); on those platforms the
# script prints the right instructions and stops instead of guessing.

set -e

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------

BOLD=""
NORMAL=""
RED=""
GREEN=""
if [ -t 1 ]; then
    BOLD="$(printf '\033[1m')"
    NORMAL="$(printf '\033[0m')"
    RED="$(printf '\033[31m')"
    GREEN="$(printf '\033[32m')"
fi

# By default only ok()/die() messages are printed. log() (verbose/progress
# detail) is silent unless --log was passed - see the early scan for it in
# main(), which runs before anything else so verbosity is in effect from
# the very first possible log() call (e.g. inside require_root()).
VERBOSE=0

log() {
    # Written as an `if` (not `[ ... ] && printf ...`) plus an explicit
    # `return 0` so this is always successful under `set -e`, regardless of
    # whether VERBOSE is on - a log() call must never itself abort the script.
    if [ "$VERBOSE" -eq 1 ]; then
        printf '%s[ntop-repo]%s %s\n' "$BOLD" "$NORMAL" "$1"
    fi
    return 0
}
ok()   { printf '%s[ntop-repo]%s %s%s%s\n' "$BOLD" "$NORMAL" "$GREEN" "$1" "$NORMAL"; }
die()  { printf '%s[ntop-repo]%s %sERROR: %s%s\n' "$BOLD" "$NORMAL" "$RED" "$1" "$NORMAL" >&2; exit 1; }

# Re-exec under sudo if not root, so the script works with the documented
# "curl | sh" one-liner style without forcing the user to type sudo first.
require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        if [ -f "$0" ] && [ -r "$0" ]; then
            if command -v sudo >/dev/null 2>&1; then
                log "Root privileges are required, re-running with sudo..."
                exec sudo -E sh "$0" "$@"
            else
                die "This script must be run as root (sudo not found)."
            fi
        else
            die "Root privileges are required, and this script can't re-exec itself with sudo when run via a pipe (no real file to re-run). Prefix the whole pipeline with sudo instead, e.g.: curl -fsSL <script-url> | sudo sh -s -- --dev   (or download the script first and run it directly)."
        fi
    fi
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1
}

# ----------------------------------------------------------------------------
# Channel selection: dev (nightly) vs stable
# ----------------------------------------------------------------------------

CHANNEL=""

parse_args() {
    for arg in "$@"; do
        case "$arg" in
            --channel=*)   CHANNEL="${arg#*=}" ;;
            --dev)         CHANNEL="dev" ;;
            --stable)      CHANNEL="stable" ;;
            --log)         VERBOSE=1 ;;
            -h|--help)
                cat <<EOF
Usage: ntop_repositories_install.sh --dev|--stable|--channel=dev|stable [--log]

  --dev            install nightly/development builds
  --stable         install stable builds
  --log            verbose logging (default: only success/error messages
                   are printed)

The channel must be specified explicitly - there is no default and this
script never prompts interactively for it. Environment variable
NTOP_CHANNEL is also honored (useful for non-interactive / curl | sh
usage).

This script only sets up the ntop package repository (and, on EL10, the
redis dependency it needs) - it does not install or launch any ntop
package itself. Use your package manager afterward for that, e.g.:
'apt install ntopng nprobe' or 'dnf install ntopng nprobe' or
'pkg install ntopng nprobe', depending on your platform.

On FreeBSD/pfSense/OPNsense only the 'dev' channel exists: --stable is
reported and 'dev' is used instead there.
EOF
                exit 0
                ;;
        esac
    done

    if [ -z "$CHANNEL" ] && [ -n "${NTOP_CHANNEL:-}" ]; then
        CHANNEL="$NTOP_CHANNEL"
    fi

    # No default and no interactive prompt: the channel must be given
    # explicitly, every time, on every platform.
    if [ -z "$CHANNEL" ]; then
        die "No channel specified. Pass --dev or --stable (or --channel=dev|stable, or set NTOP_CHANNEL). Run with --help for details."
    fi

    case "$CHANNEL" in
        dev|stable) : ;;
        *) die "Invalid channel '$CHANNEL' (expected 'dev' or 'stable')." ;;
    esac

    # PLATFORM_FAMILY is set by detect_os(), which must run before parse_args().
    if [ "$PLATFORM_FAMILY" = "freebsd" ] && [ "$CHANNEL" = "stable" ]; then
        # Only the dev/nightly channel is published for FreeBSD/pfSense/OPNsense
        # (see https://packages.ntop.org/FreeBSD/ - there is no *-stable
        # counterpart there today). Report it explicitly rather than silently
        # ignoring the request.
        log "Only the 'dev' (nightly) channel is published for FreeBSD/pfSense/OPNsense; 'stable' does not exist there yet (see https://packages.ntop.org/FreeBSD/). Using 'dev' instead."
        CHANNEL="dev"
    fi

    log "Selected channel: $CHANNEL"
}

# ----------------------------------------------------------------------------
# OS / distro detection
# ----------------------------------------------------------------------------

# PLATFORM_FAMILY is "linux" or "freebsd"; it is what every later stage
# branches on. detect_os() dispatches to the right detector based on the
# kernel, since /etc/os-release alone is not a reliable signal across this
# whole family (see detect_freebsd_os below).
PLATFORM_FAMILY=""

DISTRO_ID=""
DISTRO_VERSION=""
DISTRO_CODENAME=""
IS_RASPBERRY=0

FREEBSD_VARIANT=""   # freebsd | pfsense | opnsense
FREEBSD_MAJOR=""     # e.g. 14, 15, 16 (from `uname -r`)
FREEBSD_RELEASE=""   # full `uname -r`, e.g. 14.2-RELEASE-p3
ARCH=""              # `uname -m`, e.g. amd64

detect_os() {
    kernel="$(uname -s)"
    case "$kernel" in
        Linux)
            detect_linux_os
            ;;
        FreeBSD)
            detect_freebsd_os
            ;;
        *)
            die "Unsupported kernel '$kernel'. This script supports Linux and FreeBSD/pfSense/OPNsense; see https://packages.ntop.org/index.php for macOS/Windows instructions."
            ;;
    esac
}

detect_linux_os() {
    PLATFORM_FAMILY="linux"

    if [ ! -r /etc/os-release ]; then
        die "Cannot find /etc/os-release on this Linux system."
    fi
    # shellcheck disable=SC1091
    . /etc/os-release

    DISTRO_ID="${ID:-unknown}"
    DISTRO_VERSION="${VERSION_ID:-}"
    DISTRO_CODENAME="${VERSION_CODENAME:-}"

    # Raspberry Pi boards report as debian/raspbian in os-release but need
    # the dedicated *_pi ntop repository.
    if grep -qi "raspberry pi" /proc/cpuinfo 2>/dev/null \
       || grep -qi "raspberry pi" /proc/device-tree/model 2>/dev/null; then
        IS_RASPBERRY=1
    fi

    ok "Detected: platform=Linux ID=$DISTRO_ID VERSION_ID=$DISTRO_VERSION CODENAME=$DISTRO_CODENAME RaspberryPi=$IS_RASPBERRY"

    if [ "$IS_RASPBERRY" -eq 1 ]; then
        pi_arch="$(dpkg --print-architecture 2>/dev/null || echo unknown)"
        if [ "$pi_arch" != "arm64" ]; then
            die "This is a 32-bit Raspberry Pi OS install (dpkg architecture: '$pi_arch'), but ntop's Raspberry Pi packages are only published for arm64/64-bit (see https://www.ntop.org/support/documentation/software-installation/). The repo may already be (or would appear to be) successfully configured, but packages like nprobe/ntopng are not actually installable through it on this system. Use a 64-bit Raspberry Pi OS install, or check https://packages.ntop.org/RaspberryPI/ for any armhf-specific alternative."
        fi
    fi
}

# FreeBSD, pfSense and OPNsense all report kernel "FreeBSD" and often carry
# similar/no useful /etc/os-release content, so they are told apart using
# distribution-specific markers instead:
#   - OPNsense ships its own tree under /usr/local/opnsense and the
#     `opnsense-update`/`opnsense-version` tools.
#   - pfSense ships pfSense-specific helpers (`pfSsh.php`, `/etc/pfSense-rc`)
#     and historically identifies itself in /etc/platform.
#   - anything else with kernel FreeBSD is treated as plain FreeBSD.
detect_freebsd_os() {
    PLATFORM_FAMILY="freebsd"
    ARCH="$(uname -m)"
    FREEBSD_RELEASE="$(uname -r)"
    FREEBSD_MAJOR="$(echo "$FREEBSD_RELEASE" | cut -d. -f1)"

    if need_cmd opnsense-version || need_cmd opnsense-update \
       || [ -d /usr/local/opnsense ]; then
        FREEBSD_VARIANT="opnsense"
    elif need_cmd pfSsh.php \
         || [ -f /etc/pfSense-rc ] \
         || { [ -f /etc/platform ] && grep -qi pfsense /etc/platform 2>/dev/null; }; then
        FREEBSD_VARIANT="pfsense"
    else
        FREEBSD_VARIANT="freebsd"
    fi

    ok "Detected: platform=FreeBSD variant=$FREEBSD_VARIANT release=$FREEBSD_RELEASE major=$FREEBSD_MAJOR arch=$ARCH"
}

# ----------------------------------------------------------------------------
# Idempotency check: is the ntop repo already configured, and for which
# channel?
# ----------------------------------------------------------------------------

# Sets INSTALLED_CHANNEL to "dev", "stable" or "unknown" (repo present but we
# can't tell which channel it points at), leaves it empty if no repo is
# configured at all.
INSTALLED_CHANNEL=""

repo_already_configured() {
    INSTALLED_CHANNEL=""

    if [ "$PLATFORM_FAMILY" = "freebsd" ]; then
        # Only one channel ("dev") is published for this family, so if the
        # repo is present at all it is, by definition, the dev channel.
        if [ -f /usr/local/etc/pkg/repos/ntop.conf ]; then
            INSTALLED_CHANNEL="dev"
            return 0
        fi
        if need_cmd pkg && pkg info -e ntop-1.0 >/dev/null 2>&1; then
            INSTALLED_CHANNEL="dev"
            return 0
        fi
        return 1
    fi

    # APT-based systems: the installed bootstrap package name tells us the
    # channel unambiguously.
    if need_cmd dpkg-query; then
        if dpkg-query -W -f='${Status}' apt-ntop-stable 2>/dev/null | grep -q "install ok installed"; then
            INSTALLED_CHANNEL="stable"
            return 0
        fi
        if dpkg-query -W -f='${Status}' apt-ntop 2>/dev/null | grep -q "install ok installed"; then
            INSTALLED_CHANNEL="dev"
            return 0
        fi
    fi

    # Raspbian/other apt setups where ntop.list might exist for some other
    # reason: the docs only publish one (dev) set of lines historically for
    # this platform, so we can't distinguish a channel from the file alone.
    if [ -f /etc/apt/sources.list.d/ntop.list ]; then
        INSTALLED_CHANNEL="unknown"
        return 0
    fi

    # YUM/DNF-based systems: the ntop.repo baseurl points at either
    # .../centos/... (dev) or .../centos-stable/... (stable).
    if [ -f /etc/yum.repos.d/ntop.repo ]; then
        if grep -q "centos-stable" /etc/yum.repos.d/ntop.repo 2>/dev/null; then
            INSTALLED_CHANNEL="stable"
        elif grep -Eq "baseurl.*/centos/" /etc/yum.repos.d/ntop.repo 2>/dev/null; then
            INSTALLED_CHANNEL="dev"
        else
            INSTALLED_CHANNEL="unknown"
        fi
        return 0
    fi

    return 1
}

# ----------------------------------------------------------------------------
# Debian / Ubuntu / Raspbian (apt)
# ----------------------------------------------------------------------------

setup_apt_common_tools() {
    apt-get update -qq
    apt-get install -y wget whiptail lsb-release gnupg \
        apt-transport-https ca-certificates >/dev/null
}

add_contrib_if_missing() {
    # Debian only: packages.ntop.org requires "contrib" enabled. Debian's
    # sources layout differs by release/image:
    #   - legacy one-line format: /etc/apt/sources.list, "deb ... main"
    #   - DEB822 format (default on Debian 12/bookworm+ official images):
    #     /etc/apt/sources.list.d/*.sources, "Components: main"
    # Both are handled, idempotently, and we report if neither was found
    # rather than silently doing nothing.
    touched_any=0
    found_any=0

    legacy="/etc/apt/sources.list"
    if [ -f "$legacy" ] && [ -s "$legacy" ]; then
        found_any=1
        if grep -Eq '^deb(-src)? .*contrib' "$legacy" 2>/dev/null; then
            log "'contrib' component already present in $legacy"
        else
            log "Enabling 'contrib' component in $legacy"
            cp "$legacy" "${legacy}.ntop-repo.bak"
            sed -i -E '/^deb(-src)? /{/contrib/!s/$/ contrib/}' "$legacy"
            touched_any=1
        fi
    fi

    for f in /etc/apt/sources.list.d/*.sources; do
        [ -f "$f" ] || continue
        grep -Eq '^Components:' "$f" 2>/dev/null || continue
        found_any=1
        if grep -Eq '^Components:.*\bcontrib\b' "$f" 2>/dev/null; then
            log "'contrib' component already present in $f"
        else
            log "Enabling 'contrib' component in $f"
            cp "$f" "${f}.ntop-repo.bak"
            sed -i -E 's/^(Components:.*)$/\1 contrib/' "$f"
            touched_any=1
        fi
    done

    if [ "$found_any" -eq 0 ]; then
        log "WARNING: no recognizable apt sources file found to enable 'contrib' in (checked $legacy and /etc/apt/sources.list.d/*.sources). If package installs fail later with 'unable to locate package', enable 'contrib' manually."
    fi
    [ "$touched_any" -eq 1 ] || return 0
}

setup_ubuntu() {
    case "$DISTRO_VERSION" in
        22.04|24.04|26.04) ;;
        *) die "Unsupported Ubuntu version '$DISTRO_VERSION'. Supported per current docs: 22.04, 24.04, 26.04 (see https://www.ntop.org/support/documentation/software-installation/)." ;;
    esac

    setup_apt_common_tools
    # software-properties-common (for add-apt-repository) is Ubuntu-specific;
    # Debian doesn't need it and, as of trixie, doesn't reliably ship it.
    apt-get install -y software-properties-common >/dev/null
    add-apt-repository -y universe

    workdir="$(mktemp -d)"
    if [ "$CHANNEL" = "stable" ]; then
        case "$DISTRO_VERSION" in
            22.04|24.04|26.04) pkg="apt-ntop-stable.deb" ;;
            *) die "Stable channel is not published for Ubuntu $DISTRO_VERSION yet (see https://www.ntop.org/support/documentation/software-installation/). Try --dev instead." ;;
        esac
        url="https://packages.ntop.org/apt-stable/$DISTRO_VERSION/all/$pkg"
    else
        pkg="apt-ntop.deb"
        url="https://packages.ntop.org/apt/$DISTRO_VERSION/all/$pkg"
    fi

    log "Downloading $url"
    wget -q -O "$workdir/$pkg" "$url" || die "Could not download $url"
    apt install -y "$workdir/$pkg"
    rm -rf "$workdir"
}

setup_debian_like() {
    # $1 = codename (bullseye|bookworm|trixie)
    codename="$1"

    setup_apt_common_tools
    add_contrib_if_missing

    workdir="$(mktemp -d)"
    if [ "$CHANNEL" = "stable" ]; then
        case "$codename" in
            bullseye|bookworm|trixie)
                url="https://packages.ntop.org/apt-stable/$codename/all/apt-ntop-stable.deb"
                ;;
            *) die "Unsupported Debian codename '$codename'." ;;
        esac
    else
        case "$codename" in
            bullseye|bookworm|trixie)
                url="https://packages.ntop.org/apt/$codename/all/apt-ntop.deb"
                ;;
            *) die "Unsupported Debian codename '$codename'." ;;
        esac
    fi

    pkg="$(basename "$url")"
    log "Downloading $url"
    wget -q -O "$workdir/$pkg" "$url" || die "Could not download $url"
    apt install -y "$workdir/$pkg"
    rm -rf "$workdir"
}

setup_raspbian() {
    # As of this writing, ntop's own current instructions (packages.ntop.org
    # index page) use a self-contained bootstrap .deb here - the same
    # pattern as Debian/Ubuntu, NOT the older "echo deb-lines into
    # sources.list.d" approach (which pointed at apt.ntop.org, a domain that
    # no longer resolves). (The arm64-only architecture check for this
    # platform lives in detect_linux_os(), since it must fire even when the
    # repo is already configured and this function never runs again.)
    #
    # Per https://www.ntop.org/support/documentation/software-installation/
    # only ONE build is currently documented for Raspbian/rPi OS - there is
    # no separate stable tab/URL at all (unlike Debian/Ubuntu/RHEL family).
    if [ "$CHANNEL" = "stable" ]; then
        ok "Only the 'dev' (nightly) build is currently documented for Raspbian/rPi OS (see https://www.ntop.org/support/documentation/software-installation/). Using it instead of 'stable'."
    fi
    setup_apt_common_tools

    workdir="$(mktemp -d)"
    url="https://packages.ntop.org/RaspberryPI/apt-ntop.deb"

    log "Downloading $url"
    wget -q -O "$workdir/apt-ntop.deb" "$url" || die "Could not download $url"
    apt install -y "$workdir/apt-ntop.deb"
    rm -rf "$workdir"
}

# ----------------------------------------------------------------------------
# RHEL family (CentOS / Rocky / AlmaLinux / RHEL) via yum/dnf
# ----------------------------------------------------------------------------

setup_rhel_like() {
    major="$(echo "$DISTRO_VERSION" | cut -d. -f1)"

    if [ "$CHANNEL" = "stable" ]; then
        repo_url="https://packages.ntop.org/centos-stable/ntop.repo"
    else
        repo_url="https://packages.ntop.org/centos/ntop.repo"
    fi

    log "Adding ntop repo file from $repo_url"
    curl -fsSL "$repo_url" -o /etc/yum.repos.d/ntop.repo || die "Could not download $repo_url"

    # `dnf config-manager` (used below to enable crb/powertools/remi) is
    # provided by the dnf-plugins-core plugin, which is not installed by
    # default on minimal images (e.g. official rockylinux/almalinux
    # containers). Install it once, up front, idempotently.
    if need_cmd dnf; then
        dnf install -y dnf-plugins-core
    elif need_cmd yum; then
        yum install -y dnf-plugins-core
    fi

    case "$DISTRO_ID" in
        rocky|almalinux)
            case "$major" in
                9|10)
                    if [ "$major" = "9" ]; then
                        dnf config-manager --set-enabled crb
                    fi
                    dnf install -y epel-release
                    ;;
                8)
                    dnf config-manager --set-enabled powertools
                    dnf install -y epel-release
                    ;;
                *) die "Unsupported $DISTRO_ID version '$DISTRO_VERSION'." ;;
            esac
            ;;
        centos|rhel)
            case "$major" in
                8)
                    yum install -y epel-release
                    rpm -ivh http://rpms.remirepo.net/enterprise/remi-release-8.rpm || true
                    dnf config-manager --set-enabled powertools
                    dnf config-manager --set-enabled remi
                    ;;
                9|10)
                    if [ "$major" = "9" ]; then
                        dnf config-manager --set-enabled crb
                    fi
                    dnf install -y epel-release
                    ;;
                *) die "Unsupported $DISTRO_ID version '$DISTRO_VERSION'." ;;
            esac
            ;;
        *)
            die "Unsupported RHEL-family distro '$DISTRO_ID'."
            ;;
    esac

    if [ "$major" = "10" ]; then
        # New as of the current docs: redis was dropped from EL10's base
        # repos by the distro maintainers and must be installed manually via
        # remi, or package installs the user does later (e.g. ntopng) can
        # fail on the missing redis dependency.
        log "EL10: redis was removed from base repos upstream - installing it via remi, per current docs."
        dnf install -y https://rpms.remirepo.net/enterprise/remi-release-10.rpm \
            || die "Could not install remi-release-10.rpm (needed for redis on EL10)."
        dnf module enable -y redis:remi-7.2 \
            || die "Could not enable the redis:remi-7.2 module stream."
        dnf install -y redis \
            || die "Could not install redis from the remi repo."
        systemctl enable redis 2>/dev/null || log "WARNING: 'systemctl enable redis' failed (non-systemd container? harmless if so)."
    fi
}

# ----------------------------------------------------------------------------
# FreeBSD / pfSense / OPNsense (pkg)
# ----------------------------------------------------------------------------

setup_freebsd_family() {
    case "$ARCH" in
        amd64) : ;;
        *) die "Unsupported architecture '$ARCH' for FreeBSD/pfSense/OPNsense. Only amd64 is published (see https://packages.ntop.org/FreeBSD/)." ;;
    esac

    case "$FREEBSD_MAJOR" in
        14|15|16) : ;;
        *) die "Unsupported FreeBSD major version '$FREEBSD_MAJOR' (from '$FREEBSD_RELEASE'). Supported per current docs: 14, 15, 16 (see https://www.ntop.org/support/documentation/software-installation/)." ;;
    esac

    need_cmd pkg || die "'pkg' command not found."

    # Unlike apt/yum this is a single step: `pkg add` on this bootstrap
    # package both registers the ntop repository and installs it, mirroring
    # what apt-ntop.deb / ntop.repo do on Linux.
    url="https://packages.ntop.org/FreeBSD/FreeBSD:${FREEBSD_MAJOR}:${ARCH}/latest/ntop-1.0.pkg"
    log "Adding the ntop repository via: pkg add $url"
    pkg add "$url" || die "Could not add the ntop repository from $url"
}

# ----------------------------------------------------------------------------
# Final step: refresh the apt index where relevant (dnf/yum/pkg refresh on
# their own), then tell the user what to do next. This script only ever
# sets up the repository (and, on EL10, redis) - it never installs or
# launches any ntop package/tool itself.
# ----------------------------------------------------------------------------

finish() {
    install_cmd=""

    if [ "$PLATFORM_FAMILY" = "freebsd" ]; then
        install_cmd="pkg install ntopng nprobe"
        if [ "$FREEBSD_VARIANT" != "freebsd" ]; then
            log "Note: $FREEBSD_VARIANT ships a subset of the FreeBSD packages (e.g. Kafka support is not available). See https://packages.ntop.org/FreeBSD/ for details."
        fi
    elif need_cmd apt-get; then
        # Always refresh, even when the repo config was already present:
        # "the repo file/package is there" does NOT guarantee the local apt
        # index cache is actually populated/fresh (stale after a reboot, a
        # cleared cache, time passing, etc.).
        apt-get clean all
        apt-get update -qq
        install_cmd="apt install ntopng nprobe"
    elif need_cmd dnf; then
        install_cmd="dnf install ntopng nprobe"
    elif need_cmd yum; then
        install_cmd="yum install ntopng nprobe"
    fi

    ok "ntop repositories are ready."
    if [ -n "$install_cmd" ]; then
        ok "Now you can manually install the wanted program, for example via '$install_cmd' (or similar)."
    else
        ok "Now you can manually install the wanted program using your platform's package manager."
    fi
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------

main() {
    # Cheap early scan just for --log, so verbosity is already in effect for
    # every log() call from here on - including ones inside require_root()
    # and detect_os(), both of which run before the real parse_args() call
    # (parse_args() also recognizes --log itself, for --help/consistency,
    # but by then require_root()/detect_os() would already have run).
    for arg in "$@"; do
        if [ "$arg" = "--log" ]; then
            VERBOSE=1
        fi
    done

    require_root "$@"
    # detect_os runs before parse_args because channel validation depends
    # on PLATFORM_FAMILY (only "dev" exists on the FreeBSD family).
    detect_os
    parse_args "$@"

    if repo_already_configured; then
        if [ "$PLATFORM_FAMILY" = "freebsd" ]; then
            ok "ntop repository already configured for $FREEBSD_VARIANT, skipping repository setup."
            finish
            return
        fi

        case "$INSTALLED_CHANNEL" in
            "$CHANNEL")
                ok "ntop repository already configured with the '$CHANNEL' channel, skipping repository setup."
                ;;
            unknown)
                die "ntop repository already configured, but this script cannot determine which channel (dev/stable) it points to. Skipping repository setup; remove the existing ntop repo files manually first if you need to switch to '$CHANNEL'."
                ;;
            *)
                die "ntop repository already configured, but with the '$INSTALLED_CHANNEL' channel, NOT the requested '$CHANNEL' channel. Skipping repository setup. If you want to switch channel, please look at https://www.ntop.org/faq/how-can-i-switch-from-stable-to-dev-builds-or-vice-versa/"
                ;;
        esac
        finish
        return
    fi

    if [ "$PLATFORM_FAMILY" = "freebsd" ]; then
        setup_freebsd_family
        finish
        return
    fi

    case "$DISTRO_ID" in
        ubuntu)
            setup_ubuntu
            ;;
        raspbian)
            setup_raspbian
            ;;
        debian)
            if [ "$IS_RASPBERRY" -eq 1 ]; then
                setup_raspbian
            else
                case "$DISTRO_CODENAME" in
                    bullseye|bookworm|trixie) setup_debian_like "$DISTRO_CODENAME" ;;
                    *) die "Unsupported Debian codename '$DISTRO_CODENAME'." ;;
                esac
            fi
            ;;
        rocky|almalinux|centos|rhel)
            setup_rhel_like
            ;;
        *)
            die "Unsupported/unrecognized distribution '$DISTRO_ID'. See https://packages.ntop.org/index.php for manual instructions (macOS, Windows, Docker)."
            ;;
    esac

    ok "ntop repository added successfully (channel: $CHANNEL)."
    finish
}

main "$@"
