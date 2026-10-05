#!/bin/sh
#
# ntop_migrate_repository.sh
#
# After an OS upgrade (e.g. Ubuntu 24.04 -> 26.04), the ntop package
# repository still points at the OLD OS version and package updates for
# ntopng/nprobe/etc. stop working. This script re-points it at the OS
# version currently running, so that the normal update command
# (apt upgrade ntopng ...) works again.
#
# It does this the same way a first-time install would: it re-downloads and
# re-applies ntop's own official apt-ntop(-stable).deb for the OS that is
# running right now, keeping whichever channel (dev/stable) was already
# configured. It does NOT install or upgrade ntopng/nprobe/etc. itself -
# that part is left to the user, as usual.
#
# Run manually, as root, with no options:
#   sudo ./ntop_migrate_repository.sh
#
# Supported: Ubuntu, x86_64.
#
# RHEL-like systems (RHEL/CentOS/AlmaLinux/Rocky) are deliberately NOT
# handled here: their ntop.repo baseurl uses dnf/yum's own $releasever
# variable instead of a hardcoded OS version, so it has no per-OS version
# string that can go stale after an upgrade in the first place - there is
# nothing for this script to fix on those systems. This was verified
# empirically (not just assumed): ntopng/nprobe stayed upgradeable across a
# real Rocky Linux 9 -> 10 major-version upgrade with no migration step at
# all. Running this script on such a system would only add a redundant
# re-download with nothing to correct, so instead it just says so and exits.
#
# Debian is detected but also deliberately NOT handled here: its ntop repo
# file hardcodes the release codename (e.g. bookworm), but Debian's official
# upgrade instructions have you replace the old codename with the new one in
# all apt sources, which includes the ntop repo file - so anyone who follows
# them has already migrated the ntop repository as part of the upgrade, and
# there is nothing left for this script to do.
#
# --- how to extend --------------------------------------------------------
# New OS VERSION of an already-supported family: nothing to do, it just
#   works - the version is read from /etc/os-release at run time.
# New OS FAMILY whose repo file DOES hardcode an OS version and whose
#   upgrade procedure does NOT update it (like Ubuntu): add it to the case
#   in "OS detection" below and give it the same treatment as Ubuntu.
# New OS FAMILY that needs no migration (like RHEL-family, or Debian): add
#   it to a "nothing to do" branch of that case instead.
# ---------------------------------------------------------------------------

set -eu

log() {
    echo "[ntop_migrate_repository] $*" >&2
}

die() {
    log "ERROR: $*"
    exit 1
}

# --- preconditions ---------------------------------------------------------

[ "$(id -u)" = "0" ] || die "must be run as root (try: sudo $0)"

[ "$(uname -m)" = "x86_64" ] || die "unsupported architecture '$(uname -m)': only x86_64 is supported"

command -v curl >/dev/null 2>&1 || die "curl is required but not installed"

[ -r /etc/os-release ] || die "/etc/os-release not found: cannot detect the OS"
. /etc/os-release
# ID and VERSION_ID now available.

# --- OS detection ------------------------------------------------------

case "$ID" in
    rhel|centos|almalinux|rocky)
        log "Nothing to do/migrate on $ID. You can already run the usual package update/upgrade command for ntopng/nprobe/etc."
        exit 0
        ;;
    debian)
        log "Nothing to do on Debian: if you follow (or have followed) the official Debian upgrade instructions, the ntop repository gets updated (or was already updated) together with the rest of your apt sources. You can already run the usual package update/upgrade command for ntopng/nprobe/etc."
        exit 0
        ;;
    ubuntu) version_token="$VERSION_ID" ;;  # e.g. 24.04, 26.04
    *) die "unsupported OS '$ID'." ;;
esac

# --- channel detection (dev vs stable) --------------------------------
#
# We must reapply whichever channel is already configured, never switch it.
# The configured channel is identifiable by the substring "stable" in the
# installed package name.

if dpkg-query -W -f='${Status}' apt-ntop-stable 2>/dev/null | grep -q "install ok installed"; then
    channel="stable"
elif dpkg-query -W -f='${Status}' apt-ntop 2>/dev/null | grep -q "install ok installed"; then
    channel="dev"
else
    die "no existing ntop repository package (apt-ntop / apt-ntop-stable) found - nothing to migrate"
fi

if [ "$channel" = "stable" ]; then
    deb_name="apt-ntop-stable.deb"
    url="https://packages.ntop.org/apt-stable/$version_token/all/$deb_name"
else
    deb_name="apt-ntop.deb"
    url="https://packages.ntop.org/apt/$version_token/all/$deb_name"
fi

log "OS: $ID $version_token, channel: $channel"

# --- apply: redo the official "add the ntop repository" step --------------

# apt-ntop's package version doesn't encode the OS version (the same
# version number is used for every OS release), so the only reliable way to
# tell whether this OS is already correctly configured is to check what the
# installed repo file actually points at. That file is written by
# apt-ntop's postinst script rather than shipped as package content, so it
# won't show up via `dpkg -L` - search sources.list.d directly.
list_file="$(grep -rlE 'packages\.ntop\.org' /etc/apt/sources.list.d 2>/dev/null | head -1)"
if [ -n "$list_file" ] && grep -q "/$version_token/" "$list_file"; then
    log "ntop repository already matches this OS - nothing to do. You can already run the usual package update/upgrade command for ntopng/nprobe/etc."
    exit 0
fi

log "downloading $url"

tmp_deb="$(mktemp /tmp/ntop-migrate.XXXXXX.deb)"
trap 'rm -f "$tmp_deb"' EXIT
curl -fsSL "$url" -o "$tmp_deb" \
    || die "download failed: $url (does ntop publish packages for $ID $version_token yet?)"

log "reinstalling $deb_name"
dpkg -i "$tmp_deb" >/dev/null || apt-get install -f -y >/dev/null || die "failed to install $deb_name"

log "refreshing package lists"
apt-get update -qq || die "apt-get update failed after repository migration"

log "done. The ntop repository now matches this OS. You can now run the usual package update/upgrade command for ntopng/nprobe/etc."
