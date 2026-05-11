# Spike — SessionEnd Hook Schema (Plan 13 Stage S0)

**조사 일시**: 2026-05-11
**Plan 13 dependency**: Stage S0 BLOCKING prerequisite
**조사 방법**: WebFetch + Context7 + GH issue 검색

## 종합 결론

- **Hook event name**: `SessionEnd` (공식 선정, stable)
- **필수 payload fields**: `session_id` (string), `transcript_path` (string), `cwd` (string), `hook_event_name` (literal "SessionEnd"), `reason` (enum: clear|logout|prompt_input_exit|other)
- **선택 fields**: `permission_mode` (optional)
- **Fire 조건**: Ctrl+D (clean close). ⚠️ /exit 커맨드 시 **fire 안 함** (issue #17885, #35892 open bug)
- **Plan 13 Stage A 권장**:
  - Hook 이름: `post-session-end-metrics.sh` (기존 handoff 메모와 일치)
  - `transcript_path` field 반드시 포함하여 최종 conversation log 접근
  - /exit 미지원 인지, fallback plan 검토 권장 (Stop hook 또는 수동 trigger)

---

## Q1. Hook event 이름

**공식 선정**: `SessionEnd`

**Stability tier**: Stable (v1.0.85+ 이후 released)

**Docs**: https://code.claude.com/docs/en/hooks (Context7 쿼리 결과)

**TypeScript signature** (from SDK docs):
```typescript
type SessionEndHookInput = BaseHookInput & {
  hook_event_name: "SessionEnd";
  reason: ExitReason;
};
```

---

## Q2. Payload schema

**JSON example** (Context7 docs):
```json
{
  "session_id": "abc123",
  "transcript_path": "/Users/.../.claude/projects/.../00893aaf-19fa-41d2-8238-13269b9b3ca0.jsonl",
  "cwd": "/Users/...",
  "hook_event_name": "SessionEnd",
  "reason": "other"
}
```

**Field table** (BaseHookInput + SessionEnd-specific):

| Field | Type | Required | Description | Format |
|---|---|---|---|---|
| `session_id` | string | ✓ | Unique session identifier | UUID or similar |
| `transcript_path` | string | ✓ | Path to session JSONL transcript | Absolute filesystem path |
| `cwd` | string | ✓ | Current working directory | Absolute path |
| `hook_event_name` | string | ✓ | Literal "SessionEnd" | Constant |
| `reason` | string enum | ✓ | Exit reason (see below) | see Q3 |
| `permission_mode` | string | ✗ | Optional permission context | (unknown values) |

**`reason` enum values** (from Context7 + GH issues):
- `clear` — /clear command
- `logout` — User logout
- `prompt_input_exit` — User exited during prompt input
- `other` — Other/default reason

⚠️ **UNCONFIRMED**: `resume` listed in Context7 docs but not all sources consistent. GH issue #17885 suggests `exit` may also be value (docs inconsistency).

---

## Q3. Trigger 조건

| Trigger | Fire? | Payload `reason` | Notes |
|---|---|---|---|
| **Ctrl+D (EOF)** | ✓ Yes | `other` | Clean exit, documented working case |
| **/exit command** | ✗ **NO** | — | Known issue #17885, #35892 (open). Hardcoded "Goodbye!" message appears but hook silent |
| **/clear command** | ✗ **NO** | `clear` | Issue #6428 — docs claim `clear` reason but hook doesn't actually fire |
| **Ctrl+C (SIGINT)** | ⚠️ Partial | — | Hook fires but **cancelled mid-execution** with "Request interrupted by user" (issue #32712) |
| **Session error/crash** | ✓ Yes | `other` | Inferred from design |
| **--continue resume** | ✓ Yes but buggy | stale value | Issue #9188 — hook receives **previous session's** session_id/transcript_path (not current resumed session) |

**Key insight**: SessionEnd is **reliable only for Ctrl+D exit**. CLI/error paths have known gaps.

---

## Q4. Multi-event 동작

**Single fire per session**: SessionEnd fires **once** at session termination (not repeated).

**Contrast with Stop hook**: Stop hook fires **after every Claude response** (multiple times). SessionEnd by design is terminal event.

---

## Q5. Hook 등록

**settings.json** configuration (inferred from Context7 + docs):
```json
{
  "hooks": {
    "SessionEnd": [
      {
        "type": "command",
        "command": "/path/to/post-session-end-metrics.sh"
      }
    ]
  }
}
```

**Input delivery**: Hook receives JSON via `stdin` (not command-line args).

**Hook script pattern** (bash):
```bash
#!/bin/bash
input=$(cat)  # read JSON from stdin
session_id=$(echo "$input" | jq -r '.session_id')
transcript_path=$(echo "$input" | jq -r '.transcript_path')
reason=$(echo "$input" | jq -r '.reason')
cwd=$(echo "$input" | jq -r '.cwd')

# ... write metrics to JSONL
```

**Exit code behavior**: Hook exit code 0 = success, non-zero = error (appears in Claude UI but doesn't block session).

---

## Q6. 알려진 버그/한계

| Issue | Severity | GH Link | Impact |
|---|---|---|---|
| SessionEnd doesn't fire on /exit | HIGH | [#17885](https://github.com/anthropics/claude-code/issues/17885), [#35892](https://github.com/anthropics/claude-code/issues/35892) | CLI exit path broken; workarounds: use Ctrl+D or Stop hook |
| SessionEnd doesn't fire on /clear | MEDIUM | [#6428](https://github.com/anthropics/claude-code/issues/6428) | /clear session cleanup unavailable |
| SessionEnd hook killed on Ctrl+C | HIGH | [#32712](https://github.com/anthropics/claude-code/issues/32712) | Async hooks (API calls, file writes) interrupted mid-flight |
| SessionEnd hooks killed before async work completes | HIGH | [#41577](https://github.com/anthropics/claude-code/issues/41577) | Long-running cleanup (e.g., upload to remote) fails silently |
| Stale transcript_path on --continue | MEDIUM | [#9188](https://github.com/anthropics/claude-code/issues/9188) | Hook receives old session's path after resume, not current session |
| transcript_path empty in some hooks | LOW | [#13668](https://github.com/anthropics/claude-code/issues/13668) | PreCompact hook only; SessionEnd not affected |

---

## Plan 13 Stage A 권장 (적용)

**Hook 이름**: `post-session-end-metrics.sh` ✓ (handoff 메모 일치)

**사용 payload fields (minimum viable subset)**:
- `session_id` — Unique session key for correlation
- `transcript_path` — Path to final JSONL log (must exist + be readable before fire)
- `cwd` — Session working directory context
- `reason` — Exit reason for classification

**Acceptance criteria 갱신**:
1. Hook script reads 4 fields above from stdin JSON
2. Script writes determinism metrics to `~/.claude/state/session-metrics-{session_id}.jsonl` (one record per session-end)
3. **Tested exit path**: Ctrl+D only (confirmed working). /exit path explicitly documented as "not supported" pending upstream fix.
4. **Timeout handling**: Set `timeout 5s` wrapper in script (issue #41577 risk — hook may be killed by Claude before completion)
5. **Fallback**: If SessionEnd proves unreliable in real workflows, Switch to Stop hook (fires reliably after every response) with periodic dedup on session_id.

**Risk**:
- ⚠️ /exit command users will miss session metrics (open GH bugs prevent fire). Mitigation: Ctrl+D exit instructions in docs, or switch to Stop hook + aggregation.
- ⚠️ Async operations (network, file I/O) at 5s timeout risk; keep hook synchronous + lightweight.
- ⚠️ transcript_path may be stale after --continue resume (issue #9188); recommend test with `--continue` workflows.

---

## Sources

- [Claude Code Hooks Reference](https://docs.anthropic.com/en/docs/claude-code/hooks)
- [SessionEnd Hook Doesn't Fire on /exit Command — Issue #17885](https://github.com/anthropics/claude-code/issues/17885)
- [SessionEnd/Stop Hooks Should Fire on /exit Command — Issue #35892](https://github.com/anthropics/claude-code/issues/35892)
- [SessionEnd Hook Does Not Fire with /clear — Issue #6428](https://github.com/anthropics/claude-code/issues/6428)
- [SessionEnd Hook Cancelled on Ctrl+C — Issue #32712](https://github.com/anthropics/claude-code/issues/32712)
- [SessionEnd Hooks Killed Before Async Work Completes — Issue #41577](https://github.com/anthropics/claude-code/issues/41577)
- [Hooks Receive Stale session_id/transcript_path After /exit and --continue — Issue #9188](https://github.com/anthropics/claude-code/issues/9188)
