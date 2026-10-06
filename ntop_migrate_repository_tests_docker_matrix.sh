#!/bin/sh
#
# ntop_migrate_repository_tests_docker_matrix.sh
#
# For Ubuntu cases: starts a container already running the NEW OS
# version, but first seeds it with the OLD OS version's ntop repo config
# (exactly what a real in-place OS upgrade leaves behind - this is the
# "invalid situation" the migration script exists to fix), then runs
# ntop_migrate_repository.sh and checks the repo now works.
#
# For RHEL-like cases: ntop_migrate_repository.sh does nothing there by
# design (see the comment in the main script), so these instead prove it
# exits cleanly, says so, and leaves the existing repo file untouched.
#
# For Debian: same idea - it does nothing and explains why (official Debian
# upgrade instructions already update the ntop repo file along with the
# rest of the apt sources).
#
# Usage: ./ntop_migrate_repository_tests_docker_matrix.sh
# (run from the directory containing ntop_migrate_repository.sh)
#
# --- how to extend ---------------------------------------------------------
# New case for an already-supported scenario: add one more call to the
#   matching helper below (check / check_fails / check_noop / check_rhel_noop).
# New OS family whose repo file hardcodes an OS version and isn't updated
#   by its own upgrade procedure (like Ubuntu): use check() with the right SEED_CMD/REFRESH_CMD for that
#   family's package manager.
# New OS family whose repo file does NOT hardcode a version (like RHEL-
#   family): use check_rhel_noop() instead, matching the main script's
#   "nothing to do" treatment for that family.
# -----------------------------------------------------------------------------

set -u

SCRIPT="$(cd "$(dirname "$0")" && pwd)/ntop_migrate_repository.sh"
[ -f "$SCRIPT" ] || { echo "ntop_migrate_repository.sh not found next to this test script"; exit 1; }

PASS=0
FAIL=0

# check NAME IMAGE SEED_CMD REFRESH_CMD PATTERN...
#
# NAME:        label for this case
# IMAGE:       the container's OS - i.e. the version already upgraded TO
# SEED_CMD:    shell snippet that installs the OLD version's ntop repo,
#              recreating the stale post-upgrade state, before migration runs
# REFRESH_CMD: this family's "reload package lists" command, run AFTER
#              migration to prove the repo is genuinely usable again
# PATTERN...:  strings that must all appear in the output for a PASS
check() {
    name="$1"; image="$2"; seed_cmd="$3"; refresh_cmd="$4"; shift 4

    echo "=================================================================="
    echo "CASE: $name   IMAGE: $image"
    echo "=================================================================="

    out="$(docker run --rm -v "$SCRIPT:/ntop_migrate_repository.sh:ro" "$image" sh -c "
        set -e
        echo ===SEED-STALE-CONFIG===
        $seed_cmd
        echo ===RUN-MIGRATION===
        sh /ntop_migrate_repository.sh
        echo ===VERIFY-REFRESH===
        $refresh_cmd
    " 2>&1)"
    rc=$?

    echo "$out"
    echo "--- exit code: $rc ---"

    ok=1
    [ "$rc" -eq 0 ] || { echo "MISSING: overall exit code 0 (got $rc)"; ok=0; }
    for pattern in "$@"; do
        echo "$out" | grep -qF "$pattern" || { echo "MISSING EXPECTED OUTPUT: $pattern"; ok=0; }
    done

    if [ "$ok" -eq 1 ]; then echo "RESULT: PASS"; PASS=$((PASS + 1))
    else echo "RESULT: FAIL"; FAIL=$((FAIL + 1)); fi
    echo
}

# check_fails NAME IMAGE SEED_CMD PATTERN...
#
# Same as check(), but for cases where ntop_migrate_repository.sh is
# expected to die() cleanly (non-zero exit) rather than succeed - e.g. when
# there is no existing ntop repo to migrate.
check_fails() {
    name="$1"; image="$2"; seed_cmd="$3"; shift 3

    echo "=================================================================="
    echo "CASE (expected to fail cleanly): $name   IMAGE: $image"
    echo "=================================================================="

    out="$(docker run --rm -v "$SCRIPT:/ntop_migrate_repository.sh:ro" "$image" sh -c "
        set -e
        echo ===SEED===
        $seed_cmd
        echo ===RUN-MIGRATION===
        set +e
        sh /ntop_migrate_repository.sh
        echo MIGRATION_EXIT_CODE:\$?
    " 2>&1)"

    echo "$out"

    ok=1
    echo "$out" | grep -q "MIGRATION_EXIT_CODE:0" && { echo "MISSING: expected a non-zero exit from ntop_migrate_repository.sh"; ok=0; }
    for pattern in "$@"; do
        echo "$out" | grep -qF "$pattern" || { echo "MISSING EXPECTED OUTPUT: $pattern"; ok=0; }
    done

    if [ "$ok" -eq 1 ]; then echo "RESULT: PASS"; PASS=$((PASS + 1))
    else echo "RESULT: FAIL"; FAIL=$((FAIL + 1)); fi
    echo
}

