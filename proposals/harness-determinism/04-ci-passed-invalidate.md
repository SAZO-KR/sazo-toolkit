# 04. ci_passed_at Invalidation

**우선순위**: P1
**의존**: 없음 (단, 기존 `simple_audit` helper 활용 — Plan 02 audit_log 도입 전까지 임시)
**예상 비용**: 0.5주
**결정성 이동**: 🟡 → 🟢 (CI 통과 후 mutating 변경 신뢰를 코드로 검증)

## 목표

CI 통과 timestamp(`ci_passed_at`)가 PR 생성까지 영구 유효한 현 동작 수정. CI 통과 후 코드가 mutating 변경되면 invalidate → PR 생성 전 CI 재실행 강제.

## 현재 상태 / 문제

`session-state.sh` schema에 `ci_passed_at` 필드 (PostToolUse Bash hook이 set, `workflow-state-machine.sh:168`).

문제: CI 통과 → 추가 commit → push 시퀀스에서 새 변경이 깨졌을 수 있는데 ci stage는 이미 "통과"로 표시 → PR 생성 hook을 통과.

## 제안

### 1. Mutating 파일 분류 helper

`packages/ai-harness/scripts/hooks/lib/session-state.sh` 끝부분에 추가:

```bash
# ----- ci invalidate helpers -----

# _is_doc_only_path: 문서/마크다운 전용 경로면 0 (skip 대상). 패턴 우선:
# *.md 또는 path segment에 docs/ 가 들어가면 docs로 본다.
# 호출자는 _is_doc_only_path 먼저 평가 → true면 invalidate skip.
_is_doc_only_path() {
    case "$1" in
        *.md) return 0 ;;
        docs/*|*/docs/*) return 0 ;;
        *) return 1 ;;
    esac
}

# _is_code_file: 코드/설정 파일이면 0. doc 우선 평가 후 사용.
# Lockfile은 코드 취급 (CI 영향), README는 _is_doc_only_path가 먼저 잡음.
_is_code_file() {
    case "$1" in
        *.go|*.ts|*.tsx|*.js|*.jsx|*.mjs|*.cjs|*.py|*.rs|*.sh) return 0 ;;
        *.bash|*.zsh|*.rb|*.java|*.kt|*.swift|*.c|*.h|*.cpp|*.hpp) return 0 ;;
        *.json|*.yml|*.yaml|*.toml|*.ini|*.lock|*.sum) return 0 ;;
        Dockerfile|*/Dockerfile|Makefile|*/Makefile) return 0 ;;
        *) return 1 ;;
    esac
}

# ci_invalidate_if_code_changed <sid> <cwd> <file_path> [source]
# Pure helper — 외부에서 호출. 내부에서 stage_is_passed 평가 후
# ci_passed_at != null일 때만 null로 설정 + audit log.
# `source` 인자 (기본 "edit")는 audit 메시지에 들어감 — `git_commit` 같은
# defense layer를 분리해 추적.
ci_invalidate_if_code_changed() {
    local sid="$1" cwd="$2" path="$3" src="${4:-edit}"
    [ -z "$path" ] && return 0
    if _is_doc_only_path "$path"; then
        return 0
    fi
    if ! _is_code_file "$path"; then
        return 0
    fi
    # SAZO_DISABLE_CI_INVALIDATE=1 → 우회 (rollback knob)
    [ "${SAZO_DISABLE_CI_INVALIDATE:-0}" = "1" ] && return 0

    local cur
    cur=$(state_get "$sid" ".ci_passed_at" "$cwd")
    [ -z "$cur" ] || [ "$cur" = "null" ] && return 0

    state_set_json "$sid" ".ci_passed_at" "null" "$cwd" || return 1
    simple_audit "ci_invalidated" "src=$src" "path=$path" "sid=$sid"
}
```

기준: `_is_doc_only_path` 가 먼저 평가됨 — `docs/build/foo.go` 처럼 docs 경로면 invalidate skip (Risk R2 완화). 그 외에 `_is_code_file` 매치 시 invalidate.

### 2. PostToolUse Edit/Write/NotebookEdit 분기 추가

`workflow-state-machine.sh` 의 `handle_post()` `case` 에 추가:

```bash
Edit|Write|NotebookEdit)
    local file_path
    file_path=$(echo "$SAZO_TOOL_INPUT" | jq -r '.file_path // .notebook_path // ""')
    ci_invalidate_if_code_changed "$SAZO_SESSION_ID" "$SAZO_CWD" "$file_path" "edit"
    ;;
```

