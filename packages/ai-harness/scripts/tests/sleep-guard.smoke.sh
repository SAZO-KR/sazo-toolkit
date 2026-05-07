#!/bin/bash
# sleep-guard 스크립트 smoke test — 문법 + 핵심 분기 로직 회귀 감지.
#
# 검증 항목:
#   1) 세 스크립트 bash -n 문법 통과
#   2) launchd.plist.template이 __WATCHDOG__ 치환 후 정상 plist
#   3) caffeinate-session.sh heartbeat/stop 동작 (마커 생성/삭제)
#   4) watchdog.sh가 stale 마커 제거
#   5) setup.sh --quiet 가 init-done 마커 없을 때 no-op (새 사용자 시나리오)
#   6) setup.sh opt-out 마커 존재 시 즉시 exit 0
#   7) setup.sh 비-macOS 시뮬레이션 — Darwin이 아니면 즉시 exit 0
#
# 주의: 실제 pmset / launchctl / sudoers 는 건드리지 않음 (격리된 HOME 사용).
# setup.sh의 "실제 설치" 경로는 단위 테스트 범위 밖 — install.sh 대화형 실행으로 커버.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GUARD_DIR="$SCRIPT_DIR/sleep-guard"

CAFF="$GUARD_DIR/caffeinate-session.sh"
WATCH="$GUARD_DIR/watchdog.sh"
SETUP="$GUARD_DIR/setup.sh"
PLIST_TPL="$GUARD_DIR/launchd.plist.template"

for f in "$CAFF" "$WATCH" "$SETUP" "$PLIST_TPL"; do
    if [ ! -f "$f" ]; then
        echo "FAIL: missing $f"; exit 1
    fi
done

FAIL=0
pass() { echo "  OK   $1"; }
fail() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }

# ─── 1. 문법 ───
echo "Case 1: bash -n syntax"
for f in "$CAFF" "$WATCH" "$SETUP"; do
    if bash -n "$f"; then pass "$(basename "$f") syntax"
    else fail "$(basename "$f") syntax"; fi
done

# ─── 2. plist 치환 ───
echo ""
echo "Case 2: launchd.plist.template 치환"
RENDERED=$(sed \
    -e "s|__WATCHDOG__|/tmp/fake/watchdog.sh|g" \
    -e "s|__STALE_SECS__|1800|g" \
    -e "s|__USER__|testuser|g" \
    "$PLIST_TPL")
if echo "$RENDERED" | grep -q "/tmp/fake/watchdog.sh"; then pass "WATCHDOG 치환"
else fail "WATCHDOG 치환 실패"; fi
if echo "$RENDERED" | grep -q ">1800<"; then pass "STALE_SECS 치환"
else fail "STALE_SECS 치환 실패"; fi
if echo "$RENDERED" | grep -q "testuser"; then pass "USER 치환"
else fail "USER 치환 실패"; fi
if echo "$RENDERED" | grep -q "__WATCHDOG__\|__STALE_SECS__\|__USER__"; then fail "placeholder 잔존"
else pass "placeholder 제거 확인"; fi
if command -v plutil >/dev/null 2>&1; then
    TMP=$(mktemp)
    echo "$RENDERED" > "$TMP"
    # `--`로 file-arg separator 명시 — 일부 plutil 대체 구현은 분리자 없으면 "No files specified" 반환
    if plutil -lint -- "$TMP" >/dev/null 2>&1; then pass "plist 구조 유효"
    else fail "plist 구조 무효"; fi
    rm -f "$TMP"
fi

