#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
AWAKE_BIN="$ROOT_DIR/scripts/awake/awake.sh"

fail() {
    echo "not ok - $1" >&2
    exit 1
}

assert_file_contains() {
    local file="$1"
    local pattern="$2"
    grep -Eq "$pattern" "$file" || fail "expected '$pattern' in $file"
}

test_awake_on_uses_helper_and_writes_state() {
    local tmpdir helper state_dir stdout_file stderr_file
    tmpdir="$(mktemp -d)"
    helper="$tmpdir/fake-helper.sh"
    state_dir="$tmpdir/state"
    stdout_file="$tmpdir/stdout"
    stderr_file="$tmpdir/stderr"

    cat > "$helper" <<'EOF'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >> "$AWAKE_TEST_HELPER_LOG"
exit 0
EOF
    chmod +x "$helper"

    export AWAKE_HELPER_BIN="$helper"
    export AWAKE_SUDO_BIN=""
    export AWAKE_STATE_DIR="$state_dir"
    export AWAKE_UNAME="Darwin"
    export AWAKE_TEST_HELPER_LOG="$tmpdir/helper.log"
    export AWAKE_CAFFEINATE_BIN="$tmpdir/does-not-exist"

    bash "$AWAKE_BIN" on 30m >"$stdout_file" 2>"$stderr_file" || fail "awake on 30m should succeed"

    assert_file_contains "$AWAKE_TEST_HELPER_LOG" '^start 1800 '
    [ -f "$state_dir/awake.state" ] || fail "expected awake.state to be created"
}

test_awake_off_restores_and_cleans_state() {
    local tmpdir helper state_dir stdout_file stderr_file
    tmpdir="$(mktemp -d)"
    helper="$tmpdir/fake-helper.sh"
    state_dir="$tmpdir/state"
    stdout_file="$tmpdir/stdout"
    stderr_file="$tmpdir/stderr"

    cat > "$helper" <<'EOF'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >> "$AWAKE_TEST_HELPER_LOG"
exit 0
EOF
    chmod +x "$helper"

    mkdir -p "$state_dir"
    cat > "$state_dir/awake.state" <<EOF
version=1
token=token-off
expires_epoch=4102444800
helper_bin=$helper
EOF

    export AWAKE_HELPER_BIN="$helper"
    export AWAKE_SUDO_BIN=""
    export AWAKE_STATE_DIR="$state_dir"
    export AWAKE_UNAME="Darwin"
    export AWAKE_TEST_HELPER_LOG="$tmpdir/helper.log"

    bash "$AWAKE_BIN" off >"$stdout_file" 2>"$stderr_file" || fail "awake off should succeed"

    assert_file_contains "$AWAKE_TEST_HELPER_LOG" '^restore token-off$'
    [ ! -f "$state_dir/awake.state" ] || fail "expected awake.state to be removed"
}

test_awake_off_stops_legacy_caffeinate_before_cleanup() {
    local tmpdir helper state_dir ps_bin kill_bin stdout_file stderr_file
    tmpdir="$(mktemp -d)"
    helper="$tmpdir/fake-helper.sh"
    state_dir="$tmpdir/state"
    ps_bin="$tmpdir/fake-ps.sh"
    kill_bin="$tmpdir/fake-kill.sh"
    stdout_file="$tmpdir/stdout"
    stderr_file="$tmpdir/stderr"

    cat > "$helper" <<'EOF'
#!/bin/bash
set -euo pipefail
exit 0
EOF
    chmod +x "$helper"

    cat > "$ps_bin" <<'EOF'
#!/bin/bash
set -euo pipefail
printf 'caffeinate\n'
EOF
    chmod +x "$ps_bin"

    cat > "$kill_bin" <<'EOF'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >> "$AWAKE_TEST_KILL_LOG"
EOF
    chmod +x "$kill_bin"

    mkdir -p "$state_dir"
    printf '12345\n' > "$state_dir/awake.pid"
    printf '9999999999\n' > "$state_dir/awake.expires"

    export AWAKE_HELPER_BIN="$helper"
    export AWAKE_SUDO_BIN=""
    export AWAKE_STATE_DIR="$state_dir"
    export AWAKE_UNAME="Darwin"
    export AWAKE_PS_BIN="$ps_bin"
    export AWAKE_KILL_BIN="$kill_bin"
    export AWAKE_TEST_KILL_LOG="$tmpdir/kill.log"

    bash "$AWAKE_BIN" off >"$stdout_file" 2>"$stderr_file" || fail "awake off should succeed"

    assert_file_contains "$AWAKE_TEST_KILL_LOG" '^12345$'
    [ ! -f "$state_dir/awake.pid" ] || fail "expected legacy awake.pid to be removed"
    [ ! -f "$state_dir/awake.expires" ] || fail "expected legacy awake.expires to be removed"
}

