#!/bin/bash
# awake CLI smoke tests — caffeinate stub 기반.
#
# 검증 항목:
#   1. duration parser: 30s/5m/2h/1h30m/90/invalid
#   2. on/status/off cycle
#   3. on 중복 호출 시 기존 PID 종료
#   4. extend: 남은 시간 + add → 재시작
#   5. status가 stale PID 파일 정리
#   6. caffeinate 인자 (-dimsu -t SECS) 정확히 전달

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
AWAKE="$PROJECT_DIR/packages/ai-harness/scripts/awake/awake.sh"

if [ ! -f "$AWAKE" ]; then
    echo "FAIL: awake.sh not found at $AWAKE" >&2
    exit 1
fi

TMP=$(mktemp -d -t awake-smoke.XXXXXX)
cleanup() {
    # state dir의 PID들 살아있으면 종료
    if [ -f "$TMP/state/awake.pid" ]; then
        pid=$(cat "$TMP/state/awake.pid" 2>/dev/null || echo "")
        [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
    fi
    # 떠도는 stub caffeinate 자식들 정리
    pkill -f "$TMP/bin/caffeinate" 2>/dev/null || true
    rm -rf "$TMP"
}
trap cleanup EXIT

# ─── caffeinate stub ───
# -t SECS 를 sleep 으로 시뮬레이션. 호출 인자는 "$TMP/calls.log"에 1줄로 기록.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/caffeinate" <<STUB
#!/bin/bash
echo "\$@" >> "$TMP/calls.log"
secs=600
while [ \$# -gt 0 ]; do
    case "\$1" in
        -t) shift; secs="\$1" ;;
        *) ;;
    esac
    shift
done
exec sleep "\$secs"
STUB
chmod +x "$TMP/bin/caffeinate"

export AWAKE_CAFFEINATE_BIN="$TMP/bin/caffeinate"
export AWAKE_STATE_DIR="$TMP/state"

PASS=0
FAIL=0
assert() {
    local label="$1" cond="$2"
    if eval "$cond"; then
        echo "  ✓ $label"
        PASS=$((PASS+1))
    else
        echo "  ✗ $label" >&2
        FAIL=$((FAIL+1))
    fi
}
# `must`: prerequisite assertion — 실패 시 즉시 abort. 후속 테스트가 stale state로
# 가짜 pass 만들지 않도록 차단.
must() {
    local label="$1" cond="$2"
    if eval "$cond"; then
        echo "  ✓ $label"
        PASS=$((PASS+1))
    else
        echo "  ✗ $label (PREREQUISITE — abort)" >&2
        FAIL=$((FAIL+1))
        echo ""
        echo "PASS: $PASS, FAIL: $FAIL"
        exit 1
    fi
}
# 파일이 생길 때까지 폴링 — caffeinate stub의 calls.log race 방지.
wait_for_file() {
    local f="$1" max_iters=20
    local i=0
    while [ "$i" -lt "$max_iters" ]; do
        [ -s "$f" ] && return 0
        sleep 0.05
        i=$((i+1))
    done
    return 1
}

# ─── 1. duration parser ───
echo "[1] parse_duration"
parse() { bash "$AWAKE" __parse "$1" 2>/dev/null; }

assert "30s → 30"     '[ "$(parse 30s)" = "30" ]'
assert "5m → 300"     '[ "$(parse 5m)" = "300" ]'
assert "2h → 7200"    '[ "$(parse 2h)" = "7200" ]'
assert "1h30m → 5400" '[ "$(parse 1h30m)" = "5400" ]'
assert "90 → 90"      '[ "$(parse 90)" = "90" ]'
assert "invalid 'abc' rejected"  '! parse abc'
assert "invalid empty rejected"  '! parse ""'
assert "invalid '0' rejected'"   '! parse 0'
assert "negative '-5m' rejected" '! parse -5m'
# MAX 24h(86400) 초과는 reject — 25h
assert "over-cap '25h' rejected" '! parse 25h'
assert "exact 24h accepted"      '[ "$(parse 24h)" = "86400" ]'

# ─── 2. on → status → off ───
echo "[2] on/status/off cycle"
out=$(bash "$AWAKE" on 30)
assert "on prints pid"          '[[ "$out" == *"pid"* ]]'
must "pid file exists"          '[ -f "$TMP/state/awake.pid" ]'
must "expires file exists"      '[ -f "$TMP/state/awake.expires" ]'

pid=$(cat "$TMP/state/awake.pid")
must "pid alive"                'kill -0 "$pid" 2>/dev/null'

st=$(bash "$AWAKE" status)
assert "status shows on"        '[[ "$st" == *"on"* ]]'
assert "status shows seconds"   '[[ "$st" == *"s remaining"* ]]'

bash "$AWAKE" off >/dev/null
assert "off cleans pid file"    '[ ! -f "$TMP/state/awake.pid" ]'
assert "off cleans expires"     '[ ! -f "$TMP/state/awake.expires" ]'

st=$(bash "$AWAKE" status)
assert "status off after off"   '[[ "$st" == *"off"* ]]'

