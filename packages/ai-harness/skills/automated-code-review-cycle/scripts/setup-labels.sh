#!/usr/bin/env bash
# setup-labels.sh — Plan 08: create/update bot-review labels on the GitHub repo.
#
# Usage: setup-labels.sh [--config <path>] [--repo-dir <path>]
#
# --repo-dir: path to the git repo root. When .github/sazo-bot-review.json
#   exists, its active_reviewers override (including custom label_prefix values)
#   is merged before creating labels — ensuring setup and polling use the same
#   label names. Without --repo-dir, only the base config is used.
#
# Idempotent via --force (create or update). Safe to call on every ROUND==1.
# Skips reviewers with enabled=false (schema v2; formerly _disabled=true).
#
# Exit codes:
#   0 — success
#   1 — error

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_CONFIG="$(cd "$SCRIPT_DIR/.." && pwd)/config.json"

# ── argument parsing ──────────────────────────────────────
CONFIG_PATH="$DEFAULT_CONFIG"
REPO_DIR=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --config)   CONFIG_PATH="$2"; shift 2 ;;
        --repo-dir) REPO_DIR="$2"; shift 2 ;;
        *) shift ;;
    esac
done

if [[ ! -f "$CONFIG_PATH" ]]; then
    echo "ERROR: config not found: $CONFIG_PATH" >&2
    exit 1
fi

# ── load + merge config (same logic as poll-labels.sh) ───────────────────────
# CRITICAL: merge repo override so custom label_prefix values produce the same
# label names that the poller waits for. Without this, setup creates default
# labels while the poller (and Step 4-8) uses custom-prefix labels → gh issue
# edit --add-label fails because the label doesn't exist.
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

# ── extract fields ─────────────────────────────────────────
OVERRIDE_LABEL=$(echo "$MERGED_CONFIG" | jq -r '.override_label // "bot-review/override"')

# ── resolve -R OWNER/REPO from REPO_DIR (or cwd fallback) ────────────────────
# CRITICAL: gh label commands resolve the repo from cwd by default. When called
# from a harness directory that differs from the target checkout (REPO_DIR), labels
# are created in the wrong repo or gh fails with "not a git repository".
# Derive the slug explicitly from REPO_DIR so this script is cwd-independent.
GH_REPO_FLAG=()
if [[ -n "$REPO_DIR" ]]; then
    _remote_url=$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null || true)
    if [[ -n "$_remote_url" ]]; then
        # Strip protocol/host, trailing .git — keep OWNER/REPO
        _slug=$(echo "$_remote_url" | sed -E 's|.*github\.com[:/]||; s|\.git$||')
        [[ -n "$_slug" ]] && GH_REPO_FLAG=(-R "$_slug")
    fi
fi

# ── create labels per active reviewer × suffix ────────────
# Iterate over reviewers
echo "$MERGED_CONFIG" | jq -c '.active_reviewers | to_entries[]' | while IFS= read -r entry; do
    reviewer_key=$(echo "$entry" | jq -r '.key')
    enabled=$(echo "$entry" | jq -r '.value.enabled // true')
    if [[ "$enabled" == "false" ]]; then
        continue
    fi
    prefix=$(echo "$entry" | jq -r '.value.label_prefix')

    # Iterate over label suffixes
    echo "$MERGED_CONFIG" | jq -c '.labels | to_entries[]' | while IFS= read -r lentry; do
        suffix=$(echo "$lentry" | jq -r '.value.suffix')
        color=$(echo "$lentry" | jq -r '.value.color')
        label_name="${prefix}${suffix}"
        gh label create "${GH_REPO_FLAG[@]+"${GH_REPO_FLAG[@]}"}" "$label_name" -c "$color" -d "Plan 08: bot-review label" --force
    done
done

# ── create override label ─────────────────────────────────
gh label create "${GH_REPO_FLAG[@]+"${GH_REPO_FLAG[@]}"}" "$OVERRIDE_LABEL" -c "1d76db" -d "Plan 08: manual override" --force
