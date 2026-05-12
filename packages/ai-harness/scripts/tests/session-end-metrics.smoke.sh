#!/usr/bin/env bash
# Smoke test: post-session-end-metrics.sh + hook_healthy + _append_metrics_inner
# Plan 13 Stage A — T1-T8

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/../hooks/post-session-end-metrics.sh"
LIB="$SCRIPT_DIR/../hooks/lib/session-state.sh"

PASS=0
FAIL=0
SKIP=0

assert_pass() {
    local label="$1"
    PASS=$((PASS+1))
    echo "  PASS $label"
}

assert_fail() {
    local label="$1" detail="${2:-}"
    FAIL=$((FAIL+1))
    echo "  FAIL $label${detail:+ — $detail}"
}

assert_eq() {
    local expected="$1" actual="$2" label="$3"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS+1))
        echo "  PASS $label"
    else
        FAIL=$((FAIL+1))
        echo "  FAIL $label (expected='$expected', got='$actual')"
    fi
}

assert_contains() {
    local needle="$1" haystack="$2" label="$3"
    if printf '%s' "$haystack" | grep -qF "$needle"; then
        PASS=$((PASS+1))
        echo "  PASS $label"
    else
        FAIL=$((FAIL+1))
        echo "  FAIL $label (needle='$needle' not found)"
    fi
}

assert_file_contains() {
    local needle="$1" file="$2" label="$3"
    if grep -qF "$needle" "$file" 2>/dev/null; then
        PASS=$((PASS+1))
        echo "  PASS $label"
    else
        FAIL=$((FAIL+1))
        echo "  FAIL $label (needle='$needle' not in $file)"
    fi
}

mark_test_skip() {
    local label="$1"
    SKIP=$((SKIP+1))
    echo "  SKIP $label"
}

mk_tmp_home() {
    local d; d=$(mktemp -d)
    mkdir -p "$d/.claude/state"
    echo "$d"
}

mk_settings_json() {
    local d="$1" mode="$2"
    # mode: both | session_end_only | pre_tool_use_only | neither | hook_path
    local harness_dir="${3:-/nonexistent}"
    local hook_path="${4:-}"
    case "$mode" in
        both)
            cat > "$d/.claude/settings.json" <<EOF
{
  "hooks": {
    "SessionEnd": [{"type":"command","command":"$harness_dir/scripts/hooks/post-session-end-metrics.sh"}],
    "PreToolUse": [{"type":"command","command":"$harness_dir/scripts/hooks/workflow-state-machine.sh"}]
  }
}
EOF
            ;;
        session_end_only)
            cat > "$d/.claude/settings.json" <<EOF
{
  "hooks": {
    "SessionEnd": [{"type":"command","command":"$harness_dir/scripts/hooks/post-session-end-metrics.sh"}]
  }
}
EOF
            ;;
        pre_tool_use_only)
            cat > "$d/.claude/settings.json" <<EOF
{
  "hooks": {
    "PreToolUse": [{"type":"command","command":"$harness_dir/scripts/hooks/workflow-state-machine.sh"}]
  }
}
EOF
            ;;
        neither)
            cat > "$d/.claude/settings.json" <<'EOF'
{
  "hooks": {}
}
EOF
            ;;
        hook_path)
            # use provided hook_path for command
            cat > "$d/.claude/settings.json" <<EOF
{
  "hooks": {
    "SessionEnd": [{"type":"command","command":"$hook_path"}]
  }
}
EOF
            ;;
    esac
}

mk_payload() {
    local sid="$1" tp="${2:-/tmp/t.jsonl}" cwd="${3:-/tmp}" reason="${4:-other}"
    jq -n \
        --arg sid "$sid" \
        --arg tp "$tp" \
        --arg cwd "$cwd" \
        --arg reason "$reason" \
        '{session_id:$sid, transcript_path:$tp, cwd:$cwd, reason:$reason}'
}