# ─── 3. caffeinate-session.sh heartbeat/stop 동작 ───
echo ""
echo "Case 3: caffeinate-session.sh heartbeat/stop"
SANDBOX=$(mktemp -d)
# 실제 스크립트가 사용하는 $USER 기반 경로와 일치시킴 (멀티유저 경로 분리 후)
USER_SUFFIX="${USER:-$(id -u)}"
AWAKE_DIR="/tmp/claude-awake-${USER_SUFFIX}"
LOCK_DIR="/tmp/claude-awake-${USER_SUFFIX}.lock.d"
# lock.d 정리 추가 — Case 4 재실행 시 stale lock이 남아 watchdog이 no-op 하는 것 방지
trap "rm -rf '$SANDBOX' '$AWAKE_DIR'/smoke-test-session '$AWAKE_DIR'/smoke-stale-session '$AWAKE_DIR'/smoke-fresh-session '$AWAKE_DIR'/default; rmdir '$LOCK_DIR' 2>/dev/null || true" EXIT
MARKER="$AWAKE_DIR/smoke-test-session"
rm -f "$MARKER"

# heartbeat
echo '{"session_id":"smoke-test-session"}' | "$CAFF" heartbeat
sleep 0.1
if [ -f "$MARKER" ]; then pass "heartbeat 마커 생성"
else fail "heartbeat 마커 생성 실패"; fi

# stop
echo '{"session_id":"smoke-test-session"}' | "$CAFF" stop
sleep 0.1
if [ ! -e "$MARKER" ]; then pass "stop 마커 삭제"
else fail "stop 마커 삭제 실패"; fi

# 잘못된 mode
RC=0
echo '{}' | "$CAFF" invalid-mode || RC=$?
if [ "$RC" -eq 0 ]; then pass "invalid mode → exit 0 (silent)"
else fail "invalid mode → exit $RC"; fi

# session_id sanitization (path traversal 방어)
echo '{"session_id":"../evil"}' | "$CAFF" heartbeat
sleep 0.1
if [ ! -e "$AWAKE_DIR/../evil" ] && [ -f "$AWAKE_DIR/default" ]; then
    pass "session_id path traversal 방어"
else
    fail "session_id path traversal 방어 실패"
fi
rm -f "$AWAKE_DIR/default"

# ─── 4. watchdog stale 정리 ───
echo ""
echo "Case 4: watchdog stale 마커 제거"
STALE_MARKER="$AWAKE_DIR/smoke-stale-session"
FRESH_MARKER="$AWAKE_DIR/smoke-fresh-session"
mkdir -p "$AWAKE_DIR"
touch "$STALE_MARKER" "$FRESH_MARKER"
# stale 마커의 mtime을 과거로 (1시간 전)
if touch -t "$(date -v-1H +%Y%m%d%H%M.%S 2>/dev/null || date -d '1 hour ago' +%Y%m%d%H%M.%S 2>/dev/null)" "$STALE_MARKER" 2>/dev/null; then
    # STALE_SECS=900 (15분), 1시간 전이면 stale 판정
    # 직전 실행의 stale lock이 남아 있으면 watchdog이 no-op로 빠지므로 제거
    rmdir "$LOCK_DIR" 2>/dev/null || true
    CLAUDE_AWAKE_STALE_SECS=900 "$WATCH" sync
    if [ ! -e "$STALE_MARKER" ]; then pass "stale 마커 제거"
    else fail "stale 마커 잔존"; fi
    if [ -e "$FRESH_MARKER" ]; then pass "fresh 마커 보존"
    else fail "fresh 마커 오삭제"; fi
else
    echo "  SKIP touch -t 미지원 환경"
fi
rm -f "$STALE_MARKER" "$FRESH_MARKER"

# ─── 5. setup.sh --quiet, init-done 마커 없음 → no-op ───
echo ""
echo "Case 5: setup.sh --quiet, 초기 상태 → no-op (sudoers/plist 건드리지 않음)"
H="$SANDBOX/c5"
mkdir -p "$H/.config/sazo-ai-harness" "$H/.claude"
out=$(env -i HOME="$H" PATH="/usr/bin:/bin" "$SETUP" --quiet 2>&1)
rc=$?
if [ "$rc" -eq 0 ]; then pass "quiet 초기 상태 → exit 0"
else fail "quiet 초기 상태 exit=$rc"; fi
if [ ! -f "$H/.config/sazo-ai-harness/.sleep-guard-init-done" ]; then
    pass "init-done 마커 생성 안 됨 (opt-in 전)"