# check_noop NAME IMAGE SEED_CMD PATTERN...
#
# Same as check(), but for cases where ntop_migrate_repository.sh must do
# nothing - no download, no reinstall - and exit 0: either because the repo
# is ALREADY correct for this OS (Ubuntu), or because the OS needs no
# migration at all (Debian).
check_noop() {
    name="$1"; image="$2"; seed_cmd="$3"; shift 3

    echo "=================================================================="
    echo "CASE (expected to do nothing): $name   IMAGE: $image"
    echo "=================================================================="

    out="$(docker run --rm -v "$SCRIPT:/ntop_migrate_repository.sh:ro" "$image" sh -c "
        set -e
        echo ===SEED-ALREADY-CORRECT-CONFIG===
        $seed_cmd
        echo ===RUN-MIGRATION===
        sh /ntop_migrate_repository.sh
    " 2>&1)"
    rc=$?

    echo "$out"
    echo "--- exit code: $rc ---"

    ok=1
    [ "$rc" -eq 0 ] || { echo "MISSING: exit code 0 (got $rc)"; ok=0; }
    for pattern in "$@"; do
        echo "$out" | grep -qF "$pattern" || { echo "MISSING EXPECTED OUTPUT: $pattern"; ok=0; }
    done
    echo "$out" | grep -q "downloading https://" \
        && { echo "UNEXPECTED: script downloaded something - it should have done nothing"; ok=0; }

    if [ "$ok" -eq 1 ]; then echo "RESULT: PASS"; PASS=$((PASS + 1))
    else echo "RESULT: FAIL"; FAIL=$((FAIL + 1)); fi
    echo
}

# check_rhel_noop NAME IMAGE SEED_CMD PATTERN...
#
# For RHEL-like systems ntop_migrate_repository.sh now does nothing at all
# (see the comment in the main script for why) - this proves it exits 0,
# says so, and leaves the existing ntop.repo file completely untouched.
check_rhel_noop() {
    name="$1"; image="$2"; seed_cmd="$3"; shift 3

    echo "=================================================================="
    echo "CASE (RHEL-like, expected to do nothing): $name   IMAGE: $image"
    echo "=================================================================="

    out="$(docker run --rm -v "$SCRIPT:/ntop_migrate_repository.sh:ro" "$image" sh -c "
        set -e
        echo ===SEED===
        $seed_cmd
        before=\$(md5sum /etc/yum.repos.d/ntop.repo | cut -d' ' -f1)
        echo ===RUN-MIGRATION===
        sh /ntop_migrate_repository.sh
        after=\$(md5sum /etc/yum.repos.d/ntop.repo | cut -d' ' -f1)
        echo BEFORE_MD5:\$before
        echo AFTER_MD5:\$after
    " 2>&1)"
    rc=$?

    echo "$out"
    echo "--- exit code: $rc ---"

    ok=1
    [ "$rc" -eq 0 ] || { echo "MISSING: exit code 0 (got $rc)"; ok=0; }
    for pattern in "$@"; do
        echo "$out" | grep -qF "$pattern" || { echo "MISSING EXPECTED OUTPUT: $pattern"; ok=0; }
    done

    before_md5="$(echo "$out" | grep '^BEFORE_MD5:' | cut -d: -f2)"
    after_md5="$(echo "$out" | grep '^AFTER_MD5:' | cut -d: -f2)"
    if [ -z "$before_md5" ] || [ "$before_md5" != "$after_md5" ]; then
        echo "UNEXPECTED: ntop.repo file changed (before='$before_md5' after='$after_md5') - script should not have touched it"
        ok=0
    else
        echo "OK: ntop.repo untouched (md5 $before_md5)"
    fi

    if [ "$ok" -eq 1 ]; then echo "RESULT: PASS"; PASS=$((PASS + 1))
    else echo "RESULT: FAIL"; FAIL=$((FAIL + 1)); fi
    echo
}

# lsb-release, gnupg and whiptail are apt-ntop's own dependencies. A normal
# host has these already; the minimal ubuntu Docker image doesn't, so
# the seed step needs to install them explicitly or dpkg -i fails.
APT_PREP="apt-get update -qq && apt-get install -y -qq curl ca-certificates lsb-release gnupg whiptail"

# --- Ubuntu: upgraded 24.04 -> 26.04, dev channel was configured ----------
#
# apt-ntop's postinst detects the LIVE OS at install time and writes the
# repo file to match it, regardless of which version's .deb URL was used to
# fetch it - so installing the OLD version's .deb here would just self-
# correct to 26.04 and prove nothing. Instead: install the CURRENT (26.04)
# .deb for real (so dpkg genuinely registers apt-ntop as installed, which
# the migration script's channel detection requires), then age the
# resulting file's version token back down to 24.04 - reproducing exactly
# what a real in-place OS upgrade leaves behind: package still installed,
# config stale.
check "ubuntu 24.04->26.04 dev" "ubuntu:26.04" \
    "$APT_PREP && curl -fsSL https://packages.ntop.org/apt/26.04/all/apt-ntop.deb -o /tmp/cur.deb && (dpkg -i /tmp/cur.deb || apt-get install -f -y) && list=\$(grep -rlE 'packages\.ntop\.org' /etc/apt/sources.list.d | head -1) && sed -i 's/26\.04/24.04/g' \$list" \
    "apt-get update" \
    "channel: dev" "done. The ntop repository now matches this OS"

