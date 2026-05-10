---
description: macOS sleep 차단 토글 (awake CLI wrapper). `/awake on|off|status|extend [duration]`
allowed-tools: Bash(awake:*), Bash(test:*), Bash(echo:*)
argument-hint: on|off|status|extend [duration]
---

# /awake — macOS sleep 차단 제어

명시적으로 sleep 차단을 켜고 끈다. `caffeinate` wrapper. sudo 불필요.

## 사용법

```
/awake on            # 기본 2h
/awake on 30m        # 30분
/awake on 1h30m      # 1시간 30분
/awake off
/awake status
/awake extend 30m
```

duration: `30s` / `5m` / `2h` / `1h30m` / `90` (초)

## 동작

!`bash -c '
set -u
if ! command -v awake >/dev/null 2>&1; then
    echo "awake CLI 미설치 — ~/.local/bin/awake 심볼릭 링크 확인. 재설치: bash ~/.config/sazo-ai-harness/packages/ai-harness/install.sh"
    exit 1
fi
ARGS="${ARGUMENTS:-status}"
# 빈 문자열이면 status 기본
[ -z "$ARGS" ] && ARGS="status"
# 사용자 입력은 단일 문자열로 들어옴 — read로 토큰화해 word splitting 안전 처리.
read -r -a ARGV <<< "$ARGS"
awake "${ARGV[@]}"
'`

## 비고

- 이 커맨드는 자동으로 발동하지 않음. 사용자가 명시적으로 호출해야 함.
- TTL이 지나면 caffeinate 자동 종료 → sleep 정상 복귀.
- 터미널 닫아도 살아있음 (`nohup` + `disown`). 강제 종료: `awake off`.
- `extend`는 caffeinate `-t` 변경 불가 제약상 기존 프로세스 kill + 신규 시작
  (~250ms disablesleep drop window 발생). 실 사용엔 영향 없음 (macOS sleep
  delay > 30s).
