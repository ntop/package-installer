#!/bin/sh

# ==============================================================================
#
# (C) 2026 - ntop
#
# Cross-Platform OS Detection & Installer
# Supports: Debian, Ubuntu, RH/Rocky Linux, FreeBSD
# ==============================================================================

set -eu

# Default option values
STABLE=
BRANCH="dev"

# 0. Usage Help & Argument Parsing
usage() {
    cat <<EOF
Usage: $0 [-s] [-h]
	
Options:	
  -s    Install stable packages version. Default is dev (nightly).
  -h    Show this help message and exit
EOF
}

parse_args() {
    # Use "s:h" instead of "sh" if -s requires a value (e.g., -s foo)
    while getopts "sh" opt; do
	case "$opt" in
	    s)
		STABLE="-stable"
		BRANCH="stable"
		;;
	    h)
		usage
		exit 0
		;;
	    \?)
		usage >&2
		exit 1
		;;
	esac
    done
    # Shift processed options so remaining positional arguments ($1, $2...) work normally
    shift $((OPTIND - 1))
}

# 1. Detect OS, Version, and Codename
detect_os() {
    OS_FAMILY=""
    OS_DISTRO=""
    OS_VERSION=""
    OS_CODENAME=""

    KERNEL_NAME=$(uname -s)

    case "$KERNEL_NAME" in
	Linux)
	    OS_FAMILY="linux"
	    if [ -f /etc/os-release ]; then
		. /etc/os-release
		OS_DISTRO="${ID:-unknown}"
		OS_VERSION="${VERSION_ID:-unknown}"
		# Safely read VERSION_CODENAME; fallback to "none" if unset (e.g., on Rocky)
		OS_CODENAME="${VERSION_CODENAME:-none}"
	    else
		echo "Error: Cannot detect Linux distribution (/etc/os-release missing)." >&2
		exit 1
	    fi
	    ;;
	FreeBSD)
	    OS_FAMILY="freebsd"
	    OS_DISTRO="freebsd"
	    OS_VERSION=$(freebsd-version -u | cut -d'-' -f1)
	    OS_CODENAME="none"
	    ;;
	*)
	    echo "Error: Unsupported operating system ($KERNEL_NAME)." >&2
	    exit 1
	    ;;
    esac
}

# 2. Check for Root Privileges
require_root() {
    if [ "$(id -u)" -ne 0 ]; then
	echo "Error: This installer must be run as root." >&2
	exit 1
    fi
}

# 3. OS-Specific Installation Routines
install_debian() {
    VERSION="$1"
    CODENAME="$2"

    echo ">>> Running Debian ($VERSION - $CODENAME) installation steps..."

    # Example: Adding a third-party APT repository using the codename
    # echo "deb [signed-by=/usr/share/keyrings/example.gpg] https://example.com $CODENAME main" > /etc/apt/sources.list.d/example.list

    case "$VERSION" in
	11|12|13)
	    apt update
	    apt -y install lsb-release wget gnupg apt-transport-https ca-certificates whiptail
	    wget https://packages.ntop.org/apt/$CODENAME/all/apt-ntop.deb
	    apt -y install ./apt-ntop.deb
	    rm -f ./apt-ntop.deb
	    ;;
	*)
	    echo "Warning: Debian codename '$CODENAME' ($VERSION) is unsupported."
	    exit 1
	    ;;
    esac

    ntop-installer
}

install_ubuntu() {
    VERSION="$1"
    CODENAME="$2"

    echo ">>> Running Ubuntu ($VERSION - $CODENAME) installation steps..."

    case "$VERSION" in
	26.04|24.04|22.04)
	    apt update
	    apt -y install software-properties-common wget whiptail
	    wget https://packages.ntop.org/apt$STABLE/$OS_VERSION/all/apt-ntop.deb
	    apt -y install ./apt-ntop.deb
	    rm ./apt-ntop.deb
	    ;;
	
	*)
	    echo "Warning: Ubuntu version $OS_VERSION is not supported."
	    exit
	    ;;
    esac

    ntop-installer
}

install_rocky() {
    VERSION="$1"
    MAJOR_VERSION=$(echo "$VERSION" | cut -d'.' -f1)

    echo ">>> Running RH/Rocky Linux ($VERSION) installation steps..."

    case "$MAJOR_VERSION" in
	10)
	    # Nothing to do
	    ;;
	9)
	    dnf config-manager --set-enabled crb
	    ;;	
	8)
	    yum install epel-release
	    rpm -ivh http://rpms.remirepo.net/enterprise/remi-release-8.rpm
	    yum install dnf-plugins-core	    
	    dnf config-manager --set-enabled powertools
	    dnf config-manager --set-enabled remi
	    ;;	
	*)
	    echo "Warning: RH/Rocky Linux version $VERSION is unsupported."
	    exit 1
	    ;;
    esac

    # Do the rest
    dnf -y install epel-release
    curl https://packages.ntop.org/centos$STABLE/ntop.repo > /etc/yum.repos.d/ntop.repo
    dnf -y install ntop-installer
    ntop-installer
}

install_freebsd() {
    VERSION="$1"
    MAJOR_VERSION=$(echo "$VERSION" | cut -d'.' -f1)

    echo ">>> Running FreeBSD ($VERSION) installation steps..."

    case "$MAJOR_VERSION" in
	14|15|16)
	    pkg add https://packages.ntop.org/FreeBSD/FreeBSD:$MAJOR_VERSION:amd64/latest/ntop-1.0.pkg
	    echo "Applying FreeBSD $MAJOR_VERSION specific steps."
	    ;;
	*)
	    echo "Warning: FreeBSD version $VERSION is unsupported."
	    exit 1
	    ;;
    esac
}

# 4. Main Execution Flow
main() {
    parse_args "$@"
    require_root
    detect_os

    echo "Detected: Family=$OS_FAMILY | Distro=$OS_DISTRO | Version=$OS_VERSION | Codename=$OS_CODENAME | Branch=$BRANCH"

    case "$OS_DISTRO" in
	debian)
	    install_debian "$OS_VERSION" "$OS_CODENAME"
	    ;;
	ubuntu)
	    install_ubuntu "$OS_VERSION" "$OS_CODENAME"
	    ;;
	rocky)
	    install_rocky "$OS_VERSION"
	    ;;
	freebsd)
	    install_freebsd "$OS_VERSION"
	    ;;
	*)
	    echo "Error: Unsupported distribution '$OS_DISTRO'." >&2
	    exit 1
	    ;;
    esac

    echo ">>> Installation completed successfully!"
}

main "$@"
