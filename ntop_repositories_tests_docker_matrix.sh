#!/bin/sh
# Runs the real ntop_repositories_installation.sh inside real containers for each supported Linux
# distro/version and does basic assertions on the output.
#
# Usage: ./ntop_repositories_tests_docker_matrix.sh [--install-packages] [ntop_repositories_installation.sh path]
#   (run from the directory containing ntop_repositories_installation.sh, or pass its path)
#
#   --install-packages   after each ntop_repositories_installation.sh run, also attempt to
#                         actually install nprobe/ntopng from the freshly
#                         configured repo (apt-get/dnf/yum, whichever
#                         applies) and check that it succeeds - this proves
#                         the repo is not just "added" but genuinely usable.
#                         Default: off (repo setup is checked, but nothing
#                         beyond it is installed).
#   --no-install-packages   explicit opposite, mainly useful if
#                         INSTALL_PACKAGES=1 is set in the environment.
set -u

INSTALL_PACKAGES="${INSTALL_PACKAGES:-0}"
SCRIPT=""
for arg in "$@"; do
    case "$arg" in
        --install-packages)    INSTALL_PACKAGES=1 ;;
        --no-install-packages) INSTALL_PACKAGES=0 ;;
        *)                     SCRIPT="$arg" ;;
    esac
done
SCRIPT="${SCRIPT:-$(pwd)/ntop_repositories_installation.sh}"
[ -f "$SCRIPT" ] || { echo "ntop_repositories_installation.sh not found at $SCRIPT"; exit 1; }
SCRIPT="$(cd "$(dirname "$SCRIPT")" && pwd)/$(basename "$SCRIPT")"

if [ "$INSTALL_PACKAGES" = "1" ]; then
    echo "NOTE: --install-packages is on - every check_image run will also"
    echo "attempt to install nprobe/ntopng for real and check it succeeds."
    echo
fi

PASS=0
FAIL=0

# check_image IMAGE ARGS PATTERN...
# Runs ntop_repositories_installation.sh once in a fresh container; all PATTERNs must appear in
# the combined output for the case to PASS. Set PRECMD before calling to
# run an extra shell snippet inside the container before ntop_repositories_installation.sh (used
# below for the debian:11 EOL-mirror workaround); it's reset after use.
# If INSTALL_PACKAGES=1, also attempts `<pkg-mgr> install -y nprobe ntopng`
# after ntop_repositories_installation.sh and requires that to exit 0 as well - this is the real
# proof the configured repo actually works, not just that files got written.
check_image() {
    image="$1"; args="$2"; shift 2
    precmd="${PRECMD:-}"
    PRECMD=""
    echo "=================================================================="
    echo "IMAGE: $image   ARGS: $args"
    [ "$INSTALL_PACKAGES" = "1" ] && echo "  (+ will attempt: install nprobe ntopng)"
    echo "=================================================================="

    cmd="sh /ntop_repositories_installation.sh $args"
    if [ "$INSTALL_PACKAGES" = "1" ]; then
        # Try whichever package manager ntop_repositories_installation.sh itself would have used.
        # DEBIAN_FRONTEND=noninteractive avoids hanging on any debconf
        # prompt (e.g. license-acknowledgement style questions) that would
        # otherwise block forever with no TTY attached.
        cmd="$cmd
echo ===PACKAGE-INSTALL===
if command -v apt-get >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y nprobe ntopng
elif command -v dnf >/dev/null 2>&1; then
    dnf install -y nprobe ntopng
elif command -v yum >/dev/null 2>&1; then
    yum install -y nprobe ntopng
else
    echo 'No known package manager found for the package-install step' >&2
    false
fi
echo PACKAGE_INSTALL_EXIT_CODE:\$?"
    fi

    out="$(docker run --rm -v "$SCRIPT:/ntop_repositories_installation.sh:ro" "$image" \
        sh -c "${precmd}${cmd}" 2>&1)"
    rc=$?
    echo "$out"
    echo "--- exit code: $rc ---"

    ok=1
    [ "$rc" -eq 0 ] || { echo "MISSING: exit code 0 (got $rc)"; ok=0; }
    for pattern in "$@"; do
        if ! echo "$out" | grep -qF "$pattern"; then
            echo "MISSING EXPECTED OUTPUT: $pattern"
            ok=0
        fi
    done

    if [ "$INSTALL_PACKAGES" = "1" ] && ! echo "$out" | grep -q "PACKAGE_INSTALL_EXIT_CODE:0"; then
        echo "MISSING: nprobe/ntopng package install did not report exit code 0"
        ok=0
    fi

    if [ "$ok" -eq 1 ]; then echo "RESULT: PASS"; PASS=$((PASS+1))
    else echo "RESULT: FAIL"; FAIL=$((FAIL+1)); fi
    echo
}

