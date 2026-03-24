---
description: Analyze git changes since last Friday and generate weekly report markdown for Notion
---

## Your Task

Generate a **weekly developer report summary**. Organize by meaningful work units so team members can quickly identify "what's happening" and "what's relevant to me".

**CRITICAL: All output MUST be written in Korean. Every category name, description, and summary must be in Korean language.**

## Step 1: Find Base Commit (Previous Friday)

```bash
git fetch origin main

# Get previous Friday date
if [[ $(date +%u) -le 5 ]]; then
  DAYS_BACK=$(($(date +%u) + 2))
else
  DAYS_BACK=$(($(date +%u) - 5))
fi
LAST_FRIDAY=$(date -v-${DAYS_BACK}d +%Y-%m-%d 2>/dev/null || date -d "${DAYS_BACK} days ago" +%Y-%m-%d)
echo "Base date: $LAST_FRIDAY"

# Find the first commit ON or AFTER last Friday
BASE_COMMIT=$(git log origin/main --since="$LAST_FRIDAY" --reverse --format="%H" | head -1)

if [ -z "$BASE_COMMIT" ]; then
  BASE_COMMIT=$(git log origin/main --until="$LAST_FRIDAY" --format="%H" -1)
fi

echo "Base commit: $BASE_COMMIT"
```

## Step 2: Get Total Diff

```bash
git diff --name-status $BASE_COMMIT..origin/main
git diff --stat $BASE_COMMIT..origin/main
git diff $BASE_COMMIT..origin/main
```

## Step 3: Write Weekly Summary

### Target Audience: 프로덕트 조직 (개발 배경 있음)

프로덕트 조직원이 "이번 주에 뭐가 됐지?"를 빠르게 파악할 수 있도록 작성.
대부분 개발에 익숙하므로 기술 용어 병기 OK.

### Business Impact Filter

**포함 (✅ INCLUDE)**
- 새로운 기능/플랫폼 지원
- 비즈니스 로직 변경
- 성능/안정성 개선
- 외부 시스템 연동 변경
- 버그 수정
- 모니터링/알림 추가
- 리팩토링 (구조 개선, 모듈화 등)

**제외 또는 1줄 요약 (❌ EXCLUDE or SUMMARIZE)**
- 타입 정의 수정, 린트 에러 수정
- 테스트 코드 추가/수정만 있는 경우
- 의존성 업데이트
- 문서 수정

### Writing Guidelines

1. **비즈니스 용어(개발 용어)** - 결과를 먼저, 괄호 안에 기술 용어 병기. 예: "상품 동기화 속도 개선 (N+1 쿼리 제거)"
2. **결과 중심** - "무엇을 했는지"보다 "무엇이 가능해졌는지/개선됐는지"
3. **도메인별 그룹핑** - eBay, Joom, Bunjang, 상품, 주문 등 비즈니스 도메인으로 먼저 분류
4. **1줄 요약** - 세부사항은 과감히 생략
5. **한국어로 작성** - 모든 카테고리명, 설명은 한국어

## Step 4: Output Format (Notion-compatible)

**IMPORTANT: Use this exact format for Notion compatibility**

- Category line: `- **[emoji] Category Name**` (bullet point BEFORE emoji)
- Sub-items: 4-space indent `    - description`
- No blank lines between items in the same category

### Format Template:

```
- **[emoji] Category Name (in Korean)**
    - Sub-item description (in Korean)
    - Another sub-item (in Korean)
- **[emoji] Next Category (in Korean)**
    - Sub-item (in Korean)
```

### Emoji Guidelines:

- 🔐 Auth, OAuth, Security
- ⚡ Performance
- 🏷️ Category mapping, Aspects
- 🎵 K-POP
- 🎛️ Settings, Filters
- 🤖 AI, Translation
- 📦 Product conversion, Import/Export
- 🔔 Alerts, Monitoring
- 🐛 Bug fixes
- ✨ New features
- 🔧 Infrastructure, Refactoring
- 🔄 Sync, Reconciliation
- 🔍 Search
- 🌍 Shipping

### Output Structure Example:

```
- **🔄 재고/주문 정합성**
    - 매일 밤 자동으로 eBay-내부 재고 불일치 체크 (Reconciliation Scheduler)
    - 불일치 발견 시 슬랙 알림 발송
- **🤖 번역 품질 개선**
    - 영어 번역 품질 향상 (ko→ja→en 피벗 번역)
    - 상품명에 브랜드/모델번호 자동 추가
- **📦 JOOM 플랫폼**
    - API 속도 제한 자동 대응 (429 발생 시 동시성 동적 조절)
- **🔧 리팩토링**
    - 동기화 정책 중앙화 (sync-policy.ts로 통합)
```

### Bad vs Good Examples:

```markdown
❌ Bad (코드 레벨, 너무 세부적):
- ProductSyncService.syncProducts에서 findManyWithSort 사용으로 변경
- translationHash, aiPredictionHash 필드를 checksum 계산에 추가

✅ Good (결과 + 기술 용어 병기):
- 변경된 상품만 선별 처리 (per-field hash 도입으로 불필요한 API 호출 감소)
- 동기화 정책 중앙화 (sync-policy.ts로 매직넘버 제거)
```

## Step 5: Present to User

1. Show analysis period: `[last Friday] ~ [today]`
2. Present summary in Notion-compatible format (ALL TEXT IN KOREAN)
3. Ask if adjustments needed

## Notes

- **필터링 원칙**: "팀원이 알면 좋을 변경인가?" 기준
- 테스트/타입 수정만 있는 주: "내부 코드 정리" 1줄로 요약
- 성능 개선이 여러 개: "⚡ 성능 개선" 카테고리로 묶기
- 리팩토링이 여러 개: "🔧 리팩토링" 카테고리로 묶기
- 최종 상태만 (중간 과정 무시)
- **한국어로 작성**: 모든 요약과 설명은 한국어
- **Notion 호환 포맷**: 복사해서 바로 붙여넣기 가능하도록