test_awake_on_respects_platform_override() {
    local tmpdir helper state_dir stdout_file stderr_file
    tmpdir="$(mktemp -d)"
    helper="$tmpdir/fake-helper.sh"
    state_dir="$tmpdir/state"
    stdout_file="$tmpdir/stdout"
    stderr_file="$tmpdir/stderr"

    cat > "$helper" <<'EOF'
#!/bin/bash
set -euo pipefail
exit 0
EOF
    chmod +x "$helper"

    export AWAKE_HELPER_BIN="$helper"
    export AWAKE_SUDO_BIN=""
    export AWAKE_STATE_DIR="$state_dir"
    export AWAKE_UNAME="Linux"

    if bash "$AWAKE_BIN" on 30m >"$stdout_file" 2>"$stderr_file"; then
        fail "awake on 30m should fail when platform override is Linux"
    fi

    assert_file_contains "$stderr_file" 'only supported on macOS'
}

test_awake_status_cleans_expired_state_even_when_sleepdisabled_is_one() {
    local tmpdir helper pmset_bin state_dir stdout_file stderr_file
    tmpdir="$(mktemp -d)"
    helper="$tmpdir/fake-helper.sh"
    pmset_bin="$tmpdir/fake-pmset.sh"
    state_dir="$tmpdir/state"
    stdout_file="$tmpdir/stdout"
    stderr_file="$tmpdir/stderr"

    cat > "$helper" <<'EOF'
#!/bin/bash
set -euo pipefail
if [ "${1:-}" = "status" ]; then
    printf 'active=0\n'
    exit 0
fi
exit 0
EOF
    chmod +x "$helper"

    cat > "$pmset_bin" <<'EOF'
#!/bin/bash
set -euo pipefail
if [ "${1:-}" = "-g" ]; then
    printf ' SleepDisabled 1\n'
    exit 0
fi
exit 1
EOF
    chmod +x "$pmset_bin"

    mkdir -p "$state_dir"
    cat > "$state_dir/awake.state" <<EOF
version=1
token=token-expired
expires_epoch=1
helper_bin=/usr/local/libexec/sazo-ai-harness/awake-helper
EOF

    export AWAKE_HELPER_BIN="$helper"
    export AWAKE_SUDO_BIN=""
    export AWAKE_STATE_DIR="$state_dir"
    export AWAKE_PMSET_BIN="$pmset_bin"
    export AWAKE_UNAME="Darwin"

    bash "$AWAKE_BIN" status >"$stdout_file" 2>"$stderr_file" || fail "awake status should succeed"

    assert_file_contains "$stdout_file" '^awake: off$'
    [ ! -f "$state_dir/awake.state" ] || fail "expected expired awake.state to be removed"
}

test_awake_off_cleans_expired_state_when_helper_restore_is_missing() {
    local tmpdir helper state_dir stdout_file stderr_file
    tmpdir="$(mktemp -d)"
    helper="$tmpdir/fake-helper.sh"
    state_dir="$tmpdir/state"
    stdout_file="$tmpdir/stdout"
    stderr_file="$tmpdir/stderr"

    cat > "$helper" <<'EOF'
#!/bin/bash
set -euo pipefail
if [ "${1:-}" = "status" ]; then
    printf 'active=0\n'
    exit 0
fi
exit 1
EOF
    chmod +x "$helper"

    mkdir -p "$state_dir"
    cat > "$state_dir/awake.state" <<EOF
version=1
token=token-expired-off
expires_epoch=1
helper_bin=$helper
EOF

    export AWAKE_HELPER_BIN="$helper"
    export AWAKE_SUDO_BIN=""
    export AWAKE_STATE_DIR="$state_dir"
    export AWAKE_UNAME="Darwin"

    bash "$AWAKE_BIN" off >"$stdout_file" 2>"$stderr_file" || fail "awake off should treat expired stale state as already off"

    assert_file_contains "$stdout_file" '^awake: off$'
    [ ! -f "$state_dir/awake.state" ] || fail "expected expired awake.state to be removed after off"
}

