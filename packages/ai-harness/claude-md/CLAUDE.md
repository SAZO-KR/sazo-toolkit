# 개발 워크플로우 (Development Workflow)

코드 수정/구현/버그 수정 등 **코딩 작업**에 적용한다.
단순 조사, 분석, 문서만 수정하는 작업에는 적용하지 않는다.
메인 루프가 Intent를 확인하고 복잡도를 판단한 뒤, **구현 단계에 진입할 때** 이 워크플로우를 따른다.

<required>

## 0. 에이전트 위임 원칙 (토큰 경제)

메인 루프는 오케스트레이터다. **탐색·리서치·리뷰·문서 등 위임 가능한 작업은 반드시 subagent로 분리**한다.
- 이유: subagent는 독립 컨텍스트에서 지정된 모델(haiku/sonnet/opus)로 실행되므로 **메인 세션의 컨텍스트 윈도우를 점유하지 않는다** (긴 대화에서도 메인 성능 유지). 또한 탐색/리서치에 haiku 같은 저렴한 모델을 사용하면 **전체 토큰 비용** 자체도 절감된다. 파일을 수십 개 직접 grep/read 하면 전부 메인 컨텍스트에 쌓이므로 위임이 큰 차이를 만든다.
- 위임하지 말 것: 사용자가 결정해야 하는 스코프/설계, 최종 구현 판단, CI 실행 결과 해석.
- Subagent는 **1회 호출 → 결과 1회 리턴 → 종료**. 프롬프트는 자기완결적으로 작성한다.
- 독립적인 subagent 호출은 **병렬로** (단일 메시지에 여러 Task 호출).

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
  - 예외: 설정/문서만 수정하는 경우
- worktree 생성 후 **clean baseline 확인**: 프로젝트 CI 커맨드 실행 (프로젝트 CLAUDE.md/AGENTS.md에 정의)
  - baseline 실패 시 → 사용자에게 보고. 내 변경과 기존 실패를 구분하기 위함.

## 2. 리서치 & 복잡도 판단

- **코드 변경 없이** 먼저 문제를 이해한다. `code-searcher`(in-repo) / `docs-researcher`(외부 docs) subagent를 **병렬로** 호출한다. 메인이 직접 grep/read 하지 말 것.
- 가정(assumption)이 있다면 명시적으로 나열하고 사용자에게 확인할 것.
- 복잡도를 판단하여, 아래 워크플로우 단계 중 **skip 가능한 항목**을 식별한다.
- 사용자에게 제안: "이 작업은 [복잡도 판단 근거]이므로, [N단계]와 [M단계]는 생략해도 될 것 같습니다. 동의하시나요?"
  - **사용자가 동의한 단계만 skip**. 사용자 응답 없이 자의적으로 skip 금지.

<system-reminder>quick/standard/full 같은 모드명을 사용자에게 강요하지 말 것. 사용자는 모드를 기억할 필요 없다. 복잡도 판단은 에이전트의 몫이고, skip 결정은 사용자의 몫이다.</system-reminder>

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

- `git commit` 직전, **staged 파일만** lint autofix를 돌리고 수정된 결과를 다시 staging한 뒤 커밋한다.
- 전체 프로젝트 lint:fix 실행(`yarn lint:fix`를 인자 없이 호출 등)은 **금지** — 스코프 외 파일 drift가 PR에 섞이는 원인이 된다 (cf. `SAZO-KR/integrator` PR #622).
- Claude Code 환경에서는 PreToolUse hook `pre-commit-lint.sh`가 matcher `Bash(git commit:*)`로 자동 발동 — 별도 지시 없이 실행됨.
- matcher는 `git commit`으로 시작하는 모든 호출(`-m`, `--amend`, `--no-verify` 포함)을 커버한다. AI가 hook을 미리 수동 실행할 필요 없이 `git commit`을 그대로 호출하면 된다.
- OpenCode 등 PreToolUse hook이 없는 환경에서는 매 커밋 전에 같은 규칙을 수동 적용 — `git diff --cached --name-only --diff-filter=ACMR`로 staged 목록을 뽑아 해당 파일들에만 autofix 실행 → `git add <files>` → commit.

**자동 감지 우선순위** (`lint-autofix-detect.sh`):

1. 전역 캐시 `~/.config/sazo-ai-harness/lint-fix-cache.json` (repo root 경로 sha256 키)
2. `package.json`에 `lint-staged` 의존성 존재 → `{yarn|pnpm|npx} lint-staged` (파일 인자 불필요)
3. `pyproject.toml`에 `[tool.ruff]` → `ruff check --fix <files>`
4. `pyproject.toml`에 `[tool.black]` → `black <files>`
5. `go.mod` → `gofmt -w <files>`
6. 위 전부 실패 → hook이 stderr로 안내하고 **이번 커밋은 lint 없이 통과**시킨다. AI는 사용자에게 다음 템플릿으로 질문한다:

   > "이 저장소에서 **staged 파일만** autofix하는 정확한 커맨드가 뭔가요? 예: `npx lint-staged`, `yarn lint --fix`, 직접 만든 스크립트 등. 그 커맨드가 파일 경로를 인자로 받아 실행하는 형태인지도 알려주세요 (예: `black <files>`는 인자 받음, `npx lint-staged`는 안 받음)."

   답변을 받으면 아래 명령으로 전역 캐시에 등록:

   ```bash
   ~/.config/sazo-ai-harness/packages/ai-harness/scripts/pre-commit-lint.sh --set '<command>' [--files-arg]
   ```

   `--files-arg`는 **커맨드 뒤에 staged 파일 경로를 공백 구분으로 붙여 실행해야 하는 경우에만** 추가. lint-staged처럼 내부에서 staged를 스스로 감지하는 도구는 붙이지 않는다. **잘못 선택하면 전 프로젝트 lint로 확장되어 정확히 이 hook이 막으려는 스코프 유출이 발생**하므로 확신이 없으면 사용자에게 재확인.

   커맨드는 **단일 바이너리 + flag 형태**로 등록 권장. 쉘 체인(`&&`, 파이프, 세미콜론), 중첩 따옴표 포함 시 동작이 불안정하므로, 복잡한 로직이 필요하면 저장소에 스크립트를 하나 만들어 그 경로를 등록한다.

   등록 후 다음 커밋부터 자동 적용. 캐시 키가 `git rev-parse --show-toplevel` 기반이라 worktree 경로가 다르면 worktree별 재등록이 필요할 수 있다.

- 이 hook은 git layer가 아닌 Claude Code PreToolUse layer라 `git commit --no-verify`로 스킵되지 않는다(= git의 `.husky/pre-commit`만 `--no-verify`가 우회). 의도적 우회 시도는 전역 "금지 사항: hook 건너뛰기 금지"로 이미 커버됨.

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
- PR 생성 여부는 사용자에게 확인. ulw 모드에서만 자동 생성.

</required>

# 금지 사항

- 프로덕션 데이터 변경 금지
- 보호 브랜치 직접 수정 금지
- 서드파티 API 변경 금지
- `as any`, `@ts-ignore`, `@ts-expect-error` 금지
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
