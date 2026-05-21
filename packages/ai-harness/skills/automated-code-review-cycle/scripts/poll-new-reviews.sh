#!/usr/bin/env bash
# poll-new-reviews.sh — detect bot review progress after a push.
#
# Usage: poll-new-reviews.sh --pr <num> [--config <path>] [--repo-dir <path>] [--cycle-start-time <iso8601>] [--max-polls <n>] [--interval <sec>]
#
# Outputs JSON on stdout:
#   {
#     "push_time": "2026-05-21T09:00:00Z",
#     "new_review_found": true,
#     "codex_reaction": "+1",
#     "new_review_count": 1,
#     "quota_hit": false,
#     "codex_quota_count": 0,
#     "gemini_quota_count": 0
#   }
#
# Exit codes:
#   0 — success
#   1 — argument/config/repo resolution error
#   2 — could not obtain server-authoritative push time

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_CONFIG="$(cd "$SCRIPT_DIR/.." && pwd)/config.json"
source "$SCRIPT_DIR/utils.sh"

# ── argument parsing ──────────────────────────────────────
PR_NUM=""
CONFIG_PATH="$DEFAULT_CONFIG"
REPO_DIR=""
MAX_POLLS=20
INTERVAL_SECONDS=30
CYCLE_START_TIME=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --pr)               PR_NUM="$2"; shift 2 ;;
        --config)           CONFIG_PATH="$2"; shift 2 ;;
        --repo-dir)         REPO_DIR="$2"; shift 2 ;;
        --cycle-start-time) CYCLE_START_TIME="$2"; shift 2 ;;
        --max-polls)        MAX_POLLS="$2"; shift 2 ;;
        --interval)         INTERVAL_SECONDS="$2"; shift 2 ;;
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

if [[ ! -f "$CONFIG_PATH" ]]; then
    echo "ERROR: config not found: $CONFIG_PATH" >&2
    exit 1
fi

# ── load + merge config ───────────────────────────────────
MERGED_CONFIG=$(merge_review_config "$CONFIG_PATH" "$REPO_DIR")

CODEX_BOT_LOGIN=$(echo "$MERGED_CONFIG" | jq -r '.active_reviewers.codex.bot_login // empty')
GEMINI_BOT_LOGIN=$(echo "$MERGED_CONFIG" | jq -r '.active_reviewers.gemini.bot_login // empty')
if [[ -z "$CODEX_BOT_LOGIN" || -z "$GEMINI_BOT_LOGIN" ]]; then
    echo "ERROR: active_reviewers.*.bot_login missing from config" >&2
    exit 1
fi

# ── resolve target repository ─────────────────────────────
_resolve_dir="${REPO_DIR:-.}"
REPO_SLUG=$(resolve_repo_slug "$_resolve_dir")

if [[ -z "$REPO_SLUG" ]]; then
    echo "ERROR: could not resolve GitHub repository slug" >&2
    exit 1
fi

fetch_push_time() {
    local t
    for attempt in 1 2 3; do
        t=$(gh api "repos/$REPO_SLUG" --jq '.pushed_at' 2>/dev/null || true)
        if [[ -n "$t" && "$t" != "null" ]]; then
            printf '%s' "$t"
            return 0
        fi
        sleep 2
    done
    return 1
}

PUSH_TIME=$(fetch_push_time) || {
    echo "FATAL: Could not obtain server-authoritative push time from repo.pushed_at" >&2
    exit 2
}

NEW_REVIEW_FOUND=false
NEW_REVIEWS=0
CODEX_REACTION="none"
QUOTA_HIT=false
CODEX_QUOTA_COUNT=0
GEMINI_QUOTA_COUNT=0

check_quota_comments() {
    if [[ -z "$CYCLE_START_TIME" ]]; then
        return 0
    fi

    CODEX_QUOTA_COUNT=$(gh pr view "$PR_NUM" -R "$REPO_SLUG" --comments --json comments \
        --jq "[.comments[] | select(
          .createdAt > \"$CYCLE_START_TIME\" and
          (.body | test(\"reached your.*quota|reached your.*usage limits\"))
        )] | length")

    GEMINI_QUOTA_COUNT=$(gh pr view "$PR_NUM" -R "$REPO_SLUG" --comments --json comments \
        --jq "[.comments[] | select(
          .createdAt > \"$CYCLE_START_TIME\" and
          (.body | test(\"reached your daily quota limit\"))
        )] | length")

    if [[ "$CODEX_QUOTA_COUNT" -gt 0 || "$GEMINI_QUOTA_COUNT" -gt 0 ]]; then
        QUOTA_HIT=true
    fi
}

for _ in $(seq 1 "$MAX_POLLS"); do
    sleep "$INTERVAL_SECONDS"

    NEW_REVIEWS=$(gh api "repos/$REPO_SLUG/pulls/$PR_NUM/reviews" --paginate \
        --jq '.[] | {id: .id, submitted_at: .submitted_at, login: .user.login}' \
        | jq -s --arg codex "$CODEX_BOT_LOGIN" --arg gemini "$GEMINI_BOT_LOGIN" --arg since "$PUSH_TIME" \
            '[.[] | select(.submitted_at > $since and (.login == $codex or .login == $gemini))] | length')

    CODEX_REACTION=$(gh api "repos/$REPO_SLUG/issues/$PR_NUM/reactions" --paginate \
        --jq '.[] | {content: .content, created_at: .created_at, login: .user.login}' \
        | jq -rs --arg bot "$CODEX_BOT_LOGIN" --arg since "$PUSH_TIME" \
            '[.[] | select(.login == $bot and .created_at > $since)]
             | sort_by(.created_at) | last.content // "none"')

    if [[ "$NEW_REVIEWS" -gt 0 || "$CODEX_REACTION" != "none" ]]; then
        NEW_REVIEW_FOUND=true
        break
    fi

    check_quota_comments
    if [[ "$QUOTA_HIT" == "true" ]]; then
        break
    fi
done

jq -n \
    --arg push_time "$PUSH_TIME" \
    --arg codex_reaction "$CODEX_REACTION" \
    --argjson new_review_found "$NEW_REVIEW_FOUND" \
    --argjson new_review_count "$NEW_REVIEWS" \
    --argjson quota_hit "$QUOTA_HIT" \
    --argjson codex_quota_count "$CODEX_QUOTA_COUNT" \
    --argjson gemini_quota_count "$GEMINI_QUOTA_COUNT" \
    '{
      push_time: $push_time,
      new_review_found: $new_review_found,
      codex_reaction: $codex_reaction,
      new_review_count: $new_review_count,
      quota_hit: $quota_hit,
      codex_quota_count: $codex_quota_count,
      gemini_quota_count: $gemini_quota_count
    }'
