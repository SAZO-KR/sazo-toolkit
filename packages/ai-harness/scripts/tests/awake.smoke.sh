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
    export AWAKE_TEST_HELPER_LOG="$tmpdir/helper.log"

    bash "$AWAKE_BIN" off >"$stdout_file" 2>"$stderr_file" || fail "awake off should succeed"

    assert_file_contains "$AWAKE_TEST_HELPER_LOG" '^restore token-off$'
    [ ! -f "$state_dir/awake.state" ] || fail "expected awake.state to be removed"
}

test_awake_on_uses_helper_and_writes_state
test_awake_off_restores_and_cleans_state
echo "ok - awake on uses helper and writes state"
