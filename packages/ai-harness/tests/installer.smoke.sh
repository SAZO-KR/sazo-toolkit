#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LIB_PATH="$ROOT_DIR/lib/installer-common.sh"

fail() {
    echo "not ok - $1" >&2
    exit 1
}

assert_file_contains() {
    local file="$1"
    local pattern="$2"
    grep -Eq "$pattern" "$file" || fail "expected '$pattern' in $file"
}

# --- lib/installer-common.sh tests ---

test_lib_sources_cleanly() {
    bash -n "$LIB_PATH" || fail "installer-common.sh has syntax errors"
    bash -c "source '$LIB_PATH' && type -t log_info | grep -q 'function'" || fail "log_info not a function"
    bash -c "source '$LIB_PATH' && type -t safe_symlink | grep -q 'function'" || fail "safe_symlink not a function"
    bash -c "source '$LIB_PATH' && type -t acquire_lock | grep -q 'function'" || fail "acquire_lock not a function"
    bash -c "source '$LIB_PATH' && type -t sparse_clone_tool | grep -q 'function'" || fail "sparse_clone_tool not a function"
    bash -c "source '$LIB_PATH' && type -t write_receipt | grep -q 'function'" || fail "write_receipt not a function"
    bash -c "source '$LIB_PATH' && type -t read_receipt | grep -q 'function'" || fail "read_receipt not a function"
    bash -c "source '$LIB_PATH' && type -t clear_receipt | grep -q 'function'" || fail "clear_receipt not a function"
    bash -c "source '$LIB_PATH' && type -t is_tool_installed | grep -q 'function'" || fail "is_tool_installed not a function"
    bash -c "source '$LIB_PATH' && type -t remove_receipt_entries | grep -q 'function'" || fail "remove_receipt_entries not a function"
    echo "ok - lib sources cleanly and all functions defined"
}

test_check_platform_darwin() {
    local result
    result=$(bash -c "source '$LIB_PATH' && check_platform any; echo \$?")
    [ "$result" = "0" ] || fail "check_platform any should return 0"

    echo "ok - check_platform any returns 0"
}

test_check_platform_unsupported() {
    local result
    result=$(bash -c "source '$LIB_PATH' && SAZO_UNAME=Linux check_platform darwin; echo \$?")
    [ "$result" = "3" ] || fail "check_platform darwin on wrong OS should return 3, got $result"

    echo "ok - check_platform darwin on wrong OS returns 3"
}

test_ask_yes_no_noninteractive() {
    local result
    result=$(SAZO_NON_INTERACTIVE=1 bash -c "source '$LIB_PATH' && ask_yes_no 'test?' y && echo YES || echo NO")
    [ "$result" = "YES" ] || fail "ask_yes_no with default y should return YES in non-interactive mode"

    result=$(SAZO_NON_INTERACTIVE=1 bash -c "source '$LIB_PATH' && ask_yes_no 'test?' n && echo YES || echo NO")
    [ "$result" = "NO" ] || fail "ask_yes_no with default n should return NO in non-interactive mode"

    echo "ok - ask_yes_no works in non-interactive mode"
}

test_receipt_round_trip() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    local receipt_dir="$tmpdir/receipts"

    result=$(SAZO_BASE_DIR="$tmpdir" bash -c "
        source '$LIB_PATH'
        write_receipt test-tool 'symlink:/home/user/.local/bin/tool' 'state:/home/user/.config/sazo-ai-harness/test.state'
        cat '$receipt_dir/test-tool.receipt'
    ")
    echo "$result" | grep -q "symlink:/home/user/.local/bin/tool" || fail "receipt should contain symlink entry"
    echo "$result" | grep -q "state:/home/user/.config/sazo-ai-harness/test.state" || fail "receipt should contain state entry"

    SAZO_BASE_DIR="$tmpdir" bash -c "
        source '$LIB_PATH'
        is_tool_installed test-tool && exit 0 || exit 1
    " || fail "tool should be installed after write_receipt"

    rm -rf "$tmpdir"
    echo "ok - receipt round-trip works"
}

