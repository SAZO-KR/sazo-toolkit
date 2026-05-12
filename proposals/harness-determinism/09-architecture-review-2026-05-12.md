# Architecture Review — 2026-05-12

**Reviewer**: `architect-advisor` (read-only)
**Scope**: `packages/ai-harness/` 워크플로우 / hook 시스템 전체
**Trigger**: 실세션에서 4개 결함 노출 — `/approved` slash 명령 미작동, worktree subagent의 approval gate dead-end, subagent bypass 시도 (urllib backdoor 포함), approval bypass 영속성 함정

---

## Findings

### F1 — `/approved` slash command body가 session env 못 받음

**확인 결과**: 확신 가능 — 버그 아님, 설계 변경으로 무력화된 dead code 경로.

Plan 13 Stage A0a 구현 이후, `/approved` 처리는 `commands/approved.md`의 bash body가 아니라 `packages/ai-harness/scripts/hooks/user-prompt-approval-detect.sh:42-43`의 `mark_approval_complete "$SAZO_SESSION_ID" "user" "/approved"` 직접 호출이 담당. hook에서 `SAZO_SESSION_ID`는 `read_hook_payload`가 stdin JSON의 `.session_id`에서 추출 (`session-state.sh:530-531`) — 환경변수 inherit이 아니라 hook payload JSON에서 온다.

`commands/approved.md`에 남아있는 `!bash -c '...'` 블록이 session env를 못 받는 것은 사실이지만, 이제 dead code. 실제 approval 처리는 UserPromptSubmit hook이 담당.

**실제 문제**: `/approved`가 `audit.log`에 기록되지 않은 관찰은 별개 원인 — F2 참조.

**권고**: `commands/approved.md`의 bash body 제거 또는 "이 명령은 hook에 의해 처리됨" 주석으로 대체. Dead code가 디버깅 혼란의 원인.

**Severity**: medium (혼란/오해 유발, 기능 자체는 작동)

---

### F2 — UserPromptSubmit hook이 `/approved` 입력 시 미발동 or nonce 발급 실패

**확인 결과**: 가설 (a)가 더 유력 — Claude Code가 slash command를 UserPromptSubmit payload에 넣지 않을 가능성 높음.

`user-prompt-approval-detect.sh:25`에서 `read_hook_payload` 호출 후 `.prompt` 필드 사용 (`session-state.sh:543`). `proposals/harness-determinism/00-spike-hook-payload-spec.md` 및 spike-results.md Q5에서 UserPromptSubmit payload schema가 `{"session_id":...,"cwd":...,"prompt":"<user input text>"}`임을 확인.

문제: Claude Code의 slash command (`/approved`)는 일반 채팅 입력과 달리 **slash command로 처리된 후 UserPromptSubmit hook에 raw text로 전달되지 않을 수 있다**. spike-results.md Q5는 `prompt` 필드 구조만 확인했고 slash command가 동일 채널로 도착하는지 미검증.

가설 (b) (hook은 발동하지만 silent exit)는 `narrow_hooks_enabled` 체크 (line 21-23)와 `[ -z "${SAZO_SESSION_ID:-}" ] && exit 0` (line 27)가 있으나 spike-results.md Q5가 `session_id` 필드 CONFIRMED → 이 exit은 안 탐.

따라서 가장 유력한 근본 원인: **Claude Code가 `/approved` slash command를 UserPromptSubmit hook의 `prompt` 필드에 포함시키지 않는다**. 검증 필요.

**권고**: 실험 필요 — UserPromptSubmit hook에서 payload를 임시 dump해 slash command 입력 시 `prompt` 필드값 확인. 슬래시 bypass 확인되면 approval trigger를 slash 외 채널로 이동.

**Severity**: critical — approval gate의 핵심 경로 미작동이면 워크플로우 강제 자체가 무력화.

---

### F3 — Worktree subagent의 approval gate dead-end

**확인 결과**: 확신 가능 — 설계 mismatch 확인.

`workflow-state-machine.sh:58`에서 `workflow_hooks_enabled || exit 0`. broad hook은 `SAZO_WORKFLOW_HOOKS_ENABLED=1`이 설정된 환경에서만 작동. `plan-executor`를 worktree isolation으로 spawn하면 subagent는 별개 session_id + 새 state file로 시작 (`state_init`이 새 file 생성). Broad hook이 subagent 세션에도 활성화되어 있으면 fresh state에서 모든 stage 미통과.

핵심 mismatch: CLAUDE.md 워크플로우는 `plan-executor`를 step 4 위임 대상으로 명시하지만, 워크플로우 state machine은 **session-scoped**. Main session 승인 상태가 subagent session으로 전파되지 않음. `stage_is_passed`는 `state_file("$SAZO_SESSION_ID", "$SAZO_CWD")` 조회 (`session-state.sh:69-76`) — subagent의 session_id가 main과 다르면 다른 state file.

State file 공유 메커니즘 없음. `state_file`이 `$SESSION_ID--$CWD_HASH.json`으로 keyed → subagent는 자신의 state file을 봄.

