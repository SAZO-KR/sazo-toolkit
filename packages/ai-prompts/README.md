# AI Prompts

팀 공용 AI 프롬프트 (Commands, Skills, Agents) 저장소

## 설치

```bash
curl -fsSL https://raw.githubusercontent.com/SAZO-KR/sazo-toolkit/main/packages/ai-prompts/install.sh | bash
```

## 설치되는 것

| 항목 | 경로 |
|------|------|
| 설치 위치 | `~/.config/sazo-ai-prompts/` |
| Commands | `~/.claude/commands/*.md` |
| Skills | `~/.claude/skills/*/` |
| Agents | `~/.claude/agents/*.md` |
| Auto-update | SessionStart hook |

## 자동 업데이트

- Claude 세션 시작 시 자동 체크
- 새 파일 추가 시 자동으로 심볼릭 링크 생성
- 1시간 이내 체크했으면 스킵
- 로그: `~/.claude/logs/ai-prompts-update.log`

---

## 포함된 항목

### Commands

| 커맨드 | 설명 |
|--------|------|
| `/generate-changelog` | 주간 개발 리포트 생성 (Notion용) |

### Skills

(아직 없음 - 기여 환영!)

### Agents

(아직 없음 - 기여 환영!)

---

## 기여하기

### 1. 저장소 클론

```bash
git clone https://github.com/SAZO-KR/sazo-toolkit.git
cd sazo-toolkit/packages/ai-prompts
```

### 2. 타입별 생성 방법

#### Command 추가

```bash
# 템플릿 복사
cp commands/_TEMPLATE.md commands/my-command.md

# 편집 후 커밋
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
# 디렉토리 생성
mkdir skills/my-skill
cp skills/_TEMPLATE/SKILL.md skills/my-skill/SKILL.md

# 편집 후 커밋
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
# 템플릿 복사
cp agents/_TEMPLATE.md agents/my-agent.md

# 편집 후 커밋
```

**필수 필드:**
```yaml
---
name: agent-name
description: 에이전트 역할 설명
color: blue
---
```

### 3. PR 생성

```bash
git add .
git commit -m "feat(ai-prompts): add my-command command"
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

| 타입 | 파일명 | 예시 |
|------|--------|------|
| Command | `kebab-case.md` | `generate-changelog.md` |
| Skill | `kebab-case/SKILL.md` | `code-review/SKILL.md` |
| Agent | `kebab-case.md` | `security-reviewer.md` |

---

## 제거

```bash
rm -rf ~/.config/sazo-ai-prompts

find ~/.claude/commands -type l -lname '*sazo-ai-prompts*' -delete 2>/dev/null
find ~/.claude/skills -type l -lname '*sazo-ai-prompts*' -delete 2>/dev/null
find ~/.claude/agents -type l -lname '*sazo-ai-prompts*' -delete 2>/dev/null

if [ -f ~/.claude/settings.json ]; then
    TMP=$(mktemp)
    jq '.hooks.SessionStart = [.hooks.SessionStart[]? | select(.hooks[]?.command | contains("auto-update.sh") | not)]' ~/.claude/settings.json > "$TMP" && mv "$TMP" ~/.claude/settings.json 2>/dev/null || rm -f "$TMP"
fi
```