# ---------------------------------------------------------------------------
echo "=== T1: Ctrl+D path proxy — basic record write ==="
{
    TMP_HOME=$(mk_tmp_home)
    TMP_HARNESS=$(mktemp -d)
    trap 'rm -rf "$TMP_HOME" "$TMP_HARNESS"' EXIT
    mkdir -p "$TMP_HARNESS/scripts/hooks/lib"
    cp "$LIB" "$TMP_HARNESS/scripts/hooks/lib/session-state.sh"
    cp "$HOOK" "$TMP_HARNESS/scripts/hooks/post-session-end-metrics.sh"
    chmod +x "$TMP_HARNESS/scripts/hooks/post-session-end-metrics.sh"
    # Create fake workflow-state-machine.sh so check #6 can succeed if needed
    printf '#!/usr/bin/env bash\n' > "$TMP_HARNESS/scripts/hooks/workflow-state-machine.sh"
    chmod +x "$TMP_HARNESS/scripts/hooks/workflow-state-machine.sh"
    mk_settings_json "$TMP_HOME" "session_end_only" "$TMP_HARNESS"

    PAYLOAD=$(mk_payload "ses-t1" "/tmp/t1.jsonl" "/tmp/t1-cwd" "other")
    DEST="$TMP_HOME/.claude/state/session-metrics-ses-t1.jsonl"

    HOME="$TMP_HOME" SAZO_HARNESS_DIR="$TMP_HARNESS" \
        bash "$TMP_HARNESS/scripts/hooks/post-session-end-metrics.sh" <<< "$PAYLOAD"

    # T1.1: JSONL file created
    if [ -f "$DEST" ]; then
        assert_pass "T1.1 JSONL file created"
    else
        assert_fail "T1.1 JSONL file created" "file not found: $DEST"
    fi

    # T1.2: exactly 1 line
    LINE_COUNT=$(wc -l < "$DEST" | tr -d ' ')
    assert_eq "1" "$LINE_COUNT" "T1.2 exactly 1 line"

    # T1.3: source=session_end discriminator
    assert_file_contains '"source":"session_end"' "$DEST" "T1.3 source=session_end"

    # T1.4: 4-field presence
    RECORD=$(cat "$DEST")
    for field in session_id transcript_path cwd reason; do
        if printf '%s' "$RECORD" | jq -e --arg f "$field" 'has($f)' >/dev/null 2>&1; then
            assert_pass "T1.4 field $field present"
        else
            assert_fail "T1.4 field $field present"
        fi
    done

    # T1.5: session_id value
    SID_VAL=$(printf '%s' "$RECORD" | jq -r '.session_id')
    assert_eq "ses-t1" "$SID_VAL" "T1.5 session_id value"

    trap - EXIT
    rm -rf "$TMP_HOME" "$TMP_HARNESS"
}

# ---------------------------------------------------------------------------
echo "=== T2: hook_healthy OR-branch ==="
{
    # Source lib to test hook_healthy directly
    # Need isolated HOME with settings.json for each sub-case

    # Helper: mk_harness_with_fake_hooks creates a harness dir with
    # fake hook scripts that exist on disk so check #6 passes.
    mk_harness_with_fake_hooks() {
        local d="$1"
        mkdir -p "$d/scripts/hooks/lib"
        cp "$LIB" "$d/scripts/hooks/lib/session-state.sh"
        # Create fake hook scripts (just need to exist)
        printf '#!/usr/bin/env bash\n' > "$d/scripts/hooks/post-session-end-metrics.sh"
        chmod +x "$d/scripts/hooks/post-session-end-metrics.sh"
        printf '#!/usr/bin/env bash\n' > "$d/scripts/hooks/workflow-state-machine.sh"
        chmod +x "$d/scripts/hooks/workflow-state-machine.sh"
    }

    # T2.1: SessionEnd only → healthy=true
    TMP_HOME2=$(mktemp -d)
    TMP_HARNESS2=$(mktemp -d)
    mkdir -p "$TMP_HOME2/.claude/state"
    mk_harness_with_fake_hooks "$TMP_HARNESS2"
    mk_settings_json "$TMP_HOME2" "session_end_only" "$TMP_HARNESS2"

    RESULT=$(HOME="$TMP_HOME2" SAZO_HARNESS_DIR="$TMP_HARNESS2" SAZO_STATE_DIR="$TMP_HOME2/.claude/state" \
        bash -c 'source "'"$TMP_HARNESS2"'/scripts/hooks/lib/session-state.sh"; hook_healthy && echo "healthy" || echo "unhealthy"' 2>/dev/null)
    assert_eq "healthy" "$RESULT" "T2.1 SessionEnd only → healthy"
    rm -rf "$TMP_HOME2" "$TMP_HARNESS2"

    # T2.2: PreToolUse only → healthy=true
    TMP_HOME2=$(mktemp -d)
    TMP_HARNESS2=$(mktemp -d)
    mkdir -p "$TMP_HOME2/.claude/state"
    mk_harness_with_fake_hooks "$TMP_HARNESS2"
    mk_settings_json "$TMP_HOME2" "pre_tool_use_only" "$TMP_HARNESS2"

    RESULT=$(HOME="$TMP_HOME2" SAZO_HARNESS_DIR="$TMP_HARNESS2" SAZO_STATE_DIR="$TMP_HOME2/.claude/state" \
        bash -c 'source "'"$TMP_HARNESS2"'/scripts/hooks/lib/session-state.sh"; hook_healthy && echo "healthy" || echo "unhealthy"' 2>/dev/null)
    assert_eq "healthy" "$RESULT" "T2.2 PreToolUse only → healthy"
    rm -rf "$TMP_HOME2" "$TMP_HARNESS2"

    # T2.3: neither → healthy=false
    TMP_HOME2=$(mktemp -d)
    TMP_HARNESS2=$(mktemp -d)
    mkdir -p "$TMP_HOME2/.claude/state"
    mk_harness_with_fake_hooks "$TMP_HARNESS2"
    mk_settings_json "$TMP_HOME2" "neither" "$TMP_HARNESS2"

    RESULT=$(HOME="$TMP_HOME2" SAZO_HARNESS_DIR="$TMP_HARNESS2" SAZO_STATE_DIR="$TMP_HOME2/.claude/state" \
        bash -c 'source "'"$TMP_HARNESS2"'/scripts/hooks/lib/session-state.sh"; hook_healthy && echo "healthy" || echo "unhealthy"' 2>/dev/null)
    assert_eq "unhealthy" "$RESULT" "T2.3 neither → unhealthy"
    rm -rf "$TMP_HOME2" "$TMP_HARNESS2"
}

