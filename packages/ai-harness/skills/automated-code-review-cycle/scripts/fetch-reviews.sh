#!/usr/bin/env bash
# fetch-reviews.sh — fetch bot review comments and unanswered threads.
#
# Usage: fetch-reviews.sh --pr <num> [--config <path>] [--repo-dir <path>]
#
# Outputs JSON on stdout:
#   {
#     "codex": {"review_ids": [], "all_comments": [], "unanswered": [], "unanswered_count": 0},
#     "gemini": {"review_ids": [], "all_comments": [], "unanswered": [], "unanswered_count": 0},
#     "gemini_enabled": false,
#     "replied_ids": []
#   }
#
# Exit codes:
#   0 — success
#   1 — argument/config/repo resolution error

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_CONFIG="$(cd "$SCRIPT_DIR/.." && pwd)/config.json"

# ── argument parsing ──────────────────────────────────────
PR_NUM=""
CONFIG_PATH="$DEFAULT_CONFIG"
REPO_DIR=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --pr)       PR_NUM="$2"; shift 2 ;;
        --config)   CONFIG_PATH="$2"; shift 2 ;;
        --repo-dir) REPO_DIR="$2"; shift 2 ;;
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

# ── load + merge config (same logic as poll-labels.sh/setup-labels.sh) ────────
REPO_OVERRIDE=""
if [[ -n "$REPO_DIR" && -f "$REPO_DIR/.github/sazo-bot-review.json" ]]; then
    REPO_OVERRIDE="$REPO_DIR/.github/sazo-bot-review.json"
fi

