---
description: 최근 Claude Code 세션을 되짚어 하네스 개선 후보(룰/hook/subagent 체크리스트/삭제)를 도출
argument-hint: [기간, 예: 7d (기본), 14d, 30d]
---

## 목적

최근 $1 (미지정 시 **7일**) 동안의 Claude Code session 로그를 mining해, 반복 교정·가이드라인 위반·툴 사용 비효율을 찾아내고 **하네스 개선 후보**를 제안한다. 사람 경험에 의존한 "그거 또 그랬네"를 데이터화하는 절차.

## 원칙 (반드시 준수)

- **메타 churn 경계**: 1회성 교정은 제안 대상이 아니다. **N회/M세션 이상** 반복되는 신호만.
- **정량화**: "자주 발생" 같은 모호한 표현 금지. "X회, Y개 세션, Z일 중"처럼 수치.
- **기존 룰의 효과도 평가**: 잘 지켜지는데 과잉·반복 명시된 룰은 **delete** 후보로.
- 외부 네트워크 호출 금지 — 로컬 jsonl만 읽는다.
- 발견한 것 중 **확신이 없는 것은 "검토 필요"로 표기**. 임의 단정 금지.

## 대상 세션 수집

Claude Code session 로그 구조:
- 메인 세션: `~/.claude/projects/<project-slug>/<uuid>.jsonl` (프로젝트 디렉토리 바로 아래)
- subagent: `~/.claude/projects/<project-slug>/<uuid>/subagents/agent-*.jsonl` (제외)

메인이 직접 목록 구성:

```bash
find ~/.claude/projects -maxdepth 2 -name '*.jsonl' -not -path '*/subagents/*' -mtime -<일수> -size +10k
```

- `<일수>` = $1의 숫자 (기본 7)
- mtime 필터로 기간 제한
- 10KB 미만(진입만 하고 종료) 제외
- subagents/ 경로 전면 제외 (메인 루프만 대상 — subagent는 짧고 자기완결적이라 signal 신뢰도 낮음)

## 분석 (subagent 위임)

세션 파일 목록을 2~4개 그룹으로 나눠 **`code-searcher` subagent(haiku) 병렬 호출** (jsonl 파싱을 위한 재활용 — 전용 log-analyzer 에이전트가 없어 일반 검색/grep 능력을 빌려옴). 각 subagent에게 다음 지시:

> 아래 session jsonl 파일들(경로 리스트)을 읽고 다음 **신호**만 추출하라.
>
> 1. **사용자 교정 신호** — `type: "user"` 메시지 내용에 교정 의도 표현:
>    - "아니", "그거 아니야", "그러지 말고", "왜 그걸", "다시 해", "틀렸어"
>    - "그게 아니라", "그건 필요 없어", "그렇게 하지 마"
>    - 교정 직전 **assistant의 마지막 액션(tool call 또는 텍스트 요약)**을 함께 기록
>
> 2. **가이드라인 위반 의심** — assistant tool_use 중:
>    - `Bash`로 직접 `grep/find/rg/cat/head/tail/sed/awk` 실행 (→ 전용 도구 미사용)
>    - main/master/dev 브랜치에서 Edit/Write 직접 시도 (보호 브랜치 규칙)
>    - `git commit --no-verify` 또는 `as any` / `as unknown as` / `@ts-ignore` 포함 편집
>    - Opus급 에이전트가 많은 수(5+)의 Read/Grep을 직접 수행 (subagent 미위임)
>
> 3. **툴 사용 비효율** — 동일 파일을 5회 이상 Read, 동일 검색을 3회 이상 Grep, 실패 tool call을 3회 이상 재시도.
>
> 4. **계획 누락** — TDD/플랜 승인 없이 Edit/Write부터 시작한 구현 세션.
>
> 각 신호마다 `{session_id, timestamp, signal_type, context: "100자 이내"}` 구조로 JSON 리스트 반환. 원문 그대로 옮기지 말고 요약.

## 집계 및 리포트 작성

subagent 결과를 받아 메인이 통합·카테고리화·빈도 집계. 최종 리포트 구조:

### 1. 데이터 개요
- 대상 기간, 세션 수, 총 메시지 수, 총 tool call 수

### 2. 반복 패턴 Top 10
카테고리, 빈도(회/세션 수), 대표 예시 1~2건(session file + 시각).

### 3. 하네스 개선 제안
각 상위 패턴마다:
- **위치**: (a) 전역 CLAUDE.md 룰 추가 / (b) settings.json hook 추가 / (c) subagent 체크리스트 보강 / (d) 기존 룰 **delete**
- **구체안**: 1~2문장. 작성 시 **긍정형·경계형 지시**로 (부정형 "don't X"는 Opus 4.7이 과도 추종)
- **투자 대비 효과**: high / medium / low

### 4. 잘 지켜지는 룰 (칭찬 겸 유지 확인)
위반이 0~2회에 그친 기존 룰을 1~3개 나열. 과잉 명시된 것은 delete 후보.

### 5. 한계
- LLM judge의 false positive 가능성
- 교정 키워드 휴리스틱의 누락
- 단일 사용자·소규모 샘플의 일반화 주의

## 출력

마크다운 리포트. 파일 저장 없이 메시지로 리턴. 사용자가 보고 실제 반영 결정.

분량 guideline: **2000자 이내**. 장황함 방지 목적 커맨드이므로 메타 아이러니 피할 것.
