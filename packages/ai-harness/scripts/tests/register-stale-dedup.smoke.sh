#!/usr/bin/env bash
# register-stale-dedup.smoke.sh — stale path dedup logic in register-workflow-hooks.sh
#
# T1: stale entry only (no current) → stale pruned + new added
# T2: stale + current both present → stale pruned, current stays
# T3: no stale → noop (idempotent)
# T4: different script basename → unaffected by dedup
# T5: exact same command already registered → matcher migration path unaffected

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS="$(cd "$HERE/../.." && pwd)"
REG="$HARNESS/scripts/register-workflow-hooks.sh"

PASS=0
FAIL=0

assert() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS+1))
        echo "  ✓ $label"
    else
        FAIL=$((FAIL+1))
        echo "  ✗ $label"
        echo "      expected: $expected"
        echo "      actual:   $actual"
    fi
}

# ---------------------------------------------------------------------------
# Helper: make a minimal settings.json in a temp dir with given PreToolUse hooks
# $1 = JSON array of hook group objects
make_settings() {
    local hooks_json="$1"
    local dir
    dir=$(mktemp -d)
    jq -n --argjson h "$hooks_json" '{"hooks": {"PreToolUse": $h}}' > "$dir/settings.json"
    echo "$dir"
}

# Helper: run register_workflow_hooks with a fake hooks dir whose only hook is
# a script named like $1 (e.g. "pre-worktree-gate.sh") pointing to $2 path.
# We source register-workflow-hooks.sh and invoke _register_one_hook directly
# after redefining it.
run_register() {
    local settings_file="$1" harness_dir="$2"
    # source the register script so register_workflow_hooks is available
    # but we need the hooks dir to exist
    bash -c "
        source \"$REG\"
        register_workflow_hooks \"$harness_dir\" \"$settings_file\"
    "
}

# ---------------------------------------------------------------------------
# Build a fake harness dir with the hooks we need for the tests
FAKE_OLD_HARNESS=$(mktemp -d)
FAKE_NEW_HARNESS=$(mktemp -d)
FAKE_OTHER_HARNESS=$(mktemp -d)

for h in "$FAKE_OLD_HARNESS" "$FAKE_NEW_HARNESS" "$FAKE_OTHER_HARNESS"; do
    mkdir -p "$h/scripts/hooks/lib"
    # Stub all hook scripts register-workflow-hooks.sh references
    for s in pre-worktree-gate.sh pre-exploration-gate.sh pre-task-general-purpose-gate.sh \
              workflow-state-machine.sh user-prompt-approval-detect.sh; do
        printf '#!/bin/bash\nexit 0\n' > "$h/scripts/hooks/$s"
        chmod +x "$h/scripts/hooks/$s"
    done
done

# For other harness: give it a DIFFERENT basename hook alongside same basename ones
# (used in T4)
printf '#!/bin/bash\nexit 0\n' > "$FAKE_OTHER_HARNESS/scripts/hooks/other-hook.sh"
chmod +x "$FAKE_OTHER_HARNESS/scripts/hooks/other-hook.sh"

