# AI Harness

팀 공용 AI 도구 설정 하네스 — Claude Code 프롬프트 + OpenCode 환경 셋업

## 설치

```bash
# 전체 설치 (Claude Code + OpenCode)
curl -fsSL https://raw.githubusercontent.com/SAZO-KR/sazo-toolkit/main/packages/ai-harness/install.sh | bash

# Claude Code 프롬프트만 설치 (OpenCode 건너뛰기)
curl -fsSL https://raw.githubusercontent.com/SAZO-KR/sazo-toolkit/main/packages/ai-harness/install.sh | bash -s -- --no-opencode
```

## 설치되는 것

### Claude Code

| 항목            | 경로                      |
| --------------- | ------------------------- |
| 설치 위치       | `~/.config/sazo-ai-harness/` |
| CLAUDE.md       | `~/.claude/CLAUDE.md` (managed block) |
| Commands        | `~/.claude/commands/*.md` |
| Skills          | `~/.claude/skills/*/`     |
| Agents          | `~/.claude/agents/*.md`   |
| Auto-update     | SessionStart hook         |
| Pre-commit lint | PreToolUse hook `Bash(git commit:*)` |

### OpenCode (선택)

| 항목               | 설명                                           |
| ------------------ | ---------------------------------------------- |
| OpenCode 설치      | `brew install opencode` (미설치 시)            |
| Plugins            | oh-my-opencode, anthropic-auth, antigravity 등 |
| Provider Models    | Antigravity Gemini 커스텀 모델 정의            |
| claude-sync        | Claude CLI → OpenCode 토큰 자동 동기화 (15분)  |
| claude-sync-notify | 토큰 만료 시 macOS 알림                        |

## Pre-commit lint autofix hook

