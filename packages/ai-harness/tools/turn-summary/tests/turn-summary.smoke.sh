#!/bin/bash
#
# Smoke tests for the turn-summary Stop hook tool.
# Covers behavior (gate decisions, hook output, settings.json merge/remove),
# not just syntax. jq-dependent blocks skip cleanly when jq is absent.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
TOOL_DIR="$ROOT_DIR/tools/turn-summary"
GATE="$TOOL_DIR/scripts/gate.sh"
HOOK="$TOOL_DIR/scripts/stop-summary.sh"
SETTINGS_HOOK="$TOOL_DIR/scripts/settings-hook.sh"

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); printf '\033[32mok\033[0m - %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '\033[31mnot ok\033[0m - %s\n' "$1"; }

has_jq() { command -v jq >/dev/null 2>&1; }

# --- Transcript fixtures (JSONL, one JSON object per line) ---

U_REAL='{"type":"user","message":{"role":"user","content":"please do the thing"}}'
U_TOOLRESULT='{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]}}'
A_EDIT='{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Edit","input":{}}]}}'
A_WRITE='{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Write","input":{}}]}}'
A_AGENT='{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Agent","input":{}}]}}'
A_TASK='{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Task","input":{}}]}}'
A_BASH='{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{}}]}}'
A_TEXT='{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"done"}]}}'

# gate exit: 0 = work, 1 = no work. Returns the actual exit code without aborting.
gate_rc() { local f="$1"; if bash "$GATE" "$f"; then echo 0; else echo $?; fi; }

# --- 1. Manifest + syntax ---

test_manifest_and_syntax() {
    # shellcheck disable=SC1090
    ( source "$TOOL_DIR/tool.sh"; [ "$TOOL_NAME" = "turn-summary" ] ) \
        && ok "tool.sh TOOL_NAME is turn-summary" || fail "tool.sh TOOL_NAME wrong"

    local f
    for f in install.sh uninstall.sh scripts/gate.sh scripts/stop-summary.sh scripts/settings-hook.sh; do
        bash -n "$TOOL_DIR/$f" && ok "$f syntax valid" || fail "$f syntax error"
    done
}

# --- 2. Gate behavior ---

test_gate_behavior() {
    if ! has_jq; then
        printf 'skip - gate behavior (jq not installed)\n'
        return
    fi
    local d; d="$(mktemp -d)"

    printf '%s\n%s\n' "$U_REAL" "$A_EDIT" > "$d/A.jsonl"
    [ "$(gate_rc "$d/A.jsonl")" = "0" ] && ok "gate: Edit after user => work" || fail "gate A"

    printf '%s\n%s\n%s\n%s\n' "$U_REAL" "$A_BASH" "$U_TOOLRESULT" "$A_TEXT" > "$d/B.jsonl"
    [ "$(gate_rc "$d/B.jsonl")" = "1" ] && ok "gate: only Bash+text => no work" || fail "gate B"

    printf '%s\n%s\n' "$U_REAL" "$A_AGENT" > "$d/C.jsonl"
    [ "$(gate_rc "$d/C.jsonl")" = "0" ] && ok "gate: Agent (subagent) => work" || fail "gate C"

    printf '%s\n%s\n' "$U_REAL" "$A_TASK" > "$d/C2.jsonl"
    [ "$(gate_rc "$d/C2.jsonl")" = "0" ] && ok "gate: Task (legacy subagent) => work" || fail "gate C2"

    # Edit happened in a PRIOR turn; nothing after the latest user message.
    printf '%s\n%s\n%s\n%s\n' "$U_REAL" "$A_EDIT" "$U_REAL" "$A_TEXT" > "$d/D.jsonl"
    [ "$(gate_rc "$d/D.jsonl")" = "1" ] && ok "gate: edit only in prior turn => no work" || fail "gate D"

    : > "$d/E.jsonl"
    [ "$(gate_rc "$d/E.jsonl")" = "1" ] && ok "gate: empty transcript => no work" || fail "gate E"

    [ "$(gate_rc "$d/missing.jsonl")" = "1" ] && ok "gate: missing file => no work" || fail "gate missing"

    rm -rf "$d"
}

# --- 3. Stop hook output behavior ---

test_hook_output() {
    if ! has_jq; then
        printf 'skip - hook output (jq not installed)\n'
        return
    fi
    local d; d="$(mktemp -d)"
    printf '%s\n%s\n' "$U_REAL" "$A_EDIT" > "$d/work.jsonl"
    printf '%s\n%s\n%s\n%s\n' "$U_REAL" "$A_BASH" "$U_TOOLRESULT" "$A_TEXT" > "$d/nowork.jsonl"
    local out

    # Loop guard: stop_hook_active=true => no output even when work happened.
    out="$(printf '{"stop_hook_active":true,"transcript_path":"%s"}' "$d/work.jsonl" | bash "$HOOK")"
    [ -z "$out" ] && ok "hook: stop_hook_active=true => silent" || fail "hook loop guard"

    # Work => block decision JSON with a non-empty reason.
    out="$(printf '{"stop_hook_active":false,"transcript_path":"%s"}' "$d/work.jsonl" | bash "$HOOK")"
    if printf '%s' "$out" | jq -e '.decision == "block" and (.reason | length) > 0' >/dev/null 2>&1; then
        ok "hook: work => block decision with reason"
    else
        fail "hook block output"
    fi

    # No work => silent.
    out="$(printf '{"stop_hook_active":false,"transcript_path":"%s"}' "$d/nowork.jsonl" | bash "$HOOK")"
    [ -z "$out" ] && ok "hook: no work => silent" || fail "hook no-work output"

    # Missing transcript_path => silent (safe).
    out="$(printf '{"stop_hook_active":false}' | bash "$HOOK")"
    [ -z "$out" ] && ok "hook: no transcript => silent" || fail "hook missing transcript"

    rm -rf "$d"
}

# --- 4. settings.json merge / remove / idempotency ---

test_settings_merge() {
    if ! has_jq; then
        printf 'skip - settings.json merge (jq not installed)\n'
        return
    fi
    local d; d="$(mktemp -d)"
    local s="$d/settings.json"
    local cmd="/some/base/tools/turn-summary/scripts/stop-summary.sh"

    # Preserve an unrelated existing hook to prove we don't clobber it.
    cat > "$s" <<'EOF'
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/other/keep.sh"}]}]}}
EOF

    bash "$SETTINGS_HOOK" add "$s" "$cmd" || fail "settings add returned error"
    local n
    n="$(jq '[.hooks.Stop[].hooks[] | select(.command == "'"$cmd"'")] | length' "$s")"
    [ "$n" = "1" ] && ok "settings: hook added once" || fail "settings add count=$n"

    # Idempotent: adding again does not duplicate.
    bash "$SETTINGS_HOOK" add "$s" "$cmd" || fail "settings add (2nd) error"
    n="$(jq '[.hooks.Stop[].hooks[] | select(.command == "'"$cmd"'")] | length' "$s")"
    [ "$n" = "1" ] && ok "settings: add is idempotent" || fail "settings idempotent count=$n"

    # Unrelated hook still present.
    jq -e '[.hooks.Stop[].hooks[] | select(.command == "/other/keep.sh")] | length == 1' "$s" >/dev/null \
        && ok "settings: unrelated hook preserved" || fail "settings clobbered other hook"

    # Remove by suffix match; ours gone, other preserved, valid JSON.
    bash "$SETTINGS_HOOK" remove "$s" "turn-summary/scripts/stop-summary.sh" || fail "settings remove error"
    n="$(jq '[.hooks.Stop[]?.hooks[]? | select(.command == "'"$cmd"'")] | length' "$s")"
    [ "$n" = "0" ] && ok "settings: our hook removed" || fail "settings remove count=$n"
    jq -e '[.hooks.Stop[].hooks[] | select(.command == "/other/keep.sh")] | length == 1' "$s" >/dev/null \
        && ok "settings: other hook still there after remove" || fail "settings remove dropped other"

    # Add into a fresh (absent) settings file.
    local s2="$d/new/settings.json"
    bash "$SETTINGS_HOOK" add "$s2" "$cmd" || fail "settings add to absent file error"
    jq -e '.hooks.Stop[0].hooks[0].command == "'"$cmd"'"' "$s2" >/dev/null \
        && ok "settings: created from absent file" || fail "settings create absent"

    rm -rf "$d"
}

test_manifest_and_syntax
test_gate_behavior
test_hook_output
test_settings_merge

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
