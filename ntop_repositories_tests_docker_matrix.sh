#!/bin/sh
# Runs the real ntop_repositories_install.sh inside real containers for each supported Linux
# distro/version and does basic assertions on the output.
#
# Usage: ./ntop_repositories_tests_docker_matrix.sh [--install-packages] [ntop_repositories_install.sh path]
#   (run from the directory containing ntop_repositories_install.sh, or pass its path)
#
#   --install-packages   after each ntop_repositories_install.sh run, also attempt to
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
SCRIPT="${SCRIPT:-$(pwd)/ntop_repositories_install.sh}"
[ -f "$SCRIPT" ] || { echo "ntop_repositories_install.sh not found at $SCRIPT"; exit 1; }
SCRIPT="$(cd "$(dirname "$SCRIPT")" && pwd)/$(basename "$SCRIPT")"

if [ "$INSTALL_PACKAGES" = "1" ]; then
    echo "NOTE: --install-packages is on - every check_image run will also"
    echo "attempt to install nprobe/ntopng for real and check it succeeds."
    echo
fi

PASS=0
FAIL=0

# The real, currently-published script on GitHub's main branch. Tests using
# this fetch it fresh over the network each run - they exercise whatever is
# LIVE right now, not local changes (push first if you want these to reflect
# work in progress), and need real network access to both
# raw.githubusercontent.com and packages.ntop.org from inside the container,
# on top of what check_image already requires.
REMOTE_URL="https://raw.githubusercontent.com/ntop/package-installer/refs/heads/main/ntop_repositories_install.sh"

