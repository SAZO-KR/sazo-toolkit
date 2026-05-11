# Control Flow Determinism — ADR

Architecture Decision Records for the harness control flow determinism workstream (Plan 13 implementation).

## D1. SessionEnd hook event over Stop hook

### Decision

Session-end metrics use the Anthropic Claude Code `SessionEnd` hook event, not the `Stop` hook.

### Rationale

- `Stop` hook fires after every Claude response (multiple times per session) → per-turn semantics, unsuited for terminal metrics aggregation
- `SessionEnd` fires once at session termination → 1 record per session, natural fit for determinism metrics
- Confirmed via Stage S0 spike (`proposals/harness-determinism/spike-stop-hook.md`, PR #32 merged)

### Trade-offs

- `SessionEnd` does NOT fire on `/exit` command (GH#17885, #35892) — known limitation, Ctrl+D required for clean exit
- `/clear` does NOT fire (GH#6428)
- Ctrl+C fires but mid-execution kill (GH#32712)
- `--continue` resume sends stale `session_id`/`transcript_path` (GH#9188)
- Async work may be killed before 5s (GH#41577) → `timeout 5` portable wrapper mitigates

### Fallback

If `/exit` loss ratio proves significant in production, activate Stop hook fallback (`post-stop-metrics-fallback.sh`, deferred PR). Record schema already includes `source: "session_end" | "stop_fallback"` discriminator. Dedup key: `(session_id, source)`. Plan 02 workflow CLI metrics layer handles dedup.

---

## D2. Bash 호환성 정책

### Decision

모든 hook script와 lib는 bash 3.0+에서 동작해야 한다 (3.2 권장).

### Rationale

macOS 기본 `/bin/bash` = 3.2.57. 사용자가 brew로 newer bash 설치 가능하지만 default 보장 못함. Linux는 bash 4+/5+가 일반적이므로 3.2 호환은 사실상 macOS 보장 의미.

### 정책

- **Shebang**: `#!/usr/bin/env bash`
- **사용 금지** (bash 4+ 기능):
  - associative arrays (`declare -A`)
  - case conversion (`${var^^}`, `${var,,}`)
  - `[[ -v var ]]` (use `[ -n "${var+x}" ]`)
  - `mapfile` / `readarray` (use `while IFS= read -r line; do ... done < <(...)`)
  - `${!var}` indirect expansion (use case statement)
- **사용 OK**:
  - `set -uo pipefail`
  - indexed arrays
  - parameter expansion `${var#pattern}` / `${var%pattern}`
  - regex `[[ "$x" =~ regex ]]`
- **Runtime version gate 없음** — shebang + 정적 검토 (CI lint)만
- **Path 정규화**: `cd "$(dirname X)" && pwd -P` (realpath 미사용 — BSD/GNU 차이)

### Spike doc 예외

`proposals/harness-determinism/spike-stop-hook.md` line 119의 예제 `#!/bin/bash`는 reference example로서 본 ADR 정책 외. 실 hook 본체(`post-session-end-metrics.sh`)는 ADR D2에 따라 `#!/usr/bin/env bash` 적용.

---

## D3. Portable timeout wrapper

### Decision

Hook script 내부의 timeout 적용은 4-tier fallback 패턴 사용:

1. `timeout` (GNU coreutils, Linux 기본 / macOS는 brew coreutils 별도 설치 필요)
2. `gtimeout` (macOS brew coreutils 표준 이름)
3. `perl -e 'alarm shift @ARGV; exec @ARGV' ...` (POSIX perl)
4. timeout 없이 직접 실행 + `audit_log warn` entry

### Rationale

- macOS 기본 환경에 `timeout` binary 부재 (BSD에 미포함)
- `perl`은 macOS 기본 포함 — 신뢰 가능한 fallback
- `command -v` detect로 안전한 분기

### Trade-off (Plan 13 OQ6 / R8 risk)

perl alarm fallback이 shell function 인자를 받을 때 `exec @ARGV`로 직접 호출 불가 — caller가 shell function이면 lock 우회 + audit warn으로 graceful fail. record loss <5s window 가능 (BSD timeout 미설치 환경 한정).

Detection 패턴 (`_run_with_timeout` 내부):
```bash
if [ "$(type -t "$1" 2>/dev/null)" = "function" ]; then
    # shell function — perl alarm 미적용, lock 우회 + warn
    audit_log "session-end" "warn" "perl timeout fallback skips lock for shell function: $1"
    "$@"
else
    perl -e 'alarm shift @ARGV; exec @ARGV' "$secs" "$@"
fi
```

---

## D4. hook_healthy check #6 path resolve

### Decision

`hook_healthy` check #6 (settings.json command path 실재 검증)에서 path 해석 기준:

- **Absolute path** (`/...` 시작): 직접 `[ -e "$path" ]` 검증
- **Relative path**: `~/.claude/` prefix 가정 후 `[ -e "${HOME}/.claude/${path}" ]` 검증

### Rationale (Plan 13 OQ7)

- settings.json schema가 path 기준 명시 안 함
- `~/.claude/`가 ai-harness install 기본 경로 → 사용자 hooks 다수 거기서 resolve
- 더 정교한 multi-base resolve (cwd + ~/.claude/ + 절대) 는 가능하나 fixture 복잡도 증가 → 보수적으로 ~/.claude/ 단일 prefix 채택
- 향후 cwd 기준 등록 패턴이 추가되면 OQ로 재검토

---

## 변경 이력

- 2026-05-11 — D1, D2, D3, D4 신규 (Plan 13 Stage A0a/A0b/A/A'/B 구현 동반)