`git commit` 직전에 **스테이징된 파일만** 대상으로 lint autofix를 자동 실행한다. 스코프 외 파일 drift가 PR에 섞이는 문제(cf. integrator PR #622)를 차단하는 용도.

- **위치**: `~/.claude/settings.json`의 `hooks.PreToolUse`, matcher `Bash(git commit:*)`
- **스크립트**: `~/.config/sazo-ai-harness/packages/ai-harness/scripts/pre-commit-lint.sh`
- **등록 시점**: `install.sh`가 최초 등록(idempotent). 이미 `install.sh`를 돌려본 기존 사용자는 `auto-update.sh`(매 SessionStart)가 hook 미등록 감지 시 자동 추가.
- **적용 범위**: Claude Code Bash tool을 통한 `git commit` 호출만. 사용자가 터미널에서 직접 치는 `git commit`은 영향 없음 (git의 pre-commit hook과 별개 layer).
- **실패 시**: lint autofix가 exit != 0이면 PreToolUse hook이 exit 2로 `git commit`을 **차단**. 에러를 stderr로 Claude에게 피드백.
- **성공 시**: 원래 staged였던 파일을 re-stage(autofix가 내용을 바꿨을 수 있음). autofix가 파일을 삭제한 경우 skip. staged 아닌 파일은 건드리지 않음(스코프 유출 방지).
- **파일 인자 안전성**: `supports_files_arg=true` 경로는 staged 파일명 앞에 `./` prefix를 붙여 lint 커맨드에 전달 — `--foo=x` 같은 이름이 옵션으로 해석되는 것을 방지.

### 자동 감지

감지 우선순위 (`scripts/lint-autofix-detect.sh`):

1. 전역 캐시 `~/.config/sazo-ai-harness/lint-fix-cache.json`
2. `package.json`에 `lint-staged` 의존성 존재 → `{yarn|pnpm|npx} lint-staged` (파일 인자 불필요, lint-staged가 내부에서 staged 감지)
3. `pyproject.toml`의 `[tool.ruff]` → `ruff check --fix <files>` (파일 인자 필요)
4. `pyproject.toml`의 `[tool.black]` → `black <files>` (파일 인자 필요)
5. `go.mod` → `gofmt -w <files>` (파일 인자 필요)
6. 없음 → hook이 stderr로 안내 + 해당 커밋은 lint 없이 통과

### 감지 실패 시 캐시 등록

hook stderr 안내에 따라 사용자에게 정확한 커맨드를 물어본 뒤:

```bash
# repo 루트에서
~/.config/sazo-ai-harness/packages/ai-harness/scripts/pre-commit-lint.sh --set 'npx lint-staged'

# 파일 인자를 받는 커맨드면
~/.config/sazo-ai-harness/packages/ai-harness/scripts/pre-commit-lint.sh --set 'yarn lint --fix' --files-arg

# 등록 해제
~/.config/sazo-ai-harness/packages/ai-harness/scripts/pre-commit-lint.sh --unset
```

캐시 키는 `git rev-parse --show-toplevel` 경로의 sha256. repo별 독립이며, **worktree 경로가 다르면 worktree마다 재등록 필요**.

**⚠️ `--set`의 커맨드는 이후 매 커밋마다 `bash -c`로 평가된다.** `$(...)`, `` ` ``, `;`, `&&`, 파이프 등이 포함되면 실행됨. 신뢰할 수 있는 단일 바이너리 + flag 형태로만 등록하고, 복잡한 로직은 저장소 내 스크립트로 빼서 경로만 등록하는 것이 안전.

### 한계

- **Claude Code 전용**. OpenCode 등 다른 AI는 PreToolUse hook이 없어 적용 불가 — 해당 환경에선 `claude-md/CLAUDE.md`의 "커밋 규율" 지시 기반으로만 작동.
- **사용자 터미널 직접 `git commit`은 커버하지 않는다**. 이 hook은 Claude Code tool call layer에서만 발동하므로 사람 commit에는 영향 없음 — AI 작업의 전역 기본 방어막 성격. 더 강건한 방어가 필요한 저장소는 자체 Husky + lint-staged 도입 권장 (cf. sazo-ko-admin 하네스 1차 강화 PR #256). ai-harness는 프로젝트 Husky를 대체하지 않고 보완하는 레이어.
- **`--no-verify`는 우회 수단 아님**. 이 hook은 git이 아니라 Claude Code 레벨이라 `--no-verify`로 스킵되지 않음. 정당한 사유로도 우회 escape hatch는 제공하지 않는다. hook이 과도하게 느리거나 부적절하면 repo의 lint 설정 자체를 고쳐야 한다.
- **lint 실행이 60초 초과하면 stderr 경고**, 차단은 안 함.
- **신뢰할 수 있는 저장소 전제**. 악성 `package.json`에 `lint-staged` 의존성이 선언돼 있으면 hook이 `npx lint-staged`를 자동 실행하며, lint-staged의 config는 임의 쉘 명령을 허용한다. 이는 본 hook만의 이슈가 아니라 Claude Code에서 신뢰 없는 저장소를 여는 일반적 위협 — 신뢰할 수 없는 repo에서는 Claude Code 사용 자체를 재고해야 한다.

## 자동 업데이트

- Claude 세션 시작 시 자동 체크
- 새 파일 추가 시 자동으로 심볼릭 링크 생성
- CLAUDE.md managed block 자동 교체 (유저 커스텀 내용 보존)
- 1시간 이내 체크했으면 스킵
- 로그: `~/.claude/logs/ai-harness-update.log`

---

## 포함된 항목

### Commands

| 커맨드                | 설명                             |
| --------------------- | -------------------------------- |
| `/weekly-report` | 주간 업무 보고서 생성 — 코드, 이슈, 메일, 슬랙, 캘린더, 문서 전체 취합 (Notion용) |

### Skills

(기여 환영!)

### Agents

6단계 workflow에 맞춰 역할별로 모델이 선택됨. 메인 루프가 오케스트레이터로 동작하며, 아래 에이전트에게 독립 컨텍스트로 위임한다. 자세한 원칙은 `CLAUDE.md` §0 참고.

| 에이전트 | 역할 | 모델 | 주 사용 단계 |
|---|---|---|---|
| `code-searcher` | in-repo 검색/심볼 찾기 | haiku | 2 (리서치) |
| `docs-researcher` | 외부 docs/OSS 리서치 (context7 MCP 지원) | haiku | 2 (리서치) |
| `image-analyzer` | 스크린샷/다이어그램/PDF 분석 | haiku | 2 (리서치) |
| `plan-drafter` | 전략 인터뷰 + 실행 플랜 초안 | opus | 3 (플랜) |
| `plan-auditor` | 플랜 gap 분석 | sonnet | 3 (플랜) |
| `plan-critic` | 플랜 최종 게이트 (APPROVE/BLOCK) | sonnet | 3 (플랜) |
| `plan-executor` | 승인된 플랜 순차 실행 | sonnet | 4 (구현) |
| `ui-engineer` | 프론트엔드/UI/UX 구현 | sonnet | 4 (구현) |
| `code-reviewer` | diff 기반 종합 코드리뷰 | sonnet | 6 (리뷰) |
| `architect-advisor` | 아키텍처/설계 심층 판단, read-only | sonnet (opus 승격 가능) | 6 (리뷰 심층) |
| `doc-writer` | 기술 문서 작성 | haiku | 7 (마무리) |

**이전 이름에서 바뀐 경우** (2026-04-19 rename): `explore→code-searcher`, `librarian→docs-researcher`, `multimodal-looker→image-analyzer`, `document-writer→doc-writer`, `frontend-engineer→ui-engineer`, `prometheus→plan-drafter`, `metis→plan-auditor`, `momus→plan-critic`, `atlas→plan-executor`, `oracle→architect-advisor`. `sisyphus`는 subagent nesting 제약 때문에 제거됨. `install.sh`는 구 이름 파일 발견 시 삭제 여부를 물어본다.

---

## 기여하기

### 1. 저장소 클론

```bash
git clone https://github.com/SAZO-KR/sazo-toolkit.git
cd sazo-toolkit/packages/ai-harness
```

### 2. 타입별 생성 방법

#### Command 추가

```bash
cp commands/_TEMPLATE.md commands/my-command.md
```

**필수 필드:**

```yaml
---
description: 커맨드 설명 (슬래시 메뉴에 표시)
---
```

**선택 필드:** `allowed-tools`, `model`, `argument-hint`

#### Skill 추가

```bash
mkdir skills/my-skill
cp skills/_TEMPLATE/SKILL.md skills/my-skill/SKILL.md
```

**필수 필드:**

```yaml
---
name: Skill Name
description: 언제 사용하는지 설명
---
```

**핵심 패턴:** `<required>` 블록으로 TodoWrite 체크리스트 정의

**스킬이 요구하는 bash 권한 선언 (필수):**

스킬이 `~/.claude/settings.json` 기본 `permissions.allow`에 없는 bash 명령(예: `date`, `sleep`, `echo`, `seq` 등)을 사용한다면, **반드시** 해당 스킬 디렉토리에 `permissions.json`을 두어야 한다. 그렇지 않으면 사용자가 스킬 실행 중 반복적으로 권한 승인을 요구받게 된다.

```bash
cp skills/_TEMPLATE/permissions.json skills/my-skill/permissions.json
```

포맷:

```json
{
  "bash": ["date:*", "sleep:*", "echo:*", "seq:*"]
}
```

- 값은 `Bash(...)` 권한 표기의 괄호 **안쪽** 패턴 — `date:*`는 `Bash(date:*)`로 wrap되어 `~/.claude/settings.json`의 `permissions.allow`에 union됨
- `install.sh` 설치 시점과 `auto-update.sh` 세션 시작 시점에 자동 merge (중복·커스텀 엔트리 보존)
- 기본 allow에 이미 있는 명령(`gh api:*`, `git:*`, `jq:*` 등)은 선언 불필요
- 추가가 필요한 명령이 없으면 `permissions.json` 파일 자체를 두지 않아도 됨

**DO / DON'T:**

| ✅ DO | ❌ DON'T | 이유 |
| --- | --- | --- |
| `"date:*"` | `"Bash(date:*)"` | `Bash(...)`는 자동으로 wrap되므로 이중 wrap 방지 |
| `"sleep:*"` | `"sleep"` | prefix 매칭에 `:*` 필수 (뒤 인자 허용) |
| `"echo:*"` | `"for:*"`, `"while:*"`, `"if:*"` | bash keyword는 권한 매칭 대상이 아님 (실행되는 외부 명령만 선언) |
| 실제 실행되는 유틸만 (date/sleep/echo/seq 등) | 보호 위해 과도하게 선언 | dead entry 양산. 스킬 SKILL.md에서 실제 호출하는 명령만 나열 |

#### Agent 추가

```bash
cp agents/_TEMPLATE.md agents/my-agent.md
```

**필수 필드:**

```yaml
---
name: agent-name
description: 에이전트 역할 설명
color: blue
---
```

**OpenCode에서 특정 모델로 실행하려면** `opencode/agents.json`에도 추가:

```json
{
  "my-agent": {
    "model": "provider/model-id",
    "description": "에이전트 설명"
  }
}
```

#### OpenCode 플러그인/모델 변경

`opencode/config.json`을 수정하면 install.sh가 팀원 `opencode.json`에 머지합니다.

### 3. PR 생성

```bash
git add .
git commit -m "feat(ai-harness): add my-command command"
git push origin main
```

### 4. 반영

- 팀원들은 다음 Claude 세션 시작 시 자동 반영
- 새 파일은 자동으로 심볼릭 링크 생성됨

---

## 타입별 상세 가이드

### Commands

슬래시 명령어. 반복 작업 자동화에 적합.

```markdown
---
description: 주간 리포트 생성
allowed-tools: Read, Grep, Bash(git:*)
---

## Step 1: 데이터 수집
...
```

**동적 요소:**

- `$ARGUMENTS` - 전체 인자
- `$1`, `$2` - 개별 인자
- `@path/to/file` - 파일 내용 삽입
- `` !`command` `` - Bash 실행 결과 삽입

### Skills

재사용 가능한 지식/지침. 복잡한 워크플로우 정의에 적합.

```markdown
---
name: Code Review Checklist
description: PR 리뷰 시 사용
---

<required>
*CRITICAL* Add the following steps to your Todo list using TodoWrite:

1. 보안 취약점 체크
2. 성능 이슈 체크
3. 코드 컨벤션 체크
</required>

## 상세 가이드
...
```

### Agents

특화된 페르소나. 전문 역할 정의에 적합.

```markdown
---
name: security-reviewer
description: 보안 취약점 전문 리뷰어
color: red
---

# Security Reviewer

보안 전문가 관점에서 코드를 검토...

## Core Expertise
- SQL Injection
- XSS
- CSRF
...
```

---

## 네이밍 컨벤션

| 타입    | 파일명                | 예시                    |
| ------- | --------------------- | ----------------------- |
| Command | `kebab-case.md`       | `weekly-report.md`      |
| Skill   | `kebab-case/SKILL.md` | `code-review/SKILL.md`  |
| Agent   | `kebab-case.md`       | `security-reviewer.md`  |

---

## ai-prompts에서 마이그레이션

기존 `ai-prompts` 사용자는 제거 후 재설치:

```bash
# 기존 제거
rm -rf ~/.config/sazo-ai-prompts
find ~/.claude/commands -type l -lname '*sazo-ai-prompts*' -delete 2>/dev/null
find ~/.claude/skills -type l -lname '*sazo-ai-prompts*' -delete 2>/dev/null
find ~/.claude/agents -type l -lname '*sazo-ai-prompts*' -delete 2>/dev/null
rm -f ~/.config/opencode/plugins/sazo-ai-prompts-update.ts

if [ -f ~/.claude/settings.json ]; then
    TMP=$(mktemp)
    jq '.hooks.SessionStart = [.hooks.SessionStart[]? | select(any(.hooks[]?.command; contains("auto-update.sh")) | not)]' ~/.claude/settings.json > "$TMP" && mv "$TMP" ~/.claude/settings.json || rm -f "$TMP"
fi

# 새로 설치
curl -fsSL https://raw.githubusercontent.com/SAZO-KR/sazo-toolkit/main/packages/ai-harness/install.sh | bash
```

## 제거

```bash
rm -rf ~/.config/sazo-ai-harness

find ~/.claude/commands -type l -lname '*sazo-ai-harness*' -delete 2>/dev/null
find ~/.claude/skills -type l -lname '*sazo-ai-harness*' -delete 2>/dev/null
find ~/.claude/agents -type l -lname '*sazo-ai-harness*' -delete 2>/dev/null

if [ -f ~/.claude/settings.json ]; then
    TMP=$(mktemp)
    jq '.hooks.SessionStart = [.hooks.SessionStart[]? | select(any(.hooks[]?.command; contains("auto-update.sh")) | not)]' ~/.claude/settings.json > "$TMP" && mv "$TMP" ~/.claude/settings.json || rm -f "$TMP"
fi

# CLAUDE.md managed block 제거
if [ -f ~/.claude/CLAUDE.md ] \
  && grep -qF "BEGIN SAZO-AI-HARNESS MANAGED BLOCK" ~/.claude/CLAUDE.md \
  && grep -qF "END SAZO-AI-HARNESS MANAGED BLOCK" ~/.claude/CLAUDE.md; then
    TMP=$(mktemp)
    awk '/^# BEGIN SAZO-AI-HARNESS MANAGED BLOCK/{skip=1;next} /^# END SAZO-AI-HARNESS MANAGED BLOCK/{skip=0;next} !skip' ~/.claude/CLAUDE.md > "$TMP" && mv "$TMP" ~/.claude/CLAUDE.md
    echo "CLAUDE.md managed block removed (user content preserved)"
fi
```
