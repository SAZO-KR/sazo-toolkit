#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
HELPER_BIN="$ROOT_DIR/scripts/awake/awake-helper.sh"

fail() {
    echo "not ok - $1" >&2
    exit 1
}

assert_file_contains() {
    local file="$1"
    local pattern="$2"
    grep -Eq "$pattern" "$file" || fail "expected '$pattern' in $file"
}

test_helper_start_and_restore() {
    local tmpdir pmset_bin state_dir lock_dir state_file
    tmpdir="$(mktemp -d)"
    pmset_bin="$tmpdir/fake-pmset.sh"
    state_dir="$tmpdir/root-state"
    lock_dir="$tmpdir/lockdir"
    state_file="$state_dir/awake-root.state"

    cat > "$pmset_bin" <<'EOF'
#!/bin/bash
set -euo pipefail
state_file="$AWAKE_TEST_PMSET_STATE"
log_file="$AWAKE_TEST_PMSET_LOG"
current="0"
[ -f "$state_file" ] && current="$(/bin/cat "$state_file")"

if [ "${1:-}" = "-g" ]; then
    printf ' SleepDisabled %s\n' "$current"
    exit 0
fi

if [ "${1:-}" = "-a" ] && [ "${2:-}" = "disablesleep" ]; then
    printf '%s\n' "$3" > "$state_file"
    printf 'set %s\n' "$3" >> "$log_file"
    exit 0
fi

exit 1
EOF
    chmod +x "$pmset_bin"

    export AWAKE_HELPER_PMSET_BIN="$pmset_bin"
    export AWAKE_HELPER_STATE_DIR="$state_dir"
    export AWAKE_HELPER_LOCK_DIR="$lock_dir"
    export AWAKE_HELPER_SLEEP_BIN="/bin/sleep"
    export AWAKE_TEST_PMSET_STATE="$tmpdir/pmset.state"
    export AWAKE_TEST_PMSET_LOG="$tmpdir/pmset.log"

    printf '0\n' > "$AWAKE_TEST_PMSET_STATE"

    bash "$HELPER_BIN" start 1800 token-1 4102444800 >/dev/null 2>&1 || fail "helper start should succeed"
    [ -f "$state_file" ] || fail "expected root awake state file"
    assert_file_contains "$state_file" '^token=token-1$'
    assert_file_contains "$AWAKE_TEST_PMSET_LOG" '^set 1$'

    bash "$HELPER_BIN" restore token-1 >/dev/null 2>&1 || fail "helper restore should succeed"
    [ ! -f "$state_file" ] || fail "expected root awake state file to be removed"
    assert_file_contains "$AWAKE_TEST_PMSET_LOG" '^set 0$'
}

test_helper_reset_and_token_mismatch_rollback() {
    local tmpdir pmset_bin state_dir lock_dir state_file
    tmpdir="$(mktemp -d)"
    pmset_bin="$tmpdir/fake-pmset.sh"
    state_dir="$tmpdir/root-state"
    lock_dir="$tmpdir/lockdir"
    state_file="$state_dir/awake-root.state"

    cat > "$pmset_bin" <<'EOF'
#!/bin/bash
set -euo pipefail
state_file="$AWAKE_TEST_PMSET_STATE"
log_file="$AWAKE_TEST_PMSET_LOG"
current="0"
[ -f "$state_file" ] && current="$(/bin/cat "$state_file")"

if [ "${1:-}" = "-g" ]; then
    printf ' SleepDisabled %s\n' "$current"
    exit 0
fi

if [ "${1:-}" = "-a" ] && [ "${2:-}" = "disablesleep" ]; then
    printf '%s\n' "$3" > "$state_file"
    printf 'set %s\n' "$3" >> "$log_file"
    exit 0
fi

exit 1
EOF
    chmod +x "$pmset_bin"

    export AWAKE_HELPER_PMSET_BIN="$pmset_bin"
    export AWAKE_HELPER_STATE_DIR="$state_dir"
    export AWAKE_HELPER_LOCK_DIR="$lock_dir"
    export AWAKE_TEST_PMSET_STATE="$tmpdir/pmset.state"
    export AWAKE_TEST_PMSET_LOG="$tmpdir/pmset.log"

    printf '0\n' > "$AWAKE_TEST_PMSET_STATE"

    bash "$HELPER_BIN" start 1800 token-2 4102444800 >/dev/null 2>&1 || fail "helper start should succeed"
    [ -f "$state_file" ] || fail "expected root awake state file"

    bash "$HELPER_BIN" rollback wrong-token 4102444800 >/dev/null 2>&1 || fail "token mismatch rollback should no-op"
    [ -f "$state_file" ] || fail "expected state to survive token mismatch rollback"
    assert_file_contains "$AWAKE_TEST_PMSET_LOG" '^set 1$'

    bash "$HELPER_BIN" reset >/dev/null 2>&1 || fail "helper reset should succeed"
    [ ! -f "$state_file" ] || fail "expected reset to remove state"
    assert_file_contains "$AWAKE_TEST_PMSET_LOG" '^set 0$'
}

