# 04. ci_passed_at Invalidation

**우선순위**: P1
**의존**: 없음
**예상 비용**: 0.5주
**결정성 이동**: 🟡 → 🟢 (CI 통과 후 mutating 변경 신뢰를 코드로 검증)

## 목표

CI 통과 timestamp(`ci_passed_at`)가 PR 생성까지 영구 유효한 현 동작 수정. CI 통과 후 코드가 mutating 변경되면 invalidate → PR 생성 전 CI 재실행 강제.

## 현재 상태 / 문제

`session-state.sh` schema에 `ci_passed_at` 필드 (PostToolUse Bash hook이 set, `workflow-state-machine.sh:139`).

문제: CI 통과 → 추가 commit → push 시퀀스에서 새 변경이 깨졌을 수 있는데 ci stage는 이미 "통과"로 표시 → PR 생성 hook을 통과.

## 제안

### 1. Mutating tool 정의 helper

`packages/ai-harness/scripts/lib/session-state.sh` 추가:

```bash
_is_code_file() {
  local path="$1"
  case "$path" in
    *.go|*.ts|*.tsx|*.js|*.jsx|*.py|*.rs|*.sh) return 0;;
    *.bash|*.zsh|*.rb|*.java|*.kt|*.swift) return 0;;
    *.json|*.yml|*.yaml|*.toml) return 0;;  # config도 코드로 취급
    *) return 1;;
  esac
}

_is_doc_only_path() {
  # docs.md, README.md, CLAUDE.md, *.md (위 _is_code_file에서 *.json 등은 코드)
  case "$1" in
    *.md|docs/*|*/docs/*) return 0;;
    *) return 1;;
  esac
}
```

기준: 코드 파일 변경만 invalidate. 순수 docs/README는 invalidate skip.

### 2. PostToolUse Edit/Write hook 추가 분기

`workflow-state-machine.sh` 의 `_handle_post` Edit/Write/NotebookEdit 분기에 추가:

```bash
if [[ "$tool_name" =~ ^(Edit|Write|NotebookEdit)$ ]]; then
  file_path=$(jq -r '.tool_input.file_path' <<<"$payload")
  if _is_code_file "$file_path" && ! _is_doc_only_path "$file_path"; then
    if state_get_str ".ci_passed_at" != "null"; then
      state_set_json ".ci_passed_at" "null"
      audit_log "ci_invalidated" "code_file_modified" "$file_path"
    fi
  fi
fi
```

### 3. Bash mutating 검출

문제: `git status`, `ls`, `cat` 같은 read-only Bash가 invalidate triggering 하면 안 됨.

해결: PostToolUse Bash가 invalidate하지 않음. 이유:
- Bash로 파일 변경하는 케이스 (`sed`, `mv` 등) 드뭄. 주로 Edit/Write 사용.
- Bash 명령 패턴 매치는 false positive 위험 큼.
- 만약 `git apply`, `sed -i` 같은 mutating Bash가 있으면 → 그 후속 Edit/Write 또는 commit 시점에 detect 가능.

대안: `git commit` PreToolUse hook에서 staged 파일 중 코드 파일 있고 `ci_passed_at != null`이면 invalidate. (방어 layer 1추가, 구현 단순)

### 4. ci stage history 보존

**Append-only invariant 유지**: `ci_passed_at` field만 null로. history 배열의 ci entry는 그대로 (audit trail).

`stage_is_passed "ci"` 평가 (`session-state.sh:286-292`)에 추가 조건:
```
.history[] | select(.stage=="ci" AND status=="completed" AND by∈{"user","auto"})
AND .ci_passed_at != null   ← 신규 조건
```

null이면 history에 entry 있어도 미통과로 평가.

### 5. 재CI 후 ci_passed_at 재set

기존 PostToolUse Bash CI exit 0 detection 그대로. 재실행 → ci_passed_at 다시 set.

## 변경 파일

```
packages/ai-harness/scripts/lib/session-state.sh    (_is_code_file/_is_doc_only_path helper, ci_passed_at AND 조건)
packages/ai-harness/scripts/hooks/workflow-state-machine.sh  (PostToolUse Edit/Write 분기 추가, git commit pre)
packages/ai-harness/scripts/tests/ci-invalidate.smoke.sh  (신규)
~/.claude/CLAUDE.md MANAGED BLOCK   (CI 후 코드 변경 시 재실행 강제 명시)
```

## State schema 변경

기존 `ci_passed_at` 그대로 사용. 추가 필드 없음.

`ci_passed_at` semantics 변경:
- 기존: "마지막 CI 통과 시각, 한 번 set되면 영구"
- 변경: "마지막 CI 통과 후 코드 변경 없는 상태의 timestamp. 코드 변경 발생 시 null."

## Test plan

`ci-invalidate.smoke.sh`:

1. CI 통과 → `ci_passed_at` set 확인
2. CI 통과 후 `*.go` Edit → `ci_passed_at` null
3. CI 통과 후 `README.md` Edit → `ci_passed_at` 유지 (skip)
4. CI 통과 후 `package.json` Edit → null (config 코드 취급)
5. CI 통과 후 docs/foo.md Edit → 유지
6. Invalidate 후 `gh pr create` PreToolUse → block (ci 미통과)
7. CI 재실행 → 다시 set → PR create 통과
8. Audit log entry 형식 검증
9. `git commit` PreToolUse + ci_passed_at != null + 코드 파일 staged → invalidate
10. Edit이 NotebookEdit, Write 모두 동일 동작

## Open questions

1. `_is_code_file` 패턴 list 확장성 — 새 언어 추가 시? CLAUDE.md에서 패턴 읽기? (out-of-scope, 향후 plan)
2. `package-lock.json`, `go.sum` 같은 lockfile은 코드인가 docs인가? 제안: 코드 (CI 영향).
3. 사용자가 일부러 docs만 수정한 PR 만들 때 ci 자동 통과 표시 유지 → 옳은 동작?

## Risk

- **R1 (med)**: `_is_code_file` false negative (새 확장자) → invalidate 안 됨 → CI 깨진 상태로 PR 가능. 완화: 알려진 확장자 list 충분히 커버, fallback "확장자 모르면 invalidate" 검토.
- **R2 (low)**: `_is_doc_only_path` false positive (docs/build/output.go 같은 경로) → invalidate 누락. 완화: 패턴 우선순위 (`_is_code_file` 먼저).
- **R3 (low)**: 사용자 frustration — "CI 다시 돌려야 하나" 답답함. 완화: 의도된 동작, CLAUDE.md에 명시.

## Rollback

- `SAZO_DISABLE_CI_INVALIDATE=1` env로 새 분기 우회
- `_is_code_file` 정의 revert → 기존 동작 복구

## Acceptance criteria

- [ ] `_is_code_file` / `_is_doc_only_path` helper 추가
- [ ] PostToolUse Edit/Write/NotebookEdit이 코드 파일 변경 시 ci_passed_at null
- [ ] Docs-only Edit는 invalidate 안 함
- [ ] `stage_is_passed "ci"`가 ci_passed_at null이면 false 반환
- [ ] PR create hook이 invalidated 상태에서 block
- [ ] 재CI → set → PR create 가능
- [ ] Smoke test 10개 통과
- [ ] CLAUDE.md 정책 명시