# ─── 3. on 중복 → 기존 PID 종료 + 재시작 ───
echo "[3] on while running replaces"
bash "$AWAKE" on 60 >/dev/null
must "first on succeeded"       '[ -f "$TMP/state/awake.pid" ]'
old_pid=$(cat "$TMP/state/awake.pid")
must "old_pid non-empty"        '[ -n "$old_pid" ]'
bash "$AWAKE" on 60 >/dev/null
must "second on succeeded"      '[ -f "$TMP/state/awake.pid" ]'
new_pid=$(cat "$TMP/state/awake.pid")
must "new_pid non-empty"        '[ -n "$new_pid" ]'
assert "new pid differs"        '[ "$old_pid" != "$new_pid" ]'
# kill -0 race 방지 — 폴링: 5초 안에 죽어야 함
i=0
while kill -0 "$old_pid" 2>/dev/null && [ "$i" -lt 100 ]; do
    sleep 0.05
    i=$((i+1))
done
assert "old pid dead"           '! kill -0 "$old_pid" 2>/dev/null'
assert "new pid alive"          'kill -0 "$new_pid" 2>/dev/null'
bash "$AWAKE" off >/dev/null

# ─── 4. extend ───
echo "[4] extend"
bash "$AWAKE" on 30 >/dev/null
exp1=$(cat "$TMP/state/awake.expires")
sleep 1
bash "$AWAKE" extend 60 >/dev/null
exp2=$(cat "$TMP/state/awake.expires")
diff=$(( exp2 - exp1 ))
# 새 만료 = 남은 시간(~29) + 60 + now offset(1) ≈ 90, 따라서 diff ≈ 60 (±5)
assert "extend bumps expiry by ~60s"  '[ "$diff" -ge 55 ] && [ "$diff" -le 65 ]'
bash "$AWAKE" off >/dev/null

# extend without running
out=$(bash "$AWAKE" extend 30 2>&1 || true)
assert "extend without running errors"  '[[ "$out" == *"not running"* ]]'

# extend cap clamp — `on 23h; extend 23h` → cap (86400) 까지만 클램프되어야 함.
# 우회 방지 테스트 (이전에는 cmd_on 정수 경로가 cap 검증 안 해 우회 가능).
bash "$AWAKE" on 23h >/dev/null
out=$(bash "$AWAKE" extend 23h 2>&1 || true)
assert "extend over-cap clamped warning"  '[[ "$out" == *"clamped"* ]]'
exp_after=$(cat "$TMP/state/awake.expires" 2>/dev/null || echo 0)
now_after=$(date +%s)
remain_after=$(( exp_after - now_after ))
# 24h(86400) ±10s 이내. 클램프 정확성 확인.
assert "extend clamp result ≤ 24h"  '[ "$remain_after" -le 86410 ]'
assert "extend clamp result ≥ 24h-10s"  '[ "$remain_after" -ge 86390 ]'
bash "$AWAKE" off >/dev/null

# ─── 5. status cleans stale PID file ───
echo "[5] status cleans stale state"
mkdir -p "$TMP/state"
echo 99999 > "$TMP/state/awake.pid"
echo 0 > "$TMP/state/awake.expires"
st=$(bash "$AWAKE" status)
assert "stale pid → off"        '[[ "$st" == *"off"* ]]'
assert "stale pid file removed" '[ ! -f "$TMP/state/awake.pid" ]'

# ─── 6. caffeinate 인자 검증 ───
echo "[6] caffeinate arguments"
rm -f "$TMP/calls.log"
bash "$AWAKE" on 45 >/dev/null
# fixed sleep 대신 폴링 — CI 부하에서도 flake 없음
must "caffeinate called (calls.log written)"  'wait_for_file "$TMP/calls.log"'
last_call=$(tail -1 "$TMP/calls.log" 2>/dev/null || echo "")
assert "caffeinate called"          '[ -n "$last_call" ]'
assert "args include -dimsu"        '[[ "$last_call" == *"-dimsu"* ]]'
assert "args include -t 45"         '[[ "$last_call" == *"-t 45"* ]]'
bash "$AWAKE" off >/dev/null

# ─── 7. invalid command / arg ───
echo "[7] error handling"
out=$(bash "$AWAKE" frobnicate 2>&1 || true)
assert "unknown command errors"  '[[ "$out" == *"Unknown"* || "$out" == *"Usage"* ]]'

out=$(bash "$AWAKE" on bogus 2>&1 || true)
assert "invalid duration errors" '[[ "$out" == *"Invalid"* ]]'

# ─── 8. caffeinate 경로 잘못된 경우 PID 안 쓰임 ───
echo "[8] missing caffeinate binary"
rm -f "$TMP/state/awake.pid" "$TMP/state/awake.expires"
out=$(AWAKE_CAFFEINATE_BIN=/nonexistent/path/caffeinate bash "$AWAKE" on 30 2>&1 || true)
assert "missing binary errors"   '[[ "$out" == *"Failed to start"* ]]'
assert "no pid file written"     '[ ! -f "$TMP/state/awake.pid" ]'
assert "no expires file written" '[ ! -f "$TMP/state/awake.expires" ]'

# ─── 결과 ───
echo ""
echo "PASS: $PASS, FAIL: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "✅ awake smoke tests passed"
