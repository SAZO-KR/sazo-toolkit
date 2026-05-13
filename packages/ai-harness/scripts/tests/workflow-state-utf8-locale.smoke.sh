#!/usr/bin/env bash
# workflow-state-utf8-locale.smoke.sh
#
# Verifies that soft_warn_or_block does NOT crash with "unbound variable" when
# LC_ALL=C (POSIX locale) — the bug was $count회 where bash parsed the first
# UTF-8 byte of 회 (0xED) as part of the variable name.
#
# T1: LC_ALL=C — 4 calls (warn_threshold=3) → hard_block path (exit 2), no unbound variable
# T2: LC_ALL=en_US.UTF-8 (or ko_KR.UTF-8 / C.UTF-8) — same → exit 2, no unbound variable

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="$SCRIPT_DIR/../hooks/lib/session-state.sh"
MACHINE="$SCRIPT_DIR/../hooks/workflow-state-machine.sh"

PASS=0
FAIL=0

assert_eq() {
    local expected="$1" actual="$2" label="$3"
    if [ "$actual" = "$expected" ]; then
        PASS=$((PASS+1))
        echo "  PASS $label"
    else
        FAIL=$((FAIL+1))
        echo "  FAIL $label (expected=$expected, got=$actual)"
    fi
}

assert_no_match() {
    local pattern="$1" text="$2" label="$3"
    if echo "$text" | grep -qE "$pattern"; then
        FAIL=$((FAIL+1))
        echo "  FAIL $label (found pattern: $pattern)"
        echo "       stderr: $text"
    else
        PASS=$((PASS+1))
        echo "  PASS $label"
    fi
}

echo "=== workflow-state-utf8-locale smoke ==="

# ---- helper: call soft_warn_or_block in a subshell under a given locale ----
#
# Sources session-state.sh (required by soft_warn_or_block for state_increment/state_get)
# then sources workflow-state-machine.sh functions directly by extracting just what we need.
# Simpler: source the lib + define a minimal audit_log stub + copy soft_warn_or_block deps.

call_soft_warn() {
    local locale="$1" sid="$2" stage="$3" threshold="$4"
    (
        export LC_ALL="$locale"
        export SAZO_STATE_DIR="$TMP_DIR/state-$sid"
        mkdir -p "$SAZO_STATE_DIR"
        export SAZO_SESSION_ID="$sid"
        export SAZO_TOOL_NAME="Edit"
        export SAZO_WORKFLOW_HOOKS_ENABLED=1
        export SAZO_SKIP_STATE_MACHINE=0
        export SAZO_CWD="/tmp"

        # shellcheck source=../hooks/lib/session-state.sh
        source "$LIB"
        state_init "$sid" "/tmp" "test-model"

        # Minimal stub for audit_log (not the focus of this test)
        audit_log() { :; }

        # Extract and eval soft_warn_or_block from the machine script.
        # We grep the function body between 'soft_warn_or_block()' and the closing '^}'.
        eval "$(awk '/^soft_warn_or_block\(\)/{found=1} found{print} found && /^\}$/{exit}' "$MACHINE")"

        # Call 4 times (threshold+1) so we exceed the warn limit and hit hard_block path
        local i rc=0
        for i in 1 2 3 4; do
            soft_warn_or_block "$stage" "test message for locale $locale" "$threshold" || rc=$?
        done
        exit $rc
    )
}

# ---- T1: LC_ALL=C ----
echo "--- T1: LC_ALL=C → exit 2, no unbound variable ---"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

SID1="utf8-t1-$$"
T1_STDERR=""
T1_EXIT=0
T1_STDERR=$(call_soft_warn "C" "$SID1" "research" "3" 2>&1 >/dev/null) || T1_EXIT=$?

assert_eq "2" "$T1_EXIT" "T1: LC_ALL=C exit=2 (hard_block path)"
assert_no_match "unbound variable|count.*unbound|bad substitution" "$T1_STDERR" \
    "T1: LC_ALL=C no unbound variable error"

# ---- T2: UTF-8 locale ----
echo "--- T2: UTF-8 locale → exit 2, no unbound variable ---"

# Try common UTF-8 locales; fall back to checking if en_US.UTF-8 is available
UTF8_LOCALE=""
for candidate in en_US.UTF-8 C.UTF-8 ko_KR.UTF-8; do
    if LC_ALL="$candidate" locale 2>/dev/null | grep -q "LC_ALL=$candidate"; then
        UTF8_LOCALE="$candidate"
        break
    fi
    # Some systems don't output LC_ALL= line; try a simpler check
    if LC_ALL="$candidate" bash -c 'echo ok' 2>/dev/null | grep -q ok; then
        UTF8_LOCALE="$candidate"
        break
    fi
done

if [ -z "$UTF8_LOCALE" ]; then
    echo "  SKIP T2: no UTF-8 locale available on this system"
    PASS=$((PASS+1))  # count as pass (environment limitation, not a code bug)
else
    SID2="utf8-t2-$$"
    T2_STDERR=""
    T2_EXIT=0
    T2_STDERR=$(call_soft_warn "$UTF8_LOCALE" "$SID2" "research" "3" 2>&1 >/dev/null) || T2_EXIT=$?

    assert_eq "2" "$T2_EXIT" "T2: $UTF8_LOCALE exit=2 (hard_block path)"
    assert_no_match "unbound variable|count.*unbound|bad substitution" "$T2_STDERR" \
        "T2: $UTF8_LOCALE no unbound variable error"
fi

# ---- T3: LC_ALL=C stderr contains count value (not garbage) ----
echo "--- T3: LC_ALL=C stderr output sanity — count value visible ---"

SID3="utf8-t3-$$"
T3_STDERR=""
T3_EXIT=0
T3_STDERR=$(call_soft_warn "C" "$SID3" "plan" "3" 2>&1 >/dev/null) || T3_EXIT=$?

# The hard_block message should contain "4회" (count=4 after 4 calls) — not garbled
if echo "$T3_STDERR" | grep -qF "4회"; then
    PASS=$((PASS+1))
    echo "  PASS T3: stderr contains '4회' (count correctly rendered)"
else
    FAIL=$((FAIL+1))
    echo "  FAIL T3: '4회' not found in stderr"
    echo "       stderr: $T3_STDERR"
fi

# ---- summary ----
echo ""
echo "=== workflow-state-utf8-locale.smoke: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