`register-workflow-hooks.sh` 의 PostToolUse matcher 에도 `Write|Edit|NotebookEdit` 추가 (기존 `Task|Bash` → `Task|Bash|Write|Edit|NotebookEdit`).

### 3. PreToolUse `git commit` defense layer

문제: `sed -i`, `git apply` 같은 mutating Bash가 후속 commit으로 들어가면 invalidate 누락. 해결: PreToolUse Bash 에서 `git commit` 검출 시 staged 코드 파일 있으면 invalidate.

`workflow-state-machine.sh handle_pre()` Bash 분기에 추가 (gh pr create 검사 **위**):

```bash
# git commit defense — staged code 있으면 ci invalidate
if echo "$cmd" | grep -qE '(^|[[:space:]&|;()])git[[:space:]]+commit\b'; then
    if [ "${SAZO_DISABLE_CI_INVALIDATE:-0}" != "1" ]; then
        local cur
        cur=$(state_get "$SAZO_SESSION_ID" ".ci_passed_at" "$SAZO_CWD")
        if [ -n "$cur" ] && [ "$cur" != "null" ]; then
            local repo_root
            repo_root=$(git -C "$SAZO_CWD" rev-parse --show-toplevel 2>/dev/null)
            if [ -n "$repo_root" ]; then
                # diff-filter ACMR: added/copied/modified/renamed (deleted 제외)
                local has_code=0
                while IFS= read -r f; do
                    [ -z "$f" ] && continue
                    if _is_doc_only_path "$f"; then continue; fi
                    if _is_code_file "$f"; then has_code=1; break; fi
                done < <(git -C "$repo_root" diff --cached --name-only --diff-filter=ACMR 2>/dev/null)
                if [ "$has_code" = "1" ]; then
                    state_set_json "$SAZO_SESSION_ID" ".ci_passed_at" "null" "$SAZO_CWD" || true
                    simple_audit "ci_invalidated" "src=git_commit" "sid=$SAZO_SESSION_ID"
                fi
            fi
        fi
    fi
    # commit 자체는 차단 안 함 — invalidate만 수행하고 fall-through
fi
```

이 layer는 `git commit` 자체는 block 안 하고 invalidate만 부수 효과로 수행. PR 생성 시점에 ci stage 미통과로 잡힘.

### 4. `stage_is_passed "ci"` AND 조건 추가

`session-state.sh` line 299-307 `ci)` 분기 변경:

```jq
.history | any(
    .stage == "ci"
    and ((.status == "completed" and (.by == "user" or .by == "auto"))
        or (.status == "skipped" and .by == "user"))
)
and ((.ci_passed_at != null) or (.history | any(.stage == "ci" and .status == "skipped" and .by == "user")))
```

핵심: completed-by-auto/user는 `ci_passed_at != null` 도 동시에 만족해야 통과. user-skipped 는 ci_passed_at 무관 (사용자 명시 override 경로 보존).

**Backward compat**: 기존 state file에 `ci_passed_at` 키 없는 케이스 — `jq` `.ci_passed_at` 은 missing key를 `null` 로 평가. AND 조건 false 처리되므로 **invalidated state와 동일하게 다룸**. legacy 통과 케이스를 살리려면 history에 `auto/user completed` 가 있고 `ci_passed_at` 키 자체가 absent (즉 null) 인 상태를 별도 통과시켜야 하지만, 본 plan은 **Phase 1 부터 strict 적용** — 워크플로우 hook 자체가 opt-in alpha (`SAZO_WORKFLOW_HOOKS_ENABLED=1`) 이며 hook 비활성 사용자는 영향 없음.

### 5. 재CI 후 ci_passed_at 재set

기존 PostToolUse Bash CI exit 0 detection 그대로. 재실행 → ci_passed_at 재 set + history 재 mark.

기존 코드 (`workflow-state-machine.sh:164-174`):
```bash
if [ "$exit_code" = "0" ] && _is_full_ci_command "$cmd"; then
    if ! stage_is_passed "$SAZO_SESSION_ID" "ci"; then
        if state_set_str "$SAZO_SESSION_ID" ".ci_passed_at" "$(date +...)"; then
            stage_mark "$SAZO_SESSION_ID" "ci" "completed" "auto" "ci-cmd matched"
        ...
```

`stage_is_passed "ci"` 가 invalidated state에서 false 리턴 → 재 set + 재 mark 동작. 추가 변경 없음.

### 6. GH #34692 fallback (subagent 내부 mutation)

스파이크 결과: subagent 가 Edit/Write/Bash 호출 → parent hook fire 안 함. 따라서 subagent가 코드 mutating 해도 ci_passed_at 자동 invalidate 발동 안 됨.