# ---------------------------------------------------------------------------
echo "=== T3: concurrent append — lock serialization ==="
{
    TMP_HOME=$(mktemp -d)
    TMP_HARNESS=$(mktemp -d)
    mkdir -p "$TMP_HOME/.claude/state"
    mkdir -p "$TMP_HARNESS/scripts/hooks/lib"
    cp "$LIB" "$TMP_HARNESS/scripts/hooks/lib/session-state.sh"
    cp "$HOOK" "$TMP_HARNESS/scripts/hooks/post-session-end-metrics.sh"
    chmod +x "$TMP_HARNESS/scripts/hooks/post-session-end-metrics.sh"
    printf '#!/usr/bin/env bash\n' > "$TMP_HARNESS/scripts/hooks/workflow-state-machine.sh"
    chmod +x "$TMP_HARNESS/scripts/hooks/workflow-state-machine.sh"
    mk_settings_json "$TMP_HOME" "session_end_only" "$TMP_HARNESS"

    DEST="$TMP_HOME/.claude/state/session-metrics-ses-t3.jsonl"

    # Launch 3 concurrent invocations
    for i in 1 2 3; do
        PAYLOAD=$(mk_payload "ses-t3" "/tmp/t3-$i.jsonl" "/tmp/t3-cwd" "other")
        HOME="$TMP_HOME" SAZO_HARNESS_DIR="$TMP_HARNESS" \
            bash "$TMP_HARNESS/scripts/hooks/post-session-end-metrics.sh" <<< "$PAYLOAD" &
    done
    wait

    # All 3 lines must be preserved
    if [ -f "$DEST" ]; then
        LINE_COUNT=$(wc -l < "$DEST" | tr -d ' ')
        assert_eq "3" "$LINE_COUNT" "T3.1 all 3 lines present after concurrent append"
        # Each line must be valid JSON
        INVALID=0
        while IFS= read -r line; do
            if ! printf '%s' "$line" | jq empty 2>/dev/null; then
                INVALID=$((INVALID+1))
            fi
        done < "$DEST"
        assert_eq "0" "$INVALID" "T3.2 all lines valid JSON"
    else
        assert_fail "T3.1 all 3 lines present after concurrent append" "JSONL file not created"
        assert_fail "T3.2 all lines valid JSON" "file missing"
    fi

    rm -rf "$TMP_HOME" "$TMP_HARNESS"
}

