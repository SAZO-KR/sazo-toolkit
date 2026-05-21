#!/usr/bin/env bash
# poll-labels.sh — Plan 08: poll GitHub PR labels for bot-review verdict.
#
# Usage: poll-labels.sh --pr <num> [--config <path>] [--repo-dir <path>] [--skip-reviewer <name>]
#
# --skip-reviewer: reviewer key to exclude at runtime (repeatable).
#   Used by skill when GEMINI_ENABLED=false (Gemini never reviewed the PR).
#
# Exit codes:
#   0 — all active reviewers approved (or override label present)
#   2 — polling timeout (max_iterations reached)
#   3 — changes-requested detected (skill: outer while continue)
#   4 — gh CLI not installed/not authenticated
#   5 — active_reviewers empty (after enabled filter)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_CONFIG="$(cd "$SCRIPT_DIR/.." && pwd)/config.json"
source "$SCRIPT_DIR/utils.sh"

# ── argument parsing ──────────────────────────────────────
PR_NUM=""
CONFIG_PATH="$DEFAULT_CONFIG"
REPO_DIR=""
SKIP_REVIEWERS=()  # reviewer keys to exclude at runtime (GEMINI_ENABLED=false etc.)
while [[ $# -gt 0 ]]; do
    case "$1" in
        --pr)             PR_NUM="$2";    shift 2 ;;
        --config)         CONFIG_PATH="$2"; shift 2 ;;
        --repo-dir)       REPO_DIR="$2"; shift 2 ;;
        --skip-reviewer)  SKIP_REVIEWERS+=("$2"); shift 2 ;;
        *) shift ;;
    esac
done

if [[ -z "$PR_NUM" ]]; then
    echo "ERROR: --pr <num> required" >&2
    exit 1
fi

# ── gh CLI check ──────────────────────────────────────────
if ! command -v gh >/dev/null 2>&1; then
    echo "WARN: gh CLI not found — Plan 08 label gate skip" >&2
    exit 4
fi

# ── load + merge config ───────────────────────────────────
if [[ ! -f "$CONFIG_PATH" ]]; then
    echo "ERROR: config not found: $CONFIG_PATH" >&2
    exit 1
fi

MERGED_CONFIG=$(merge_review_config "$CONFIG_PATH" "$REPO_DIR")

# ── resolve -R OWNER/REPO from REPO_DIR (or cwd fallback) ────────────────────
# CRITICAL: gh pr view resolves the repo from cwd by default. When poll-labels.sh
# is invoked from a harness/script directory that differs from the PR's checkout,
# it polls labels on the wrong repo or fails with "not a git repository".
# Derive the slug explicitly from REPO_DIR so this script is cwd-independent.
GH_REPO_FLAG=()
if [[ -n "$REPO_DIR" ]]; then
    _slug=$(resolve_repo_slug "$REPO_DIR")
    [[ -n "$_slug" ]] && GH_REPO_FLAG=(-R "$_slug")
fi

# ── extract polling params ────────────────────────────────
OVERRIDE_LABEL=$(echo "$MERGED_CONFIG" | jq -r '.override_label // "bot-review/override"')
POLL_INTERVAL="${SAZO_BOT_POLL_INTERVAL:-$(echo "$MERGED_CONFIG" | jq -r '.polling.interval_seconds // 30')}"
MAX_ITER="${SAZO_BOT_MAX_ITER:-$(echo "$MERGED_CONFIG" | jq -r '.polling.max_iterations // 60')}"

# ── extract label suffixes from config (supports .labels.*.suffix overrides) ─
APPROVED_SUFFIX=$(echo "$MERGED_CONFIG" | jq -r '.labels.approved.suffix // "approved"')
CHANGES_SUFFIX=$(echo "$MERGED_CONFIG" | jq -r '.labels.changes_requested.suffix // "changes-requested"')

# ── build active reviewer list (filter enabled=false + runtime skip) ─────────
# Build jq expression to exclude runtime-skipped reviewers
SKIP_JQ_FILTER=""
for _skip in "${SKIP_REVIEWERS[@]+"${SKIP_REVIEWERS[@]}"}"; do
    SKIP_JQ_FILTER="$SKIP_JQ_FILTER | select(.key != \"$_skip\")"
