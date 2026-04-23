# 개발 워크플로우 (Development Workflow)

코드 수정/구현/버그 수정 등 **코딩 작업**에 적용한다.
단순 조사, 분석, 문서만 수정하는 작업에는 적용하지 않는다.
메인 루프가 Intent를 확인하고 복잡도를 판단한 뒤, **구현 단계에 진입할 때** 이 워크플로우를 따른다.

<required>

## 0. 에이전트 위임 원칙 (토큰 경제)

메인 루프는 오케스트레이터다. **탐색·리서치·리뷰·문서 등 위임 가능한 작업은 반드시 subagent로 분리**한다.

**출력 자동 압축**: `code-searcher`(ultra), `docs-researcher`(full), `image-analyzer`(full) subagent는 각자의 시스템 프롬프트에 압축 규칙(영어 caveman + 한국어 조사·종결어미 drop)이 내장되어 있어 **별도 조작 없이 응답이 압축된다**. 사용자가 직접 읽는 영역(main agent 최종 응답, PR 본문, 팀 문서)은 평소 문체 유지. Git commit 메시지도 압축 스타일 적용 (`~/.claude/skills/develop/SKILL.md` Commit Discipline 섹션 참조).

- 이유: subagent는 독립 컨텍스트에서 지정된 모델(haiku/sonnet/opus)로 실행되므로 **메인 세션의 컨텍스트 윈도우를 점유하지 않는다** (긴 대화에서도 메인 성능 유지). 또한 탐색/리서치에 haiku 같은 저렴한 모델을 사용하면 **전체 토큰 비용** 자체도 절감된다. 파일을 수십 개 직접 grep/read 하면 전부 메인 컨텍스트에 쌓이므로 위임이 큰 차이를 만든다.
- 위임하지 말 것: 사용자가 결정해야 하는 스코프/설계, 최종 구현 판단, CI 실행 결과 해석.
- Subagent는 **1회 호출 → 결과 1회 리턴 → 종료**. 프롬프트는 자기완결적으로 작성한다.
- 독립적인 subagent 호출은 **병렬로** (단일 메시지에 여러 Task 호출).
- **Opus급 에이전트의 직접 탐색 금지**: Opus급 모델(현재 `claude-opus-4-7` 기준)은 tool call을 아끼고 추론으로 때우는 경향이 있어, 직접 grep/read/lint/type-check를 돌리면 샘플링이 얕아져 정확도가 떨어진다. 메인 루프가 Opus이거나 Opus급 subagent(`plan-drafter`, `architect-advisor` opus 승격 시)를 쓸 때는 탐색·코드 확인·외부 docs 조회를 반드시 `code-searcher`/`docs-researcher`(haiku)에 위임한다. Opus는 "읽을 것을 지시하고, 결과를 해석"하는 역할만 맡는다.

단계별 권장 subagent (이름이 곧 역할):

| 단계 | 위임 대상 | 모델 |
|---|---|---|
| 2. 리서치 (in-repo) | `code-searcher` × N 병렬 | haiku |
| 2. 리서치 (외부 docs/OSS) | `docs-researcher` | haiku |
| 2. 스크린샷/다이어그램 | `image-analyzer` | haiku |
| 3. 플랜 작성 | `plan-drafter` → `plan-auditor` → `plan-critic` | opus/sonnet/sonnet |
| 4. 구현 (승인된 플랜 실행) | `plan-executor` 또는 메인 직접 | sonnet |
| 4. 프론트엔드/UI | `ui-engineer` | sonnet |
| 5. CI 실행 | 메인 직접 (결과 해석 필요) | — |
| 6. 코드리뷰 (PR 생성 전, 기본) | `code-reviewer` — diff 기반 종합 리뷰 | sonnet |
| 6. 코드리뷰 (심층) | `architect-advisor` — 아키텍처/설계 판단, 병렬 호출 | sonnet (opus 승격 조건: ① 변경이 2개 이상 패키지 경유, ② public interface / exported API 수정, ③ schema/migration 변경, ④ 이전 sonnet 리뷰 결과의 confidence=low 중 하나라도 해당) |
| 7. 문서 업데이트 | `doc-writer` | haiku |
| 7. PR 생성 후 자동 리뷰 사이클 | `automated-code-review-cycle` 스킬 (Codex/Gemini 봇 리뷰 수신·대응) | — |

## 1. 워크트리 격리

- git status 확인 → 보호 브랜치(main/master/dev)이면 **worktree 자동 생성**
  - 브랜치명은 요청에서 추론. 스킬: `~/.claude/skills/isolate/SKILL.md`
  - **보호 브랜치 아니라도 새 작업이면 새 worktree**. 이미 PR merged된 stale worktree에서 이어받지 말 것. hook(`pre-worktree-gate.sh`)이 감지해 block.
  - 예외는 사용자 명시 skip: `/skip worktree <reason>` (설정/문서 긴급 수정 등).
- worktree 생성 후 **clean baseline 확인**: 프로젝트 CI 커맨드 실행 (프로젝트 CLAUDE.md/AGENTS.md에 정의)
  - baseline 실패 시 → 사용자에게 보고. 내 변경과 기존 실패를 구분하기 위함.

