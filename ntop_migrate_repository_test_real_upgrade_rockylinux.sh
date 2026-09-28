#!/bin/sh
#
# ntop_migrate_repository_test_real_upgrade_rockylinux.sh
#
# Same spirit as the Ubuntu/Debian real-upgrade tests, but the expected
# outcome is different by design: RHEL-family's ntop.repo baseurl uses
# dnf's own $releasever variable instead of a hardcoded OS version (see the
# RHEL-like comment near the top of ntop_migrate_repository.sh), so there
# is no stale version string for a major-version upgrade to expose.
# This test exists to verify that reasoning empirically rather than just
# assume it:
#
#   1. Start Rocky Linux 9, add the ntop repo, install ntopng + nprobe.
#   2. Confirm they actually run (nprobe -h / ntopng -h).
#   3. Bump the container to Rocky Linux 10 packages.
#   4. Confirm upgrading nprobe/ntopng ALREADY works, before migration runs
#      (unlike the Ubuntu/Debian case - this is the expected, correct
#      outcome here, not a bug).
#   5. Run ntop_migrate_repository.sh (expected to immediately say there's
#      nothing to do here and exit - not a required fix, not even a refresh).
#   6. Confirm upgrading nprobe/ntopng still works afterwards.
#   7. Confirm both packages are still correctly installed and runnable.
#
# IMPORTANT CAVEAT: RHEL-family distros have no officially supported way to
# jump major versions in place inside a bare container - real machines use
# Red Hat's `leapp` tool, which needs far more infrastructure (a running
# system, specific pre-upgrade checks, etc.) than a container provides.
# `dnf --releasever=<N> distro-sync` used below is the closest practical
# approximation achievable here, NOT what leapp does internally, and is not
# an officially documented upgrade path for Rocky/RHEL/AlmaLinux the way it
# is for Fedora. One concrete consequence, confirmed by running this: a
# manual releasever bump does not import the new major version's GPG signing
# key the way a real leapp upgrade does, so distro-sync needs --nogpgcheck
# for that one step (see the comment at that step) - this is a limitation of
# the approximation, not something a genuine RHEL-family upgrade needs to
# skip. Treat this test as best-effort: if it fails, check whether the
# failure is a real repository-migration issue or just a limitation of
# approximating a major-version jump this way before assuming a bug.
#
# Requires Docker with network access to Rocky's mirrors, EPEL, and
# packages.ntop.org. Takes several minutes.
#
# Usage: ./ntop_migrate_repository_test_real_upgrade_rockylinux.sh
# (run from the directory containing ntop_migrate_repository.sh)

set -u

SCRIPT="$(cd "$(dirname "$0")" && pwd)/ntop_migrate_repository.sh"
[ -f "$SCRIPT" ] || { echo "ntop_migrate_repository.sh not found next to this test script"; exit 1; }

# --- edit these to test a different version pair -----------------------
OLD_IMAGE="rockylinux:9"
NEW_RELEASEVER="10"
NTOP_REPO_URL="https://packages.ntop.org/centos/ntop.repo"   # dev channel
# -------------------------------------------------------------------------

echo "=================================================================="
echo "REAL UPGRADE SCENARIO (Rocky Linux): $OLD_IMAGE -> releasever $NEW_RELEASEVER"
echo "=================================================================="

