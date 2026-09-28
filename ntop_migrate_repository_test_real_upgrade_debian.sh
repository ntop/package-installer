#!/bin/sh
#
# ntop_migrate_repository_test_real_upgrade_debian.sh
#
# Same scenario as ntop_migrate_repository_test_real_upgrade.sh (the Ubuntu
# one), adapted for Debian:
#
#   1. Start Debian bookworm, enable 'contrib' (a real ntop.org prerequisite
#      for Debian only), add the ntop repo, install ntopng + nprobe.
#   2. Confirm they actually run (nprobe -h / ntopng -h).
#   3. Genuinely upgrade the container's packages from bookworm to trixie.
#      (Same caveat as the Ubuntu test: a real do-release-upgrade needs
#      systemd/interactive infra a container doesn't have, so this does what
#      that tool does at its core - point apt at the new codename and run a
#      full-upgrade.)
#   4. Confirm that upgrading nprobe/ntopng now FAILS (the bug this script
#      fixes: the ntop repo still points at bookworm).
#   5. Run ntop_migrate_repository.sh.
#   6. Confirm upgrading nprobe/ntopng now SUCCEEDS again.
#   7. Confirm both packages are still correctly installed and runnable.
#
# Debian-specific note: Debian docker images vary in whether they use the
# classic /etc/apt/sources.list or the newer deb822 *.sources format
# depending on image version, so both are handled when enabling 'contrib'
# and when renaming the codename.
#
# Requires Docker with network access to Debian's archive and
# packages.ntop.org. Takes several minutes (a real package-set upgrade).
#
# Usage: ./ntop_migrate_repository_test_real_upgrade_debian.sh
# (run from the directory containing ntop_migrate_repository.sh)

set -u

SCRIPT="$(cd "$(dirname "$0")" && pwd)/ntop_migrate_repository.sh"
[ -f "$SCRIPT" ] || { echo "ntop_migrate_repository.sh not found next to this test script"; exit 1; }

# --- edit these to test a different version pair -----------------------
OLD_IMAGE="debian:bookworm"
OLD_CODENAME="bookworm"
NEW_CODENAME="trixie"
NTOP_DEB_URL="https://packages.ntop.org/apt/bookworm/all/apt-ntop.deb"   # dev channel
# -------------------------------------------------------------------------

echo "=================================================================="
echo "REAL UPGRADE SCENARIO (Debian): $OLD_IMAGE ($OLD_CODENAME) -> $NEW_CODENAME"
echo "=================================================================="

