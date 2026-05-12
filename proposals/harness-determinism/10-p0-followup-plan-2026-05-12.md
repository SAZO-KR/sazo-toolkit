# P0 후속 작업 plan — 2026-05-12 architecture review 후속

**입력**: `09-architecture-review-2026-05-12.md`
**Drafter**: `plan-drafter` subagent (background)
**상태**: 사용자 결정 3건 대기 (Open Questions 섹션)

## 목표

F1(dead code 제거) + F2(slash command payload spike) + F3(plan-executor dead-end 문서화)를 단계적으로 머지해 P0 결함 3건을 해소한다. F3 구조적 수정은 P1으로 분리.

## Assumptions

- **확신**: `~/.claude/commands/approved.md`는 `install.sh`가 만든 심볼릭 링크. 원본은 `packages/ai-harness/commands/approved.md`.
- **확신**: `spike-results.md` Q5는 일반 텍스트 prompt 구조만 검증. slash command 라우팅은 미검증 가설로 명시.
- **가설 / 검증 필요**: Claude Code의 slash command가 UserPromptSubmit hook에 도달할 때 `.prompt` 필드 raw text가 `"/approved"`인지, expanded markdown body인지, 아예 UserPromptSubmit 자체가 발사되지 않는지 — 3가지 모두 spike에서 확인.
- **확신**: `agents/plan-executor.md`는 ai-harness 내부에 존재 (`packages/ai-harness/agents/plan-executor.md`). 설치 시 `~/.claude/agents/`로 link.
- **확신**: broad hook `workflow-state-machine`은 session-scoped state file (`$SESSION_ID--$CWD_HASH.json`) — subagent fresh session에서 별개 state 생성. parent approval marker 상속 안 됨.

## Open Questions (사용자 결정)

### Q1. 머지 전략

| 옵션 | 설명 |
|---|---|
| (a) 4-PR 분리 (drafter 권장) | PR1: proposals만 / PR2: F1 / PR3: F2 spike / PR4: F3 문서화 |
| (b) 3-PR (F1+F3 합치기) | PR1: proposals / PR2: F2 spike / PR3: F1+F3 문서 |

### Q2. F2 spike dump 파일 위치

| 옵션 | 설명 |
|---|---|
| (a) `/tmp/sazo-prompt-dump.log` | 사용자 영역 밖, 자동 cleanup |
| (b) `~/.claude/session-state/spike/prompt-dump.log` | audit log 옆, 보존성·발견성 ↑ |

### Q3. F3 문서화 위치

| 옵션 | 설명 |
|---|---|
| (a) CLAUDE.md user-global + ai-harness 내부 둘 다 | 가시성 최대 |
| (b) ai-harness 내부 README.md "한계" 섹션 + workflow-hooks.md만 | source-of-truth 일원화, 메인 워크플로우 표에 inline 1줄만 |

## 작업 1 — F1: `commands/approved.md` dead code 제거

### 변경 대상
- `/Users/hakun.lee/work/sazo-toolkit/packages/ai-harness/commands/approved.md` (line 18-50 `!bash -c '...'` 블록 + line 16 "## 동작" 헤더)

### 구현 단계
1. `commands/approved.md` line 18-50 bash body 삭제 — verify: `grep -c '!bash' commands/approved.md` == 0.
2. 동일 위치에 hook 처리 설명 stub 삽입 (2-3줄 markdown) — verify: 파일 head 60줄 manual read, `user-prompt-approval-detect.sh:42-43` 참조 포함.
3. line 3 `allowed-tools:` frontmatter는 불필요 — 제거 또는 빈 list. verify: `grep '^allowed-tools' commands/approved.md` empty 또는 minimal.
4. 시스템 링크 영향 확인: `ls -la ~/.claude/commands/approved.md` → symlink target이 ai-harness repo path. verify: `readlink` 결과가 `packages/ai-harness/commands/approved.md` 포함.
5. `approval-immediate.smoke.sh` / `approval-bypass.smoke.sh` 영향 grep — hook 경로만 test하므로 영향 없음 예상. verify: 두 smoke 실행 후 exit 0.

### 테스트 계획
- 기존 smoke 2종 회귀만 확인 — `bash scripts/tests/approval-immediate.smoke.sh && bash scripts/tests/approval-bypass.smoke.sh`.
- 신규 smoke 불필요 (dead code 제거이므로 negative test 불필요).

### 위험 / 의존
- Codex/Gemini bot이 "command body 없으면 사용자가 헷갈림" 지적 가능 — stub 설명 한 줄로 mitigate.