다단 fallback:

**A) Agent tool whitelist 감사 (이 plan 범위 안)**
`packages/ai-harness/agents/*.md` 의 `tools:` 필드 audit 결과:

| agent | tools | mutating? |
|---|---|---|
| architect-advisor | Read, Glob, Grep | no |
| code-reviewer | Read, Grep, Glob | no |
| code-searcher | Glob, Grep, Read | no |
| docs-researcher | WebSearch, WebFetch, Read, Grep, Glob, mcp_context7_* | no |
| image-analyzer | Read, WebFetch | no |
| plan-auditor | Read, Glob, Grep | no |
| plan-critic | Read, Glob, Grep | no |
| plan-drafter | Read, Glob, Grep, WebFetch | no |
| **doc-writer** | Read, **Write, Edit**, Glob, Grep, WebFetch | docs-only by design (skip 가능) |
| **plan-executor** | Read, **Edit, Write**, Glob, Grep, Bash | **yes** |
| **ui-engineer** | Read, **Edit, Write**, Glob, Grep, Bash | **yes** |

별도 enforcement 변경은 하지 않음 (별도 plan 13 참조).

**B) PreToolUse Task preemptive invalidate (이 plan 범위 안)**
`workflow-state-machine.sh handle_pre()` 에 Task 분기 추가:

```bash
Task)
    if [ "${SAZO_DISABLE_CI_INVALIDATE:-0}" != "1" ]; then
        local subagent_type cur
        subagent_type=$(echo "$SAZO_TOOL_INPUT" | jq -r '.subagent_type // ""')
        cur=$(state_get "$SAZO_SESSION_ID" ".ci_passed_at" "$SAZO_CWD")
        if [ -n "$cur" ] && [ "$cur" != "null" ]; then
            case "$subagent_type" in
                # 코드 mutating 가능성 있는 agent (위 audit 표 기반)
                plan-executor|ui-engineer)
                    state_set_json "$SAZO_SESSION_ID" ".ci_passed_at" "null" "$SAZO_CWD" || true
                    simple_audit "ci_invalidated" "src=task_preemptive" "agent=$subagent_type" "sid=$SAZO_SESSION_ID"
                    ;;
            esac
        fi
    fi
    ;;
```

근거: 위 list 의 agent는 Edit/Write 권한 보유 또는 mutating intent를 가지는 agent. Task 호출 자체가 발견될 때 (parent hook은 fire) preemptive 처리. Pure read-only agent (`code-searcher`, `docs-researcher`) 는 invalidate 안 함.

**C) commit defense layer (이미 §3)**
subagent 내부 Bash 가 mutating 해도 Claude main 이 결국 `git commit` 호출 시점에 §3 layer 가 staged 코드 검출.

이 3중 fallback으로 GH #34692 영향 완화 — 100% deterministic 은 아니지만 (claude main 이 commit 안 하고 push 까지 자체 호출하면 §3 우회 가능), 가장 흔한 경로 (subagent edit → main commit) 는 차단.

## 변경 파일

```
packages/ai-harness/scripts/hooks/lib/session-state.sh
  - _is_doc_only_path/_is_code_file/ci_invalidate_if_code_changed helper 추가
  - stage_is_passed "ci" jq AND 조건 추가
packages/ai-harness/scripts/hooks/workflow-state-machine.sh
  - PostToolUse Edit/Write/NotebookEdit 분기 추가
  - PreToolUse Bash git commit defense layer 추가
  - PreToolUse Task preemptive invalidate (subagent fallback)
packages/ai-harness/scripts/register-workflow-hooks.sh
  - PostToolUse matcher 에 Write|Edit|NotebookEdit 추가
packages/ai-harness/scripts/tests/ci-invalidate.smoke.sh  (신규)
CLAUDE.md (project)
  - ai-harness CI 행에 ci-invalidate.smoke.sh 추가
```

## State schema 변경

기존 `ci_passed_at` 그대로 사용. 추가 필드 없음.

`ci_passed_at` semantics 변경:
- 기존: "마지막 CI 통과 시각, 한 번 set되면 영구"
- 변경: "마지막 CI 통과 후 코드 변경 없는 상태의 timestamp. 코드 변경 발생 시 null."

## Test plan (`ci-invalidate.smoke.sh`)

신규 smoke test 10+ 케이스:

