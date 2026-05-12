#!/usr/bin/env bash
# bot-review-label.smoke.sh — Plan 08 bot review label gate smoke tests.
#
# T1:  setup-labels idempotency — 2 invocations → same 7 calls + --force every call
# T2:  codex+gemini approved → exit 0
# T3:  codex/approved + gemini/in-progress + max_iter=2 → exit 2 (timeout)
# T4:  codex/changes-requested → exit 3
# T5:  always in-progress + max_iter=2 → exit 2
# T6:  bot-review/override only → exit 0
# T7:  default config both approved → exit 0
# T8:  repo override disables gemini → codex/approved alone → exit 0
# T9:  active_reviewers empty → exit 5
# T10: gh missing → exit 4
# T11: --add-label write capture (Step 4-8 mimic)

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS="$(cd "$HERE/../.." && pwd)"
SKILL_DIR="$HARNESS/skills/automated-code-review-cycle"
SETUP_LABELS="$SKILL_DIR/scripts/setup-labels.sh"
POLL_LABELS="$SKILL_DIR/scripts/poll-labels.sh"
CONFIG="$SKILL_DIR/config.json"

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

PASS=0
FAIL=0

assert_exit() {
    local expected="$1" actual="$2" label="$3"
    if [ "$actual" = "$expected" ]; then
        PASS=$((PASS+1))
        echo "  ✓ $label"
    else
        FAIL=$((FAIL+1))
        echo "  ✗ $label (expected exit=$expected, got $actual)"
    fi
}

assert_contains() {
    local label="$1" pattern="$2" file="$3"
    # Use -- to guard against patterns starting with -- (ugrep/grep option ambiguity)
    if grep -qF -- "$pattern" "$file" 2>/dev/null; then
        PASS=$((PASS+1))
        echo "  ✓ $label"
    else
        FAIL=$((FAIL+1))
        echo "  ✗ $label (pattern '$pattern' not found in $file)"
    fi
}

assert_count() {
    local label="$1" expected="$2" actual="$3"
    if [ "$actual" -eq "$expected" ]; then
        PASS=$((PASS+1))
        echo "  ✓ $label"
    else
        FAIL=$((FAIL+1))
        echo "  ✗ $label (expected count=$expected, got $actual)"
    fi
}

# ─────────────────────────────────────────────────────────
# T1: setup-labels idempotency
# 2 invocations → same 7 calls (6 reviewer×label + 1 override), --force every call
# ─────────────────────────────────────────────────────────
echo "=== T1: setup-labels idempotency ==="

T1_BIN="$SANDBOX/t1-bin"
T1_LOG="$SANDBOX/t1-gh.log"
mkdir -p "$T1_BIN"

# mock gh: log every call
cat > "$T1_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
echo "$@" >> "$T1_LOG_FILE"
exit 0
GHEOF
chmod +x "$T1_BIN/gh"

T1_LOG_FILE="$T1_LOG"
export T1_LOG_FILE

# 1st invocation
rc1=0
PATH="$T1_BIN:$PATH" bash "$SETUP_LABELS" --config "$CONFIG" 2>/dev/null
rc1=$?
# 2nd invocation (idempotent)
rc2=0
PATH="$T1_BIN:$PATH" bash "$SETUP_LABELS" --config "$CONFIG" 2>/dev/null
rc2=$?

assert_exit 0 "$rc1" "T1: setup-labels 1st invocation exit 0"
assert_exit 0 "$rc2" "T1: setup-labels 2nd invocation exit 0"

# Count total calls per invocation — each should be 7
calls_total=$(wc -l < "$T1_LOG" | tr -d ' ')
# 2 invocations × 7 = 14
assert_count "T1: total calls = 14 (7 per invocation × 2)" 14 "$calls_total"

# --force present in every call
force_count=$(grep -c -- '--force' "$T1_LOG" || true)
assert_count "T1: --force in every call (14 occurrences)" 14 "$force_count"

# ─────────────────────────────────────────────────────────
# T2: codex+gemini approved → exit 0
# ─────────────────────────────────────────────────────────
echo ""
echo "=== T2: codex+gemini approved → exit 0 ==="

T2_BIN="$SANDBOX/t2-bin"
mkdir -p "$T2_BIN"
cat > "$T2_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
# mock: return labels with both approved
if [[ "$*" == *"pr view"* ]]; then
    echo "bot-review/codex/approved"
    echo "bot-review/gemini/approved"
fi
exit 0
GHEOF
chmod +x "$T2_BIN/gh"

rc=0
PATH="$T2_BIN:$PATH" SAZO_BOT_POLL_INTERVAL=0 SAZO_BOT_MAX_ITER=2 \
    bash "$POLL_LABELS" --pr 1 --config "$CONFIG" 2>/dev/null
rc=$?
assert_exit 0 "$rc" "T2: codex+gemini approved → exit 0"