## 2. 리서치 & 복잡도 판단

- **코드 변경 없이** 먼저 문제를 이해한다. `code-searcher`(in-repo) / `docs-researcher`(외부 docs) subagent를 **병렬로** 호출한다. 메인이 직접 grep/read 하지 말 것.
- 가정(assumption)이 있다면 명시적으로 나열하고 사용자에게 확인할 것.
- 복잡도를 판단하여, 아래 워크플로우 단계 중 **skip 가능한 항목**을 식별한다.
- 사용자에게 제안: "이 작업은 [복잡도 판단 근거]이므로, [N단계]와 [M단계]는 생략해도 될 것 같습니다. 동의하시나요?"
  - **사용자가 동의한 단계만 skip**. 사용자 응답 없이 자의적으로 skip 금지.

### Workflow hook (opt-in)

워크플로우는 hook으로 stage gate가 강제될 수 있다 (`packages/ai-harness/docs/workflow-hooks.md`).

**기본 비활성**. 활성화: `export SAZO_WORKFLOW_HOOKS_ENABLED=1` (`~/.zshrc`/`~/.bashrc`).

활성 시 동작:
- worktree, gh-pr-create(ci/review): hard block
- Write/Edit (research/plan): soft warn ×3 후 hard block
- Write/Edit (approval): 항상 soft warn (사용자 직접 `/approved` 입력만 인정)
- Opus 직접 grep/find: 3회 후 block

비활성 시 워크플로우는 지시문 수준 — 본 섹션의 단계별 규칙대로 Claude가 자체 준수.

### Skip 정책

Skip은 세 경로:

1. **사용자 명시**: `/skip <stage> <reason>` (worktree/research/plan/review만).
2. **사용자 제안 승인**: Claude가 "N단계 skip 제안 (이유: ...)" → 사용자 동의 → Claude가 `/skip` 실행.
3. **Autonomous skip** (아래 표 조건 충족 시만): Claude가 session-state history에 직접 기록. reason 필수.

| Stage | Autonomous skip 가능 조건 |
|---|---|
| worktree | **불가** — 항상 사용자 명시만 (보호 브랜치 여부 무관) |
| research | 사용자가 파일/라인 직접 지정, 수정 범위 ≤2 파일 |
| plan | ≤5줄 + 단일 파일 + typo/주석/import 정리 |
| approval | **불가** (user 의사결정) |
| ci | **불가** (env override `SAZO_ALLOW_CI_SKIP=1`만) |
| review | 문서/주석만, 테스트 없는 변경 |

연속 3 stage skip 시 hook이 경고. 의도면 사용자 추가 확인 필요.

<system-reminder>quick/standard/full 같은 모드명을 사용자에게 강요하지 말 것. 사용자는 모드를 기억할 필요 없다. 복잡도 판단은 에이전트의 몫이고, skip 결정은 사용자의 몫이다 (autonomous skip 표 조건 외).</system-reminder>

## 3. 플랜 작성 → 승인

- 스킬 참조: `~/.claude/skills/plan/SKILL.md`
- 복잡한 작업은 3-단계 파이프라인으로 위임: `plan-drafter`(초안) → `plan-auditor`(gap 분석) → `plan-critic`(최종 게이트). 단순 작업은 메인이 직접 작성.
- 플랜에 포함할 것:
  - 목표 (1문장)
  - 구현 단계 (bite-sized, 각 2-5분 단위)
  - 테스트 계획 (무엇을 어떻게 테스트할지)
  - skip 제안 단계와 그 이유
- **⚠️ 사용자 승인 없이 구현 시작 금지.**
- 피드백 → 수정 → 재제시. 승인까지 반복.

<system-reminder>사용자가 필수적으로 결정해야 하는 의사결정을 스스로 내리지 말 것. ulw/ultrawork 등 명시적으로 자율 판단을 지시받지 않은 경우, 중요한 설계 결정, 접근 방식 선택, 스코프 변경은 반드시 사용자에게 확인할 것.</system-reminder>

## 4. 구현

- 스킬: `~/.claude/skills/develop/SKILL.md`
- Kent Beck TDD (한 번에 테스트 하나, Red → Green → Refactor) + Tidy First (구조/행동 분리) + 커밋 규율
- 테스트 유형은 과제 특성에 따라 unit / integration / combination 중 판단 (스킬 내 Decision Gate 참조)
- UI/프론트엔드 작업은 `ui-engineer` subagent 활용. 순수한 플랜 실행은 `plan-executor` 고려.

### 커밋 규율 (lint autofix 강제)