cleanup() {
    rm -rf "$FAKE_OLD_HARNESS" "$FAKE_NEW_HARNESS" "$FAKE_OTHER_HARNESS"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# T1: stale only → pruned + new added
# Start with old-path pre-worktree-gate.sh registered; run register with new-path harness.
# Expect: old entry gone, new entry present.

OLD_CMD="$FAKE_OLD_HARNESS/scripts/hooks/pre-worktree-gate.sh"
NEW_CMD="$FAKE_NEW_HARNESS/scripts/hooks/pre-worktree-gate.sh"

STALE_ONLY=$(jq -n --arg cmd "$OLD_CMD" '[
    {"matcher": "Write|Edit|NotebookEdit|Bash", "hooks": [{"type":"command","command":$cmd}]}
]')
T1_DIR=$(make_settings "$STALE_ONLY")
T1_SETTINGS="$T1_DIR/settings.json"

export SAZO_DISABLE_SESSION_END_HOOK=1
export SAZO_DISABLE_TASK_OUTPUT_AUDIT=1
run_register "$T1_SETTINGS" "$FAKE_NEW_HARNESS" >/dev/null 2>&1

old_count=$(jq --arg cmd "$OLD_CMD" '
    [.hooks.PreToolUse // [] | .[] | .hooks // [] | .[] | select(.command == $cmd)] | length
' "$T1_SETTINGS")
new_count=$(jq --arg cmd "$NEW_CMD" '
    [.hooks.PreToolUse // [] | .[] | .hooks // [] | .[] | select(.command == $cmd)] | length
' "$T1_SETTINGS")

assert "T1: old (stale) entry removed" "0" "$old_count"
assert "T1: new entry added" "1" "$new_count"
rm -rf "$T1_DIR"

# ---------------------------------------------------------------------------
# T2: stale + current both present → stale pruned, current stays
# Pre-populate settings with BOTH old-path and new-path entries.
# run register with new-path harness. Expect old gone, new stays (count=1).

BOTH=$(jq -n --arg old "$OLD_CMD" --arg new "$NEW_CMD" '[
    {"matcher": "Write|Edit|NotebookEdit|Bash", "hooks": [{"type":"command","command":$old}]},
    {"matcher": "Write|Edit|NotebookEdit|Bash", "hooks": [{"type":"command","command":$new}]}
]')
T2_DIR=$(make_settings "$BOTH")
T2_SETTINGS="$T2_DIR/settings.json"

run_register "$T2_SETTINGS" "$FAKE_NEW_HARNESS" >/dev/null 2>&1

old_count=$(jq --arg cmd "$OLD_CMD" '
    [.hooks.PreToolUse // [] | .[] | .hooks // [] | .[] | select(.command == $cmd)] | length
' "$T2_SETTINGS")
new_count=$(jq --arg cmd "$NEW_CMD" '
    [.hooks.PreToolUse // [] | .[] | .hooks // [] | .[] | select(.command == $cmd)] | length
' "$T2_SETTINGS")

assert "T2: stale entry removed when both present" "0" "$old_count"
assert "T2: current entry preserved" "1" "$new_count"
rm -rf "$T2_DIR"

# ---------------------------------------------------------------------------
# T3: no stale → noop (idempotent)
# Pre-populate with only new-path entry, run register again. Count stays 1.

CURRENT_ONLY=$(jq -n --arg cmd "$NEW_CMD" '[
    {"matcher": "Write|Edit|NotebookEdit|Bash", "hooks": [{"type":"command","command":$cmd}]}
]')
T3_DIR=$(make_settings "$CURRENT_ONLY")
T3_SETTINGS="$T3_DIR/settings.json"

run_register "$T3_SETTINGS" "$FAKE_NEW_HARNESS" >/dev/null 2>&1

new_count=$(jq --arg cmd "$NEW_CMD" '
    [.hooks.PreToolUse // [] | .[] | .hooks // [] | .[] | select(.command == $cmd)] | length
' "$T3_SETTINGS")

assert "T3: no stale → count stays 1 (idempotent)" "1" "$new_count"
rm -rf "$T3_DIR"

# ---------------------------------------------------------------------------
# T4: different script basename → unaffected
# Pre-populate with an entry whose basename is "other-hook.sh" from old harness.
# Run register with new harness. "other-hook.sh" entry from old harness must survive
# (dedup must not touch scripts with different basename than the ones being registered).

OTHER_OLD_CMD="$FAKE_OLD_HARNESS/scripts/hooks/other-hook.sh"

# We use a completely separate harness that only registers other-hook.sh
# But register-workflow-hooks.sh doesn't register other-hook.sh — it's not in the list.
# So after running register with new harness, the OTHER_OLD_CMD entry should be intact.

OTHER_ONLY=$(jq -n --arg cmd "$OTHER_OLD_CMD" '[
    {"matcher": "SomeEvent", "hooks": [{"type":"command","command":$cmd}]}
]')
T4_SETTINGS_FILE=$(mktemp)
jq -n --argjson h "$OTHER_ONLY" '{"hooks": {"PreToolUse": $h}}' > "$T4_SETTINGS_FILE"

run_register "$T4_SETTINGS_FILE" "$FAKE_NEW_HARNESS" >/dev/null 2>&1

other_count=$(jq --arg cmd "$OTHER_OLD_CMD" '
    [.hooks.PreToolUse // [] | .[] | .hooks // [] | .[] | select(.command == $cmd)] | length
' "$T4_SETTINGS_FILE")

assert "T4: different basename entry unaffected by dedup" "1" "$other_count"
rm -f "$T4_SETTINGS_FILE"

# ---------------------------------------------------------------------------
# T5: matcher migration path unaffected — same command, different matcher → update matcher
# This is the existing migration logic; dedup must not interfere.
# Pre-populate with new-path command but WRONG matcher "OldMatcher".
# Run register. Expect matcher updated to correct one, entry count still 1.

WRONG_MATCHER=$(jq -n --arg cmd "$NEW_CMD" '[
    {"matcher": "OldMatcher", "hooks": [{"type":"command","command":$cmd}]}
]')
T5_DIR=$(make_settings "$WRONG_MATCHER")
T5_SETTINGS="$T5_DIR/settings.json"

run_register "$T5_SETTINGS" "$FAKE_NEW_HARNESS" >/dev/null 2>&1

# The worktree-gate hook should now have the correct matcher
correct_matcher=$(jq -r --arg cmd "$NEW_CMD" '
    .hooks.PreToolUse // []
    | map(select(.hooks // [] | any(.command == $cmd)))
    | .[0].matcher // ""
' "$T5_SETTINGS")

assert "T5: matcher migration succeeds (correct matcher set)" "Write|Edit|NotebookEdit|Bash" "$correct_matcher"

# Also confirm only 1 entry for this command (no duplicate from dedup+migration)
entry_count=$(jq --arg cmd "$NEW_CMD" '
    [.hooks.PreToolUse // [] | .[] | .hooks // [] | .[] | select(.command == $cmd)] | length
' "$T5_SETTINGS")
assert "T5: no duplicate entry after matcher migration" "1" "$entry_count"
rm -rf "$T5_DIR"

# ---------------------------------------------------------------------------
echo ""
echo "─────────────────────"
if [ "$FAIL" -eq 0 ]; then
    echo "PASS: $PASS  FAIL: $FAIL"
    exit 0
else
    echo "PASS: $PASS  FAIL: $FAIL"
    exit 1
fi