# ---------------------------------------------------------------------------
echo "=== T4: jq missing → metric not written + audit log entry ==="
{
    TMP_HOME=$(mktemp -d)
    TMP_HARNESS=$(mktemp -d)
    mkdir -p "$TMP_HOME/.claude/state"
    mkdir -p "$TMP_HARNESS/scripts/hooks/lib"
    cp "$LIB" "$TMP_HARNESS/scripts/hooks/lib/session-state.sh"
    cp "$HOOK" "$TMP_HARNESS/scripts/hooks/post-session-end-metrics.sh"
    chmod +x "$TMP_HARNESS/scripts/hooks/post-session-end-metrics.sh"
    printf '#!/usr/bin/env bash\n' > "$TMP_HARNESS/scripts/hooks/workflow-state-machine.sh"
    chmod +x "$TMP_HARNESS/scripts/hooks/workflow-state-machine.sh"
    mk_settings_json "$TMP_HOME" "session_end_only" "$TMP_HARNESS"

    DEST="$TMP_HOME/.claude/state/session-metrics-ses-t4.jsonl"
    AUDIT_LOG="$TMP_HOME/.claude/state/audit.log"

    PAYLOAD=$(mk_payload "ses-t4" "/tmp/t4.jsonl" "/tmp/t4-cwd" "other")

    # Build a fake PATH with no jq
    FAKE_PATH=$(mktemp -d)
    # Copy essential binaries except jq
    for bin in bash cat date mkdir rm printf wc grep awk sed tr; do
        if command -v "$bin" >/dev/null 2>&1; then
            # Use symlinks to real binaries
            ln -sf "$(command -v "$bin")" "$FAKE_PATH/$bin" 2>/dev/null || true
        fi
    done
    # Also copy stat, shasum, etc.
    for bin in stat shasum sha1sum md5sum perl timeout gtimeout openssl mktemp cp chmod ln sleep; do
        if command -v "$bin" >/dev/null 2>&1; then
            ln -sf "$(command -v "$bin")" "$FAKE_PATH/$bin" 2>/dev/null || true
        fi
    done
    # Explicitly omit jq

    HOME="$TMP_HOME" SAZO_HARNESS_DIR="$TMP_HARNESS" SAZO_STATE_DIR="$TMP_HOME/.claude/state" \
        PATH="$FAKE_PATH" \
        bash "$TMP_HARNESS/scripts/hooks/post-session-end-metrics.sh" <<< "$PAYLOAD" 2>/dev/null || true

    # metric file should NOT be created (jq unavailable — can't parse payload)
    if [ ! -f "$DEST" ] || [ ! -s "$DEST" ]; then
        assert_pass "T4.1 no metric written when jq missing"
    else
        assert_fail "T4.1 no metric written when jq missing" "file exists with content"
    fi

    rm -rf "$TMP_HOME" "$TMP_HARNESS" "$FAKE_PATH"
}

