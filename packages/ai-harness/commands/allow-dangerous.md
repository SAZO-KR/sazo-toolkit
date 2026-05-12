---
description: 위험 명령 1회 우회 nonce 발급. dangerous-bash-block hook의 다음 차단 1회를 skip.
allowed-tools: Bash(jq:*), Bash(date:*), Bash(mkdir:*), Bash(cat:*), Bash(mv:*), Bash(printf:*), Bash(rmdir:*), Bash(stat:*), Bash(sleep:*), Bash(shasum:*), Bash(cut:*), Bash(test:*), Bash(echo:*), Bash(openssl:*), Bash(tr:*)
---

# /allow-dangerous — 위험 명령 1회 우회

## 사용법

```
/allow-dangerous <reason>
```

**사용자 직접 입력 전용**. UserPromptSubmit hook이 `/allow-dangerous`를 감지하고 1회용 nonce를 발급한다.  
Claude가 자의로 호출하면 nonce 검증 실패 → 차단 유지.

## 동작

다음 번 `dangerous-bash-block` hook 차단 시 nonce를 소비하고 명령을 통과시킨다.  
nonce는 1회만 유효 — 소비 후 즉시 null로 리셋되고 이력(`dangerous_override_history`)에 기록된다.

!`bash -c '
set -euo pipefail
HARNESS_DIR="${SAZO_HARNESS_DIR:-$HOME/.config/sazo-ai-harness/packages/ai-harness}"
LIB="$HARNESS_DIR/scripts/hooks/lib/session-state.sh"
[ -f "$LIB" ] || { echo "session-state lib 누락: $LIB"; exit 1; }
# shellcheck disable=SC1090
source "$LIB"

SID="${CLAUDE_SESSION_ID:-${SAZO_SESSION_ID:-}}"
[ -z "$SID" ] && { echo "session_id 없음"; exit 1; }
CWD="${CLAUDE_CWD:-$PWD}"

state_init "$SID" "$CWD" "${CLAUDE_MODEL:-unknown}"

NONCE=$(state_get "$SID" ".dangerous_override_nonce" "$CWD")
if printf "%s" "$NONCE" | grep -qE "^[0-9a-f]{32}$" 2>/dev/null; then
    echo "✓ /allow-dangerous nonce 발급됨 (1회용). 다음 위험 명령 1회 통과."
else
    cat <<EOF
✗ dangerous_override_nonce 미발급.
/allow-dangerous는 사용자 직접 타이핑만 인정.
EOF
    exit 1
fi
'`

## Known gaps (Phase 1 미커버)

- **quoted-arg evasion**: `git push '"'"'--force'"'"'` — quoted arg 내 `--force`는 regex 미매칭. Phase 2 wrapper-level abstraction 예정.
- **abbreviation**: `gh pr m` 등 CLI alias — wrapper level 처리 예정 (Plan 13 follow-up).
- **env -S quoted parse**: POSIX ERE 본질적 한계.

## 비활성

전 세션 비활성: `export SAZO_DISABLE_DANGEROUS_BLOCK=1` (`.zshrc`/`.bashrc`).