done
ACTIVE_REVIEWERS=$(echo "$MERGED_CONFIG" | jq -r "
    .active_reviewers
    | to_entries[]
    | select(.value.enabled != false)
    $SKIP_JQ_FILTER
    | .key
")

if [[ -z "$ACTIVE_REVIEWERS" ]]; then
    echo "WARN: active_reviewers empty — Plan 08 label gate skip" >&2
    exit 5
fi

# ── Phase 2 prep: read label_authority (Phase 1 informational only) ─────────
# label_authority="skill"    → LLM (SKILL.md Step 4-8) attaches labels (Phase 1 default)
# label_authority="actions"  → GitHub Actions auto-attaches labels (Phase 2)
# Phase 1 logs this value for observability but does NOT branch on it.
# Evaluated per-reviewer inside the polling loop to support per-reviewer config.
while IFS= read -r _ar; do
    [[ -z "$_ar" ]] && continue
    _la=$(echo "$MERGED_CONFIG" | jq -r --arg k "$_ar" '.active_reviewers[$k].label_authority // "skill"')
    echo "INFO: reviewer=$_ar label_authority=$_la" >&2
done <<< "$ACTIVE_REVIEWERS"

# ── polling loop ──────────────────────────────────────────
iter=0
while true; do
    # fetch current labels — exit 4 on auth/access failure (not just "gh not installed")
    _gh_err_file="/tmp/poll-labels-gh-err-${PR_NUM}"
    if ! LABELS=$(gh pr view "${GH_REPO_FLAG[@]+"${GH_REPO_FLAG[@]}"}" "$PR_NUM" --json labels --jq '.labels[].name' 2>"$_gh_err_file"); then
        GH_ERR=$(cat "$_gh_err_file" 2>/dev/null || true)
        echo "ERROR: gh pr view failed: $GH_ERR" >&2
        exit 4
    fi

    # check override label
    if echo "$LABELS" | grep -qxF "$OVERRIDE_LABEL"; then
        exit 0
    fi

    # check changes-requested (any active reviewer)
    CHANGES_REQUESTED=false
    ALL_APPROVED=true

    while IFS= read -r reviewer; do
        [[ -z "$reviewer" ]] && continue
        prefix=$(echo "$MERGED_CONFIG" | jq -r --arg k "$reviewer" '.active_reviewers[$k].label_prefix // ""')
        if [[ -z "$prefix" ]]; then
            enabled=$(echo "$MERGED_CONFIG" | jq -r --arg k "$reviewer" '.active_reviewers[$k].enabled // "true"')
            if [[ "$enabled" == "false" ]]; then
                continue  # intentionally disabled (enabled=false)
            fi
            echo "WARN: reviewer '$reviewer' has empty label_prefix (config error: incomplete repo override?). skipping." >&2
            ALL_APPROVED=false  # missing prefix = not approved; do not silently pass the gate
            continue
        fi

        changes_label="${prefix}${CHANGES_SUFFIX}"
        approved_label="${prefix}${APPROVED_SUFFIX}"

        if echo "$LABELS" | grep -qxF "$changes_label"; then
            CHANGES_REQUESTED=true
            ALL_APPROVED=false
            break
        fi

        if ! echo "$LABELS" | grep -qxF "$approved_label"; then
            ALL_APPROVED=false
        fi
    done <<< "$ACTIVE_REVIEWERS"

    if [[ "$CHANGES_REQUESTED" == "true" ]]; then
        exit 3
    fi

    if [[ "$ALL_APPROVED" == "true" ]]; then
        # ── Pre-termination verification (W5-B6) ──────────────────────────────
        # Before returning exit 0, fetch gh api .../reviews per active reviewer
        # and confirm each bot_login's latest review state is APPROVED.
        # If state is CHANGES_REQUESTED or absent → labels are stale; fall through.
        # On gh api failure (non-zero exit) → trust label with WARN (not exit 4).
        _B6_VERIFIED=true
        while IFS= read -r _reviewer; do
            [[ -z "$_reviewer" ]] && continue
            _bot_login=$(echo "$MERGED_CONFIG" | jq -r --arg k "$_reviewer" '.active_reviewers[$k].bot_login // ""')
            [[ -z "$_bot_login" ]] && continue

            _repo_owner_repo=""
            if [[ ${#GH_REPO_FLAG[@]} -gt 0 ]]; then
                _repo_owner_repo="${GH_REPO_FLAG[1]}"
            fi

            _b6_err_file="/tmp/poll-labels-b6-err-${PR_NUM}-${_bot_login//[^a-zA-Z0-9_-]/_}"
            # CRITICAL: --paginate required — PRs with >30 reviews only return first page without it.
            # 2-stage pattern: raw emit per page → jq -s to slurp all pages into one array.
            # CRITICAL: detect gh api failure before piping to jq. When gh api fails, the pipe
            # still produces output from jq (e.g. `[]` on empty input), so -z check on _reviews_json
            # is never true and the WARN+trust-label path is unreachable. Capture exit code via a
            # temp file to distinguish API failure from empty result.
            _b6_gh_ok=true
            if [[ -n "$_repo_owner_repo" ]]; then
                _reviews_raw=$(gh api --paginate "repos/$_repo_owner_repo/pulls/$PR_NUM/reviews" \
                    --jq '.[] | {state, submitted_at, user_login: .user.login}' 2>"$_b6_err_file") \
                    || _b6_gh_ok=false
            else
                _reviews_raw=$(gh api --paginate "repos/{owner}/{repo}/pulls/$PR_NUM/reviews" \
                    --jq '.[] | {state, submitted_at, user_login: .user.login}' 2>"$_b6_err_file") \
                    || _b6_gh_ok=false
            fi

            if [[ "$_b6_gh_ok" == "false" ]]; then
                _b6_err=$(cat "$_b6_err_file" 2>/dev/null || true)
                echo "WARN: B6 pre-termination gh api failed for $_reviewer: $_b6_err — trusting label" >&2
                continue
            fi

            _reviews_json=$(echo "$_reviews_raw" | jq -s '.' 2>/dev/null || echo "[]")

            _latest_state=$(echo "$_reviews_json" | jq -r --arg login "$_bot_login" \
                '[.[] | select(.user_login == $login)] | sort_by(.submitted_at) | last | .state // "NONE"' 2>/dev/null || echo "NONE")
            if [[ "$_latest_state" != "APPROVED" ]]; then
                echo "WARN: B6 pre-termination: $_reviewer ($_bot_login) latest review state=$_latest_state — label stale, continuing poll" >&2
                _B6_VERIFIED=false
                break
            fi
        done <<< "$ACTIVE_REVIEWERS"

        [[ "$_B6_VERIFIED" == "true" ]] && exit 0
    fi

    # timeout check
    iter=$((iter + 1))
    if [[ "$iter" -ge "$MAX_ITER" ]]; then
        echo "WARN: polling timeout (max_iterations=$MAX_ITER reached)" >&2
        exit 2
    fi

    sleep "$POLL_INTERVAL"
done