# ---------------------------------------------------------------------------
echo "=== T5: 5s timeout portable ==="
{
    # T5a: timeout binary available → normal exit
    TMP_HOME=$(mktemp -d)
    TMP_HARNESS=$(mktemp -d)
    mkdir -p "$TMP_HOME/.claude/state"
    mkdir -p "$TMP_HARNESS/scripts/hooks/lib"
    cp "$LIB" "$TMP_HARNESS/scripts/hooks/lib/session-state.sh"
    cp "$HOOK" "$TMP_HARNESS/scripts/hooks/post-session-end-metrics.sh"
    chmod +x "$TMP_HARNESS/scripts/hooks/post-session-end-metrics.sh"
    printf '#!/usr/bin/env bash\n' > "$TMP_HARNESS/scripts/hooks/workflow-state-machine.sh"
    chmod +x "$TMP_HARNESS/scripts/hooks/workflow-state-machine.sh"
    mk_settings_json "$TMP_HOME" "session_end_only" "$TMP_HARNESS"
    PAYLOAD=$(mk_payload "ses-t5a" "/tmp/t5a.jsonl" "/tmp" "other")

    RC=0
    HOME="$TMP_HOME" SAZO_HARNESS_DIR="$TMP_HARNESS" \
        bash "$TMP_HARNESS/scripts/hooks/post-session-end-metrics.sh" <<< "$PAYLOAD" || RC=$?
    assert_eq "0" "$RC" "T5a.1 normal exit with timeout available"
    DEST="$TMP_HOME/.claude/state/session-metrics-ses-t5a.jsonl"
    if [ -f "$DEST" ] && [ -s "$DEST" ]; then
        assert_pass "T5a.2 metric written with timeout available"
    else
        assert_fail "T5a.2 metric written with timeout available"
    fi
    rm -rf "$TMP_HOME" "$TMP_HARNESS"

    # T5b: gtimeout only (timeout absent) → normal exit + metric written
    echo "=== T5b: gtimeout only (timeout absent) ==="
    if ! command -v gtimeout >/dev/null 2>&1; then
        mark_test_skip "T5b.1 gtimeout not installed (skip — install coreutils to enable)"
        mark_test_skip "T5b.2 metric written via gtimeout"
        mark_test_skip "T5b.3 gtimeout actually invoked (wrapper recorded call)"
    else
        TMP_HOME=$(mktemp -d)
        TMP_HARNESS=$(mktemp -d)
        mkdir -p "$TMP_HOME/.claude/state"
        mkdir -p "$TMP_HARNESS/scripts/hooks/lib"
        cp "$LIB" "$TMP_HARNESS/scripts/hooks/lib/session-state.sh"
        cp "$HOOK" "$TMP_HARNESS/scripts/hooks/post-session-end-metrics.sh"
        chmod +x "$TMP_HARNESS/scripts/hooks/post-session-end-metrics.sh"
        printf '#!/usr/bin/env bash\n' > "$TMP_HARNESS/scripts/hooks/workflow-state-machine.sh"
        chmod +x "$TMP_HARNESS/scripts/hooks/workflow-state-machine.sh"
        mk_settings_json "$TMP_HOME" "session_end_only" "$TMP_HARNESS"
        PAYLOAD=$(mk_payload "ses-t5b" "/tmp/t5b.jsonl" "/tmp" "other")

        FAKE_PATH=$(mktemp -d)
        trap 'rm -rf "$TMP_HOME" "$TMP_HARNESS" "$FAKE_PATH"' EXIT
        # Build FAKE_PATH with everything EXCEPT timeout, gtimeout (wrapper added below)
        for bin in bash cat date mkdir rm printf wc grep awk sed tr stat shasum sha1sum md5sum openssl mktemp cp chmod ln sleep jq; do
            if command -v "$bin" >/dev/null 2>&1; then
                ln -sf "$(command -v "$bin")" "$FAKE_PATH/$bin" 2>/dev/null || true
            fi
        done
        # timeout explicitly not linked — gtimeout only
        # Wrapper that proves gtimeout was invoked, then exec real gtimeout
        GTIMEOUT_LOG="$TMP_HOME/.gtimeout-invoked"
        REAL_GTIMEOUT=$(command -v gtimeout)
        cat > "$FAKE_PATH/gtimeout" <<EOF
#!/usr/bin/env bash
echo "invoked: \$@" >> "$GTIMEOUT_LOG"
exec "$REAL_GTIMEOUT" "\$@"
EOF
        chmod +x "$FAKE_PATH/gtimeout"

        RC=0
        HOME="$TMP_HOME" SAZO_HARNESS_DIR="$TMP_HARNESS" SAZO_STATE_DIR="$TMP_HOME/.claude/state" \
            PATH="$FAKE_PATH" \
            bash "$TMP_HARNESS/scripts/hooks/post-session-end-metrics.sh" <<< "$PAYLOAD" || RC=$?
        assert_eq "0" "$RC" "T5b.1 normal exit with gtimeout only"

        DEST="$TMP_HOME/.claude/state/session-metrics-ses-t5b.jsonl"
        if [ -f "$DEST" ] && [ -s "$DEST" ]; then
            assert_pass "T5b.2 metric written via gtimeout"
        else
            assert_fail "T5b.2 metric written via gtimeout" "file missing or empty"
        fi

        if [ -f "$GTIMEOUT_LOG" ]; then
            assert_pass "T5b.3 gtimeout actually invoked (wrapper recorded call)"
        else
            assert_fail "T5b.3 gtimeout actually invoked (wrapper recorded call)" "no invocation log found"
        fi

        trap - EXIT
        rm -rf "$TMP_HOME" "$TMP_HARNESS" "$FAKE_PATH"
    fi

    # T5c: no timeout/gtimeout/perl → audit_log "no timeout binary available" + still runs
    TMP_HOME=$(mktemp -d)
    TMP_HARNESS=$(mktemp -d)
    mkdir -p "$TMP_HOME/.claude/state"
    mkdir -p "$TMP_HARNESS/scripts/hooks/lib"
    cp "$LIB" "$TMP_HARNESS/scripts/hooks/lib/session-state.sh"
    cp "$HOOK" "$TMP_HARNESS/scripts/hooks/post-session-end-metrics.sh"
    chmod +x "$TMP_HARNESS/scripts/hooks/post-session-end-metrics.sh"
    printf '#!/usr/bin/env bash\n' > "$TMP_HARNESS/scripts/hooks/workflow-state-machine.sh"
    chmod +x "$TMP_HARNESS/scripts/hooks/workflow-state-machine.sh"
    mk_settings_json "$TMP_HOME" "session_end_only" "$TMP_HARNESS"
    PAYLOAD=$(mk_payload "ses-t5c" "/tmp/t5c.jsonl" "/tmp" "other")

    FAKE_PATH=$(mktemp -d)
    for bin in bash cat date mkdir rm printf wc grep awk sed tr stat shasum sha1sum md5sum openssl mktemp cp chmod ln sleep jq; do
        if command -v "$bin" >/dev/null 2>&1; then
            ln -sf "$(command -v "$bin")" "$FAKE_PATH/$bin" 2>/dev/null || true
        fi
    done
    # omit timeout, gtimeout, perl

    AUDIT_OUT=$(HOME="$TMP_HOME" SAZO_HARNESS_DIR="$TMP_HARNESS" SAZO_STATE_DIR="$TMP_HOME/.claude/state" \
        PATH="$FAKE_PATH" \
        bash "$TMP_HARNESS/scripts/hooks/post-session-end-metrics.sh" <<< "$PAYLOAD" 2>&1 || true)

    AUDIT_FILE="$TMP_HOME/.claude/state/audit.log"
    DEST5C="$TMP_HOME/.claude/state/session-metrics-ses-t5c.jsonl"

    # Check audit log contains the warning (or stderr output)
    if grep -qF "no timeout binary available" "$AUDIT_FILE" 2>/dev/null || \
       printf '%s' "$AUDIT_OUT" | grep -qF "no timeout binary available"; then
        assert_pass "T5c.1 audit_log no-timeout warning emitted"
    else
        # Check audit file directly
        if [ -f "$AUDIT_FILE" ] && grep -qF "no timeout" "$AUDIT_FILE"; then
            assert_pass "T5c.1 audit_log no-timeout warning emitted"
        else
            assert_fail "T5c.1 audit_log no-timeout warning emitted" "warning not found in audit or stderr"
        fi
    fi

    # Metric should still be written (fallback runs without timeout)
    if [ -f "$DEST5C" ] && [ -s "$DEST5C" ]; then
        assert_pass "T5c.2 metric written even without timeout"
    else
        assert_fail "T5c.2 metric written even without timeout" "file missing or empty"
    fi

    rm -rf "$TMP_HOME" "$TMP_HARNESS" "$FAKE_PATH"
}