test_helper_restore_failure_keeps_rollback_alive() {
    local tmpdir pmset_bin state_dir lock_dir state_file
    tmpdir="$(mktemp -d)"
    pmset_bin="$tmpdir/fake-pmset.sh"
    state_dir="$tmpdir/root-state"
    lock_dir="$tmpdir/lockdir"
    state_file="$state_dir/awake-root.state"

    cat > "$pmset_bin" <<'EOF'
#!/bin/bash
set -euo pipefail
state_file="$AWAKE_TEST_PMSET_STATE"
log_file="$AWAKE_TEST_PMSET_LOG"
current="0"
[ -f "$state_file" ] && current="$(/bin/cat "$state_file")"

if [ "${1:-}" = "-g" ]; then
    printf ' SleepDisabled %s\n' "$current"
    exit 0
fi

if [ "${1:-}" = "-a" ] && [ "${2:-}" = "disablesleep" ]; then
    if [ "${AWAKE_TEST_PMSET_FAIL_ON:-}" = "$3" ]; then
        exit 1
    fi
    printf '%s\n' "$3" > "$state_file"
    printf 'set %s\n' "$3" >> "$log_file"
    exit 0
fi

exit 1
EOF
    chmod +x "$pmset_bin"

    export AWAKE_HELPER_PMSET_BIN="$pmset_bin"
    export AWAKE_HELPER_STATE_DIR="$state_dir"
    export AWAKE_HELPER_LOCK_DIR="$lock_dir"
    export AWAKE_HELPER_SLEEP_BIN="/bin/sleep"
    export AWAKE_TEST_PMSET_STATE="$tmpdir/pmset.state"
    export AWAKE_TEST_PMSET_LOG="$tmpdir/pmset.log"

    printf '0\n' > "$AWAKE_TEST_PMSET_STATE"

    /bin/sleep 300 >/dev/null 2>&1 &
    rollback_pid="$!"
    mkdir -p "$state_dir"
    cat > "$state_file" <<EOF
version=1
token=token-3
expires_epoch=4102444800
original_disablesleep=0
rollback_pid=$rollback_pid
started_epoch=1
EOF

    [ -n "$rollback_pid" ] || fail "expected rollback pid in helper state"
    kill -0 "$rollback_pid" 2>/dev/null || fail "expected rollback process to be alive before restore"

    export AWAKE_TEST_PMSET_FAIL_ON="0"
    if bash "$HELPER_BIN" restore token-3 >/dev/null 2>&1; then
        fail "helper restore should fail when pmset restore fails"
    fi

    [ -f "$state_file" ] || fail "expected helper state to remain after restore failure"
    kill -0 "$rollback_pid" 2>/dev/null || fail "expected rollback process to survive restore failure"
    unset AWAKE_TEST_PMSET_FAIL_ON

    bash "$HELPER_BIN" reset >/dev/null 2>&1 || fail "helper reset should still succeed"
}

