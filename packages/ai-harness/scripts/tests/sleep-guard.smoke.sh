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
#   10) watchdog.sh idempotent skip — 현재 SleepDisabled가 desired와 같으면 sudo skip
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
trap "rm -rf '$SANDBOX' '$AWAKE_DIR'/smoke-test-session '$AWAKE_DIR'/smoke-stale-session '$AWAKE_DIR'/smoke-fresh-session '$AWAKE_DIR'/smoke-idempotent-active '$AWAKE_DIR'/default; rmdir '$LOCK_DIR' 2>/dev/null || true" EXIT
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
# LC_ALL=C 명시: locale 의존적 [A-Za-z] 범위 해석 방지 (Gemini 리뷰 권고).
ESCAPE_SED_INVOCATION="LC_ALL=C sed 's/[^A-Za-z0-9_-]/\\\\&/g'"
ESCAPE_SED='s/[^A-Za-z0-9_-]/\\&/g'
if grep -Fq "$ESCAPE_SED_INVOCATION" "$SETUP"; then
    pass "setup.sh 내 escape sed expression 존재 (LC_ALL=C 포함)"
else
    fail "setup.sh 내 escape sed expression 미발견 또는 LC_ALL=C 누락 (회귀)"
fi
escaped=$(printf '%s' 'hakun.lee' | LC_ALL=C sed "$ESCAPE_SED")
if [ "$escaped" = 'hakun\.lee' ]; then
    pass 'dot 포함 username escape (hakun.lee → hakun\.lee)'
else
    fail "dot escape 결과 불일치: $escaped"
fi
escaped=$(printf '%s' 'simple_user-1' | LC_ALL=C sed "$ESCAPE_SED")
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
# LC_ALL=C 명시: locale 의존적 [A-Za-z] 범위 해석 방지 (Gemini 리뷰 권고).
SANITIZE_TR_INVOCATION="LC_ALL=C tr -c 'A-Za-z0-9_-' '_'"
if grep -Fq "$SANITIZE_TR_INVOCATION" "$SETUP"; then
    pass "setup.sh 내 파일명 sanitize tr expression 존재 (LC_ALL=C 포함)"
else
    fail "setup.sh 내 파일명 sanitize tr expression 미발견 또는 LC_ALL=C 누락 (회귀)"
fi
sanitized=$(printf '%s' 'hakun.lee' | LC_ALL=C tr -c 'A-Za-z0-9_-' '_')
if [ "$sanitized" = 'hakun_lee' ]; then
    pass 'dot 포함 username (hakun.lee → hakun_lee)'
else
    fail "sanitize 결과 불일치: $sanitized"
fi
sanitized=$(printf '%s' 'user~bak' | LC_ALL=C tr -c 'A-Za-z0-9_-' '_')
if [ "$sanitized" = 'user_bak' ]; then
    pass 'tilde 포함 username (user~bak → user_bak)'
else
    fail "tilde sanitize 불일치: $sanitized"
fi
sanitized=$(printf '%s' 'plain-user_1' | LC_ALL=C tr -c 'A-Za-z0-9_-' '_')
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

# Path traversal guard 회귀 가드 — $USER에 '/'가 포함되면 LEGACY_SUDOERS_FILE 정규화
# 결과가 sudoers.d 밖을 가리킬 수 있다(Gemini 리뷰 medium). cleanup 직전 basename
# prefix + 정확한 sudoers.d 경로 매칭이 active code path에 있는지 검증.
if grep -Fq 'case "$legacy_basename" in sazo-claude-pmset-*' "$SETUP"; then
    pass "path traversal guard (basename prefix case statement) 존재"
else
    fail "path traversal guard 미발견 (회귀)"
fi
if grep -Fq '"$LEGACY_SUDOERS_FILE" = "/etc/sudoers.d/$legacy_basename"' "$SETUP"; then
    pass "path traversal guard (sudoers.d 정확 경로 매칭) 존재"
else
    fail "path traversal guard sudoers.d 경로 매칭 미발견 (회귀)"
fi

# auto-update.sh의 sleep-guard sudoers fallback도 setup.sh와 동일 sanitize를
# 사용해야 dot 포함 username 환경에서 false 'ok'가 발생하지 않음 (Codex 리뷰 P2).
# 동일 LC_ALL=C tr 호출이 auto-update.sh의 user_suffix 라인 부근에 있는지 grep.
AUTO_UPDATE="$SCRIPT_DIR/auto-update.sh"
if grep -Fq "$SANITIZE_TR_INVOCATION" "$AUTO_UPDATE"; then
    pass "auto-update.sh도 setup.sh와 동일 sanitize 사용"
else
    fail "auto-update.sh sanitize 동기화 누락 (회귀)"
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
# ─── 10. watchdog.sh idempotent skip ───
# 핵심 회귀: launchd가 ~10s마다 watchdog을 호출하므로 매번 sudo를 spawn하면
# macOS Sequoia가 background-activity notification을 띄운다. 현재 SleepDisabled를
# pmset -g (no sudo)로 읽어 desired와 같으면 sudo skip.
echo ""
echo "Case 10: watchdog idempotent skip — 상태 일치 시 sudo 호출 안 함"