test_receipt_clear() {
    local tmpdir
    tmpdir="$(mktemp -d)"

    SAZO_BASE_DIR="$tmpdir" bash -c "
        source '$LIB_PATH'
        write_receipt test-clear 'file:/tmp/test'
        is_tool_installed test-clear && exit 0 || exit 1
    " || fail "should be installed after write"

    SAZO_BASE_DIR="$tmpdir" bash -c "
        source '$LIB_PATH'
        clear_receipt test-clear
        ! is_tool_installed test-clear && exit 0 || exit 1
    " || fail "should not be installed after clear"

    rm -rf "$tmpdir"
    echo "ok - receipt clear works"
}

test_remove_harness_symlinks_can_filter_basenames() {
    local tmpdir
    tmpdir="$(mktemp -d)"

    ln -s "$HOME/.config/sazo-ai-harness/packages/ai-harness/tools/awake/commands/awake.md" "$tmpdir/awake.md"
    ln -s "$HOME/.config/sazo-ai-harness/packages/ai-harness/commands/weekly-report.md" "$tmpdir/weekly-report.md"

    bash -c "
        source '$LIB_PATH'
        remove_harness_symlinks '$tmpdir' test awake.md
    " || fail "filtered symlink cleanup should not fail"

    [ ! -e "$tmpdir/awake.md" ] || fail "awake.md should be removed"
    [ -L "$tmpdir/weekly-report.md" ] || fail "unrelated command symlink should be preserved"

    rm -rf "$tmpdir"
    echo "ok - remove_harness_symlinks can filter by basename"
}

test_root_uninstaller_fallback_removes_symlinks_without_lib() {
    local tmpdir stdout_file
    tmpdir="$(mktemp -d)"
    stdout_file="$tmpdir/out.log"

    mkdir -p "$tmpdir/.claude/commands"
    ln -s "$tmpdir/.config/sazo-ai-harness/packages/ai-harness/commands/test.md" "$tmpdir/.claude/commands/test.md"

    HOME="$tmpdir" bash "$ROOT_DIR/uninstall.sh" >"$stdout_file" 2>&1 || fail "root uninstall should tolerate missing installer-common.sh"

    [ ! -e "$tmpdir/.claude/commands/test.md" ] || fail "fallback cleanup should remove harness symlink"
    ! grep -q "command not found" "$stdout_file" || fail "fallback cleanup should avoid command not found"

    rm -rf "$tmpdir"
    echo "ok - root uninstaller fallback removes symlinks without shared lib"
}

# --- tool.sh manifest tests ---

test_tool_sh_manifest() {
    local tool_sh="$ROOT_DIR/tools/awake/tool.sh"
    [ -f "$tool_sh" ] || fail "tool.sh not found at $tool_sh"
    bash -n "$tool_sh" || fail "tool.sh has syntax errors"

    result=$(bash -c "source '$tool_sh' && echo \$TOOL_NAME")
    [ "$result" = "awake" ] || fail "TOOL_NAME should be 'awake', got '$result'"

    result=$(bash -c "source '$tool_sh' && echo \$TOOL_PLATFORM")
    [ "$result" = "darwin" ] || fail "TOOL_PLATFORM should be 'darwin', got '$result'"

    result=$(bash -c "source '$tool_sh' && echo \$TOOL_REQUIRES_SUDO")
    [ "$result" = "optional" ] || fail "TOOL_REQUIRES_SUDO should be 'optional', got '$result'"

    echo "ok - tool.sh manifest is valid"
}

# --- Installer contract tests ---

test_awake_installer_exists() {
    [ -f "$ROOT_DIR/tools/awake/install.sh" ] || fail "awake install.sh not found"
    [ -x "$ROOT_DIR/tools/awake/install.sh" ] || fail "awake install.sh not executable"
    bash -n "$ROOT_DIR/tools/awake/install.sh" || fail "awake install.sh has syntax errors"
    echo "ok - awake installer exists and is syntactically valid"
}

