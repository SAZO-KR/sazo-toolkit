# 07. Test Edits Counter (Warn Only)

**우선순위**: P2
**의존**: 없음
**예상 비용**: 0.5주
**결정성 이동**: 🟡 → 🟡+ (LLM 자율 + 코드 신호)

## 목표

`develop` SKILL이 권하는 TDD를 hook이 강제하진 않되, src 변경 vs test 변경 비율을 카운팅. CI gate 시점 또는 review subagent에 신호 전달. **block 아님**. (architect-advisor 리뷰 의견 반영: hard block은 frustration, warn only.)

## 현재 상태 / 문제

- `develop` SKILL: Kent Beck TDD 권유 (LLM 지시문)
- LLM이 prod 코드만 작성하고 "manual 확인" 합리화 가능 → CLAUDE.md 금지 사항 1번 위반 가능
- 현재 hook이 detect 못 함

## 제안

### 1. 카운터 추가

`session-state.sh` state.json:
```json
{
  "edits_counters": {
    "src_files_count": 0,
    "test_files_count": 0,
    "test_pattern_used": "default"
  }
}
```

### 2. 테스트 파일 패턴 식별

언어별 패턴 매트릭스:
- Go: `*_test.go`
- TS/JS: `*.test.ts`, `*.test.tsx`, `*.spec.ts`, `__tests__/**`
- Python: `test_*.py`, `*_test.py`, `tests/**`
- Bash: `*.smoke.sh`, `tests/**`
- 기타: 미식별 (skip)

`session-state.sh` helper:
```bash
_is_test_file() {
  case "$1" in
    *_test.go|*.test.ts|*.test.tsx|*.spec.ts|*.spec.tsx) return 0;;
    *_test.py|test_*.py) return 0;;
    *.smoke.sh|*test*.sh) return 0;;
    */__tests__/*|*/tests/*|*/test/*) return 0;;
    *) return 1;;
  esac
}

_is_src_file() {
  if _is_test_file "$1"; then return 1; fi  # test가 src보다 우선
  case "$1" in
    *.go|*.ts|*.tsx|*.js|*.py|*.rs) return 0;;
    *.sh|*.bash|*.zsh) return 0;;
    *) return 1;;
  esac
}
```

### 3. PostToolUse Edit/Write 카운터 증가

```bash
if [[ tool ∈ {Edit,Write,NotebookEdit} ]]; then
  if _is_test_file "$file_path"; then
    state_increment ".edits_counters.test_files_count"
  elif _is_src_file "$file_path"; then
    state_increment ".edits_counters.src_files_count"
  fi
fi
```

### 4. Signal 전달 — Review subagent에

review stage 진입 시(plan 01의 verdict footer hook과 통합), state에서 ratio 평가:

```
src=10, test=0 → tdd_signal = "no_tests_detected"
src=10, test=2 → tdd_signal = "low_test_ratio"
src=10, test=5 → tdd_signal = "ok"
```

이 signal은 단순히 state field로 set. main이 review Task 호출할 때 prompt에 inject (수동), 또는 `code-reviewer` agent prompt에서 state 읽기 (구현 가능 여부 확인).

**대안**: `sazo-workflow status`에 표시. main LLM이 이 정보 보고 review prompt에 직접 포함.

### 5. CI gate 시점 검사

ci stage 진입 시 (PostToolUse Bash CI exit 0 핸들러, `workflow-state-machine.sh:139`):
- `src_files_count > 0 AND test_files_count == 0` 이면 audit.log warn entry
- block 안 함

### 6. False positive 방지

- Config-only PR: `_is_src_file` 패턴이 .json/.yml 제외 (이건 plan 04의 `_is_code_file`과 다른 의미)
- Refactor PR: 사용자가 `/skip-tdd-warn <reason>` 입력 → state에 marker, 1세션 한정 warn off

## 변경 파일

```
packages/ai-harness/scripts/lib/session-state.sh    (_is_test_file/_is_src_file, edits_counters)
packages/ai-harness/scripts/hooks/workflow-state-machine.sh  (PostToolUse Edit 카운터)
packages/ai-harness/commands/skip-tdd-warn.md       (신규 slash command)
packages/ai-harness/scripts/tests/test-edits-counter.smoke.sh  (신규)
~/.claude/CLAUDE.md MANAGED BLOCK                   (TDD signal 정책 명시)
```

## State schema

`edits_counters` 필드 추가. backward compat: 기존 state init 시 기본값.

## Test plan

`test-edits-counter.smoke.sh`:

1. src 1개 + test 1개 Edit → counters 1/1
2. src 3개 + test 0 → CI 진입 시 audit warn
3. test 파일 패턴 매트릭스 정확 분류 (각 언어별 1 case)
4. NotebookEdit도 카운트
5. `/skip-tdd-warn` → 다음 ci까지 warn 없음
6. 새 세션 → warn 다시 활성
7. False positive: README.md edit → counter 변화 없음
8. `_is_test_file` 우선 매치 (예: src/__tests__/foo.go → test로 분류)
9. State에 ratio 신호 set 확인
10. Backward compat: edits_counters 없는 기존 state.json → init 시 default 0

## Open questions

1. Review subagent에 signal 전달 방식 — main LLM 수동 prompt 추가 vs agent prompt에서 state 직접 읽기? 후자는 가능성 검증 필요.
2. False positive 비율 사용자 dogfood 후 결정 — 임계값 1주 후 조정.
3. `*test*.sh` 패턴 너무 광범위? `*.smoke.sh`만으로 한정?
4. Config-only PR detect 방식 — 현재 플랜 미정의 (개별 hook 또는 LLM 자율).

## Risk

- **R1 (med)**: 패턴 false positive (예: `tests` 디렉토리에 fixture만 있고 실제 test 없는 경우). 완화: warn only, block 없음.
- **R2 (low)**: LLM이 signal 무시 — 의도된 trade-off. CLAUDE.md에 "LLM이 review에서 지적해야" 명시.
- **R3 (low)**: 카운터 누적 무한 증가 → state.json 비대. 완화: stage transition (ci 통과) 시 reset.

## Rollback

- `SAZO_DISABLE_TDD_COUNTER=1` env → 카운터 미동작
- state field 자동 init이므로 무손실 rollback

## Acceptance criteria

- [ ] `_is_test_file`, `_is_src_file` helper 추가
- [ ] PostToolUse Edit/Write/NotebookEdit이 카운터 증가
- [ ] CI 진입 시 ratio audit warn (block 없음)
- [ ] `/skip-tdd-warn` 동작
- [ ] 언어별 패턴 5개 정확 분류 smoke test
- [ ] CLAUDE.md TDD signal 정책 명시
- [ ] 카운터 ratio가 `sazo-workflow status` (plan 02)에 표시
