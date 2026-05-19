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
    export AWAKE_HELPER_SLEEP_BIN="$tmpdir/fake-sleep.sh"
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

test_helper_start_and_restore
test_helper_reset_and_token_mismatch_rollback
echo "ok - helper start and restore"
