#!/usr/bin/env bash
# Shared helpers for automated-code-review-cycle scripts.

merge_review_config() {
    local config_path="$1"
    local repo_dir="${2:-}"
    local repo_override=""

    if [[ -n "$repo_dir" && -f "$repo_dir/.github/sazo-bot-review.json" ]]; then
        repo_override="$repo_dir/.github/sazo-bot-review.json"
    fi

    if [[ -n "$repo_override" ]]; then
        # Deep-merge reviewer fields so partial repo overrides keep base fields
        # such as bot_login, while labels/polling keep their existing shape.
        jq -n \
            --slurpfile base "$config_path" \
            --slurpfile ovr "$repo_override" \
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
            '
    else
        jq '.' "$config_path"
    fi
}

repo_slug_from_remote_url() {
    local remote_url="$1"
    local slug

    # Accept common GitHub remote forms, including GHE hosts, and always strip
    # the optional .git suffix before validating the OWNER/REPO slug.
    slug=$(printf '%s' "$remote_url" \
        | sed -E \
            -e 's|^git@[^:]+:||' \
            -e 's|^ssh://git@[^/]+/||' \
            -e 's|^[A-Za-z][A-Za-z0-9+.-]*://[^/]+/||' \
            -e 's|\.git$||')

    if [[ "$slug" =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]]; then
        printf '%s' "$slug"
    fi
}

resolve_repo_slug() {
    local repo_dir="${1:-.}"
    local repo_slug remote_url

    repo_slug=$(cd "$repo_dir" && gh repo view --json owner,name -q '.owner.login + "/" + .name' 2>/dev/null) || true
    if [[ -n "$repo_slug" ]]; then
        printf '%s' "$repo_slug"
        return 0
    fi

    remote_url=$(git -C "$repo_dir" remote get-url origin 2>/dev/null || true)
    repo_slug=$(repo_slug_from_remote_url "$remote_url")
    if [[ -n "$repo_slug" ]]; then
        printf '%s' "$repo_slug"
        return 0
    fi

    return 0
}