test_awake_uninstaller_exists() {
    [ -f "$ROOT_DIR/tools/awake/uninstall.sh" ] || fail "awake uninstall.sh not found"
    [ -x "$ROOT_DIR/tools/awake/uninstall.sh" ] || fail "awake uninstall.sh not executable"
    bash -n "$ROOT_DIR/tools/awake/uninstall.sh" || fail "awake uninstall.sh has syntax errors"
    echo "ok - awake uninstaller exists and is syntactically valid"
}

test_root_installer_exists() {
    [ -f "$ROOT_DIR/install.sh" ] || fail "root install.sh not found"
    [ -x "$ROOT_DIR/install.sh" ] || fail "root install.sh not executable"
    bash -n "$ROOT_DIR/install.sh" || fail "root install.sh has syntax errors"
    echo "ok - root installer exists and is syntactically valid"
}

test_root_uninstaller_exists() {
    [ -f "$ROOT_DIR/uninstall.sh" ] || fail "root uninstall.sh not found"
    [ -x "$ROOT_DIR/uninstall.sh" ] || fail "root uninstall.sh not executable"
    bash -n "$ROOT_DIR/uninstall.sh" || fail "root uninstall.sh has syntax errors"
    echo "ok - root uninstaller exists and is syntactically valid"
}

test_discover_tools_finds_awake() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    local tools_dir="$ROOT_DIR/tools"

    local found=0
    for tool_dir in "$tools_dir"/*/; do
        [ -d "$tool_dir" ] || continue
        [ -f "$tool_dir/tool.sh" ] || continue
        local name
        name="$(basename "$tool_dir")"
        if [ "$name" = "awake" ]; then
            found=1
            break
        fi
    done

    [ "$found" -eq 1 ] || fail "discover_tools should find 'awake'"
    echo "ok - discover_tools finds awake"
}

# --- Tool-provided artifact linking tests ---

test_awake_command_is_tool_provided() {
    [ -f "$ROOT_DIR/tools/awake/commands/awake.md" ] || fail "awake command should live under tools/awake/commands/"
    [ ! -e "$ROOT_DIR/commands/awake.md" ] || fail "awake command must not duplicate under shared commands/"
    echo "ok - awake command is tool-provided under tools/awake/commands/"
}

test_install_links_tool_commands() {
    assert_file_contains "$ROOT_DIR/install.sh" "Tool-provided commands/skills/agents"
    assert_file_contains "$ROOT_DIR/install.sh" "link_files .*tool_src/commands"
    echo "ok - install.sh links tool-provided commands"
}

test_uninstall_cleans_tool_symlinks() {
    # TOOL_SRC= marker is unique to the per-tool symlink cleanup added alongside
    # install.sh's tool-command linking (full uninstall already swept shared dirs).
    assert_file_contains "$ROOT_DIR/uninstall.sh" "TOOL_SRC="
    assert_file_contains "$ROOT_DIR/uninstall.sh" "remove_harness_symlinks .*\\.claude/commands"
    echo "ok - uninstall.sh cleans tool symlinks on per-tool removal"
}

# --- Run all tests ---

test_lib_sources_cleanly
test_check_platform_darwin
test_check_platform_unsupported
test_ask_yes_no_noninteractive
test_receipt_round_trip
test_receipt_clear
test_remove_harness_symlinks_can_filter_basenames
test_root_uninstaller_fallback_removes_symlinks_without_lib
test_tool_sh_manifest
test_awake_installer_exists
test_awake_uninstaller_exists
test_root_installer_exists
test_root_uninstaller_exists
test_discover_tools_finds_awake
test_awake_command_is_tool_provided
test_install_links_tool_commands
test_uninstall_cleans_tool_symlinks

echo ""
echo "All installer smoke tests passed!"