test_awake_off_preserves_state_when_helper_restore_fails_and_helper_is_still_active() {
    local tmpdir helper state_dir stdout_file stderr_file
    tmpdir="$(mktemp -d)"
    helper="$tmpdir/fake-helper.sh"
    state_dir="$tmpdir/state"
    stdout_file="$tmpdir/stdout"
    stderr_file="$tmpdir/stderr"

    cat > "$helper" <<'EOF'
#!/bin/bash
set -euo pipefail
if [ "${1:-}" = "status" ]; then
    printf 'active=1\n'
    exit 0
fi
exit 1
EOF
    chmod +x "$helper"

    mkdir -p "$state_dir"
    cat > "$state_dir/awake.state" <<EOF
version=1
token=token-active-off
expires_epoch=1
helper_bin=$helper
EOF

    export AWAKE_HELPER_BIN="$helper"
    export AWAKE_SUDO_BIN=""
    export AWAKE_STATE_DIR="$state_dir"
    export AWAKE_UNAME="Darwin"

    if bash "$AWAKE_BIN" off >"$stdout_file" 2>"$stderr_file"; then
        fail "awake off should fail when helper restore fails and helper state is still active"
    fi

    assert_file_contains "$stderr_file" 'Failed to restore previous sleep setting'
    [ -f "$state_dir/awake.state" ] || fail "expected awake.state to remain when helper is still active"
}

test_awake_on_restores_helper_when_local_state_write_fails() {
    local tmpdir helper bad_state_dir stdout_file stderr_file
    tmpdir="$(mktemp -d)"
    helper="$tmpdir/fake-helper.sh"
    bad_state_dir="$tmpdir/not-a-dir"
    stdout_file="$tmpdir/stdout"
    stderr_file="$tmpdir/stderr"

    cat > "$helper" <<'EOF'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >> "$AWAKE_TEST_HELPER_LOG"
exit 0
EOF
    chmod +x "$helper"

    printf 'not-a-dir\n' > "$bad_state_dir"

    export AWAKE_HELPER_BIN="$helper"
    export AWAKE_SUDO_BIN=""
    export AWAKE_STATE_DIR="$bad_state_dir"
    export AWAKE_UNAME="Darwin"
    export AWAKE_TEST_HELPER_LOG="$tmpdir/helper.log"

    if bash "$AWAKE_BIN" on 30m >"$stdout_file" 2>"$stderr_file"; then
        fail "awake on should fail when local state write fails"
    fi

    assert_file_contains "$AWAKE_TEST_HELPER_LOG" '^start 1800 '
    assert_file_contains "$AWAKE_TEST_HELPER_LOG" '^restore '
}

test_awake_extend_restores_helper_when_local_state_write_fails() {
    local tmpdir helper state_dir stdout_file stderr_file
    tmpdir="$(mktemp -d)"
    helper="$tmpdir/fake-helper.sh"
    state_dir="$tmpdir/state"
    stdout_file="$tmpdir/stdout"
    stderr_file="$tmpdir/stderr"

    cat > "$helper" <<'EOF'
#!/bin/bash
set -euo pipefail
if [ "${1:-}" = "start" ]; then
    rm -rf "$AWAKE_STATE_DIR"
    printf 'not-a-dir\n' > "$AWAKE_STATE_DIR"
fi
printf '%s\n' "$*" >> "$AWAKE_TEST_HELPER_LOG"
exit 0
EOF
    chmod +x "$helper"

    mkdir -p "$state_dir"
    cat > "$state_dir/awake.state" <<EOF
version=1
token=token-extend
expires_epoch=4102445800
helper_bin=$helper
EOF
    export AWAKE_HELPER_BIN="$helper"
    export AWAKE_SUDO_BIN=""
    export AWAKE_STATE_DIR="$state_dir"
    export AWAKE_UNAME="Darwin"
    export AWAKE_TEST_HELPER_LOG="$tmpdir/helper.log"

    if bash "$AWAKE_BIN" extend 30m >"$stdout_file" 2>"$stderr_file"; then
        fail "awake extend should fail when local state write fails"
    fi

    assert_file_contains "$AWAKE_TEST_HELPER_LOG" '^start '
    assert_file_contains "$AWAKE_TEST_HELPER_LOG" '^restore '
}

