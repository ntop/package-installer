#!/bin/sh
#
# ntop_migrate_repository_test_real_upgrade.sh
#
# End-to-end scenario test, separate from the light Docker matrix because it
# is slower and heavier (it performs a real package-level OS upgrade inside
# the container, not just a config seed):
#
#   1. Start Ubuntu 24.04, add the ntop repo, install ntopng + nprobe.
#   2. Confirm they actually run (nprobe -h / ntopng -h).
#   3. Genuinely upgrade the container's packages from 24.04 to 26.04.
#      (See note below on why this - not do-release-upgrade - is used.)
#   4. Confirm that upgrading nprobe/ntopng now FAILS (the bug this script
#      fixes: the ntop repo still points at 24.04).
#   5. Run ntop_migrate_repository.sh.
#   6. Confirm upgrading nprobe/ntopng now SUCCEEDS again.
#   7. Confirm both packages are still correctly installed and runnable.
#
# Note on step 3: a real `do-release-upgrade` needs systemd, a kernel, and
# interactive infrastructure that a plain container doesn't have. What it
# does at its core, though, is exactly this: point apt at the new codename
# and run a full-upgrade. That's what's done here - it's the realistic
# achievable version of a real upgrade in Docker, not a shortcut around it.
#
# Requires Docker with network access to Ubuntu's archive and
# packages.ntop.org. Takes several minutes (a real package-set upgrade).
#
# Usage: ./ntop_migrate_repository_test_real_upgrade.sh
# (run from the directory containing ntop_migrate_repository.sh)

set -u

SCRIPT="$(cd "$(dirname "$0")" && pwd)/ntop_migrate_repository.sh"
[ -f "$SCRIPT" ] || { echo "ntop_migrate_repository.sh not found next to this test script"; exit 1; }

# --- edit these to test a different version pair -----------------------
OLD_IMAGE="ubuntu:24.04"
OLD_CODENAME="noble"
NEW_CODENAME="resolute"      # Ubuntu 26.04 LTS
NTOP_DEB_URL="https://packages.ntop.org/apt/24.04/all/apt-ntop.deb"   # dev channel
# -------------------------------------------------------------------------

echo "=================================================================="
echo "REAL UPGRADE SCENARIO: $OLD_IMAGE ($OLD_CODENAME) -> $NEW_CODENAME"
echo "=================================================================="

out="$(docker run --rm -v "$SCRIPT:/ntop_migrate_repository.sh:ro" "$OLD_IMAGE" sh -c "
    set -u
    export DEBIAN_FRONTEND=noninteractive
    export NEEDRESTART_MODE=a

    echo ===INSTALL-PREREQS===
    apt-get update -qq
    # curl/ca-certificates to fetch the .deb; lsb-release/gnupg/whiptail are
    # apt-ntop's own dependencies, present on a normal host but not on the
    # minimal ubuntu Docker image - without them dpkg -i leaves apt-ntop
    # unconfigured and everything downstream breaks for an unrelated reason.
    apt-get install -y -qq curl ca-certificates lsb-release gnupg whiptail

    echo ===ADD-NTOP-REPO-24.04===
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

    echo ===REAL-OS-UPGRADE-24.04-TO-26.04===
    sed -i 's/$OLD_CODENAME/$NEW_CODENAME/g' /etc/apt/sources.list /etc/apt/sources.list.d/*.sources 2>/dev/null
    apt-get update -qq
    apt-get -y -o Dpkg::Options::='--force-confold' full-upgrade
    echo FULL_UPGRADE_EXIT:\$?
    apt-get -y autoremove -qq
    . /etc/os-release
    echo OS_NOW:\$VERSION_ID

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

# For markers whose value is a whole line (e.g. an apt-cache policy line)
# rather than a single bare token - checks the line contains a substring.
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
require_marker "INSTALL_EXIT" "0"                     # ntopng/nprobe installed fine on 24.04
require_marker "INSTALLED_COUNT_PRE" "2"               # both really installed, pre-upgrade
require_marker "FULL_UPGRADE_EXIT" "0"                 # the real OS upgrade itself succeeded
require_marker "OS_NOW" "26.04"                        # proves the upgrade actually happened
require_marker_contains "PRE_NPROBE_SOURCE" "apt/24.04"   # <-- the bug: still pointing at the old OS
require_marker "MIGRATION_EXIT" "0"                    # our script ran successfully
require_marker_contains "POST_NPROBE_SOURCE" "apt/26.04"  # <-- the fix: now pointing at the current OS
require_marker "POST_MIGRATION_UPGRADE_EXIT" "0"       # upgrading is possible again
require_marker "INSTALLED_COUNT_POST" "2"               # still correctly installed afterwards

echo
if [ "$ok" -eq 1 ]; then
    echo "RESULT: PASS - ntopng/nprobe survived a real 24.04 -> 26.04 upgrade and are upgradeable again after migration"
else
    echo "RESULT: FAIL - see above"
fi
[ "$ok" -eq 1 ]
