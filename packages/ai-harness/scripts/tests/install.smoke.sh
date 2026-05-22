#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
INSTALL_SH="$ROOT_DIR/install.sh"

fail() {
    echo "not ok - $1" >&2
    exit 1
}

assert_file_contains() {
    local file="$1"
    local pattern="$2"
    grep -Eq "$pattern" "$file" || fail "expected '$pattern' in $file"
}

extract_symlink_guard_snippet() {
    awk '
        /BEGIN AWAKE_INSTALL_GUARD/ { in_block=1; next }
        /END AWAKE_INSTALL_GUARD/   { in_block=0 }
        in_block { print }
    ' "$INSTALL_SH"
}

run_guard() {
    local tmpdir="$1"
    local awake_symlink="$2"
    local awake_script="$3"
    local snippet="$4"
    local stdout_file="$5"

    bash -c '
        set -euo pipefail
        AWAKE_SYMLINK="'"$awake_symlink"'"
        AWAKE_SCRIPT="'"$awake_script"'"
        '"$snippet"'
        printf "install_awake=%s\n" "$install_awake"
    ' >"$stdout_file" 2>&1 || fail "guard snippet should not error"
}

test_awake_install_guard_skips_unmanaged_file() {
    local tmpdir bin_dir snippet awake_symlink awake_script stdout_file
    tmpdir="$(mktemp -d)"
    bin_dir="$tmpdir/bin"
    mkdir -p "$bin_dir"
    awake_symlink="$bin_dir/awake"
    awake_script="$tmpdir/awake.sh"
    stdout_file="$tmpdir/stdout"

    printf '#!/bin/bash\necho hi\n' > "$awake_symlink"
    chmod +x "$awake_symlink"
    printf '#!/bin/bash\necho ours\n' > "$awake_script"

    snippet="$(extract_symlink_guard_snippet)"
    [ -n "$snippet" ] || fail "expected to extract awake symlink guard snippet"

    run_guard "$tmpdir" "$awake_symlink" "$awake_script" "$snippet" "$stdout_file"

    assert_file_contains "$stdout_file" '^install_awake=0$'
    assert_file_contains "$stdout_file" 'local file exists'
    [ ! -L "$awake_symlink" ] || fail "expected awake_symlink to remain a regular file (not converted to symlink)"
    grep -q 'echo hi' "$awake_symlink" || fail "expected unmanaged awake binary to be preserved untouched"
}

test_awake_install_guard_skips_unmanaged_symlink() {
    local tmpdir bin_dir snippet awake_symlink awake_script other_target stdout_file
    tmpdir="$(mktemp -d)"
    bin_dir="$tmpdir/bin"
    mkdir -p "$bin_dir"
    awake_symlink="$bin_dir/awake"
    awake_script="$tmpdir/awake.sh"
    other_target="$tmpdir/other-tool/awake.sh"
    stdout_file="$tmpdir/stdout"

    mkdir -p "$(dirname "$other_target")"
    printf '#!/bin/bash\necho other\n' > "$other_target"
    printf '#!/bin/bash\necho ours\n' > "$awake_script"
    ln -s "$other_target" "$awake_symlink"

    snippet="$(extract_symlink_guard_snippet)"
    [ -n "$snippet" ] || fail "expected to extract awake symlink guard snippet"

    run_guard "$tmpdir" "$awake_symlink" "$awake_script" "$snippet" "$stdout_file"

    assert_file_contains "$stdout_file" '^install_awake=0$'
    assert_file_contains "$stdout_file" 'not managed by ai-harness'
    [ -L "$awake_symlink" ] || fail "expected unmanaged symlink to be preserved"
    [ "$(readlink "$awake_symlink")" = "$other_target" ] || fail "expected symlink target to remain pointing at the unrelated tool"
}

test_awake_install_guard_replaces_managed_symlink() {
    local tmpdir bin_dir snippet awake_symlink awake_script harness_target stdout_file
    tmpdir="$(mktemp -d)"
    bin_dir="$tmpdir/bin"
    mkdir -p "$bin_dir"
    awake_symlink="$bin_dir/awake"
    awake_script="$tmpdir/awake.sh"
    harness_target="$tmpdir/sazo-ai-harness/packages/ai-harness/scripts/awake/awake.sh"
    stdout_file="$tmpdir/stdout"

    mkdir -p "$(dirname "$harness_target")"
    printf '#!/bin/bash\necho prev\n' > "$harness_target"
    printf '#!/bin/bash\necho ours\n' > "$awake_script"
    ln -s "$harness_target" "$awake_symlink"

    snippet="$(extract_symlink_guard_snippet)"
    [ -n "$snippet" ] || fail "expected to extract awake symlink guard snippet"

    run_guard "$tmpdir" "$awake_symlink" "$awake_script" "$snippet" "$stdout_file"

    assert_file_contains "$stdout_file" '^install_awake=1$'
}

test_awake_install_guard_allows_when_target_missing() {
    local tmpdir bin_dir snippet awake_symlink awake_script stdout_file
    tmpdir="$(mktemp -d)"
    bin_dir="$tmpdir/bin"
    mkdir -p "$bin_dir"
    awake_symlink="$bin_dir/awake"
    awake_script="$tmpdir/awake.sh"
    stdout_file="$tmpdir/stdout"

    printf '#!/bin/bash\necho ours\n' > "$awake_script"

    snippet="$(extract_symlink_guard_snippet)"
    [ -n "$snippet" ] || fail "expected to extract awake symlink guard snippet"

    run_guard "$tmpdir" "$awake_symlink" "$awake_script" "$snippet" "$stdout_file"

    assert_file_contains "$stdout_file" '^install_awake=1$'
}

test_awake_install_guard_skips_unmanaged_file
test_awake_install_guard_skips_unmanaged_symlink
test_awake_install_guard_replaces_managed_symlink
test_awake_install_guard_allows_when_target_missing
echo "ok - awake install symlink guard"
