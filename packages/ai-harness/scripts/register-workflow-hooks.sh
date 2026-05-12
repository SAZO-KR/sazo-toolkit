#!/bin/bash
# register-workflow-hooks.sh — workflow enforcement hook을 settings.json에 등록.
#
# install.sh와 auto-update.sh 양쪽에서 source한다. Idempotent.
# 등록 hook:
#   - PreToolUse: pre-worktree-gate, pre-exploration-gate, workflow-state-machine pre
#   - PostToolUse: workflow-state-machine post
#
# 매개변수: $1 = HARNESS_DIR, $2 = SETTINGS_FILE

register_workflow_hooks() {
    local harness_dir="$1" settings_file="$2"
    local hooks_dir="$harness_dir/scripts/hooks"

    if [ ! -d "$hooks_dir" ]; then
        return 0
    fi

    # chmod +x for all hook scripts
    chmod +x "$hooks_dir"/*.sh 2>/dev/null || true
    chmod +x "$hooks_dir/lib"/*.sh 2>/dev/null || true

    _register_one_hook() {
        local event="$1" matcher="$2" script="$3" arg="${4:-}"
        local cmd
        if [ -n "$arg" ]; then
            cmd="$script $arg"
        else
            cmd="$script"
        fi

        # Stale path dedup: 같은 script basename + 다른 absolute path → 제거.
        # harness 위치 변경(~/.config → ~/work 등) 시 old entry 누적 방지.
        local script_basename
        script_basename=$(basename "$script")
        local stale_count
        stale_count=$(jq --arg b "$script_basename" --arg cur "$cmd" --arg ev "$event" \
            '(.hooks[$ev] // [])
             | map(.hooks // [] | map(.command) | .[])
             | map(select(endswith("/" + $b) and . != $cur))
             | length' "$settings_file")
        if [ "$stale_count" -gt 0 ]; then
            local tmp
            tmp=$(mktemp)
            jq --arg b "$script_basename" --arg cur "$cmd" --arg ev "$event" \
                '.hooks[$ev] = ((.hooks[$ev] // [])
                    | map(.hooks |= map(select(.command == $cur or (.command | endswith("/" + $b) | not)))))
                    | .hooks[$ev] |= map(select(.hooks | length > 0))
                ' "$settings_file" > "$tmp" && mv "$tmp" "$settings_file"
            echo "  Workflow hook ($event $matcher): stale path entries pruned ($stale_count)"
        fi

        local existing
        existing=$(jq --arg cmd "$cmd" --arg ev "$event" \
            '(.hooks[$ev] // []) | map(select(.hooks // [] | any(.command == $cmd))) | length' \
            "$settings_file")

        if [ "$existing" -gt 0 ]; then
            local cur
            cur=$(jq -r --arg cmd "$cmd" --arg ev "$event" \
                '(.hooks[$ev] // []) | map(select(.hooks // [] | any(.command == $cmd))) | .[0].matcher // ""' \
                "$settings_file")
            if [ "$cur" = "$matcher" ]; then
                return 0
            fi
            local tmp
            tmp=$(mktemp)
            jq --arg cmd "$cmd" --arg m "$matcher" --arg ev "$event" '
                .hooks[$ev] = ((.hooks[$ev] // []) | map(
                    if (.hooks // [] | any(.command == $cmd)) then .matcher = $m else . end
                ))
            ' "$settings_file" > "$tmp" && mv "$tmp" "$settings_file"
            echo "  Workflow hook ($event $matcher): matcher migrated"
        else
            local entry tmp
            if [ -z "$matcher" ]; then
                # matcher 없는 hook (UserPromptSubmit, SessionStart 등)
                entry=$(jq -n --arg cmd "$cmd" '{
                    "hooks": [{"type": "command", "command": $cmd}]
                }')
            else
                entry=$(jq -n --arg cmd "$cmd" --arg m "$matcher" '{
                    "matcher": $m,
                    "hooks": [{"type": "command", "command": $cmd}]
                }')
            fi
            tmp=$(mktemp)
            jq --argjson entry "$entry" --arg ev "$event" \
                '.hooks[$ev] = (.hooks[$ev] // []) + [$entry]' \
                "$settings_file" > "$tmp" && mv "$tmp" "$settings_file"
            echo "  Workflow hook ($event ${matcher:-*}): registered"
        fi
    }

    # 1) pre-worktree-gate — Write/Edit/NotebookEdit/Bash
    _register_one_hook "PreToolUse" "Write|Edit|NotebookEdit|Bash" \
        "$hooks_dir/pre-worktree-gate.sh"

    # 2) pre-exploration-gate — Grep/Glob/Bash (Opus 세션 내부 필터)
    # Plan 14: Glob 추가. 메인 Opus가 Glob으로 직접 파일 탐색 시 카운트.
    _register_one_hook "PreToolUse" "Grep|Glob|Bash" \
        "$hooks_dir/pre-exploration-gate.sh"

    # 2b) pre-task-general-purpose-gate — Task (Plan 14)
    # general-purpose subagent 호출 시 soft warn (Opus 부모 inherit 비용 알림).
    _register_one_hook "PreToolUse" "Task" \
        "$hooks_dir/pre-task-general-purpose-gate.sh"

    # 3) workflow-state-machine pre — Task/Write/Edit/NotebookEdit/Bash
    # Task 추가: Plan 04 §6 (B) GH#34692 fallback — subagent 내부 Edit/Write/Bash가
    # parent hook을 미발동하므로, mutating subagent(plan-executor/ui-engineer) Task
    # PreToolUse 시점에 ci_passed_at preemptive invalidate. 매처에 Task 빠지면
    # 해당 분기가 실제 설치 환경에서 절대 발동하지 않아 GH#34692 방어가 무력화됨.
    _register_one_hook "PreToolUse" "Task|Write|Edit|NotebookEdit|Bash" \
        "$hooks_dir/workflow-state-machine.sh" "pre"

    # 4) workflow-state-machine post — Task/Bash/Edit/Write/NotebookEdit
    # Edit/Write/NotebookEdit 추가는 Plan 04 — ci_passed_at invalidate 트리거.
    _register_one_hook "PostToolUse" "Task|Bash|Edit|Write|NotebookEdit" \
        "$hooks_dir/workflow-state-machine.sh" "post"

    # 5) user-prompt-approval-detect — UserPromptSubmit (matcher 없음)
    _register_one_hook "UserPromptSubmit" "" \
        "$hooks_dir/user-prompt-approval-detect.sh"

    # 6) post-session-end-metrics — SessionEnd (matcher 없음)
    # SAZO_DISABLE_SESSION_END_HOOK=1 시 등록 skip.
    if [ "${SAZO_DISABLE_SESSION_END_HOOK:-0}" != "1" ] \
        && [ -f "$hooks_dir/post-session-end-metrics.sh" ]; then
        chmod +x "$hooks_dir/post-session-end-metrics.sh" 2>/dev/null || true
        _register_one_hook "SessionEnd" "" \
            "$hooks_dir/post-session-end-metrics.sh"
    fi

    # 7) post-task-output-audit — PostToolUse Task matcher (Stage A')
    # SAZO_DISABLE_TASK_OUTPUT_AUDIT=1 시 등록 skip.
    if [ "${SAZO_DISABLE_TASK_OUTPUT_AUDIT:-0}" != "1" ] \
        && [ -f "$hooks_dir/post-task-output-audit.sh" ]; then
        chmod +x "$hooks_dir/post-task-output-audit.sh" 2>/dev/null || true
        _register_one_hook "PostToolUse" "Task" \
            "$hooks_dir/post-task-output-audit.sh"
    fi

    unset -f _register_one_hook
}