out="$(docker run --rm -v "$SCRIPT:/ntop_migrate_repository.sh:ro" "$OLD_IMAGE" sh -c "
    set -u
    export DEBIAN_FRONTEND=noninteractive
    export NEEDRESTART_MODE=a

    echo ===INSTALL-PREREQS===
    apt-get update -qq
    # curl/ca-certificates to fetch the .deb; lsb-release/gnupg/whiptail are
    # apt-ntop's own dependencies, present on a normal host but not on the
    # minimal debian Docker image.
    apt-get install -y -qq curl ca-certificates lsb-release gnupg whiptail

    echo ===ENABLE-CONTRIB===
    # ntop.org's own Debian install instructions: enable 'contrib' before
    # adding the ntop repo. Handles both the classic sources.list and the
    # newer deb822 *.sources format, whichever this image uses.
    [ -f /etc/apt/sources.list ] && sed -i -E 's/^(deb(-src)? .*)\$/\1 contrib/' /etc/apt/sources.list
    for f in /etc/apt/sources.list.d/*.sources; do
        [ -f \"\$f\" ] && sed -i -E 's/^(Components:.*)\$/\1 contrib/' \"\$f\"
    done

    echo ===ADD-NTOP-REPO-BOOKWORM===
    curl -fsSL '$NTOP_DEB_URL' -o /tmp/apt-ntop.deb
    dpkg -i /tmp/apt-ntop.deb || apt-get install -f -y
    apt-get update -qq

    echo ===INSTALL-NTOPNG-NPROBE===
    apt-get install -y ntopng nprobe
    echo INSTALL_EXIT:\$?

    echo ===PRE-UPGRADE-SANITY-CHECK===
    nprobe -h >/tmp/nprobe.out 2>&1; echo NPROBE_PRE_EXIT:\$?
    ntopng -h >/tmp/ntopng.out 2>&1; echo NTOPNG_PRE_EXIT:\$?
    echo INSTALLED_COUNT_PRE:\$(dpkg -s ntopng nprobe 2>/dev/null | grep -c '^Status: install ok installed')

    echo ===REAL-OS-UPGRADE-BOOKWORM-TO-TRIXIE===
    [ -f /etc/apt/sources.list ] && sed -i \"s/$OLD_CODENAME/$NEW_CODENAME/g\" /etc/apt/sources.list
    for f in /etc/apt/sources.list.d/*.sources; do
        [ -f \"\$f\" ] && sed -i \"s/$OLD_CODENAME/$NEW_CODENAME/g\" \"\$f\"
    done
    apt-get update -qq
    apt-get -y -o Dpkg::Options::='--force-confold' full-upgrade
    echo FULL_UPGRADE_EXIT:\$?
    apt-get -y autoremove -qq
    . /etc/os-release
    echo OS_NOW:\$VERSION_CODENAME

    echo ===PRE-MIGRATION-UPGRADE-ATTEMPT===
    apt-get update -qq
    echo PRE_NPROBE_SOURCE:\$(apt-cache policy nprobe | grep -m1 packages.ntop.org)
    set +e
    apt-get install -y --only-upgrade nprobe ntopng
    echo PRE_MIGRATION_UPGRADE_EXIT:\$?
    set -e

    echo ===RUN-MIGRATION-SCRIPT===
    set +e
    sh /ntop_migrate_repository.sh
    echo MIGRATION_EXIT:\$?
    set -e

    echo ===POST-MIGRATION-UPGRADE-ATTEMPT===
    apt-get update -qq
    echo POST_NPROBE_SOURCE:\$(apt-cache policy nprobe | grep -m1 packages.ntop.org)
    apt-get install -y --only-upgrade nprobe ntopng
    echo POST_MIGRATION_UPGRADE_EXIT:\$?

    echo ===POST-UPGRADE-SANITY-CHECK===
    echo INSTALLED_COUNT_POST:\$(dpkg -s ntopng nprobe 2>/dev/null | grep -c '^Status: install ok installed')
" 2>&1)"

echo "$out"
echo "--- container finished ---"
echo

ok=1

require_marker() {
    marker="$1"; expected="$2"
    value="$(echo "$out" | grep -o "${marker}:[^ ]*" | tail -1 | cut -d: -f2)"
    if [ "$value" != "$expected" ]; then
        echo "FAIL: $marker was '$value', expected '$expected'"
        ok=0
    else
        echo "OK:   $marker = $value"
    fi
}

require_marker_contains() {
    marker="$1"; needle="$2"
    line="$(echo "$out" | grep "^${marker}:" | tail -1)"
    if ! echo "$line" | grep -qF "$needle"; then
        echo "FAIL: $marker line ('$line') does not contain '$needle'"
        ok=0
    else
        echo "OK:   $marker contains '$needle'"
    fi
}

echo "-- checks --"
require_marker "INSTALL_EXIT" "0"                          # ntopng/nprobe installed fine on bookworm
require_marker "INSTALLED_COUNT_PRE" "2"                    # both really installed, pre-upgrade
require_marker "FULL_UPGRADE_EXIT" "0"                      # the real OS upgrade itself succeeded
require_marker "OS_NOW" "$NEW_CODENAME"                     # proves the upgrade actually happened
require_marker_contains "PRE_NPROBE_SOURCE" "apt/$OLD_CODENAME"    # <-- the bug: still pointing at bookworm
require_marker "MIGRATION_EXIT" "0"                          # our script ran successfully
require_marker_contains "POST_NPROBE_SOURCE" "apt/$NEW_CODENAME"   # <-- the fix: now pointing at trixie
require_marker "POST_MIGRATION_UPGRADE_EXIT" "0"             # upgrading is possible again
require_marker "INSTALLED_COUNT_POST" "2"                    # still correctly installed afterwards

echo
if [ "$ok" -eq 1 ]; then
    echo "RESULT: PASS - ntopng/nprobe survived a real bookworm -> trixie upgrade and are upgradeable again after migration"
else
    echo "RESULT: FAIL - see above"
fi
[ "$ok" -eq 1 ]