# check_image IMAGE ARGS PATTERN...
# Runs ntop_repositories_install.sh once in a fresh container; all PATTERNs must appear in
# the combined output for the case to PASS. Set PRECMD before calling to
# run an extra shell snippet inside the container before ntop_repositories_install.sh (used
# below for the debian:11 EOL-mirror workaround); it's reset after use.
# If INSTALL_PACKAGES=1, also attempts `<pkg-mgr> install -y nprobe ntopng`
# after ntop_repositories_install.sh and requires that to exit 0 as well - this is the real
# proof the configured repo actually works, not just that files got written.
check_image() {
    image="$1"; args="$2"; shift 2
    precmd="${PRECMD:-}"
    PRECMD=""
    echo "=================================================================="
    echo "IMAGE: $image   ARGS: $args"
    [ "$INSTALL_PACKAGES" = "1" ] && echo "  (+ will attempt: install nprobe ntopng)"
    echo "=================================================================="

    # --log is always added on top of whatever channel/etc args the test
    # itself specifies: CI needs the full diagnostic detail (e.g. "Selected
    # channel: ..."), which is intentionally quiet by default for real
    # end-user runs otherwise.
    cmd="sh /ntop_repositories_install.sh $args --log"
    if [ "$INSTALL_PACKAGES" = "1" ]; then
        # Try whichever package manager ntop_repositories_install.sh itself would have used.
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

    out="$(docker run --rm -v "$SCRIPT:/ntop_repositories_install.sh:ro" "$image" \
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

# check_curl_pipe IMAGE ARGS PATTERN...
# Genuinely exercises the documented `curl -fsSL <url> | sh -s -- ARGS`
# one-liner, fetching REMOTE_URL fresh inside the container and piping it
# straight into `sh` - as root, so this is the straightforward case. This
# is a different, complementary thing to check_image: that one proves the
# LOCAL script (mounted read-only into the container) behaves correctly;
# this one proves the actual copy-pasteable instructions work end-to-end
# against what's really published, including the network fetch and the
# pipe itself (not just the script's own logic in isolation).
check_curl_pipe() {
    image="$1"; args="$2"; shift 2
    echo "=================================================================="
    echo "CURL PIPE (live, published script): $image   ARGS: $args"
    echo "=================================================================="

    out="$(docker run --rm "$image" sh -c "
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update -qq >/dev/null 2>&1
            apt-get install -y curl ca-certificates >/dev/null 2>&1
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y curl >/dev/null 2>&1
        elif command -v yum >/dev/null 2>&1; then
            yum install -y curl >/dev/null 2>&1
        fi
        curl -fsSL '$REMOTE_URL' | sh -s -- $args --log
    " 2>&1)"
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

    if [ "$ok" -eq 1 ]; then echo "RESULT: PASS"; PASS=$((PASS+1))
    else echo "RESULT: FAIL"; FAIL=$((FAIL+1)); fi
    echo
}

# check_curl_pipe_sudo_prefix IMAGE ARGS
# Same as check_curl_pipe, but as a genuine non-root user using the OTHER
# documented form: `sudo` outside the pipe (`curl ... | sudo sh -s -- ARGS`).
# By the time `sh` starts here it's already root (sudo elevated first), so
# this does NOT exercise require_root()'s own re-exec logic - it confirms
# the documented workaround itself actually works end-to-end for a real
# non-root user, which is what people are told to use precisely because
# piped scripts can't safely elevate themselves.
check_curl_pipe_sudo_prefix() {
    image="$1"; args="$2"; shift 2
    echo "=================================================================="
    echo "CURL PIPE, non-root, 'sudo' outside the pipe: $image   ARGS: $args"
    echo "=================================================================="

    out="$(docker run --rm "$image" sh -c "
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update -qq >/dev/null 2>&1
            apt-get install -y curl ca-certificates sudo >/dev/null 2>&1
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y curl sudo >/dev/null 2>&1
        elif command -v yum >/dev/null 2>&1; then
            yum install -y curl sudo >/dev/null 2>&1
        fi
        useradd -m testuser 2>/dev/null
        echo 'testuser ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/testuser
        su - testuser -c \"curl -fsSL '$REMOTE_URL' | sudo sh -s -- $args --log\"
    " 2>&1)"
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

    if [ "$ok" -eq 1 ]; then echo "RESULT: PASS"; PASS=$((PASS+1))
    else echo "RESULT: FAIL"; FAIL=$((FAIL+1)); fi
    echo
}

# check_curl_pipe_no_sudo_dies IMAGE ARGS
# Regression test for a real bug found in production: require_root()'s
# sudo re-exec used to try `exec sudo -E sh "$0" "$@"`, but under a REAL
# `curl ... | sh` pipe (no sudo prefix, genuinely non-root), $0 is just the
# interpreter's own name ("sh"/"bash") rather than a real file - re-execing
# that crashed with "sh: 0: cannot open sh: No such file", with no useful
# explanation. The fix makes this case die() cleanly with actionable
# guidance instead. This test recreates the EXACT scenario (non-root, bare
# `curl | sh`, no external sudo) and asserts the clean failure, not the
# crash.
check_curl_pipe_no_sudo_dies() {
    image="$1"; args="$2"
    echo "=================================================================="
    echo "CURL PIPE, non-root, NO sudo prefix (must die cleanly, not crash): $image   ARGS: $args"
    echo "=================================================================="

    out="$(docker run --rm "$image" sh -c "
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update -qq >/dev/null 2>&1
            apt-get install -y curl ca-certificates sudo >/dev/null 2>&1
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y curl sudo >/dev/null 2>&1
        elif command -v yum >/dev/null 2>&1; then
            yum install -y curl sudo >/dev/null 2>&1
        fi
        useradd -m testuser 2>/dev/null
        su - testuser -c \"curl -fsSL '$REMOTE_URL' | sh -s -- $args --log\"
    " 2>&1)"
    rc=$?
    echo "$out"
    echo "--- exit code: $rc ---"

    ok=1
    if [ "$rc" -eq 0 ]; then
        echo "MISSING: expected a non-zero exit (should die() asking the user to prefix sudo)"
        ok=0
    fi
    if echo "$out" | grep -qF "cannot open"; then
        echo "REGRESSION: hit the old \$0-under-a-pipe crash (cannot open sh/bash) - require_root()'s fix is broken"
        ok=0
    fi
    if ! echo "$out" | grep -qF "can't re-exec itself with sudo when run via a pipe"; then
        echo "MISSING: expected the clean 'run via a pipe' die() message"
        ok=0
    fi

    if [ "$ok" -eq 1 ]; then echo "RESULT: PASS"; PASS=$((PASS+1))
    else echo "RESULT: FAIL"; FAIL=$((FAIL+1)); fi
    echo
}

# check_idempotency IMAGE ARGS
# Runs ntop_repositories_install.sh twice in the SAME container; the second run must report
# "already configured" rather than reconfiguring from scratch.
check_idempotency() {
    image="$1"; args="$2"
    echo "=================================================================="
    echo "IDEMPOTENCY: $image   ARGS: $args (run twice in the same container)"
    echo "=================================================================="

    out="$(docker run --rm -v "$SCRIPT:/ntop_repositories_install.sh:ro" "$image" \
        sh -c "sh /ntop_repositories_install.sh $args --log && echo ===SECOND-RUN=== && sh /ntop_repositories_install.sh $args --log" 2>&1)"
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

# check_channel_switch_dies IMAGE FIRST_ARGS SECOND_ARGS
# Runs ntop_repositories_install.sh once with FIRST_ARGS, then again with
# SECOND_ARGS in the SAME container. Since the repo is already configured for
# a DIFFERENT channel than the second run asks for, the second run must now
# die() (non-zero exit + a channel-mismatch message) rather than silently
# skip and exit 0 - not applicable to the FreeBSD family, where only one
# channel ever exists so this code path is unreachable by design.
check_channel_switch_dies() {
    image="$1"; first_args="$2"; second_args="$3"
    echo "=================================================================="
    echo "CHANNEL SWITCH: $image   $first_args -> $second_args (2nd run must die)"
    echo "=================================================================="

    out="$(docker run --rm -v "$SCRIPT:/ntop_repositories_install.sh:ro" "$image" \
        sh -c "sh /ntop_repositories_install.sh $first_args --log && echo ===SECOND-RUN=== && sh /ntop_repositories_install.sh $second_args --log" 2>&1)"
    rc=$?
    echo "$out"
    echo "--- final exit code: $rc ---"

    second_run="$(echo "$out" | sed -n '/===SECOND-RUN===/,$p')"
    if [ "$rc" -ne 0 ] && echo "$second_run" | grep -qF "NOT the requested"; then
        echo "RESULT: PASS"; PASS=$((PASS+1))
    else
        echo "MISSING: expected the second run to die() with a channel-mismatch message"
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
# apt behaving correctly on an EOL system, not an ntop_repositories_install.sh bug - this
# workaround is TEST-ONLY (never do this in ntop_repositories_install.sh itself).
#PRECMD="echo 'Acquire::Check-Valid-Until \"false\";' > /etc/apt/apt.conf.d/99no-check-valid-until-TESTONLY; "
#check_image "debian:11"    "--stable" "Selected channel: stable"  "ntop repository added successfully"

# --- RHEL family ---
# Confirmed (by direct testing, across the whole RHEL family / all majors):
# ntop-installer is never available on the stable channel, despite ntop's
# own docs not calling out an exception for it. ntop_repositories_install.sh handles this
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

# --- Channel switch must now die() (dev<->stable), not silently skip ---
check_channel_switch_dies "ubuntu:24.04" "--dev"    "--stable"
check_channel_switch_dies "ubuntu:24.04" "--stable" "--dev"
check_channel_switch_dies "ubuntu:26.04" "--dev"    "--stable"
check_channel_switch_dies "ubuntu:26.04" "--stable" "--dev"
check_channel_switch_dies "almalinux:9"  "--dev"    "--stable"

# --- Real curl-pipe one-liner against the LIVE published script ---
# See REMOTE_URL above and the check_curl_pipe* comments: these fetch the
# script fresh from GitHub inside the container rather than mounting the
# local $SCRIPT, and need real network access to raw.githubusercontent.com
# and packages.ntop.org in addition to what the rest of this matrix needs.
check_curl_pipe "ubuntu:22.04" "--dev"    "Selected channel: dev"    "ntop repository added successfully"
check_curl_pipe "ubuntu:22.04" "--stable" "Selected channel: stable" "ntop repository added successfully"
check_curl_pipe "ubuntu:24.04" "--dev"    "Selected channel: dev"    "ntop repository added successfully"
check_curl_pipe "ubuntu:24.04" "--stable" "Selected channel: stable" "ntop repository added successfully"
check_curl_pipe "ubuntu:26.04" "--dev"    "Selected channel: dev"    "ntop repository added successfully"
check_curl_pipe "ubuntu:26.04" "--stable" "Selected channel: stable" "ntop repository added successfully"
check_curl_pipe "debian:12"    "--dev"    "Selected channel: dev"    "ntop repository added successfully"
check_curl_pipe "debian:12"    "--stable" "Selected channel: stable" "ntop repository added successfully"
check_curl_pipe "debian:13"    "--dev"    "Selected channel: dev"    "ntop repository added successfully"
check_curl_pipe "debian:13"    "--stable" "Selected channel: stable" "ntop repository added successfully"
check_curl_pipe "almalinux:8"  "--stable" "Selected channel: stable" "ntop repository added successfully"
check_curl_pipe "almalinux:9"  "--stable" "Selected channel: stable" "ntop repository added successfully"
check_curl_pipe "almalinux:10" "--dev"    "Selected channel: dev"    "ntop repository added successfully"
check_curl_pipe "almalinux:10" "--stable" "Selected channel: stable" "ntop repository added successfully"
check_curl_pipe "rockylinux:9" "--dev"    "Selected channel: dev"    "ntop repository added successfully"
check_curl_pipe "rockylinux:9" "--stable" "Selected channel: stable" "ntop repository added successfully"
check_curl_pipe "rockylinux/rockylinux:10" "--dev"    "Selected channel: dev"    "ntop repository added successfully"
check_curl_pipe "rockylinux/rockylinux:10" "--stable" "Selected channel: stable" "ntop repository added successfully"
check_curl_pipe_sudo_prefix "ubuntu:24.04" "--dev" "Selected channel: dev" "ntop repository added successfully"
check_curl_pipe_no_sudo_dies "ubuntu:24.04" "--dev"

echo "=================================================================="
echo "SUMMARY: $PASS passed, $FAIL failed"
echo "=================================================================="
[ "$FAIL" -eq 0 ]