# ─────────────────────────────────────────────────────────
# T3: codex/approved + gemini/in-progress + max_iter=2 → exit 2 (timeout)
# ─────────────────────────────────────────────────────────
echo ""
echo "=== T3: codex/approved + gemini/in-progress → exit 2 ==="

T3_BIN="$SANDBOX/t3-bin"
mkdir -p "$T3_BIN"
cat > "$T3_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
if [[ "$*" == *"pr view"* ]]; then
    echo "bot-review/codex/approved"
    echo "bot-review/gemini/in-progress"
fi
exit 0
GHEOF
chmod +x "$T3_BIN/gh"

rc=0
PATH="$T3_BIN:$PATH" SAZO_BOT_POLL_INTERVAL=0 SAZO_BOT_MAX_ITER=2 \
    bash "$POLL_LABELS" --pr 1 --config "$CONFIG" 2>/dev/null
rc=$?
assert_exit 2 "$rc" "T3: codex/approved + gemini/in-progress → exit 2 (timeout)"

# ─────────────────────────────────────────────────────────
# T4: codex/changes-requested → exit 3
# ─────────────────────────────────────────────────────────
echo ""
echo "=== T4: codex/changes-requested → exit 3 ==="

T4_BIN="$SANDBOX/t4-bin"
mkdir -p "$T4_BIN"
cat > "$T4_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
if [[ "$*" == *"pr view"* ]]; then
    echo "bot-review/codex/changes-requested"
fi
exit 0
GHEOF
chmod +x "$T4_BIN/gh"

rc=0
PATH="$T4_BIN:$PATH" SAZO_BOT_POLL_INTERVAL=0 SAZO_BOT_MAX_ITER=5 \
    bash "$POLL_LABELS" --pr 1 --config "$CONFIG" 2>/dev/null
rc=$?
assert_exit 3 "$rc" "T4: codex/changes-requested → exit 3"

# ─────────────────────────────────────────────────────────
# T5: always in-progress + max_iter=2 → exit 2
# ─────────────────────────────────────────────────────────
echo ""
echo "=== T5: always in-progress → exit 2 ==="

T5_BIN="$SANDBOX/t5-bin"
mkdir -p "$T5_BIN"
cat > "$T5_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
if [[ "$*" == *"pr view"* ]]; then
    echo "bot-review/codex/in-progress"
    echo "bot-review/gemini/in-progress"
fi
exit 0
GHEOF
chmod +x "$T5_BIN/gh"

rc=0
PATH="$T5_BIN:$PATH" SAZO_BOT_POLL_INTERVAL=0 SAZO_BOT_MAX_ITER=2 \
    bash "$POLL_LABELS" --pr 1 --config "$CONFIG" 2>/dev/null
rc=$?
assert_exit 2 "$rc" "T5: always in-progress → exit 2 (timeout)"

# ─────────────────────────────────────────────────────────
# T6: bot-review/override only → exit 0
# ─────────────────────────────────────────────────────────
echo ""
echo "=== T6: bot-review/override only → exit 0 ==="

T6_BIN="$SANDBOX/t6-bin"
mkdir -p "$T6_BIN"
cat > "$T6_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
if [[ "$*" == *"pr view"* ]]; then
    echo "bot-review/override"
fi
exit 0
GHEOF
chmod +x "$T6_BIN/gh"

rc=0
PATH="$T6_BIN:$PATH" SAZO_BOT_POLL_INTERVAL=0 SAZO_BOT_MAX_ITER=2 \
    bash "$POLL_LABELS" --pr 1 --config "$CONFIG" 2>/dev/null
rc=$?
assert_exit 0 "$rc" "T6: bot-review/override → exit 0"

# ─────────────────────────────────────────────────────────
# T7: default config both approved → exit 0
# ─────────────────────────────────────────────────────────
echo ""
echo "=== T7: default config both approved → exit 0 ==="

T7_BIN="$SANDBOX/t7-bin"
mkdir -p "$T7_BIN"
cat > "$T7_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
if [[ "$*" == *"pr view"* ]]; then
    echo "bot-review/codex/approved"
    echo "bot-review/gemini/approved"
fi
exit 0
GHEOF
chmod +x "$T7_BIN/gh"

rc=0
# no --config → uses default config.json path resolved from POLL_LABELS location
PATH="$T7_BIN:$PATH" SAZO_BOT_POLL_INTERVAL=0 SAZO_BOT_MAX_ITER=2 \
    bash "$POLL_LABELS" --pr 1 2>/dev/null
rc=$?
assert_exit 0 "$rc" "T7: default config both approved → exit 0"

# ─────────────────────────────────────────────────────────
# T8: repo override disables gemini → codex/approved alone → exit 0
# ─────────────────────────────────────────────────────────
echo ""
echo "=== T8: repo override disables gemini → exit 0 ==="