test_awake_on_serializes_local_state_writes() {
    local tmpdir helper state_dir stdout1 stderr1 stdout2 stderr2 token1 token2 final_token
    tmpdir="$(mktemp -d)"
    helper="$tmpdir/fake-helper.sh"
    state_dir="$tmpdir/state"
    stdout1="$tmpdir/stdout1"
    stderr1="$tmpdir/stderr1"
    stdout2="$tmpdir/stdout2"
    stderr2="$tmpdir/stderr2"

    cat > "$helper" <<'EOF'
#!/bin/bash
set -euo pipefail
count_file="$AWAKE_TEST_HELPER_COUNT"
count=0
[ -f "$count_file" ] && count="$(cat "$count_file")"
count=$((count + 1))
printf '%s\n' "$count" > "$count_file"
printf '%s\n' "$*" >> "$AWAKE_TEST_HELPER_LOG"
if [ "$count" -eq 1 ] && [ "${1:-}" = "start" ]; then
    sleep 0.2
fi
exit 0
EOF
    chmod +x "$helper"

    mkdir -p "$state_dir"

    export AWAKE_HELPER_BIN="$helper"
    export AWAKE_SUDO_BIN=""
    export AWAKE_STATE_DIR="$state_dir"
    export AWAKE_UNAME="Darwin"
    export AWAKE_STAT_FLAVOR="$(uname -s)"
    export AWAKE_TEST_HELPER_LOG="$tmpdir/helper.log"
    export AWAKE_TEST_HELPER_COUNT="$tmpdir/helper.count"

    bash "$AWAKE_BIN" on 30m >"$stdout1" 2>"$stderr1" &
    pid1=$!
    bash "$AWAKE_BIN" on 30m >"$stdout2" 2>"$stderr2" &
    pid2=$!

    wait "$pid1" || fail "first concurrent awake on should succeed"
    wait "$pid2" || fail "second concurrent awake on should succeed"

    token1="$(sed -n '1s/^start 1800 \([^ ]*\) .*/\1/p' "$tmpdir/helper.log")"
    token2="$(sed -n '2s/^start 1800 \([^ ]*\) .*/\1/p' "$tmpdir/helper.log")"
    final_token="$(sed -n 's/^token=//p' "$state_dir/awake.state")"

    [ -n "$token1" ] || fail "expected first helper token"
    [ -n "$token2" ] || fail "expected second helper token"
    [ "$final_token" = "$token2" ] || fail "expected final awake.state token to match the second serialized invocation"
}

test_awake_on_does_not_steal_live_lock_with_old_mtime() {
    local tmpdir helper state_dir stdout_file stderr_file owner_pid_file
    tmpdir="$(mktemp -d)"
    helper="$tmpdir/fake-helper.sh"
    state_dir="$tmpdir/state"
    stdout_file="$tmpdir/stdout"
    stderr_file="$tmpdir/stderr"
    owner_pid_file="$tmpdir/lock.d/owner.pid"

    cat > "$helper" <<'EOF'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >> "$AWAKE_TEST_HELPER_LOG"
exit 0
EOF
    chmod +x "$helper"

    /bin/sleep 300 >/dev/null 2>&1 &
    live_pid="$!"

    mkdir -p "$tmpdir/lock.d"
    printf '%s\n' "$live_pid" > "$owner_pid_file"
    touch -t 200001010000 "$tmpdir/lock.d"

    export AWAKE_HELPER_BIN="$helper"
    export AWAKE_SUDO_BIN=""
    export AWAKE_STATE_DIR="$state_dir"
    export AWAKE_LOCK_DIR="$tmpdir/lock.d"
    export AWAKE_UNAME="Darwin"
    export AWAKE_STAT_FLAVOR="$(uname -s)"
    export AWAKE_TEST_HELPER_LOG="$tmpdir/helper.log"

    if bash "$AWAKE_BIN" on 30m >"$stdout_file" 2>"$stderr_file"; then
        fail "awake on should not steal a live lock even if directory mtime is old"
    fi

    kill "$live_pid" 2>/dev/null || true
    [ ! -f "$tmpdir/helper.log" ] || fail "expected no helper call while another live lock owner exists"
}

test_awake_on_uses_helper_and_writes_state
test_awake_off_restores_and_cleans_state
test_awake_off_stops_legacy_caffeinate_before_cleanup
test_awake_on_respects_platform_override
test_awake_status_cleans_expired_state_even_when_sleepdisabled_is_one
test_awake_off_cleans_expired_state_when_helper_restore_is_missing
test_awake_off_preserves_state_when_helper_restore_fails_and_helper_is_still_active
test_awake_on_restores_helper_when_local_state_write_fails
test_awake_extend_restores_helper_when_local_state_write_fails
test_awake_on_serializes_local_state_writes
test_awake_on_does_not_steal_live_lock_with_old_mtime
echo "ok - awake on uses helper and writes state"