else
    fail "init-done 마커가 무단 생성됨"
fi

# ─── 6. opt-out 마커 ───
echo ""
echo "Case 6: opt-out 마커 존재 → 즉시 exit 0"
H="$SANDBOX/c6"
mkdir -p "$H/.config/sazo-ai-harness" "$H/.claude"
touch "$H/.config/sazo-ai-harness/.sleep-guard-optout"
out=$(env -i HOME="$H" PATH="/usr/bin:/bin" "$SETUP" --quiet 2>&1)
rc=$?
if [ "$rc" -eq 0 ]; then pass "opt-out → exit 0"
else fail "opt-out exit=$rc"; fi

# ─── 7. 비-macOS 시뮬레이션 (uname stub) ───
echo ""
echo "Case 7: 비-macOS → 즉시 exit 0"
H="$SANDBOX/c7"
STUB_BIN="$SANDBOX/c7-bin"
mkdir -p "$H/.config/sazo-ai-harness" "$H/.claude" "$STUB_BIN"
cat > "$STUB_BIN/uname" <<'EOF'
#!/bin/bash
echo "Linux"
EOF
chmod +x "$STUB_BIN/uname"
out=$(env -i HOME="$H" PATH="$STUB_BIN:/usr/bin:/bin" "$SETUP" --quiet 2>&1)
rc=$?
if [ "$rc" -eq 0 ]; then pass "Linux → exit 0"
else fail "Linux exit=$rc"; fi
if [ ! -f "$H/.config/sazo-ai-harness/.sleep-guard-init-done" ]; then
    pass "비-macOS에서 설치 없음"
else
    fail "비-macOS인데 init-done 마커 생성됨"
fi

# ─── 8. sudoers username escape 회귀 가드 (presence check) ───
# username이 alphanumeric/_/- 외 문자(예: macOS firstname.lastname)를 포함하면
# sudoers User_List 매칭이 실패해 NOPASSWD 룰이 무시된다 → watchdog의
# `sudo -n pmset` 실패 → sleep-guard 사실상 미작동. setup.sh가 backslash escape
# 를 적용하는지, 그리고 escape 결과가 의도대로 나오는지 검증.
# 주의: 이 case는 단순 grep + 별도 sed 실행이라 presence/sanity check 수준이다.
# 강한 end-to-end 가드는 Case 9의 anchored extraction + isolated subshell 평가가 담당.
echo ""
echo "Case 8: sudoers username escape (dot-bearing username 회귀 가드)"
ESCAPE_SED='s/[^A-Za-z0-9_-]/\\&/g'
if grep -Fq "$ESCAPE_SED" "$SETUP"; then
    pass "setup.sh 내 escape sed expression 존재"
else
    fail "setup.sh 내 escape sed expression 미발견 (회귀)"
fi
escaped=$(printf '%s' 'hakun.lee' | sed "$ESCAPE_SED")
if [ "$escaped" = 'hakun\.lee' ]; then
    pass 'dot 포함 username escape (hakun.lee → hakun\.lee)'
else
    fail "dot escape 결과 불일치: $escaped"
fi
escaped=$(printf '%s' 'simple_user-1' | sed "$ESCAPE_SED")
if [ "$escaped" = 'simple_user-1' ]; then
    pass "alphanumeric/_/- only → escape 없음"
else
    fail "불필요한 변환: $escaped"
fi