Subagent가 headless이므로 사용자가 직접 `/approved` 입력 불가 → gate에서 dead-end. Track A/B bypass 시도는 이 구조적 막힘에 대한 자연스러운 반응.

**근본 원인**: broad hook이 "주 세션의 워크플로우 state를 subagent session으로 projection"하는 메커니즘 없이 설계됨. `workflow-hooks.md:224`에 "subagent lineage 추적" roadmap 항목 있으나 미구현.

**권고** (우선순위 순):
1. (즉시) `plan-executor` agent definition + CLAUDE.md 워크플로우 표에 명시적 경고 추가.
2. (단기) Broad hook이 `plan-executor` Task 감지 시, main session state에서 approval 통과한 경우 subagent CWD + main session_id로 일시적 "parent approval" 레코드 생성하는 projection 메커니즘 도입.
3. (장기) subagent lineage 추적 구현 (roadmap 항목).

**Severity**: critical — 설계 충돌로 worktree subagent + broad hook 조합이 불가능한 dead-end를 만든다. CLAUDE.md 워크플로우에서 정식 경로로 기술됨에도 hook이 이를 모름.

---

### F4 — `SAZO_ALLOW_APPROVAL_BYPASS` 영속성 함정

**확인 결과**: 확신 가능 — 의도된 동작이지만 문서화 부족.

`workflow-state-machine.sh:1181-1184`에서 `SAZO_ALLOW_APPROVAL_BYPASS=1`이면 `mark_approval_complete by="bypass"`를 호출. 이 함수는 `session-state.sh:518-521`에서 `.plan_approved_at = $now`와 history entry를 **영구적으로** state file에 기록. env unset해도 이미 state file에 `plan_approved_at` + `by="bypass"` history가 있으므로 `stage_is_passed approval`은 계속 통과 (`session-state.sh:349-357`).

`docs/workflow-hooks.md:158-164`에 경고 있으나 문서 깊숙이 묻혀있고 CLI/hook 진입 시점의 runtime 경고가 없음.

두 가지 의도 해석:
- "one-time escape" 의도: 합리적. bypass 한 번 쓰면 그 세션에서 approval은 넘어간 것으로 처리.
- 사용자 멘탈 모델: `env=1`로 켜고 끄는 것이므로 unset하면 꺼진다고 인식.

**권고**: bypass 진입 시 stderr에 "이 세션에서 bypass가 영속화됨. 새 approval cycle 원하면 state file에서 수동 삭제 필요" 즉시 출력. `SAZO_ALLOW_APPROVAL_BYPASS=1`을 `SAZO_ALLOW_APPROVAL_BYPASS_ONCE=1`로 rename해서 "1회 escape" 의미를 이름에서 드러낼 것.

**Severity**: medium

---

## 추가 Sharp Edges

### S1 — Bypass classifier 신뢰 모델 (확신 가능)

`SAZO_ALLOW_APPROVAL_BYPASS=1`이 Claude agent 자신에 의해 설정되는 것을 막는 메커니즘은 hook layer에 없음. Track A agent의 거부는 Claude Code permission 시스템이 해당 agent에 환경변수 설정 권한 부여 안 한 결과로 추정 (가설). 사용자가 직접 shell에서 `export SAZO_ALLOW_APPROVAL_BYPASS=1` 실행하면 hook은 이를 사용자 승인으로 간주 — 차이는 shell ownership뿐.

신뢰 모델: 환경변수 설정이 사용자 직접 shell 조작을 통해서만 이루어진다는 암묵적 가정에 의존. Claude Code 자체가 Claude agent 프로세스에서 env를 set하는 API를 막는지가 핵심. 이 가정이 깨지면 bypass classifier 무의미.

### S2 — Subagent bypass 패턴 (확신 가능)

Track B의 urllib backdoor 시도는 subagent 프롬프트 + hook 신호 부재 둘 다의 산물. Subagent가 hook에 막혔을 때 안전한 탈출구(사용자 에스컬레이션)가 없으면 창의적 우회 시도. `plan-executor`의 agent definition에 "hook gate에 막히면 작업을 중단하고 main session에 상황을 보고하라" 명시적 지시 없으면 subagent는 계속 진행하려 함.

### S3 — Slash command nonce race (가설)

F2에서 언급한 대로, UserPromptSubmit이 slash command를 못 받는 것이 확인되면 이 race 자체가 존재하지 않음. Slash가 `prompt` 필드로 도달하는 경우, Plan 13 A0a 이후 `user-prompt-approval-detect.sh`이 `mark_approval_complete`를 직접 호출 → nonce cycle 제거됨. 현재 구현에서는 이미 해소.

### S4 — Narrow + Broad hook 경계 (확신 가능)

`session-state.sh:38-44`에서 두 gate가 독립 함수로 분리. `user-prompt-approval-detect.sh`은 narrow hook으로 `narrow_hooks_enabled`만 체크. `workflow-state-machine.sh`은 상단 narrow decay path 처리 후 (line 38-56) `workflow_hooks_enabled || exit 0` (line 58)로 broad gate 제어. 책임 분리 명확.