test_helper_start_failure_preserves_existing_rollback() {
    local tmpdir pmset_bin state_dir lock_dir state_file
    tmpdir="$(mktemp -d)"
    pmset_bin="$tmpdir/fake-pmset.sh"
    state_dir="$tmpdir/root-state"
    lock_dir="$tmpdir/lockdir"
    state_file="$state_dir/awake-root.state"

    cat > "$pmset_bin" <<'EOF'
#!/bin/bash
set -euo pipefail
state_file="$AWAKE_TEST_PMSET_STATE"
log_file="$AWAKE_TEST_PMSET_LOG"
current="1"
[ -f "$state_file" ] && current="$(cat "$state_file")"

if [ "${1:-}" = "-g" ]; then
    printf ' SleepDisabled %s\n' "$current"
    exit 0
fi

if [ "${1:-}" = "-a" ] && [ "${2:-}" = "disablesleep" ]; then
    if [ "${AWAKE_TEST_PMSET_FAIL_ON:-}" = "$3" ]; then
        exit 1
    fi
    printf '%s\n' "$3" > "$state_file"
    printf 'set %s\n' "$3" >> "$log_file"
    exit 0
fi

exit 1
EOF
    chmod +x "$pmset_bin"

    export AWAKE_HELPER_PMSET_BIN="$pmset_bin"
    export AWAKE_HELPER_STATE_DIR="$state_dir"
    export AWAKE_HELPER_LOCK_DIR="$lock_dir"
    export AWAKE_HELPER_SLEEP_BIN="/bin/sleep"
    export AWAKE_TEST_PMSET_STATE="$tmpdir/pmset.state"
    export AWAKE_TEST_PMSET_LOG="$tmpdir/pmset.log"

    printf '1\n' > "$AWAKE_TEST_PMSET_STATE"

    /bin/sleep 300 >/dev/null 2>&1 &
    rollback_pid="$!"
    mkdir -p "$state_dir"
    cat > "$state_file" <<EOF
version=1
token=token-old
expires_epoch=4102444800
original_disablesleep=1
rollback_pid=$rollback_pid
started_epoch=1
EOF

    export AWAKE_TEST_PMSET_FAIL_ON="1"
    if bash "$HELPER_BIN" start 1800 token-new 4102445800 >/dev/null 2>&1; then
        fail "helper start should fail when replacement apply fails"
    fi

    kill -0 "$rollback_pid" 2>/dev/null || fail "expected existing rollback to survive replacement failure"
    assert_file_contains "$state_file" '^token=token-old$'
    unset AWAKE_TEST_PMSET_FAIL_ON

    bash "$HELPER_BIN" reset >/dev/null 2>&1 || fail "helper reset should still succeed"
}

test_helper_start_failure_restores_fresh_session_state() {
    local tmpdir pmset_bin state_dir lock_dir state_file
    tmpdir="$(mktemp -d)"
    pmset_bin="$tmpdir/fake-pmset.sh"
    state_dir="$tmpdir/root-state"
    lock_dir="$tmpdir/lockdir"
    state_file="$state_dir/awake-root.state"

    cat > "$pmset_bin" <<'EOF'
#!/bin/bash
set -euo pipefail
state_file="$AWAKE_TEST_PMSET_STATE"
log_file="$AWAKE_TEST_PMSET_LOG"
current="0"
[ -f "$state_file" ] && current="$(cat "$state_file")"

if [ "${1:-}" = "-g" ]; then
    printf ' SleepDisabled %s\n' "$current"
    exit 0
fi

if [ "${1:-}" = "-a" ] && [ "${2:-}" = "disablesleep" ]; then
    printf '%s\n' "$3" > "$state_file"
    printf 'set %s\n' "$3" >> "$log_file"
    exit 0
fi

exit 1
EOF
    chmod +x "$pmset_bin"

    export AWAKE_HELPER_PMSET_BIN="$pmset_bin"
    export AWAKE_HELPER_STATE_DIR="$state_dir"
    export AWAKE_HELPER_LOCK_DIR="$lock_dir"
    export AWAKE_HELPER_SLEEP_BIN="$tmpdir/missing-sleep"
    export AWAKE_TEST_PMSET_STATE="$tmpdir/pmset.state"
    export AWAKE_TEST_PMSET_LOG="$tmpdir/pmset.log"

    printf '0\n' > "$AWAKE_TEST_PMSET_STATE"

    if bash "$HELPER_BIN" start 1800 token-fresh 4102445800 >/dev/null 2>&1; then
        fail "helper start should fail when fresh-session rollback spawn fails"
    fi

    [ ! -f "$state_file" ] || fail "expected provisional helper state to be removed"
    assert_file_contains "$AWAKE_TEST_PMSET_LOG" '^set 1$'
    assert_file_contains "$AWAKE_TEST_PMSET_LOG" '^set 0$'
}

