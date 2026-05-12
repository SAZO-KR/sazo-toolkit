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
#   5 — active_reviewers empty (after _disabled filter)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_CONFIG="$(cd "$SCRIPT_DIR/.." && pwd)/config.json"

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

# ── resolve -R OWNER/REPO from REPO_DIR (or cwd fallback) ────────────────────
# CRITICAL: gh pr view resolves the repo from cwd by default. When poll-labels.sh
# is invoked from a harness/script directory that differs from the PR's checkout,
# it polls labels on the wrong repo or fails with "not a git repository".
# Derive the slug explicitly from REPO_DIR so this script is cwd-independent.
GH_REPO_FLAG=()
if [[ -n "$REPO_DIR" ]]; then
    _remote_url=$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null || true)
    if [[ -n "$_remote_url" ]]; then
        _slug=$(echo "$_remote_url" | sed -E 's|.*github\.com[:/]||; s|\.git$||')
        [[ -n "$_slug" ]] && GH_REPO_FLAG=(-R "$_slug")
    fi
fi

# ── extract polling params ────────────────────────────────
OVERRIDE_LABEL=$(echo "$MERGED_CONFIG" | jq -r '.override_label // "bot-review/override"')
POLL_INTERVAL="${SAZO_BOT_POLL_INTERVAL:-$(echo "$MERGED_CONFIG" | jq -r '.polling.interval_seconds // 30')}"
MAX_ITER="${SAZO_BOT_MAX_ITER:-$(echo "$MERGED_CONFIG" | jq -r '.polling.max_iterations // 60')}"

# ── extract label suffixes from config (supports .labels.*.suffix overrides) ─
APPROVED_SUFFIX=$(echo "$MERGED_CONFIG" | jq -r '.labels.approved.suffix // "approved"')
CHANGES_SUFFIX=$(echo "$MERGED_CONFIG" | jq -r '.labels.changes_requested.suffix // "changes-requested"')

# ── build active reviewer list (filter _disabled + runtime skip) ─────────
# Build jq expression to exclude runtime-skipped reviewers
SKIP_JQ_FILTER=""
for _skip in "${SKIP_REVIEWERS[@]+"${SKIP_REVIEWERS[@]}"}"; do
    SKIP_JQ_FILTER="$SKIP_JQ_FILTER | select(.key != \"$_skip\")"
done
ACTIVE_REVIEWERS=$(echo "$MERGED_CONFIG" | jq -r "
    .active_reviewers
    | to_entries[]
    | select(.value._disabled != true)
    $SKIP_JQ_FILTER
    | .key
")

if [[ -z "$ACTIVE_REVIEWERS" ]]; then
    echo "WARN: active_reviewers empty — Plan 08 label gate skip" >&2
    exit 5
fi

# ── Phase 2 prep: read label_authority (unused in Phase 1) ────────────────
# label_authority="skill"    → LLM (SKILL.md Step 4-8) attaches labels (Phase 1 default)
# label_authority="actions"  → GitHub Actions auto-attaches labels (Phase 2)
# Phase 1 reads this field for forward-compatibility but does NOT branch on it.
_LABEL_AUTHORITY=$(echo "$MERGED_CONFIG" | jq -r '.active_reviewers | to_entries[0].value.label_authority // "skill"')

# ── polling loop ──────────────────────────────────────────
iter=0
while true; do
    # fetch current labels — exit 4 on auth/access failure (not just "gh not installed")
    if ! LABELS=$(gh pr view "${GH_REPO_FLAG[@]+"${GH_REPO_FLAG[@]}"}" "$PR_NUM" --json labels --jq '.labels[].name' 2>/tmp/poll-labels-gh-err); then
        GH_ERR=$(cat /tmp/poll-labels-gh-err 2>/dev/null || true)
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
            disabled=$(echo "$MERGED_CONFIG" | jq -r --arg k "$reviewer" '.active_reviewers[$k]._disabled // "false"')
            if [[ "$disabled" == "true" ]]; then
                continue  # intentionally disabled
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