T8_DIR="$SANDBOX/t8"
T8_BIN="$T8_DIR/bin"
T8_REPO="$T8_DIR/repo"
mkdir -p "$T8_BIN" "$T8_REPO/.github"

# Repo override: disable gemini
cat > "$T8_REPO/.github/sazo-bot-review.json" <<'OVEOF'
{
  "active_reviewers": {
    "gemini": {"_disabled": true}
  }
}
OVEOF

cat > "$T8_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
if [[ "$*" == *"pr view"* ]]; then
    echo "bot-review/codex/approved"
fi
exit 0
GHEOF
chmod +x "$T8_BIN/gh"

rc=0
PATH="$T8_BIN:$PATH" SAZO_BOT_POLL_INTERVAL=0 SAZO_BOT_MAX_ITER=2 \
    bash "$POLL_LABELS" --pr 1 --config "$CONFIG" --repo-dir "$T8_REPO" 2>/dev/null
rc=$?
assert_exit 0 "$rc" "T8: gemini disabled via repo override → codex/approved → exit 0"

# ─────────────────────────────────────────────────────────
# T9: active_reviewers empty → exit 5
# ─────────────────────────────────────────────────────────
echo ""
echo "=== T9: active_reviewers empty → exit 5 ==="

T9_CFG="$SANDBOX/t9-config.json"
cat > "$T9_CFG" <<'CFGEOF'
{
  "schema_version": 1,
  "active_reviewers": {},
  "labels": {
    "approved":          {"suffix": "approved",          "color": "0e8a16"},
    "changes_requested": {"suffix": "changes-requested", "color": "d93f0b"},
    "in_progress":       {"suffix": "in-progress",       "color": "fbca04"}
  },
  "override_label": "bot-review/override",
  "polling": {"interval_seconds": 30, "max_iterations": 60}
}
CFGEOF

T9_BIN="$SANDBOX/t9-bin"
mkdir -p "$T9_BIN"
cat > "$T9_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
exit 0
GHEOF
chmod +x "$T9_BIN/gh"

rc=0
PATH="$T9_BIN:$PATH" SAZO_BOT_POLL_INTERVAL=0 SAZO_BOT_MAX_ITER=2 \
    bash "$POLL_LABELS" --pr 1 --config "$T9_CFG" 2>/dev/null
rc=$?
assert_exit 5 "$rc" "T9: active_reviewers empty → exit 5"

# ─────────────────────────────────────────────────────────
# T10: gh missing → exit 4
# ─────────────────────────────────────────────────────────
echo ""
echo "=== T10: gh missing → exit 4 ==="

T10_BIN="$SANDBOX/t10-bin"
mkdir -p "$T10_BIN"
# No gh in T10_BIN, and use minimal PATH without gh

rc=0
PATH="$T10_BIN:/usr/bin:/bin" SAZO_BOT_POLL_INTERVAL=0 SAZO_BOT_MAX_ITER=2 \
    bash "$POLL_LABELS" --pr 1 --config "$CONFIG" 2>/dev/null
rc=$?
assert_exit 4 "$rc" "T10: gh missing → exit 4"

# ─────────────────────────────────────────────────────────
# T11: --add-label write capture (Step 4-8 mimic)
# ─────────────────────────────────────────────────────────
echo ""
echo "=== T11: --add-label write capture ==="

T11_BIN="$SANDBOX/t11-bin"
T11_LOG="$SANDBOX/t11-gh.log"
mkdir -p "$T11_BIN"

# mock gh: log every call
cat > "$T11_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
echo "$@" >> "$T11_LOG_FILE"
exit 0
GHEOF
chmod +x "$T11_BIN/gh"

export T11_LOG_FILE="$T11_LOG"
PR_NUM=42

# Mimic SKILL.md Step 4-8 (LLM decides approved, removes in-progress/changes-requested)
# Use env to set PATH so mock gh is picked up by subshell
env PATH="$T11_BIN:$PATH" T11_LOG_FILE="$T11_LOG" \
    bash -c 'gh issue edit "$1" --add-label "bot-review/codex/approved" --remove-label "bot-review/codex/in-progress,bot-review/codex/changes-requested"' \
    -- "$PR_NUM"
# Gemini also (active)
env PATH="$T11_BIN:$PATH" T11_LOG_FILE="$T11_LOG" \
    bash -c 'gh issue edit "$1" --add-label "bot-review/gemini/approved" --remove-label "bot-review/gemini/in-progress,bot-review/gemini/changes-requested"' \
    -- "$PR_NUM"

assert_contains "T11: codex/approved add-label logged" \
    "--add-label bot-review/codex/approved" "$T11_LOG"
assert_contains "T11: gemini/approved add-label logged" \
    "--add-label bot-review/gemini/approved" "$T11_LOG"

# ─────────────────────────────────────────────────────────
echo ""
echo "─────────────────────"
echo "PASS: $PASS  FAIL: $FAIL"

[ "$FAIL" -gt 0 ] && exit 1
exit 0