if [[ -n "$REPO_OVERRIDE" ]]; then
    MERGED_CONFIG=$(jq -n \
        --slurpfile base "$CONFIG_PATH" \
        --slurpfile ovr "$REPO_OVERRIDE" \
        '
        ($base[0].active_reviewers // {}) as $br |
        ($ovr[0].active_reviewers // {}) as $or |
        $base[0]
        | .active_reviewers = (
            ($br + $or)
            | to_entries
            | map(.value = (($br[.key] // {}) * ($or[.key] // {})))
            | from_entries
          )
        | .labels = ($base[0].labels * ($ovr[0].labels // {}))
        | .override_label = ($ovr[0].override_label // $base[0].override_label)
        | .polling = ($base[0].polling * ($ovr[0].polling // {}))
        ')
else
    MERGED_CONFIG=$(jq '.' "$CONFIG_PATH")
fi

CODEX_BOT_LOGIN=$(echo "$MERGED_CONFIG" | jq -r '.active_reviewers.codex.bot_login // empty')
GEMINI_BOT_LOGIN=$(echo "$MERGED_CONFIG" | jq -r '.active_reviewers.gemini.bot_login // empty')
if [[ -z "$CODEX_BOT_LOGIN" || -z "$GEMINI_BOT_LOGIN" ]]; then
    echo "ERROR: active_reviewers.*.bot_login missing from config" >&2
    exit 1
fi

# ── resolve target repository ─────────────────────────────
_resolve_dir="${REPO_DIR:-.}"
REPO_SLUG=$(cd "$_resolve_dir" && gh repo view --json owner,name -q '.owner.login + "/" + .name' 2>/dev/null) || true
if [[ -z "$REPO_SLUG" ]]; then
    _remote_url=$(git -C "$_resolve_dir" remote get-url origin 2>/dev/null || true)
    REPO_SLUG=$(echo "$_remote_url" | sed -E 's|^.*[:/]([^/]+/[^/]+?)(\.git)?$|\1|')
fi

if [[ -z "$REPO_SLUG" ]]; then
    echo "ERROR: could not resolve GitHub repository slug" >&2
    exit 1
fi

fetch_review_ids() {
    local bot_login="$1"
    gh api "repos/$REPO_SLUG/pulls/$PR_NUM/reviews" --paginate \
        --jq '.[] | {id: .id, submitted_at: .submitted_at, login: .user.login}' \
        | jq -s --arg bot "$bot_login" '[.[] | select(.login == $bot)] | sort_by(.submitted_at) | [.[].id]'
}

fetch_comments_for_reviews() {
    local review_ids="$1"
    local all_comments='[]'
    local review_id comments

    for review_id in $(echo "$review_ids" | jq -r '.[]'); do
        comments=$(gh api "repos/$REPO_SLUG/pulls/$PR_NUM/reviews/$review_id/comments" --paginate \
            --jq ".[] | {id, body: .body[0:500], path, line, reviewer_login: .user.login, review_id: $review_id}" \
            | jq -s '.')
        all_comments=$(echo "$all_comments" | jq --argjson c "$comments" '. + $c')
    done

    printf '%s' "$all_comments"
}

ALL_CODEX_REVIEW_IDS=$(fetch_review_ids "$CODEX_BOT_LOGIN")
ALL_GEMINI_REVIEW_IDS=$(fetch_review_ids "$GEMINI_BOT_LOGIN")

LATEST_GEMINI_REVIEW=$(echo "$ALL_GEMINI_REVIEW_IDS" | jq 'last')
GEMINI_ENABLED=false
if [[ -n "$LATEST_GEMINI_REVIEW" && "$LATEST_GEMINI_REVIEW" != "null" ]]; then
    GEMINI_ENABLED=true
fi

CODEX_ALL_COMMENTS=$(fetch_comments_for_reviews "$ALL_CODEX_REVIEW_IDS")
GEMINI_ALL_COMMENTS='[]'
if [[ "$GEMINI_ENABLED" = true ]]; then
    GEMINI_ALL_COMMENTS=$(fetch_comments_for_reviews "$ALL_GEMINI_REVIEW_IDS")
fi

REPLIED_IDS=$(gh api "repos/$REPO_SLUG/pulls/$PR_NUM/comments" --paginate \
    --jq '.[] | select(.in_reply_to_id != null) | .in_reply_to_id' \
    | jq -s '.')

UNANSWERED_CODEX=$(echo "$CODEX_ALL_COMMENTS" \
    | jq --argjson replied "$REPLIED_IDS" \
        '[.[] | select(.id as $cid | ($replied | index($cid)) | not)]')
UNANSWERED_CODEX_COUNT=$(echo "$UNANSWERED_CODEX" | jq 'length')

UNANSWERED_GEMINI='[]'
UNANSWERED_GEMINI_COUNT=0
if [[ "$GEMINI_ENABLED" = true ]]; then
    UNANSWERED_GEMINI=$(echo "$GEMINI_ALL_COMMENTS" \
        | jq --argjson replied "$REPLIED_IDS" \
            '[.[] | select(.id as $cid | ($replied | index($cid)) | not)]')
    UNANSWERED_GEMINI_COUNT=$(echo "$UNANSWERED_GEMINI" | jq 'length')
fi

jq -n \
    --argjson codex_review_ids "$ALL_CODEX_REVIEW_IDS" \
    --argjson gemini_review_ids "$ALL_GEMINI_REVIEW_IDS" \
    --argjson codex_all_comments "$CODEX_ALL_COMMENTS" \
    --argjson gemini_all_comments "$GEMINI_ALL_COMMENTS" \
    --argjson unanswered_codex "$UNANSWERED_CODEX" \
    --argjson unanswered_gemini "$UNANSWERED_GEMINI" \
    --argjson unanswered_codex_count "$UNANSWERED_CODEX_COUNT" \
    --argjson unanswered_gemini_count "$UNANSWERED_GEMINI_COUNT" \
    --argjson gemini_enabled "$GEMINI_ENABLED" \
    --argjson replied_ids "$REPLIED_IDS" \
    '{
      codex: {
        review_ids: $codex_review_ids,
        all_comments: $codex_all_comments,
        unanswered: $unanswered_codex,
        unanswered_count: $unanswered_codex_count
      },
      gemini: {
        review_ids: $gemini_review_ids,
        all_comments: $gemini_all_comments,
        unanswered: $unanswered_gemini,
        unanswered_count: $unanswered_gemini_count
      },
      gemini_enabled: $gemini_enabled,
      replied_ids: $replied_ids
    }'
