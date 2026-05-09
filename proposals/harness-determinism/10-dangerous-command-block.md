# 10. Dangerous Command Block

**우선순위**: P2
**의존**: 없음
**예상 비용**: 0.3주
**결정성 이동**: 🟡 → 🟢 (LLM "주의" 지시 → hook hard block)

## 목표

CLAUDE.md 금지 사항 (force push, 보호 브랜치 직접 수정 등)을 LLM 자율 준수에 의존하지 않고 hook으로 block. narrow whitelist (좁은 범위 정확 차단).

## 현재 상태 / 문제

- CLAUDE.md "금지 사항"이 LLM 지시문 수준
- LLM이 무시하면 destructive 명령 실행 가능
- 좁은 범위 사고도 큰 비용 (data loss, force push)

## 제안

### 1. 차단 대상 narrow whitelist

```bash
# packages/ai-harness/scripts/hooks/dangerous-bash-block.sh

DANGEROUS_PATTERNS=(
  # Git 위험
  'git push.*--force(\s|$)'                    # --force-with-lease 제외
  'git push.*-f(\s|$)'
  'git reset.*--hard.*origin/(main|master|dev)'
  'git branch.*-D.*(main|master|dev)'
  'git checkout\s+--\s+.*'                     # 광범위 discard

  # FS 위험
  'rm\s+-rf\s+/$'                              # rm -rf /
  'rm\s+-rf\s+\$HOME'                          # rm -rf $HOME
  'rm\s+-rf\s+~'                               # rm -rf ~
  'rm\s+-rf\s+/[a-zA-Z]'                       # rm -rf /etc 등 (단, /tmp/는 허용?)

  # DB 위험
  'DROP\s+TABLE'
  'DROP\s+DATABASE'
  'TRUNCATE\s+TABLE'
)

ALLOW_NONCE_PATTERNS=(
  # Override가능: 사용자가 nonce로 확인하면 진행
)
```

### 2. PreToolUse Bash hook

```bash
# scripts/hooks/dangerous-bash-block.sh

cmd=$(jq -r '.tool_input.command' <<<"$payload")

for pattern in "${DANGEROUS_PATTERNS[@]}"; do
  if echo "$cmd" | grep -qE "$pattern"; then
    if ! state_get "$sid" ".dangerous_override_at" | grep -qv null; then
      echo "Dangerous command blocked: matches '$pattern'" >&2
      echo "Override: /allow-dangerous <reason>" >&2
      exit 2
    fi
  fi
done

exit 0
```

### 3. `/allow-dangerous` slash command

`packages/ai-harness/commands/allow-dangerous.md`:
- 사용자 입력 → state `dangerous_override_at: ts, reason: ...`
- 1회용 (consume 후 폐기)
- audit log entry

### 4. False positive 방지

- 정상 패턴 (`rm -rf build/`, `rm -rf node_modules/`, `rm -rf $TMPDIR/...`) 명시 allowlist
- `git push --force-with-lease` 는 명시적으로 패턴에서 제외 (위 regex)

### 5. CLAUDE.md 와 정합성

CLAUDE.md 금지 사항 list와 hook whitelist 1:1 매핑. 둘 중 하나만 변경 시 mismatch 위험 → CLAUDE.md MANAGED BLOCK 업데이트가 hook 변경을 require.

## 변경 파일

```
packages/ai-harness/scripts/hooks/dangerous-bash-block.sh    (신규)
packages/ai-harness/scripts/hooks/lib/register-workflow-hooks.sh  (등록)
packages/ai-harness/commands/allow-dangerous.md               (신규)
packages/ai-harness/scripts/hooks/lib/session-state.sh        (override nonce)
packages/ai-harness/scripts/tests/dangerous-bash.smoke.sh     (신규)
~/.claude/CLAUDE.md MANAGED BLOCK                             (정확한 차단 list 명시)
```

## State schema

```json
{
  "dangerous_override_at": null | "ts",
  "dangerous_override_consumed": false
}
```

## Test plan

`dangerous-bash.smoke.sh`:

1. `git push --force` → block
2. `git push --force-with-lease` → pass
3. `rm -rf build/` → pass (false positive 검증)
4. `rm -rf /` → block
5. `rm -rf $HOME` → block
6. `git reset --hard origin/main` → block
7. `git branch -D main` → block
8. `DROP TABLE users;` (Bash 안 SQL) → block
9. `/allow-dangerous fix urgent prod` → nonce set
10. nonce 후 `git push --force` 1회 통과
11. 다음 dangerous 명령 → 다시 block

## Open questions

1. `rm -rf /tmp/...` 는 허용? 아니면 block? 보수적 default = block.
2. CI 환경에서 `git push --force-with-lease` 도 막아야? (force-with-lease는 일반적으로 안전).
3. SQL 패턴 검출 — DB 쿼리 도구 호출 (psql, mysql) 통한 명령도 cover? 또는 Bash command만?
4. nonce 즉시 1회 소비 vs 5분 timeout?

## Risk

- **R1 (med)**: False positive — 정상 명령 차단 → 사용자 frustration. 완화: narrow whitelist, 명시 allowlist 추가.
- **R2 (low)**: Regex 회피 (예: `git push --force=...`). 완화: pattern review + 정기 audit.
- **R3 (low)**: Override 남용. 완화: audit log + nonce 단발성.

## Rollback

- `SAZO_DISABLE_DANGEROUS_BLOCK=1` env → 비활성
- 패턴 list revert

## Acceptance criteria

- [ ] PreToolUse Bash hook이 whitelist 매칭 시 block, exit 2
- [ ] `git push --force` block, `--force-with-lease` pass
- [ ] `rm -rf build/` pass, `rm -rf $HOME` block
- [ ] `/allow-dangerous` 1회 nonce 동작
- [ ] Smoke test 11개 통과
- [ ] CLAUDE.md hook whitelist 1:1 매핑 명시