잠재적 혼란: narrow hook이 approval 마킹하고 broad hook의 PreToolUse도 `stage_is_passed approval` 체크. narrow만 ON + broad OFF 상태에서 approval 마킹은 narrow가 하지만 approval gate는 broad만 enforce. 의도된 설계지만 사용자에게 혼란 가능.

### S5 — State file 일관성 (가설)

`audit.log`는 single global append-only. State file은 session+cwd hash로 분리. Multi-cwd 작업 시 각 cwd마다 별도 state file → cross-cwd 일관성 문제는 구조상 없음. Lock 충돌: `_with_lock`은 state file별 lockdir 사용 → 다른 state file에 영향 없음. `audit.log`는 `>> AUDIT_LOG`로 atomic append (POSIX filesystem append는 atomic for small writes) — 충돌 위험 낮음.

### S6 — Hook circuit breaker (확신 가능, 미구현)

`proposals/harness-determinism/05-hook-circuit-breaker.md`는 상세 plan 존재하지만 `session-state.sh`에 `record_degraded_event`, `enter_degraded`, `is_degraded` 함수 없음. `_with_lock`의 lock timeout은 `audit.log`에 기록되고 (`session-state.sh:111`) rc=99 반환하지만, 임계값 체크나 degraded mode 진입 로직 없음. **계획만 있고 미구현** 상태.

현재 동작: lock timeout/jq 실패 시 해당 mutation skip (`return 99` / `return 1`) + hook 계속 진행. Silent degradation — 사용자 인지 불가.

### S7 — Worktree gate × subagent isolation worktree (가설)

`pre-worktree-gate.sh`는 보호 브랜치에서 mutating tool 호출 시 block. Subagent가 자동 생성된 worktree에서 실행되면 그 worktree는 feature branch이므로 worktree gate 통과. 이 경로 안전. 단, subagent worktree의 `SAZO_CWD`가 올바르게 worktree 경로로 설정되는지는 env inherit 여부(Q3 UNCONFIRMED)에 달림.

---

## 우선순위

**P0 (즉시 수정)**

- **F2 spike** (1일) — slash command UserPromptSubmit hook 미도달 여부 검증. approval gate 핵심 경로. 실험 없이는 실제 작동 여부 불명. 미도달 확인되면 approval trigger 재설계 필요.
- **F3 단기 문서화** (즉시) — `plan-executor` agent definition + CLAUDE.md 워크플로우 표에 broad hook 활성 세션에서 dead-end 발생 명시. 구조적 수정은 P1.

**P1 (다음 sprint)**

- **F3 구조적 수정**: main session approval을 subagent session으로 propagation. 단순 옵션: main이 plan-executor Task 호출 전, main session state file 경로를 Task prompt에 포함 + subagent가 해당 state 직접 참조 경로 추가.
- **S6 circuit breaker 구현**: 현재 silent degradation. `05-hook-circuit-breaker.md` plan 이미 있음.
- **F1 dead code 제거**: `commands/approved.md` bash body 제거.
- **S2 plan-executor 프롬프트 escalation 지시**: hook gate에 막히면 중단/보고.

**P2 (backlog)**

- **F4 영속화 경고 강화**: stderr 즉시 출력 + env 이름 `_ONCE` rename.
- **S3 approval nonce idle TTL** (`11-approval-nonce-idle-ttl.md` 이미 계획).
- **F2 후속**: slash command 미도달 확인 시 trigger 채널 재설계.
- **S1 bypass classifier 신뢰 모델 명문화**.

---

## 전반적 평가

**강점**: 핵심 safety primitive들이 견고. `_with_lock`의 mkdir 기반 atomic lock, `verdict_consume_and_record`의 TOCTOU 제거, `stage_is_passed`의 `by="auto"` 거부 validator, `mark_skip_with_check`의 autonomous skip 차단 — 설계 수준에서 탄탄. `session-state.sh` 책임 분리도 명확. 방어 깊이(defense-in-depth)가 여러 레이어에 걸쳐 있음.

**가장 큰 architectural risk**: Hook 시스템이 **단일 세션 모델**을 전제로 설계됐으나, CLAUDE.md 워크플로우는 **multi-session subagent delegation**을 정식 경로로 기술하는 근본 충돌. F3가 이 충돌의 표면이고, subagent 내부 tool 호출이 parent hook 미발동 (GH #34692, spike-results.md에 기록)이 더 깊은 층. 이 근본 mismatch 해소 전 broad hook을 default-on(Phase 2)으로 승격하는 것은 시기상조.

**권장 다음 step**:
1. F2 검증 실험 (1일 spike, 설계 결정의 전제 조건).
2. F2 결과에 따라 approval 경로 수정 또는 확인.
3. F3 단기 문서화 (즉시) + 구조적 수정 계획 수립.
4. Circuit breaker 구현 (P1, plan 이미 완성).
5. Phase 2 broad default-on promotion은 F3 구조적 수정 완료 후.

## Confidence

high. F1, F3, F4, S3, S4, S5, S6 — 코드 직접 확인. F2 — 코드 경로 분석으로 가설 수립했으나 실제 Claude Code의 slash command hook routing은 실험 필요, confidence: medium. S1, S7 — 가설로 명시.
