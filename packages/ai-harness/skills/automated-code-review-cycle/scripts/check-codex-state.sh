#!/usr/bin/env bash
# check-codex-state.sh — evaluate Codex/Gemini pass state from reactions/comments.
#
# Usage: check-codex-state.sh --pr <num> --push-time <iso8601> [--gemini-enabled true|false] [--unanswered-gemini-count <n>] [--config <path>] [--repo-dir <path>]
#
# Outputs JSON on stdout:
#   {
#     "codex_state": "approved|reviewing|pending",
#     "codex_passed": true|false,
#     "gemini_passed": true|false,
#     "all_passed": true|false,
#     "sweep_race_detected": false,
#     "override_codex_all_comments": null,
#     "override_unanswered_codex": null,
#     "override_unanswered_codex_count": null
#   }
#
# Exit codes:
#   0 — success
#   1 — argument/config/repo resolution error

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_CONFIG="$(cd "$SCRIPT_DIR/.." && pwd)/config.json"
source "$SCRIPT_DIR/utils.sh"

# ── argument parsing ──────────────────────────────────────
PR_NUM=""
PUSH_TIME=""
GEMINI_ENABLED=false
UNANSWERED_GEMINI_COUNT=0
CONFIG_PATH="$DEFAULT_CONFIG"
REPO_DIR=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --pr)                     PR_NUM="$2"; shift 2 ;;
        --push-time)              PUSH_TIME="$2"; shift 2 ;;
        --gemini-enabled)         GEMINI_ENABLED="$2"; shift 2 ;;
        --unanswered-gemini-count) UNANSWERED_GEMINI_COUNT="$2"; shift 2 ;;
        --config)                 CONFIG_PATH="$2"; shift 2 ;;
        --repo-dir)               REPO_DIR="$2"; shift 2 ;;
        *) shift ;;
    esac
done

if [[ -z "$PR_NUM" ]]; then
    echo "ERROR: --pr <num> required" >&2
    exit 1
fi
if ! [[ "$PR_NUM" =~ ^[0-9]+$ ]]; then
    echo "ERROR: --pr must be a positive integer, got '$PR_NUM'" >&2
    exit 1
fi
if [[ -z "$PUSH_TIME" ]]; then
    echo "ERROR: --push-time <iso8601> required" >&2
    exit 1
fi
if [[ ! -f "$CONFIG_PATH" ]]; then
    echo "ERROR: config not found: $CONFIG_PATH" >&2
    exit 1
fi

# ── load + merge config ───────────────────────────────────
MERGED_CONFIG=$(merge_review_config "$CONFIG_PATH" "$REPO_DIR")

CODEX_BOT_LOGIN=$(echo "$MERGED_CONFIG" | jq -r '.active_reviewers.codex.bot_login // empty')
if [[ -z "$CODEX_BOT_LOGIN" ]]; then
    echo "ERROR: active_reviewers.codex.bot_login missing from config" >&2
    exit 1
fi

# ── resolve target repository ─────────────────────────────
_resolve_dir="${REPO_DIR:-.}"
REPO_SLUG=$(resolve_repo_slug "$_resolve_dir")

if [[ -z "$REPO_SLUG" ]]; then
    echo "ERROR: could not resolve GitHub repository slug" >&2
    exit 1
fi

# Codex reaction 3-state.
CODEX_LATEST=$(gh api "repos/$REPO_SLUG/issues/$PR_NUM/reactions" --paginate \
    --jq '.[] | {content: .content, created_at: .created_at, login: .user.login}' \
    | jq -rs --arg bot "$CODEX_BOT_LOGIN" --arg since "$PUSH_TIME" \
        '[.[] | select(.login == $bot and .created_at > $since)]
         | sort_by(.created_at) | last.content // "none"')

CODEX_STATE="pending"
case "$CODEX_LATEST" in
    "+1") CODEX_STATE="approved" ;;
    eyes) CODEX_STATE="reviewing" ;;
    *) CODEX_STATE="pending" ;;
esac

