#!/bin/bash
# auto-update.sh 의 notify_sleep_guard_sudoers_missing 실제 함수 smoke test.
#
# 함수 정의만 로드: `AUTOUPDATE_LOAD_ONLY=1 source auto-update.sh` 로 sourcing
# 하면 early-return 되어 함수 정의만 남고 실행 본문은 건너뛴다.
# sudoers 존재 여부는 `_SLEEP_GUARD_SUDOERS_CHECK` 환경변수로 override.
#
# 검증:
#   1) init-done O + sudoers missing → stdout에 경고, throttle 파일 생성
#   2) init-done X → no-op
#   3) throttle 24h 이내 → 재출력 안 함
#   4) throttle 24h 초과 → 다시 출력
#   5) throttle 파일 손상 (비숫자) → 재출력
#   6) sudoers ok → 출력 없음
#   7) 비-macOS (uname stub) → no-op
#   8) 동시 호출 race → set -C로 한 번만 출력

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
AUTOUPDATE="$SCRIPT_DIR/auto-update.sh"

if [ ! -f "$AUTOUPDATE" ]; then
    echo "FAIL: $AUTOUPDATE not found"; exit 1
fi

FAIL=0
pass() { echo "  OK   $1"; }
fail() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }

SANDBOX=$(mktemp -d)
trap "rm -rf '$SANDBOX'" EXIT

# 헬퍼: sandbox HOME + override로 실제 함수 호출
call_notify() {
    local home="$1" sudoers_check="$2" uname_override="${3:-}"

    # uname override는 PATH 앞에 stub 심어서 구현
    local stub_dir=""
    if [ -n "$uname_override" ]; then
        stub_dir="$home/stub-bin"
        mkdir -p "$stub_dir"
        cat > "$stub_dir/uname" <<EOF
#!/bin/bash
echo "$uname_override"
EOF
        chmod +x "$stub_dir/uname"
    fi

    env -i \
        HOME="$home" \
        PATH="${stub_dir:+$stub_dir:}/usr/bin:/bin" \
        HARNESS_DIR="$SCRIPT_DIR/.." \
        _SLEEP_GUARD_SUDOERS_CHECK="$sudoers_check" \
        AUTOUPDATE_LOAD_ONLY=1 \
        bash -c "source '$AUTOUPDATE' && notify_sleep_guard_sudoers_missing" 2>&1
}

# ── Case 1: init-done O + sudoers missing → 경고 + throttle 파일 생성 ──
echo "Case 1: init-done 마커 + sudoers missing → 경고"
H="$SANDBOX/c1"; mkdir -p "$H/.config/sazo-ai-harness"
touch "$H/.config/sazo-ai-harness/.sleep-guard-init-done"
out=$(call_notify "$H" "missing" "Darwin")
if echo "$out" | grep -q "sleep-guard"; then pass "경고 메시지 출력"
else fail "출력 누락: $out"; fi
if [ -f "$H/.config/sazo-ai-harness/.sleep-guard-notify-throttle" ]; then pass "throttle 파일 생성"
else fail "throttle 파일 없음"; fi

# ── Case 2: init-done 마커 없음 → no-op ──
echo ""
echo "Case 2: init-done 마커 없음 → no-op"
H="$SANDBOX/c2"; mkdir -p "$H/.config/sazo-ai-harness"
out=$(call_notify "$H" "missing" "Darwin")
if [ -z "$out" ]; then pass "출력 없음 (early return)"
else fail "unexpected: $out"; fi

# ── Case 3: throttle 24h 이내 → 재출력 안 함 ──
echo ""
echo "Case 3: throttle 24h 이내 → no-op"
H="$SANDBOX/c3"; mkdir -p "$H/.config/sazo-ai-harness"
touch "$H/.config/sazo-ai-harness/.sleep-guard-init-done"
now=$(date +%s); recent=$(( now - 3600 * 23 ))
echo "$recent" > "$H/.config/sazo-ai-harness/.sleep-guard-notify-throttle"
out=$(call_notify "$H" "missing" "Darwin")
if [ -z "$out" ]; then pass "throttle 이내 — 출력 없음"
else fail "throttle 위반: $out"; fi