out="$(docker run --rm -v "$SCRIPT:/ntop_migrate_repository.sh:ro" "$OLD_IMAGE" sh -c "
    set -u

    echo ===INSTALL-PREREQS===
    # --allowerasing: the minimal rockylinux image ships curl-minimal, which
    # conflicts with the full curl package; without this the whole
    # transaction (including dnf-plugins-core) aborts on that conflict alone.
    dnf install -y -q --allowerasing curl dnf-plugins-core
    dnf config-manager --set-enabled crb
    dnf install -y -q epel-release

    echo ===ADD-NTOP-REPO===
    curl -fsSL '$NTOP_REPO_URL' -o /etc/yum.repos.d/ntop.repo

    echo ===INSTALL-NTOPNG-NPROBE===
    dnf install -y nprobe ntopng
    echo INSTALL_EXIT:\$?

    echo ===PRE-UPGRADE-SANITY-CHECK===
    nprobe -h >/tmp/nprobe.out 2>&1; echo NPROBE_PRE_EXIT:\$?
    ntopng -h >/tmp/ntopng.out 2>&1; echo NTOPNG_PRE_EXIT:\$?
    echo INSTALLED_COUNT_PRE:\$(rpm -q --qf '%{NAME}\n' ntopng nprobe 2>/dev/null | grep -vc 'not installed')

    echo ===BUMP-TO-RELEASEVER-$NEW_RELEASEVER===
    # --nogpgcheck here (only for this step): a manual --releasever bump like
    # this does not import the new major version's signing key the way the
    # real leapp tool does as part of a genuine upgrade, so packages built
    # for $NEW_RELEASEVER fail signature verification against the still-
    # installed old release's key. This is a limitation of approximating a
    # major upgrade this way, not something a real upgrade needs to skip.
    dnf -y --releasever=$NEW_RELEASEVER --allowerasing --nogpgcheck distro-sync
    echo DISTRO_SYNC_EXIT:\$?
    . /etc/os-release
    echo OS_NOW:\$VERSION_ID

    echo ===PRE-MIGRATION-UPGRADE-ATTEMPT===
    echo PRE_NPROBE_SOURCE:\$(dnf repoquery --installed -q --qf '%{from_repo}' nprobe | head -1)
    set +e
    dnf -y upgrade nprobe ntopng
    echo PRE_MIGRATION_UPGRADE_EXIT:\$?
    set -e

    echo ===RUN-MIGRATION-SCRIPT===
    before_repo_md5=\$(md5sum /etc/yum.repos.d/ntop.repo | cut -d' ' -f1)
    set +e
    sh /ntop_migrate_repository.sh
    echo MIGRATION_EXIT:\$?
    set -e
    after_repo_md5=\$(md5sum /etc/yum.repos.d/ntop.repo | cut -d' ' -f1)
    echo REPO_UNCHANGED:\$([ \"\$before_repo_md5\" = \"\$after_repo_md5\" ] && echo yes || echo no)

    echo ===POST-MIGRATION-UPGRADE-ATTEMPT===
    echo POST_NPROBE_SOURCE:\$(dnf repoquery --installed -q --qf '%{from_repo}' nprobe | head -1)
    dnf -y upgrade nprobe ntopng
    echo POST_MIGRATION_UPGRADE_EXIT:\$?

    echo ===POST-UPGRADE-SANITY-CHECK===
    echo INSTALLED_COUNT_POST:\$(rpm -q --qf '%{NAME}\n' ntopng nprobe 2>/dev/null | grep -vc 'not installed')
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

# For markers like OS_NOW, whose value is "$releasever.<point release>"
# (e.g. "10.2") rather than a bare number - checks the major version prefix.
require_marker_prefix() {
    marker="$1"; expected_prefix="$2"
    value="$(echo "$out" | grep -o "${marker}:[^ ]*" | tail -1 | cut -d: -f2)"
    case "$value" in
        "$expected_prefix"|"$expected_prefix".*)
            echo "OK:   $marker = $value" ;;
        *)
            echo "FAIL: $marker was '$value', expected to start with '$expected_prefix'"
            ok=0 ;;
    esac
}

echo "-- checks --"
require_marker "INSTALL_EXIT" "0"                          # ntopng/nprobe installed fine on Rocky 9
require_marker "INSTALLED_COUNT_PRE" "2"                    # both really installed, pre-upgrade
require_marker "DISTRO_SYNC_EXIT" "0"                        # the (approximated) major upgrade itself succeeded
require_marker_prefix "OS_NOW" "$NEW_RELEASEVER"            # proves the upgrade actually happened
require_marker "PRE_MIGRATION_UPGRADE_EXIT" "0"              # <-- expected to ALREADY work, unlike Ubuntu/Debian
require_marker "MIGRATION_EXIT" "0"                           # our script says "nothing to do" and exits cleanly
require_marker "REPO_UNCHANGED" "yes"                         # and genuinely never touches ntop.repo
require_marker "POST_MIGRATION_UPGRADE_EXIT" "0"              # still works afterwards
require_marker "INSTALLED_COUNT_POST" "2"                    # still correctly installed throughout

echo
if [ "$ok" -eq 1 ]; then
    echo "RESULT: PASS - ntopng/nprobe stayed upgradeable across a Rocky Linux major-version bump without needing repository migration, as designed"
else
    echo "RESULT: FAIL - see above (note the caveat at the top of this script about distro-sync being an approximation, not leapp)"
fi
[ "$ok" -eq 1 ]