test_helper_start_failure_restores_when_state_write_fails() {
    local tmpdir pmset_bin bad_state_dir lock_dir
    tmpdir="$(mktemp -d)"
    pmset_bin="$tmpdir/fake-pmset.sh"
    bad_state_dir="$tmpdir/not-a-dir"
    lock_dir="$tmpdir/lockdir"

    cat > "$pmset_bin" <<'EOF'
#!/bin/bash
set -euo pipefail
state_file="$AWAKE_TEST_PMSET_STATE"
log_file="$AWAKE_TEST_PMSET_LOG"
current="0"
[ -f "$state_file" ] && current="$(cat "$state_file")"

if [ "${1:-}" = "-g" ]; then
    printf ' SleepDisabled %s\n' "$current"
    exit 0
fi

if [ "${1:-}" = "-a" ] && [ "${2:-}" = "disablesleep" ]; then
    printf '%s\n' "$3" > "$state_file"
    printf 'set %s\n' "$3" >> "$log_file"
    exit 0
fi

exit 1
EOF
    chmod +x "$pmset_bin"

    printf 'not-a-dir\n' > "$bad_state_dir"

    export AWAKE_HELPER_PMSET_BIN="$pmset_bin"
    export AWAKE_HELPER_STATE_DIR="$bad_state_dir"
    export AWAKE_HELPER_LOCK_DIR="$lock_dir"
    export AWAKE_HELPER_SLEEP_BIN="/bin/sleep"
    export AWAKE_TEST_PMSET_STATE="$tmpdir/pmset.state"
    export AWAKE_TEST_PMSET_LOG="$tmpdir/pmset.log"

    printf '0\n' > "$AWAKE_TEST_PMSET_STATE"

    if bash "$HELPER_BIN" start 1800 token-state-write 4102445800 >/dev/null 2>&1; then
        fail "helper start should fail when helper state write fails"
    fi

    assert_file_contains "$AWAKE_TEST_PMSET_LOG" '^set 1$'
    assert_file_contains "$AWAKE_TEST_PMSET_LOG" '^set 0$'
}

test_helper_start_failure_restores_when_heredoc_write_fails() {
    local tmpdir pmset_bin state_dir lock_dir state_file fake_cat path_backup
    tmpdir="$(mktemp -d)"
    pmset_bin="$tmpdir/fake-pmset.sh"
    state_dir="$tmpdir/root-state"
    lock_dir="$tmpdir/lockdir"
    state_file="$state_dir/awake-root.state"
    fake_cat="$tmpdir/cat"
    path_backup="$PATH"

    cat > "$pmset_bin" <<'EOF'
#!/bin/bash
set -euo pipefail
state_file="$AWAKE_TEST_PMSET_STATE"
log_file="$AWAKE_TEST_PMSET_LOG"
current="0"
[ -f "$state_file" ] && current="$(cat "$state_file")"

if [ "${1:-}" = "-g" ]; then
    printf ' SleepDisabled %s\n' "$current"
    exit 0
fi

if [ "${1:-}" = "-a" ] && [ "${2:-}" = "disablesleep" ]; then
    printf '%s\n' "$3" > "$state_file"
    printf 'set %s\n' "$3" >> "$log_file"
    exit 0
fi

exit 1
EOF
    chmod +x "$pmset_bin"

    cat > "$fake_cat" <<'EOF'
#!/bin/bash
set -euo pipefail
printf 'version=1\n'
exit 1
EOF
    chmod +x "$fake_cat"

    export PATH="$tmpdir:$path_backup"
    export AWAKE_HELPER_PMSET_BIN="$pmset_bin"
    export AWAKE_HELPER_STATE_DIR="$state_dir"
    export AWAKE_HELPER_LOCK_DIR="$lock_dir"
    export AWAKE_HELPER_SLEEP_BIN="/bin/sleep"
    export AWAKE_TEST_PMSET_STATE="$tmpdir/pmset.state"
    export AWAKE_TEST_PMSET_LOG="$tmpdir/pmset.log"

    printf '0\n' > "$AWAKE_TEST_PMSET_STATE"

    if bash "$HELPER_BIN" start 1800 token-heredoc 4102445800 >/dev/null 2>&1; then
        fail "helper start should fail when heredoc write fails"
    fi

    [ ! -f "$state_file" ] || fail "expected helper state file not to be published on heredoc failure"
    [ "$(/bin/cat "$AWAKE_TEST_PMSET_STATE")" = "0" ] || fail "expected pmset state to be restored to 0 on heredoc failure"
    export PATH="$path_backup"
}