1. CI 통과 모킹 → `ci_passed_at` set + `stage_is_passed ci` true
2. CI 통과 후 `*.go` Edit PostToolUse → `ci_passed_at` null + `stage_is_passed ci` false
3. CI 통과 후 `README.md` Edit → `ci_passed_at` 유지 (skip)
4. CI 통과 후 `package.json` Edit → null
5. CI 통과 후 `docs/foo.go` Edit → 유지 (docs 경로 우선)
6. CI 통과 후 Write `/tmp/x/handler.ts` → null
7. CI 통과 후 NotebookEdit `notebook.ipynb` (`.ipynb` not in code list) → 유지 (현 정책: noop) — assertion 명시
8. Invalidate 후 `gh pr create` PreToolUse → exit 2 (block)
9. CI 재실행 (full ci command Bash post + exit_code=0) → ci_passed_at 재 set + PR create 통과
10. `git commit` PreToolUse + staged 코드파일 + ci_passed_at!=null → invalidate (commit 자체는 block 안 함 → exit 0)
11. `git commit` + staged docs only (README.md) → ci_passed_at 유지
12. `git commit` 명령이지만 staged 비어 있음 → ci_passed_at 유지
13. PreToolUse Task `subagent_type=plan-executor` + ci_passed_at!=null → invalidate
14. PreToolUse Task `subagent_type=code-searcher` (read-only) → 유지
15. SAZO_DISABLE_CI_INVALIDATE=1 → 모든 case 에서 ci_passed_at 유지
16. user-skipped ci stage (SAZO_ALLOW_CI_SKIP) → ci_passed_at null 이어도 stage_is_passed true (override 경로 보존)
17. Audit log 형식 검증 (`ci_invalidated src=...` 패턴 grep)

## Open questions

1. `.ipynb` 코드 취급할지 — 현재 plan은 `_is_code_file` 미포함, NotebookEdit invalidate 안 됨. 향후 Jupyter 사용 늘면 추가.
2. `package-lock.json`, `go.sum` 같은 lockfile은 `*.lock`/`*.sum` 으로 코드 취급. OK.
3. user-skipped ci 후 코드 변경 시 invalidate? 현재 plan 은 `ci_invalidate_if_code_changed` 가 `ci_passed_at` 만 보므로 user-skip 후에도 정확히 invalidate 안 함 (의도). user 명시 override 가 더 강한 신호.

## Risk

- **R1 (med)**: `_is_code_file` false negative (새 확장자) → invalidate 안 됨 → CI 깨진 상태로 PR 가능. 완화: 알려진 확장자 list 충분히 커버 + 사용자 SAZO_DISABLE_CI_INVALIDATE escape hatch.
- **R2 (low)**: `_is_doc_only_path` false positive (`docs/build/output.go`) → invalidate 누락. 완화: 패턴 우선순위 (`_is_doc_only_path` 먼저), 명시 의도 (docs 경로는 코드라도 docs 취급).
- **R3 (low)**: 사용자 frustration — "CI 다시 돌려야 하나" 답답함. 완화: 의도된 동작, CLAUDE.md MANAGED BLOCK 에 명시.
- **R4 (med)**: GH #34692 — subagent 내부 mutation 미감지. 완화: §6 의 3중 fallback (whitelist audit + Task preemptive + commit defense). 100% 결정적 아님 (예: subagent가 직접 push까지) 하지만 흔한 경로 차단.

## Rollback

- `SAZO_DISABLE_CI_INVALIDATE=1` env로 새 분기 우회 (invalidate skip). hook은 정상 동작.
- helper 함수 정의 revert 시 stage_is_passed AND 조건은 그대로 → 기존 state file 도 ci_passed_at!=null 유지하므로 영향 없음.

## Acceptance criteria

- [ ] `_is_code_file` / `_is_doc_only_path` / `ci_invalidate_if_code_changed` helper 추가
- [ ] PostToolUse Edit/Write/NotebookEdit 코드 파일 변경 시 ci_passed_at null
- [ ] Docs-only Edit는 invalidate 안 함
- [ ] `git commit` PreToolUse 가 staged 코드 있으면 invalidate (commit 자체는 통과)
- [ ] PreToolUse Task subagent_type=plan-executor/ui-engineer/... → preemptive invalidate
- [ ] `stage_is_passed "ci"` 가 ci_passed_at null이면 false (user-skipped 경로 제외)
- [ ] PR create hook이 invalidated 상태에서 block
- [ ] 재CI → set → PR create 가능
- [ ] register-workflow-hooks.sh PostToolUse matcher 에 Write|Edit|NotebookEdit 추가
- [ ] Smoke test 10+ 통과
- [ ] CLAUDE.md ai-harness CI 행에 ci-invalidate.smoke.sh 등록
- [ ] Agent tool audit 결과 plan 본문에 명시 (Edit/Write 가진 agent 목록)