# ── Case 4: throttle 24h 초과 → 다시 출력 ──
echo ""
echo "Case 4: throttle 24h 초과 → 재출력"
H="$SANDBOX/c4"; mkdir -p "$H/.config/sazo-ai-harness"
touch "$H/.config/sazo-ai-harness/.sleep-guard-init-done"
old=$(( now - 3600 * 25 ))
echo "$old" > "$H/.config/sazo-ai-harness/.sleep-guard-notify-throttle"
out=$(call_notify "$H" "missing" "Darwin")
if echo "$out" | grep -q "sleep-guard"; then pass "throttle 만료 — 재출력"
else fail "재출력 실패"; fi

# ── Case 5: throttle 파일 손상 (비숫자) → 재출력 ──
echo ""
echo "Case 5: throttle 파일 손상 → 재출력"
H="$SANDBOX/c5"; mkdir -p "$H/.config/sazo-ai-harness"
touch "$H/.config/sazo-ai-harness/.sleep-guard-init-done"
echo "not-a-number" > "$H/.config/sazo-ai-harness/.sleep-guard-notify-throttle"
out=$(call_notify "$H" "missing" "Darwin")
if echo "$out" | grep -q "sleep-guard"; then pass "손상 throttle — 재출력"
else fail "손상 throttle 처리 실패"; fi

# ── Case 6: sudoers ok → 출력 없음 ──
echo ""
echo "Case 6: sudoers 정상 → no-op"
H="$SANDBOX/c6"; mkdir -p "$H/.config/sazo-ai-harness"
touch "$H/.config/sazo-ai-harness/.sleep-guard-init-done"
out=$(call_notify "$H" "ok" "Darwin")
if [ -z "$out" ]; then pass "sudoers ok — 출력 없음"
else fail "unexpected output when ok: $out"; fi

# ── Case 7: 비-macOS → no-op ──
echo ""
echo "Case 7: 비-macOS → no-op"
H="$SANDBOX/c7"; mkdir -p "$H/.config/sazo-ai-harness"
touch "$H/.config/sazo-ai-harness/.sleep-guard-init-done"
out=$(call_notify "$H" "missing" "Linux")
if [ -z "$out" ]; then pass "Linux — 출력 없음"
else fail "Linux에서 출력됨: $out"; fi

# ── Case 8: 동시 호출 race (set -C) → 한 번만 출력 ──
echo ""
echo "Case 8: 동시 호출 race → 한 번만 출력"
H="$SANDBOX/c8"; mkdir -p "$H/.config/sazo-ai-harness"
touch "$H/.config/sazo-ai-harness/.sleep-guard-init-done"
# 병렬 3회 호출. set -C로 원자 write이라 한 번만 성공해야 함.
(call_notify "$H" "missing" "Darwin" > "$SANDBOX/p1.out") &
(call_notify "$H" "missing" "Darwin" > "$SANDBOX/p2.out") &
(call_notify "$H" "missing" "Darwin" > "$SANDBOX/p3.out") &
wait
hits=0
for f in "$SANDBOX/p1.out" "$SANDBOX/p2.out" "$SANDBOX/p3.out"; do
    [ -s "$f" ] && hits=$((hits + 1))
done
# set -C 는 O_EXCL write이라 정확히 1회만 성공해야 함. 2회 이상이면 원자성
# 위반 — 절대로 PASS하면 안 됨.
if [ "$hits" -eq 1 ]; then
    pass "race 원자성 — 정확히 1회 출력"
else
    fail "race 실패 — $hits 회 출력 (expected exactly 1)"
fi

echo ""
echo "─────────────────────"
if [ "$FAIL" -eq 0 ]; then
    echo "OK: All sleep-guard-notify smoke tests passed"
    exit 0
else
    echo "FAIL: $FAIL assertion(s) failed"
    exit 1
fi