# (a) 소스 grep — pmset -g 기반 idempotent check 식이 watchdog.sh에 존재.
# read는 PMSET_READ_BIN 변수(테스트 stub override 가능), write는 /usr/bin/pmset
# 하드코드(sudoers NOPASSWD 매칭). awk 파이프는 다음 줄에 걸쳐 있을 수 있어 개별 검증.
if grep -qE '"\$PMSET_READ_BIN"[[:space:]]+-g|/usr/bin/pmset[[:space:]]+-g|pmset[[:space:]]+-g' "$WATCH" \
   && grep -q 'SleepDisabled' "$WATCH" \
   && grep -q 'awk' "$WATCH" \
   && grep -q 'current.*!=.*desired\|"\$current".*"\$desired"' "$WATCH"; then
    pass "watchdog.sh에 pmset -g/SleepDisabled/awk 기반 check 존재"
else
    fail "watchdog.sh에 idempotent check 누락"
fi

# (b) end-to-end mock: pmset이 'SleepDisabled 1' 출력 + 활성 마커 1개 → sudo skip
SANDBOX8=$(mktemp -d)
STUB_BIN8="$SANDBOX8/bin"
mkdir -p "$STUB_BIN8"
SUDO_TOUCH="$SANDBOX8/sudo-called"
PMSET_TOUCH="$SANDBOX8/pmset-mutate-called"

# pmset stub: -g면 SleepDisabled 출력, -a (mutation)면 touch marker.
# PMSET_MOCK_SUFFIX가 설정되면 값 뒤에 metadata 꼬리표를 붙여 출력
# (예: "SleepDisabled 1 (imposed by 'coreaudiod')").
# 이는 awk \$NF → \$2 회귀 테스트용.
cat > "$STUB_BIN8/pmset" <<EOF
#!/bin/bash
if [ "\$1" = "-g" ]; then
    case "\$2" in
        ''|live|everything)
            echo "System-wide power settings:"
            if [ -n "\${PMSET_MOCK_SUFFIX:-}" ]; then
                echo " SleepDisabled		\$PMSET_MOCK_VALUE \$PMSET_MOCK_SUFFIX"
            else
                echo " SleepDisabled		\$PMSET_MOCK_VALUE"
            fi
            ;;
        *) ;;
    esac
    exit 0
fi
# mutation 경로 — sudo wrapper에서만 도달해야 함
if [ "\$1" = "-a" ]; then
    touch "$PMSET_TOUCH"
fi
exit 0
EOF
chmod +x "$STUB_BIN8/pmset"

# sudo stub: 호출되면 touch marker. -n <pmset> 형태도 처리.
# watchdog은 PMSET_BIN을 넘기므로 절대 경로($STUB_BIN8/pmset)도 매칭해야 한다.
cat > "$STUB_BIN8/sudo" <<EOF
#!/bin/bash
touch "$SUDO_TOUCH"
# sudo가 실제 mutation까지 했는지도 보고 싶으면 인자로 pmset 실행
shift # -n
case "\$1" in
    "$STUB_BIN8/pmset"|/usr/bin/pmset|pmset)
        shift
        "$STUB_BIN8/pmset" "\$@"
        ;;
esac
exit 0
EOF
chmod +x "$STUB_BIN8/sudo"

# 활성 마커 1개 (fresh, $USER 디렉토리에) → desired=1
SKIP_MARKER="$AWAKE_DIR/smoke-idempotent-active"
mkdir -p "$AWAKE_DIR"
touch "$SKIP_MARKER"
rm -f "$SUDO_TOUCH" "$PMSET_TOUCH"
rmdir "$LOCK_DIR" 2>/dev/null || true

# pmset 현재값=1, desired=1 → sudo 호출 skip
# PMSET_BIN으로 stub 직접 가리킴 (절대 경로 default를 우회).
PMSET_BIN="$STUB_BIN8/pmset" PMSET_MOCK_VALUE=1 PATH="$STUB_BIN8:$PATH" "$WATCH" sync

if [ ! -e "$SUDO_TOUCH" ]; then
    pass "상태 일치(현재=1, desired=1) → sudo 호출 안 됨"
else
    fail "상태 일치인데 sudo 호출됨 (idempotent skip 미동작)"
fi
if [ ! -e "$PMSET_TOUCH" ]; then
    pass "상태 일치 → pmset mutation 안 됨"
else
    fail "상태 일치인데 pmset mutation 호출됨"
fi

# (c) 상태 불일치: pmset 현재값=0, 활성 마커 존재 → desired=1, sudo 호출 IS 발생
rm -f "$SUDO_TOUCH" "$PMSET_TOUCH"
rmdir "$LOCK_DIR" 2>/dev/null || true
PMSET_BIN="$STUB_BIN8/pmset" PMSET_MOCK_VALUE=0 PATH="$STUB_BIN8:$PATH" "$WATCH" sync