test_helper_reset_failure_keeps_rollback_alive() {
    local tmpdir pmset_bin state_dir lock_dir state_file
    tmpdir="$(mktemp -d)"
    pmset_bin="$tmpdir/fake-pmset.sh"
    state_dir="$tmpdir/root-state"
    lock_dir="$tmpdir/lockdir"
    state_file="$state_dir/awake-root.state"

    cat > "$pmset_bin" <<'EOF'
#!/bin/bash
set -euo pipefail
state_file="$AWAKE_TEST_PMSET_STATE"
current="1"
[ -f "$state_file" ] && current="$(cat "$state_file")"

if [ "${1:-}" = "-g" ]; then
    printf ' SleepDisabled %s\n' "$current"
    exit 0
fi

if [ "${1:-}" = "-a" ] && [ "${2:-}" = "disablesleep" ]; then
    if [ "${AWAKE_TEST_PMSET_FAIL_ON:-}" = "$3" ]; then
        exit 1
    fi
    printf '%s\n' "$3" > "$state_file"
    exit 0
fi

exit 1
EOF
    chmod +x "$pmset_bin"

    export AWAKE_HELPER_PMSET_BIN="$pmset_bin"
    export AWAKE_HELPER_STATE_DIR="$state_dir"
    export AWAKE_HELPER_LOCK_DIR="$lock_dir"
    export AWAKE_HELPER_SLEEP_BIN="/bin/sleep"
    export AWAKE_TEST_PMSET_STATE="$tmpdir/pmset.state"

    printf '1\n' > "$AWAKE_TEST_PMSET_STATE"

    /bin/sleep 300 >/dev/null 2>&1 &
    rollback_pid="$!"
    mkdir -p "$state_dir"
    cat > "$state_file" <<EOF
version=1
token=token-reset
expires_epoch=4102444800
original_disablesleep=1
rollback_pid=$rollback_pid
started_epoch=1
EOF

    export AWAKE_TEST_PMSET_FAIL_ON="0"
    if bash "$HELPER_BIN" reset >/dev/null 2>&1; then
        fail "helper reset should fail when pmset reset fails"
    fi

    [ -f "$state_file" ] || fail "expected helper state to remain after reset failure"
    kill -0 "$rollback_pid" 2>/dev/null || fail "expected rollback process to survive reset failure"
    unset AWAKE_TEST_PMSET_FAIL_ON

    bash "$HELPER_BIN" reset >/dev/null 2>&1 || fail "helper reset should eventually succeed"
}

test_helper_start_and_restore
test_helper_reset_and_token_mismatch_rollback
test_helper_restore_failure_keeps_rollback_alive
test_helper_start_failure_preserves_existing_rollback
test_helper_start_failure_restores_fresh_session_state
test_helper_start_failure_restores_when_state_write_fails
test_helper_start_failure_restores_when_heredoc_write_fails
test_helper_reset_failure_keeps_rollback_alive
echo "ok - helper start and restore"