# --- Ubuntu: what a REAL release upgrade leaves behind -----------------------
# do-release-upgrade can't migrate the ntop .list file, so it renames it to
# ntop.list.disabled with all lines commented out (apt ignores it). Only the
# apt-ntop package is still registered as installed.
check "ubuntu 24.04->26.04 dev, real-upgrade .list.disabled state" "ubuntu:26.04" \
    "$APT_PREP && curl -fsSL https://packages.ntop.org/apt/26.04/all/apt-ntop.deb -o /tmp/cur.deb && (dpkg -i /tmp/cur.deb || apt-get install -f -y) && list=\$(grep -rlE 'packages\.ntop\.org' /etc/apt/sources.list.d | head -1) && sed -i -e 's/26\.04/24.04/g' -e 's/^/# /' \$list && mv \$list \$list.disabled" \
    "apt-get update" \
    "channel: dev" "downloading https://" "done. The ntop repository now matches this OS"

# --- Ubuntu: 22.04 -> 24.04 real-upgrade state (.list.distUpgrade) ----------
# Observed on a real VM: after the GUI upgrade the only ntop file left is
# ntop.list.distUpgrade, still pointing at 22.04 and NOT commented out (apt
# ignores it because of the extension). No active ntop file exists.
check "ubuntu 22.04->24.04 dev, real-upgrade .list.distUpgrade state" "ubuntu:24.04" \
    "$APT_PREP && curl -fsSL https://packages.ntop.org/apt/24.04/all/apt-ntop.deb -o /tmp/cur.deb && (dpkg -i /tmp/cur.deb || apt-get install -f -y) && list=\$(grep -rlE 'packages\.ntop\.org' /etc/apt/sources.list.d | head -1) && sed -i 's/24\.04/22.04/g' \$list && mv \$list \$list.distUpgrade" \
    "apt-get update" \
    "channel: dev" "downloading https://" "done. The ntop repository now matches this OS"

# --- Ubuntu: upgraded 24.04 -> 26.04, stable channel was configured ------
check "ubuntu 24.04->26.04 stable" "ubuntu:26.04" \
    "$APT_PREP && curl -fsSL https://packages.ntop.org/apt-stable/26.04/all/apt-ntop-stable.deb -o /tmp/cur.deb && (dpkg -i /tmp/cur.deb || apt-get install -f -y) && list=\$(grep -rlE 'packages\.ntop\.org' /etc/apt/sources.list.d | head -1) && sed -i 's/26\.04/24.04/g' \$list" \
    "apt-get update" \
    "channel: stable" "done. The ntop repository now matches this OS"

# --- Debian: not handled, must say why and do nothing ---------------------
check_noop "debian -> explains official upgrade instructions, no-op" "debian:trixie" \
    "apt-get update -qq && apt-get install -y -qq curl" \
    "official Debian upgrade instructions"

# --- Already up to date: must detect this and do nothing, not re-download -
check_noop "ubuntu 24.04 already correctly configured -> no-op" "ubuntu:24.04" \
    "$APT_PREP && curl -fsSL https://packages.ntop.org/apt/24.04/all/apt-ntop.deb -o /tmp/cur.deb && (dpkg -i /tmp/cur.deb || apt-get install -f -y)" \
    "already matches this OS - nothing to do"

# RHEL-like now has no channel handling at all: ntop_migrate_repository.sh
# does nothing there, full stop (see the comment in the main script). These
# two cases prove that holds for both channels' repo files.
check_rhel_noop "almalinux 9 stable channel -> untouched, no-op" "almalinux:9" \
    "curl -fsSL https://packages.ntop.org/centos-stable/ntop.repo -o /etc/yum.repos.d/ntop.repo" \
    "Nothing to do/migrate on"

check_rhel_noop "almalinux 9 dev channel -> untouched, no-op" "almalinux:9" \
    "curl -fsSL https://packages.ntop.org/centos/ntop.repo -o /etc/yum.repos.d/ntop.repo" \
    "Nothing to do/migrate on"

# --- Preconditions: must fail cleanly, not crash, when nothing to migrate -
check_fails "no existing ntop repo -> clean failure" "ubuntu:26.04" \
    "apt-get update -qq && apt-get install -y -qq curl" \
    "no existing ntop repository package"

echo "=================================================================="
echo "SUMMARY: $PASS passed, $FAIL failed"
echo "=================================================================="
[ "$FAIL" -eq 0 ]