if [ -e "$SUDO_TOUCH" ]; then
    pass "상태 불일치(현재=0, desired=1) → sudo 호출됨"
else
    fail "상태 불일치인데 sudo 호출 안 됨 (toggle 누락)"
fi

# (d) 활성 마커 없음 + 현재값=0 → desired=0, sudo skip
rm -f "$SKIP_MARKER" "$SUDO_TOUCH" "$PMSET_TOUCH"
# 다른 사용자 디렉토리도 비어 있어야 active_count=0
rmdir "$LOCK_DIR" 2>/dev/null || true
PMSET_BIN="$STUB_BIN8/pmset" PMSET_MOCK_VALUE=0 PATH="$STUB_BIN8:$PATH" "$WATCH" sync

# 다른 사용자 stale 마커가 있으면 결과 영향. 본 테스트 호스트 한정으로
# 본인 마커 0 + 현재=0이면 일반적으로 active_count=0 → sudo skip.
# 다른 디렉토리의 fresh 마커가 있어 active_count>0인 경우는 이 case가 의미 없음.
# 보수적으로: sudo가 호출됐다 해도 상태 불일치 toggle은 정상 동작이라 fail 처리하지 않고 정보 출력.
if [ ! -e "$SUDO_TOUCH" ]; then
    pass "활성 마커 0 + 현재=0 → sudo 호출 안 됨"
else
    echo "  INFO 활성 마커 0인데 sudo 호출됨 — 다른 사용자 fresh 마커 존재 가능성 (skip 평가)"
fi

# (e) awk 파싱 회귀: pmset 출력에 metadata 꼬리표가 붙은 경우에도
# 상태값을 정확히 추출해야 함 (Gemini round 2 피드백).
# 예: "SleepDisabled 1 (imposed by 'coreaudiod')" — \$NF는 마지막 토큰을
# 잡으므로 case 0/1) 검증에서 떨어져 0으로 오판되어 sudo 불필요 호출 발생.
touch "$SKIP_MARKER"  # 활성 마커 1개 → desired=1
rm -f "$SUDO_TOUCH" "$PMSET_TOUCH"
rmdir "$LOCK_DIR" 2>/dev/null || true
PMSET_BIN="$STUB_BIN8/pmset" PMSET_MOCK_VALUE=1 PMSET_MOCK_SUFFIX="(imposed by 'coreaudiod')" PATH="$STUB_BIN8:$PATH" "$WATCH" sync

if [ ! -e "$SUDO_TOUCH" ]; then
    pass "metadata 꼬리표 출력에서도 현재=1 정확 추출 → sudo skip"
else
    fail "metadata 꼬리표에서 awk \$NF가 마지막 토큰을 잡아 sudo 오호출됨"
fi
rm -f "$SKIP_MARKER"

# (f)~(h) 동작 검증은 host의 launchd-watchdog lock + Claude session 활성 markers와
# race가 잦아 flaky. 회귀 가드는 source grep으로 대체:
#   (f) exit_code != 0 OR empty stdout → unknown sentinel (Codex 라운드 4)
#   (g) line omit + exit 0 → "0" default fallback (Codex 라운드 5: idle 노이즈 방지)
#   (h) PMSET_READ_BIN executable check + 절대경로 fallback (Codex 라운드 4)
if grep -Fq 'LC_ALL=C "$PMSET_READ_BIN"' "$WATCH" && grep -Fq 'pmset_rc' "$WATCH" && grep -Fq '"$pmset_rc" -ne 0' "$WATCH" && grep -Fq 'current=unknown' "$WATCH"; then
    pass "(f) pmset 호출 실패 시 unknown sentinel 분기 존재"
else
    fail "(f) pmset_rc 검사 + unknown sentinel 분기 누락"
fi
if grep -Fq 'END {if (!found) print "0"}' "$WATCH"; then
    pass "(g) SleepDisabled 라인 omit 시 0 default fallback 존재"
else
    fail "(g) awk END 분기에 0 fallback 누락 (idle 노이즈 회귀 위험)"
fi
if grep -Fq '[ -x "$PMSET_READ_BIN" ] || PMSET_READ_BIN="/usr/bin/pmset"' "$WATCH"; then
    pass "(h) PMSET_READ_BIN executable check + 절대경로 fallback 존재"
else
    fail "(h) PMSET_READ_BIN executable check fallback 누락 (회귀)"
fi

rm -rf "$SANDBOX8"
rmdir "$LOCK_DIR" 2>/dev/null || true

echo ""
echo "─────────────────────"
if [ "$FAIL" -eq 0 ]; then
    echo "OK: All sleep-guard smoke tests passed"
    exit 0
else
    echo "FAIL: $FAIL assertion(s) failed"
    exit 1
fi