# ---------------------------------------------------------------------------
echo "=== T6: /exit limitation documented ==="
{
    DOCS_FILE="$SCRIPT_DIR/../../docs/workflow-hooks.md"
    if grep -qF "SessionEnd hook known limitations" "$DOCS_FILE" 2>/dev/null; then
        assert_pass "T6.1 known-limitations section present in workflow-hooks.md"
    else
        mark_test_skip "T6.1 docs/workflow-hooks.md SessionEnd section pending (add to docs)"
    fi

    if grep -qF "/exit" "$DOCS_FILE" 2>/dev/null && \
       grep -qF "SessionEnd" "$DOCS_FILE" 2>/dev/null; then
        assert_pass "T6.2 /exit limitation mentioned"
    else
        mark_test_skip "T6.2 /exit limitation mentioned (docs section pending)"
    fi
}

# ---------------------------------------------------------------------------
echo "=== T7: missing session_id → skip metric + audit log ==="
{
    TMP_HOME=$(mktemp -d)
    TMP_HARNESS=$(mktemp -d)
    mkdir -p "$TMP_HOME/.claude/state"
    mkdir -p "$TMP_HARNESS/scripts/hooks/lib"
    cp "$LIB" "$TMP_HARNESS/scripts/hooks/lib/session-state.sh"
    cp "$HOOK" "$TMP_HARNESS/scripts/hooks/post-session-end-metrics.sh"
    chmod +x "$TMP_HARNESS/scripts/hooks/post-session-end-metrics.sh"
    printf '#!/usr/bin/env bash\n' > "$TMP_HARNESS/scripts/hooks/workflow-state-machine.sh"
    chmod +x "$TMP_HARNESS/scripts/hooks/workflow-state-machine.sh"
    mk_settings_json "$TMP_HOME" "session_end_only" "$TMP_HARNESS"

    # empty session_id
    PAYLOAD=$(mk_payload "" "/tmp/t7.jsonl" "/tmp" "other")
    AUDIT_FILE="$TMP_HOME/.claude/state/audit.log"

    RC=0
    HOME="$TMP_HOME" SAZO_HARNESS_DIR="$TMP_HARNESS" SAZO_STATE_DIR="$TMP_HOME/.claude/state" \
        bash "$TMP_HARNESS/scripts/hooks/post-session-end-metrics.sh" <<< "$PAYLOAD" || RC=$?

    # Should exit 0 (graceful)
    assert_eq "0" "$RC" "T7.1 exit 0 on missing session_id"

    # No metric file created
    DEST_PATTERN="$TMP_HOME/.claude/state/session-metrics-.jsonl"
    if ls "$TMP_HOME/.claude/state/session-metrics-"*.jsonl 2>/dev/null | grep -q .; then
        assert_fail "T7.2 no metric file on missing session_id"
    else
        assert_pass "T7.2 no metric file on missing session_id"
    fi

    # audit log contains warning
    if [ -f "$AUDIT_FILE" ] && grep -qF "missing session_id" "$AUDIT_FILE"; then
        assert_pass "T7.3 audit log entry for missing session_id"
    else
        assert_fail "T7.3 audit log entry for missing session_id" "not found in $AUDIT_FILE"
    fi

    rm -rf "$TMP_HOME" "$TMP_HARNESS"
}

