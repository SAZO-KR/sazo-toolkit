#!/bin/bash
# codex-approval-detection.smoke.sh
#
# 목적: automated-code-review-cycle SKILL.md의 Codex 승인 판정 로직이
# 실제 GitHub API 응답 구조와 일치하는지 검증한다.
#
# 과거 버그: SKILL.md Step 3-3이 `gh pr view --json body`에서 "👍" 문자열을
# grep하여 판정했으나, Codex는 PR(issue) reactions 엔드포인트에
# `content: "+1"`으로 승인을 표시한다. 텍스트 레벨에서는 결코 감지되지 않음.
#
# 이 테스트는 고정 픽스처 2건으로 회귀를 막는다:
#   - PR #11 (SAZO-KR/sazo-toolkit): Codex 승인됨 (+1 reaction 존재)
#   - PR #12 (SAZO-KR/sazo-toolkit): Codex 미승인 (+1 reaction 없음)
#
# gh CLI + 네트워크가 필요하므로 offline/미인증 환경에서는 SKIP.
# 실행: bash packages/ai-harness/scripts/tests/codex-approval-detection.smoke.sh

set -u

OWNER="SAZO-KR"
REPO="sazo-toolkit"
APPROVED_PR=11
UNAPPROVED_PR=12

if ! command -v gh >/dev/null 2>&1; then
    echo "SKIP: gh CLI not installed"
    exit 0
fi

if ! gh auth status >/dev/null 2>&1; then
    echo "SKIP: gh not authenticated"
    exit 0
fi

# SKILL.md Step 3-3에 기술된 판정 로직을 그대로 재현한다.
check_codex_approval() {
    local pr_num="$1"
    # --paginate는 페이지별로 jq를 독립 실행하므로 `| length`를 --jq 안에 넣으면
    # 페이지당 한 줄 숫자가 출력되어 bash `-gt` 비교가 깨진다.
    # 매칭 객체를 emit한 뒤 `jq -s 'length'`로 전 페이지를 슬럽해 단일 정수로 집계.
    gh api "repos/$OWNER/$REPO/issues/$pr_num/reactions" --paginate \
        --jq '.[] | select(.content == "+1" and (.user.login | test("codex"; "i")))' \
        2>/dev/null \
        | jq -s 'length'
}

FAIL=0

APPROVED_COUNT=$(check_codex_approval "$APPROVED_PR")
if [ "${APPROVED_COUNT:-0}" -gt "0" ]; then
    echo "PASS: PR #$APPROVED_PR detected as approved (+1 count=$APPROVED_COUNT)"
else
    echo "FAIL: PR #$APPROVED_PR should be approved but got count=$APPROVED_COUNT"
    FAIL=1
fi

UNAPPROVED_COUNT=$(check_codex_approval "$UNAPPROVED_PR")
if [ "${UNAPPROVED_COUNT:-0}" -eq "0" ]; then
    echo "PASS: PR #$UNAPPROVED_PR detected as not-approved (+1 count=0)"
else
    echo "FAIL: PR #$UNAPPROVED_PR should be unapproved but got count=$UNAPPROVED_COUNT"
    FAIL=1
fi

# 회귀 방지: 과거 버그 로직(PR body 텍스트에서 👍 grep)은 PR #11을 감지하지 못해야 한다.
OLD_LOGIC_HIT=$(gh pr view "$APPROVED_PR" --repo "$OWNER/$REPO" --json body -q .body 2>/dev/null | grep -c "👍" || true)
if [ "${OLD_LOGIC_HIT:-0}" -eq "0" ]; then
    echo "PASS: legacy PR-body grep correctly misses PR #$APPROVED_PR (confirms bug root cause)"
else
    echo "NOTE: PR #$APPROVED_PR body happens to contain 👍 (old logic would spuriously pass)"
fi

if [ "$FAIL" -ne 0 ]; then
    echo ""
    echo "FAIL: Codex approval detection logic does not match real API shape."
    exit 1
fi

echo ""
echo "OK: Codex approval detection verified against live fixtures."
