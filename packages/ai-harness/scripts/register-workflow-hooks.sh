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

    unset -f _register_one_hook
}