# ─── 9. sudoers.d 파일명 sanitize 회귀 가드 ───
# sudoers(5): /etc/sudoers.d 안의 파일명에 '.'(dot)이나 '~'(tilde)가 포함되면 sudo가
# 그 파일을 무시한다 (패키지 매니저/에디터 백업 파일 충돌 방지). macOS 'first.last'
# username 환경에서 dot이 파일명에 그대로 들어가면 NOPASSWD 룰 자체가 로드되지 않아
# sleep-guard가 사실상 동작하지 않는다. 이 케이스는 setup.sh가 파일명을 sanitize
# 하는지(`tr -c 'A-Za-z0-9_-' '_'`) 검증한다.
echo ""
echo "Case 9: sudoers.d 파일명 sanitize (dot/tilde 포함 username 회귀 가드)"
SANITIZE_TR="tr -c 'A-Za-z0-9_-' '_'"
if grep -Fq "$SANITIZE_TR" "$SETUP"; then
    pass "setup.sh 내 파일명 sanitize tr expression 존재"
else
    fail "setup.sh 내 파일명 sanitize tr expression 미발견 (회귀)"
fi
sanitized=$(printf '%s' 'hakun.lee' | tr -c 'A-Za-z0-9_-' '_')
if [ "$sanitized" = 'hakun_lee' ]; then
    pass 'dot 포함 username (hakun.lee → hakun_lee)'
else
    fail "sanitize 결과 불일치: $sanitized"
fi
sanitized=$(printf '%s' 'user~bak' | tr -c 'A-Za-z0-9_-' '_')
if [ "$sanitized" = 'user_bak' ]; then
    pass 'tilde 포함 username (user~bak → user_bak)'
else
    fail "tilde sanitize 불일치: $sanitized"
fi
sanitized=$(printf '%s' 'plain-user_1' | tr -c 'A-Za-z0-9_-' '_')
if [ "$sanitized" = 'plain-user_1' ]; then
    pass "alphanumeric/_/- only → 변환 없음"
else
    fail "불필요한 변환: $sanitized"
fi
# legacy 경로 cleanup 로직 존재 검증
if grep -Fq 'LEGACY_SUDOERS_FILE' "$SETUP"; then
    pass "legacy sudoers cleanup 로직 존재"
else
    fail "legacy sudoers cleanup 로직 미발견"
fi

# 더 강한 회귀 가드 — setup.sh의 실제 변수 선언 라인을 추출해 isolated subshell에서
# 평가한다. 단순 grep은 주석 안의 expression까지 통과시키지만, '^SUDOERS_FILENAME_USER='
# / '^SUDOERS_FILE='로 anchored 추출하면 active code path(top-level assignment)에
# 위치해야만 잡힌다. USER='hakun.lee' 입력에서 dot 제거된 결과가 산출되는지 직접 검증.
extracted=$(sed -n '/^SUDOERS_FILENAME_USER=/p; /^SUDOERS_FILE=/p' "$SETUP")
if [ -z "$extracted" ]; then
    fail "setup.sh의 SUDOERS_FILENAME_USER/SUDOERS_FILE 선언이 active code path에 없음"
else
    actual=$(USER='hakun.lee' bash -c "set -u; $extracted; echo \$SUDOERS_FILE")
    if [ "$actual" = "/etc/sudoers.d/sazo-claude-pmset-hakun_lee" ]; then
        pass "USER=hakun.lee → 실제 setup.sh 평가 결과 sazo-claude-pmset-hakun_lee"
    else
        fail "setup.sh 평가 결과 불일치: $actual"
    fi
    actual=$(USER='simple_user-1' bash -c "set -u; $extracted; echo \$SUDOERS_FILE")
    if [ "$actual" = "/etc/sudoers.d/sazo-claude-pmset-simple_user-1" ]; then
        pass "USER=simple_user-1 → 변환 없음 (실제 setup.sh 평가)"
    else
        fail "변환 없는 입력 결과 불일치: $actual"
    fi
fi

echo ""
echo "─────────────────────"
if [ "$FAIL" -eq 0 ]; then
    echo "OK: All sleep-guard smoke tests passed"
    exit 0
else
    echo "FAIL: $FAIL assertion(s) failed"
    exit 1
fi