# check_idempotency IMAGE ARGS
# Runs ntop_repositories_installation.sh twice in the SAME container; the second run must report
# "already configured" rather than reconfiguring from scratch.
check_idempotency() {
    image="$1"; args="$2"
    echo "=================================================================="
    echo "IDEMPOTENCY: $image   ARGS: $args (run twice in the same container)"
    echo "=================================================================="

    out="$(docker run --rm -v "$SCRIPT:/ntop_repositories_installation.sh:ro" "$image" \
        sh -c "sh /ntop_repositories_installation.sh $args && echo ===SECOND-RUN=== && sh /ntop_repositories_installation.sh $args" 2>&1)"
    rc=$?
    echo "$out"
    echo "--- exit code: $rc ---"

    second_run="$(echo "$out" | sed -n '/===SECOND-RUN===/,$p')"
    if [ "$rc" -eq 0 ] && echo "$second_run" | grep -qF "already configured"; then
        echo "RESULT: PASS"; PASS=$((PASS+1))
    else
        echo "MISSING: 'already configured' message on second run"
        echo "RESULT: FAIL"; FAIL=$((FAIL+1))
    fi
    echo
}

# --- Debian/Ubuntu family ---
check_image "ubuntu:22.04" "--dev"    "Selected channel: dev"     "ntop repository added successfully"
check_image "ubuntu:22.04" "--stable" "Selected channel: stable"  "ntop repository added successfully"
check_image "ubuntu:24.04" "--dev"    "Selected channel: dev"     "ntop repository added successfully"
check_image "ubuntu:24.04" "--stable" "Selected channel: stable"  "ntop repository added successfully"
check_image "ubuntu:26.04" "--dev"    "Selected channel: dev"     "ntop repository added successfully"
check_image "ubuntu:26.04" "--stable" "Selected channel: stable"  "ntop repository added successfully"
check_image "debian:12"    "--dev"    "Enabling 'contrib'"        "ntop repository added successfully"
check_image "debian:12"    "--stable" "Selected channel: stable"  "ntop repository added successfully"
check_image "debian:13"    "--dev"    "Enabling 'contrib'"        "ntop repository added successfully"
check_image "debian:13"    "--stable" "Selected channel: stable"  "ntop repository added successfully"

# debian:11 (bullseye) is past standard support; the official image's mirror
# pins can go stale enough that apt refuses expired Release files. That's
# apt behaving correctly on an EOL system, not an ntop_repositories_installation.sh bug - this
# workaround is TEST-ONLY (never do this in ntop_repositories_installation.sh itself).
PRECMD="echo 'Acquire::Check-Valid-Until \"false\";' > /etc/apt/apt.conf.d/99no-check-valid-until-TESTONLY; "
check_image "debian:11"    "--stable" "Selected channel: stable"  "ntop repository added successfully"

# --- RHEL family ---
# Confirmed (by direct testing, across the whole RHEL family / all majors):
# ntop-installer is never available on the stable channel, despite ntop's
# own docs not calling out an exception for it. ntop_repositories_installation.sh handles this
# generically (not gated to a specific major) - it skips the doomed dnf/yum
# install attempt entirely and reports it instead, still exiting 0 since the
# repo itself was configured successfully. So the --stable cases below are
# expected to report that, not to actually install ntop-installer; see the
# RHEL-family --dev cases as the working counterpart on the same images.
check_image "almalinux:8"  "--dev"    "Selected channel: dev"     "ntop repository added successfully"
check_image "almalinux:8"  "--stable" "Selected channel: stable"  "ntop repository added successfully"
check_image "almalinux:9"  "--dev"    "Selected channel: dev"     "ntop repository added successfully"
check_image "almalinux:9"  "--stable" "Selected channel: stable"  "ntop repository added successfully"
check_image "almalinux:10"  "--dev"    "Selected channel: dev"     "ntop repository added successfully"
check_image "almalinux:10"  "--stable" "Selected channel: stable"  "ntop repository added successfully"
check_image "rockylinux:8" "--dev"    "Selected channel: dev"     "ntop repository added successfully"
check_image "rockylinux:8" "--stable" "Selected channel: stable"  "ntop repository added successfully"
check_image "rockylinux:9" "--dev"    "Selected channel: dev"     "ntop repository added successfully"
check_image "rockylinux:9" "--stable" "Selected channel: stable"  "ntop repository added successfully"
check_image "rockylinux/rockylinux:10" "--dev"    "Selected channel: dev"     "ntop repository added successfully"
check_image "rockylinux/rockylinux:10" "--stable" "Selected channel: stable"  "ntop repository added successfully"

# --- Idempotency + channel-mismatch reporting ---
check_idempotency "ubuntu:24.04" "--dev"
check_idempotency "ubuntu:24.04" "--stable"
check_idempotency "ubuntu:26.04" "--dev"
check_idempotency "ubuntu:26.04" "--stable"

echo "=================================================================="
echo "SUMMARY: $PASS passed, $FAIL failed"
echo "=================================================================="
[ "$FAIL" -eq 0 ]