CODEX_PASSED=false
SWEEP_RACE_DETECTED=false
OVERRIDE_CODEX_ALL_COMMENTS='null'
OVERRIDE_UNANSWERED_CODEX='null'
OVERRIDE_UNANSWERED_CODEX_COUNT='null'

if [[ "$CODEX_STATE" == "approved" ]]; then
    # CRITICAL: Race condition sweep — do not simplify.
    SWEEP_REVIEW_IDS=$(gh api "repos/$REPO_SLUG/pulls/$PR_NUM/reviews" --paginate \
        --jq '.[] | {id: .id, submitted_at: .submitted_at, login: .user.login}' \
        | jq -s --arg bot "$CODEX_BOT_LOGIN" '[.[] | select(.login == $bot)] | sort_by(.submitted_at) | [.[].id]')

    SWEEP_COMMENTS=$(
        for REVIEW_ID in $(echo "$SWEEP_REVIEW_IDS" | jq -r '.[]'); do
            gh api "repos/$REPO_SLUG/pulls/$PR_NUM/reviews/$REVIEW_ID/comments" --paginate \
                --jq ".[] | {id, body: .body[0:500], path, line, reviewer_login: .user.login, review_id: $REVIEW_ID}"
        done | jq -s '.'
    )

    REPLIED_IDS_FRESH=$(gh api "repos/$REPO_SLUG/pulls/$PR_NUM/comments" --paginate \
        --jq '.[] | select(.in_reply_to_id != null) | .in_reply_to_id' \
        | jq -s '.')

    SWEEP_UNANSWERED=$(echo "$SWEEP_COMMENTS" | jq --argjson replied "$REPLIED_IDS_FRESH" '[.[] | select(.id as $cid | ($replied | index($cid)) | not)]')
    SWEEP_UNANSWERED_COUNT=$(echo "$SWEEP_UNANSWERED" | jq 'length')

    if [[ "${SWEEP_UNANSWERED_COUNT:-0}" -eq 0 ]]; then
        CODEX_PASSED=true
    else
        SWEEP_RACE_DETECTED=true
        OVERRIDE_CODEX_ALL_COMMENTS="$SWEEP_COMMENTS"
        OVERRIDE_UNANSWERED_CODEX="$SWEEP_UNANSWERED"
        OVERRIDE_UNANSWERED_CODEX_COUNT="$SWEEP_UNANSWERED_COUNT"
        echo "Final sweep race detected: ${SWEEP_UNANSWERED_COUNT} unanswered comments" >&2
    fi
fi

GEMINI_PASSED=true
if [[ "$GEMINI_ENABLED" == "true" ]]; then
    GEMINI_PASSED=false
    if [[ "${UNANSWERED_GEMINI_COUNT:-0}" -eq 0 ]]; then
        GEMINI_PASSED=true
    fi
fi

ALL_PASSED=false
if [[ "$CODEX_PASSED" == "true" && "$GEMINI_PASSED" == "true" ]]; then
    ALL_PASSED=true
fi

jq -n \
    --arg codex_state "$CODEX_STATE" \
    --argjson codex_passed "$CODEX_PASSED" \
    --argjson gemini_passed "$GEMINI_PASSED" \
    --argjson all_passed "$ALL_PASSED" \
    --argjson sweep_race_detected "$SWEEP_RACE_DETECTED" \
    --argjson override_codex_all_comments "$OVERRIDE_CODEX_ALL_COMMENTS" \
    --argjson override_unanswered_codex "$OVERRIDE_UNANSWERED_CODEX" \
    --argjson override_unanswered_codex_count "$OVERRIDE_UNANSWERED_CODEX_COUNT" \
    '{
      codex_state: $codex_state,
      codex_passed: $codex_passed,
      gemini_passed: $gemini_passed,
      all_passed: $all_passed,
      sweep_race_detected: $sweep_race_detected,
      override_codex_all_comments: $override_codex_all_comments,
      override_unanswered_codex: $override_unanswered_codex,
      override_unanswered_codex_count: $override_unanswered_codex_count
    }'
