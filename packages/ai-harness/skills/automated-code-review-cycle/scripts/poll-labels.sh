#!/usr/bin/env bash
# poll-labels.sh — Plan 08: poll GitHub PR labels for bot-review verdict.
#
# Usage: poll-labels.sh --pr <num> [--config <path>] [--repo-dir <path>]
#
# Exit codes:
#   0 — all active reviewers approved (or override label present)
#   2 — polling timeout (max_iterations reached)
#   3 — changes-requested detected (skill: outer while continue)
#   4 — gh CLI not installed/not authenticated
#   5 — active_reviewers empty (after _disabled filter)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_CONFIG="$(cd "$SCRIPT_DIR/.." && pwd)/config.json"

# ── argument parsing ──────────────────────────────────────
PR_NUM=""
CONFIG_PATH="$DEFAULT_CONFIG"
REPO_DIR=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --pr)       PR_NUM="$2";    shift 2 ;;
        --config)   CONFIG_PATH="$2"; shift 2 ;;
        --repo-dir) REPO_DIR="$2"; shift 2 ;;
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

# Merge repo override (entry-level replace for active_reviewers, deep merge for labels/polling)
REPO_OVERRIDE=""
if [[ -n "$REPO_DIR" && -f "$REPO_DIR/.github/sazo-bot-review.json" ]]; then
    REPO_OVERRIDE="$REPO_DIR/.github/sazo-bot-review.json"
fi

if [[ -n "$REPO_OVERRIDE" ]]; then
    MERGED_CONFIG=$(jq -n \
        --slurpfile base "$CONFIG_PATH" \
        --slurpfile ovr "$REPO_OVERRIDE" \
        '
        $base[0]
        | .active_reviewers = (($base[0].active_reviewers // {}) + ($ovr[0].active_reviewers // {}))
        | .labels = ($base[0].labels * ($ovr[0].labels // {}))
        | .override_label = ($ovr[0].override_label // $base[0].override_label)
        | .polling = ($base[0].polling * ($ovr[0].polling // {}))
        ')
else
    MERGED_CONFIG=$(jq '.' "$CONFIG_PATH")
fi

# ── extract polling params ────────────────────────────────
OVERRIDE_LABEL=$(echo "$MERGED_CONFIG" | jq -r '.override_label // "bot-review/override"')
POLL_INTERVAL="${SAZO_BOT_POLL_INTERVAL:-$(echo "$MERGED_CONFIG" | jq -r '.polling.interval_seconds // 30')}"
MAX_ITER="${SAZO_BOT_MAX_ITER:-$(echo "$MERGED_CONFIG" | jq -r '.polling.max_iterations // 60')}"

# ── build active reviewer list (filter _disabled) ─────────
ACTIVE_REVIEWERS=$(echo "$MERGED_CONFIG" | jq -r '
    .active_reviewers
    | to_entries[]
    | select(.value._disabled != true)
    | .key
')

if [[ -z "$ACTIVE_REVIEWERS" ]]; then
    echo "WARN: active_reviewers empty — Plan 08 label gate skip" >&2
    exit 5
fi

# ── polling loop ──────────────────────────────────────────
iter=0
while true; do
    # fetch current labels
    LABELS=$(gh pr view "$PR_NUM" --json labels --jq '.labels[].name' 2>/dev/null || true)

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
        [[ -z "$prefix" ]] && continue

        changes_label="${prefix}changes-requested"
        approved_label="${prefix}approved"

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
        exit 0
    fi

    # timeout check
    iter=$((iter + 1))
    if [[ "$iter" -ge "$MAX_ITER" ]]; then
        echo "WARN: polling timeout (max_iterations=$MAX_ITER reached)" >&2
        exit 2
    fi

    sleep "$POLL_INTERVAL"
done