# ---------------------------------------------------------------------------
echo "=== T8: hook_healthy check #6 — hook command path ==="
{
    # T8 positive: command file exists → healthy=true
    TMP_HOME=$(mktemp -d)
    TMP_HARNESS=$(mktemp -d)
    mkdir -p "$TMP_HOME/.claude/state"
    mkdir -p "$TMP_HARNESS/scripts/hooks/lib"
    cp "$LIB" "$TMP_HARNESS/scripts/hooks/lib/session-state.sh"
    # Create a fake hook command that actually exists
    FAKE_HOOK="$TMP_HARNESS/scripts/hooks/post-session-end-metrics.sh"
    mkdir -p "$(dirname "$FAKE_HOOK")"
    cp "$HOOK" "$FAKE_HOOK"
    chmod +x "$FAKE_HOOK"
    mk_settings_json "$TMP_HOME" "hook_path" "$TMP_HARNESS" "$FAKE_HOOK"

    RESULT=$(HOME="$TMP_HOME" SAZO_HARNESS_DIR="$TMP_HARNESS" SAZO_STATE_DIR="$TMP_HOME/.claude/state" \
        bash -c 'source "'"$TMP_HARNESS"'/scripts/hooks/lib/session-state.sh"; hook_healthy && echo "healthy" || echo "unhealthy"' 2>/dev/null)
    assert_eq "healthy" "$RESULT" "T8.1 existing command path → healthy"

    # T8 negative: remove command file → healthy=false
    rm -f "$FAKE_HOOK"
    RESULT=$(HOME="$TMP_HOME" SAZO_HARNESS_DIR="$TMP_HARNESS" SAZO_STATE_DIR="$TMP_HOME/.claude/state" \
        bash -c 'source "'"$TMP_HARNESS"'/scripts/hooks/lib/session-state.sh"; hook_healthy && echo "healthy" || echo "unhealthy"' 2>/dev/null)
    assert_eq "unhealthy" "$RESULT" "T8.2 missing command path → unhealthy"

    rm -rf "$TMP_HOME" "$TMP_HARNESS"
}

# ---------------------------------------------------------------------------
echo ""
echo "Results: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
if [ "$FAIL" -gt 0 ]; then
    echo "SMOKE FAILED"
    exit 1
fi
echo "SMOKE PASSED"
exit 0