## 작업 2 — F2: UserPromptSubmit slash command payload spike

### 목표
Claude Code slash command가 UserPromptSubmit hook의 `.prompt` 필드에 raw 형태로 도달하는지 검증.

### 구현 단계
1. spike 브랜치에서 `packages/ai-harness/scripts/hooks/user-prompt-approval-detect.sh:26` 직후 debug branch 삽입 — `[ -n "${SAZO_PROMPT_SPIKE_DUMP:-}" ] && printf '%s\n---\n' "$SAZO_USER_PROMPT" >> "$SAZO_PROMPT_SPIKE_DUMP"`. verify: `bash -n` syntax check + 환경변수 미설정 시 no-op.
2. `~/.zshrc`에 일회용 export 추가 — `export SAZO_PROMPT_SPIKE_DUMP=$HOME/.claude/session-state/spike/prompt-dump.log` + 디렉토리 생성 (Q2 결과 반영). verify: `echo $SAZO_PROMPT_SPIKE_DUMP` 출력.
3. **시나리오 (a) baseline**: 새 Claude Code 세션에서 일반 텍스트 "hello world" 입력 → dump 파일 raw text 확인. verify: dump에 `hello world` 포함.
4. **시나리오 (b) /approved**: `/approved` 정확히 입력 → dump 파일 prompt 필드값 확인. verify: dump에 `/approved` literal 라인 OR markdown body OR 부재 셋 중 어느 것인지 기록.
5. **시나리오 (c) /skip worktree test**: `/skip worktree test` 입력 → dump 확인. verify: dump에 raw `/skip worktree test`인지.
6. **시나리오 (d) /nonexistent foo**: 미등록 slash 입력 → dump 확인. verify: Claude Code가 reject 메시지 vs hook 도달 여부.
7. 결과를 `proposals/harness-determinism/spike-slash-command-routing.md`에 기록 — payload trace 4개 + 결정 트리. verify: 새 파일 존재.
8. spike 종료 — debug branch revert, env unset, dump 파일 삭제. verify: `grep SAZO_PROMPT_SPIKE_DUMP packages/ai-harness/scripts/hooks/` empty.
9. 결정 트리에 따라 follow-up issue 생성:
   - 케이스 1 (slash raw 도달) → `audit log에 메인 sid approval entry 없음` 별도 조사 issue.
   - 케이스 2 (slash가 expanded markdown으로 도달) → `user-prompt-approval-detect.sh`의 `/approved` literal match 실패 — fix plan 작성.
   - 케이스 3 (UserPromptSubmit 미발사) → approval trigger 경로 재설계 P1 plan.

### 산출물
- `proposals/harness-determinism/spike-slash-command-routing.md` (~150줄).

### 위험 / 의존
- Dump 파일이 prompt 전문 평문 기록 → 비밀번호 등 입력 시 leak. spike 즉시 종료 (단일 세션 ≤30분 권장). 사용자에게 명시 경고 필요.
- 결정 분기에 따라 P1 작업이 추가될 수 있으나 이 plan 스코프 밖.

## 작업 3 — F3: plan-executor + broad hook dead-end 문서화

### 변경 대상 (Q3 결정에 따라)
- `~/.claude/CLAUDE.md` (Q3=a) — managed block "구현" 표 row.
- `/Users/hakun.lee/work/sazo-toolkit/packages/ai-harness/agents/plan-executor.md:9` — Responsibilities 직전에 경고 박스.
- `/Users/hakun.lee/work/sazo-toolkit/packages/ai-harness/docs/workflow-hooks.md` — "Multi-session subagent + broad hook 한계" subsection 신규 추가.
- `/Users/hakun.lee/work/sazo-toolkit/packages/ai-harness/README.md` (Q3=b 선택 시 "한계" 섹션 entry).

