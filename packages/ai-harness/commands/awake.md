---
description: macOS closed-lid 실행 유지 토글. `/awake on|off|status|extend|reset [duration]`
allowed-tools: Bash(awake:*), Bash(test:*), Bash(echo:*)
argument-hint: on|off|status|extend|reset [duration]
---

# /awake — macOS closed-lid 실행 유지 제어

명시적으로 `pmset disablesleep` 기반 closed-lid 모드를 켜고 끈다.
자동 훅/워치독은 없고, 사용자가 직접 호출할 때만 동작한다.

## 사용법

```
 /awake on            # 기본 2h
 /awake on 30m        # 30분
 /awake on 1h30m      # 1시간 30분
 /awake off
 /awake status
 /awake extend 30m
 /awake reset         # stuck 상태 강제 해제
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
- closed-lid 동작은 `/usr/local/libexec/sazo-ai-harness/awake-helper` 설치가 필요.
- 기본 설치만으로는 helper/sudoers가 없을 수 있음. 이 경우 `awake on/off/...`는
  터미널에서 sudo 인증이 필요하거나 실패할 수 있음.
- TTL이 지나면 helper가 이전 `SleepDisabled` 값으로 복원 시도.
- `off`는 이전 값을 복원하고, `reset`은 강제로 `disablesleep 0`으로 되돌림.
- 전역 전원 설정을 건드리므로 가방/슬리브 안에 넣은 채 lid를 닫지 말 것.
