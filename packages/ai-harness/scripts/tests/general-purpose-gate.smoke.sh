#!/bin/bash
# general-purpose-gate.smoke.sh — Plan 14 (a)
# PreToolUse Task hook: subagent_type=general-purpose → soft warn + matrix.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS="$(cd "$HERE/../.." && pwd)"
HOOK="$HARNESS/scripts/hooks/pre-task-general-purpose-gate.sh"

export SAZO_STATE_DIR="/tmp/sazo-gpgate-$$"
cleanup() { rm -rf "$SAZO_STATE_DIR"; }
trap cleanup EXIT
mkdir -p "$SAZO_STATE_DIR"

PASS=0; FAIL=0
fail() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }
pass() { PASS=$((PASS+1)); echo "  ✓ $1"; }

run_hook() {
    local payload="$1"
    echo "$payload" | bash "$HOOK" 2>&1
    return $?
}

mk_payload() {
    local subagent="$1"
    jq -n --arg sa "$subagent" \
        '{session_id:"gpgate-test", cwd:"/tmp", tool_name:"Task", tool_input:{subagent_type:$sa}, model:"claude-opus-4-7"}'
}

echo "=== 0. Missing session_id → passthrough ==="
nosess=$(jq -n '{cwd:"/tmp", tool_name:"Task", tool_input:{subagent_type:"general-purpose"}, model:"claude-opus-4-7"}')
out=$(echo "$nosess" | bash "$HOOK" 2>&1)
rc=$?
if [ $rc -eq 0 ] && [ -z "$out" ]; then
    pass "missing session_id: no output, exit 0"
else
    fail "missing session_id: rc=$rc out=$out"
fi

echo "=== 1. general-purpose subagent → warn + exit 0 (non-blocking) ==="
out=$(run_hook "$(mk_payload general-purpose)")
rc=$?
if [ $rc -eq 0 ]; then
    pass "exit code 0 (warn-only)"
else
    fail "expected exit 0, got $rc"
fi
if echo "$out" | grep -q "general-purpose"; then
    pass "warning mentions general-purpose"
else
    fail "warning missing general-purpose mention (out=$out)"
fi
if echo "$out" | grep -qiE "code-searcher|docs-researcher|plan-drafter"; then
    pass "warning recommends specific subagent(s)"
else
    fail "warning missing specific subagent recommendation"
fi

echo "=== 2. specific subagent → no warn ==="
out=$(run_hook "$(mk_payload code-searcher)")
rc=$?
if [ $rc -eq 0 ]; then
    pass "code-searcher: exit 0"
else
    fail "code-searcher: exit $rc"
fi
if [ -z "$out" ] || ! echo "$out" | grep -qi "general-purpose"; then
    pass "code-searcher: no general-purpose warning"
else
    fail "code-searcher: spurious warning (out=$out)"
fi

echo "=== 3. non-Task tool → passthrough ==="
payload='{"session_id":"x","cwd":"/tmp","tool_name":"Bash","tool_input":{"command":"ls"},"model":"claude-opus-4-7"}'
out=$(echo "$payload" | bash "$HOOK" 2>&1)
rc=$?
if [ $rc -eq 0 ] && [ -z "$out" ]; then
    pass "Bash tool: no output, exit 0"
else
    fail "Bash tool: rc=$rc out=$out"
fi

echo "=== 4. narrow disabled → passthrough ==="
out=$(SAZO_DISABLE_NARROW_HOOKS=1 echo "$(mk_payload general-purpose)" | SAZO_DISABLE_NARROW_HOOKS=1 bash "$HOOK" 2>&1)
rc=$?
if [ $rc -eq 0 ] && ! echo "$out" | grep -qi "전용"; then
    pass "narrow disabled: no warn"
else
    fail "narrow disabled: still warned (out=$out)"
fi

echo "=== 5. per-hook skip → passthrough ==="
out=$(echo "$(mk_payload general-purpose)" | SAZO_SKIP_GENERAL_PURPOSE_GATE=1 bash "$HOOK" 2>&1)
rc=$?
if [ $rc -eq 0 ] && ! echo "$out" | grep -qi "전용"; then
    pass "SKIP env: no warn"
else
    fail "SKIP env: still warned (out=$out)"
fi

echo "=== 6. non-Opus model → passthrough (gate Opus-only) ==="
payload=$(jq -n '{session_id:"x", cwd:"/tmp", tool_name:"Task", tool_input:{subagent_type:"general-purpose"}, model:"claude-sonnet-4-6"}')
out=$(echo "$payload" | bash "$HOOK" 2>&1)
rc=$?
if [ $rc -eq 0 ] && ! echo "$out" | grep -qi "전용"; then
    pass "Sonnet model: no warn (general-purpose inherits sonnet, not Opus burden)"
else
    fail "Sonnet model: warned anyway (out=$out)"
fi

echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