### 구현 단계
1. `workflow-hooks.md`에 "Multi-session subagent + broad hook 한계" subsection 추가 (line 222 "Roadmap" 직전, ~15줄): subagent fresh session → parent approval state 미상속 → approval gate dead-end → 회피책 3가지 (env bypass, broad hook disable, main session 직접 실행). verify: section heading grep 성공.
2. `plan-executor.md` line 8-9 사이에 경고 박스 (4줄, blockquote): "broad hook (workflow-state-machine) 활성 환경에서 호출 시 fresh session approval gate dead-end. 호출자 책임: `SAZO_DISABLE_WORKFLOW_HOOKS=1` 또는 `SAZO_ALLOW_APPROVAL_BYPASS=1` env 전파, 또는 main session에서 직접 실행." verify: `grep -c "dead-end" plan-executor.md` >= 1.
3. ai-harness `commands/approved.md`와 `agents/plan-executor.md` 연결 link 추가 (workflow-hooks.md 신규 섹션 anchor 참조). verify: link target 존재.
4. user global `~/.claude/CLAUDE.md` managed block은 install/auto-update 동기화 대상 → ai-harness 원본 source 위치 grep — 확인 필요 (`packages/ai-harness/install.sh`에서 CLAUDE.md managed block 소스). 그 파일의 "구현" 표 row에 1줄 경고 inline. verify: 다음 install 후 user CLAUDE.md에 경고 반영.
5. `plan-executor` agent definition은 install link 대상 → 다음 세션에서 변경 반영. verify: `cat ~/.claude/agents/plan-executor.md`에 경고 보임.

### 테스트 계획
- 문서 변경. 자동 검증 없음. Manual review — `code-reviewer` subagent 1회.
- ai-harness CI bash chain 영향 없음 (smoke 영향 없음).

### 위험 / 의존
- F3는 *문서화*에 그침. 구조적 fix (parent approval projection to child sessions)는 별도 P1 plan으로 분리.
- 위험: 사용자가 문서만 보고 회피책 의존 → 향후 P1 fix 우선순위 떨어질 수 있음 → P1 follow-up issue를 본 PR에서 같이 open.

## 전체 Test Plan

- **작업 1**: `bash scripts/tests/approval-immediate.smoke.sh && bash scripts/tests/approval-bypass.smoke.sh` 통과.
- **작업 2**: spike 결과 문서 1개 생성 + dump 파일 cleanup 확인. debug branch revert 확인 (`git diff` empty for `user-prompt-approval-detect.sh`).
- **작업 3**: `code-reviewer` subagent 1회 — 경고 메시지 명확성·중복성·길이 검토. 전체 ai-harness CI chain 회귀 1회.
- **함께**: PR 머지 후 다음 새 Claude 세션 (worktree 격리)에서 `/approved` 입력 → audit log 확인.

## 머지 전략 (Q1 결정 대기)

drafter 권장: **4-PR 분리** (작업 1 권장 plan). 순서:
1. **PR 1** (이 PR): `09-architecture-review-2026-05-12.md` + `10-p0-followup-plan-2026-05-12.md` (proposals만).
2. **PR 2**: F1 (commands/approved.md fix + 기존 smoke 회귀).
3. **PR 3**: F2 spike 결과 문서 + debug branch는 머지 안 함, spike 종료 후 revert.
4. **PR 4**: F3 문서화.

대안: F1 + F3 합쳐 3-PR (Q1=b).

## skip 제안 단계

- **research stage**: 이 plan 작성 자체가 architect review 결과를 입력으로 받아 정리. 추가 research 불필요. `/skip research architect-review-가-research-역할`.
- **plan stage**: 이 문서로 갈음. 사용자 승인 후 plan stage 통과.
- **approval gate**: 사용자 결정 (Open Questions Q1~Q3 답변 후).
- **review skip 불가**: 작업 3에서 `code-reviewer` 1회 필수 (CLAUDE.md 변경 영향 광범위).

## 참조 파일

- `/Users/hakun.lee/work/sazo-toolkit/packages/ai-harness/commands/approved.md` (작업 1 대상)
- `/Users/hakun.lee/work/sazo-toolkit/packages/ai-harness/scripts/hooks/user-prompt-approval-detect.sh` (작업 2 debug branch 삽입 지점, line 26 이후)
- `/Users/hakun.lee/work/sazo-toolkit/packages/ai-harness/scripts/hooks/lib/session-state.sh` (line 526-543: `read_hook_payload` + `.prompt` 파싱)
- `/Users/hakun.lee/work/sazo-toolkit/packages/ai-harness/agents/plan-executor.md` (작업 3 대상)
- `/Users/hakun.lee/work/sazo-toolkit/packages/ai-harness/docs/workflow-hooks.md` (line 95-97 cwd hash, line 222 Roadmap 직전 신규 섹션)
- `/Users/hakun.lee/work/sazo-toolkit/proposals/harness-determinism/spike-results.md` (Q5 line 116-133 — slash command 미검증 가설 근거)
- `/Users/hakun.lee/work/sazo-toolkit/packages/ai-harness/scripts/tests/approval-immediate.smoke.sh`, `approval-bypass.smoke.sh` (작업 1 회귀)
