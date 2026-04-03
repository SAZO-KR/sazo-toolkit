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
| Commands        | `~/.claude/commands/*.md` |
| Skills          | `~/.claude/skills/*/`     |
| Agents          | `~/.claude/agents/*.md`   |
| Auto-update     | SessionStart hook         |

### OpenCode (선택)

| 항목               | 설명                                           |
| ------------------ | ---------------------------------------------- |
| OpenCode 설치      | `brew install opencode` (미설치 시)            |
| Plugins            | oh-my-opencode, anthropic-auth, antigravity 등 |
| Provider Models    | Antigravity Gemini 커스텀 모델 정의            |
| claude-sync        | Claude CLI → OpenCode 토큰 자동 동기화 (15분)  |
| claude-sync-notify | 토큰 만료 시 macOS 알림                        |

## 자동 업데이트

- Claude 세션 시작 시 자동 체크
- 새 파일 추가 시 자동으로 심볼릭 링크 생성
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

(기여 환영!)

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
| Command | `kebab-case.md`       | `generate-changelog.md` |
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
```