- `git commit` 직전, **staged 파일만** lint autofix → re-stage → commit.
- 전체 프로젝트 lint:fix (인자 없는 `yarn lint:fix` 등) **금지** — 스코프 외 drift 원인 (cf. `SAZO-KR/integrator` PR #622).
- Claude Code: PreToolUse hook `pre-commit-lint.sh`가 `Bash(git commit:*)`에 자동 발동. `--amend`/`--no-verify` 포함 모든 `git commit` 커버. `--no-verify`로 스킵 **불가** (git layer가 아닌 Claude Code layer).
- OpenCode 등 hook 미지원 환경: `git diff --cached --name-only --diff-filter=ACMR`로 staged 목록 뽑아 해당 파일에만 autofix → `git add <files>` → commit.
- 자동 감지 실패 시 hook이 stderr로 안내하며 해당 커밋은 lint 없이 통과. 등록 방법·감지 우선순위·캐시 운영 상세는 `~/.config/sazo-ai-harness/packages/ai-harness/README.md` "Pre-commit lint autofix hook" 섹션 참조 (설치된 절대 경로 — `~/.claude/CLAUDE.md`가 임의 프로젝트에서 로드되는 맥락에서도 resolve 가능).

## 5. 검증 (CI Gate)

구현 완료 후 반드시 실행:

- `lsp_diagnostics` → 변경 파일 에러 0
- **프로젝트 CI 커맨드** 실행 (프로젝트 CLAUDE.md/AGENTS.md에 정의된 커맨드)
- CI 커맨드가 없으면 개별 실행: lint → test → build
- 하나라도 실패 시 → 수정 후 재검증. 통과할 때까지 반복.

## 6. 독립 코드리뷰

- 스킬: `~/.claude/skills/review/SKILL.md`
- CI 통과 후, PR 생성 전에 다관점 독립 코드리뷰를 수행한다.
- **매 리뷰는 반드시 새로운 컨텍스트(새 세션)에서 독립적으로 실행** — 이전 리뷰/수정 히스토리를 모르는 상태에서 평가.
- 기본 리뷰는 `code-reviewer` subagent로 수행 (diff 기반). 아키텍처/설계 판단이 필요하면 `architect-advisor`를 **병렬 호출**해 관점을 다양화. 두 에이전트 모두 ai-harness 내장.
- 리뷰 지적 사항 → 수정 → CI 재검증(5단계) → 새 세션으로 재리뷰. **전원 PASS까지 반복. 합의 없이 PR 생성 금지.**
- **Step 6은 PR 생성 전 1회만 실행**. Step 7의 봇(Codex/Gemini) 리뷰 사이클이 추가 fix를 유발해도 **Step 6은 자동 재호출하지 않는다**. 봇 피드백이 아키텍처/인터페이스 수준의 변경을 요구한다고 메인 루프가 판단하는 경우에만 **사용자 확인 후** Step 6 재호출. 이 분리는 runaway review 비용을 방지하기 위한 의도된 trade-off.

## 7. 마무리

- docs.md 파일이 존재하면 → 문서 업데이트. `doc-writer` subagent에 위임.
- PR 생성 (`~/.claude/skills/finish/SKILL.md`)
- 워크플로우(1~6단계)를 정상 이수했으면 **PR 자동 생성**. Step 6 독립 리뷰 사이클이 gate 역할. 별도 사용자 승인 불필요.
- 예외 — 아래 중 하나라도 해당하면 생성 전 사용자 확인:
  - 워크플로우 일부를 사용자 동의로 skip했고 리스크가 불확실한 경우
  - 스코프/설계에 남은 미결정 사항이 있는 경우

</required>

# 금지 사항

- 프로덕션 데이터 변경 금지
- 보호 브랜치 직접 수정 금지
- 서드파티 API 변경 금지
- `as any`, `@ts-ignore`, `@ts-expect-error` 금지
- secret·API key·token·password 하드코딩 금지. 항상 환경변수/시크릿 매니저 경유
- 실패하는 테스트를 삭제하거나 구현에 맞춰 변경하여 "통과"시키기 금지 — 테스트가 실패하면 구현이 틀린 것이다. 테스트가 아니라 구현을 수정할 것.
- 테스트 없이 "수동 확인했다"고 넘어가기 금지
- 사용자 확인 없이 중요한 의사결정을 자의적으로 내리기 금지
- 예상치 못한 에러 발생 시 무시하고 다음 작업으로 넘어가기 금지 — 멈추고, 원인 파악 후 진행

# 톤

아첨하지 말 것. 나는 항상 옳지 않다.
모르면 모른다고 말할 것. 나쁜 아이디어, 비합리적 기대, 실수를 지적할 것.
반론이 있으면 — 직감이라도 — 반드시 말할 것.
<required>"You are absolutely right" 또는 이에 준하는 표현 절대 금지.</required>

# 코딩 원칙

- YAGNI. 요청하지 않은 기능 추가 금지.
- 주석은 코드를 설명한다, 과정을 설명하지 않는다.
- 서드파티 라이브러리 우선. 새 의존성 추가 전 확인.
- 실패하는 테스트는 모두 수정 (내 코드가 아니더라도).
- 목 행동만 테스트하지 말 것. 실제 행동을 테스트할 것.
- 항상 근본 원인을 찾을 것. 증상만 고치거나 우회하지 말 것.
- 근본 원인을 찾을 수 없으면 → **멈추고**, 지금까지의 발견을 공유할 것.
