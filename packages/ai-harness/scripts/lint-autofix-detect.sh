#!/bin/bash
# lint autofix 커맨드 자동 감지 + 전역 캐시 조회/저장 라이브러리.
#
# Usage (source):
#   . lint-autofix-detect.sh
#   RESOLVED=$(resolve_lint_command "$REPO_ROOT") || { handle_miss; }
#   cmd=$(printf '%s' "$RESOLVED" | cut -f1)
#   supports_files=$(printf '%s' "$RESOLVED" | cut -f2)   # "true" | "false"
#
# 캐시 스키마 (~/.config/sazo-ai-harness/lint-fix-cache.json):
#   { "repos": { "<sha256(repo_root)>": { path, command, supports_files_arg, set_at } } }
#
# 감지 우선순위 (D2 스코프 한정 원칙):
#   1. 전역 캐시
#   2. package.json에 lint-staged 의존성 존재 → {pm} lint-staged (파일 인자 불필요)
#   3. pyproject.toml에 [tool.ruff] → ruff check --fix <files>
#   4. pyproject.toml에 [tool.black] → black <files>
#   5. go.mod → gofmt -w <files>
#   6. 없음 → return 1 (호출자가 사용자에게 질문 유도)

LINT_CACHE_FILE="${SAZO_LINT_CACHE_FILE:-$HOME/.config/sazo-ai-harness/lint-fix-cache.json}"

_lint_cache_key() {
    local path="$1"
    if command -v shasum >/dev/null 2>&1; then
        printf '%s' "$path" | shasum -a 256 | awk '{print $1}'
    elif command -v sha256sum >/dev/null 2>&1; then
        printf '%s' "$path" | sha256sum | awk '{print $1}'
    else
        # Fallback: base64. shasum/sha256sum 둘 다 없는 환경은 극히 드물지만
        # 안전망. 키 충돌 가능성은 무시할 수 있음 (경로는 보통 짧고 고유).
        printf '%s' "$path" | base64 | tr -d '\n' | tr '/+=' '___'
    fi
}

lint_cache_get() {
    local repo="$1"
    [ -f "$LINT_CACHE_FILE" ] || return 1
    command -v jq >/dev/null 2>&1 || return 1
    local key
    key=$(_lint_cache_key "$repo")
    local cmd sf
    cmd=$(jq -r --arg k "$key" '.repos[$k].command // empty' "$LINT_CACHE_FILE" 2>/dev/null)
    [ -n "$cmd" ] || return 1
    sf=$(jq -r --arg k "$key" '.repos[$k].supports_files_arg // false' "$LINT_CACHE_FILE" 2>/dev/null)
    printf '%s\t%s\n' "$cmd" "$sf"
}

lint_cache_set() {
    local repo="$1" cmd="$2" sf="${3:-false}"
    command -v jq >/dev/null 2>&1 || return 1
    # 캐시 디렉토리·파일 권한 하드닝 — 값이 매 커밋마다 bash -c로 평가되므로,
    # 다른 사용자/프로세스가 파일을 변조해 RCE를 유도할 수 없도록 600/700.
    mkdir -p "$(dirname "$LINT_CACHE_FILE")"
    chmod 700 "$(dirname "$LINT_CACHE_FILE")" 2>/dev/null || true
    if [ ! -f "$LINT_CACHE_FILE" ]; then
        (umask 077; echo '{"repos":{}}' > "$LINT_CACHE_FILE")
    fi
    chmod 600 "$LINT_CACHE_FILE" 2>/dev/null || true

    # 손상된 캐시는 덮어쓰지 않고 abort — 사용자 다른 entry 보호
    if ! jq -e 'type == "object"' "$LINT_CACHE_FILE" >/dev/null 2>&1; then
        local backup="${LINT_CACHE_FILE}.broken-$(date +%s)"
        cp "$LINT_CACHE_FILE" "$backup"
        echo "WARN: $LINT_CACHE_FILE is not valid JSON (backup: $backup). Aborting cache write." >&2
        return 1
    fi

    local key ts tmp
    key=$(_lint_cache_key "$repo")
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    tmp=$(mktemp "${LINT_CACHE_FILE}.XXXXXX")
    jq --arg k "$key" --arg path "$repo" --arg cmd "$cmd" --argjson sf "$sf" --arg ts "$ts" '
        .repos = (.repos // {})
        | .repos[$k] = {path: $path, command: $cmd, supports_files_arg: $sf, set_at: $ts}
    ' "$LINT_CACHE_FILE" > "$tmp" && mv "$tmp" "$LINT_CACHE_FILE" || {
        rm -f "$tmp"
        return 1
    }
}

lint_cache_unset() {
    local repo="$1"
    [ -f "$LINT_CACHE_FILE" ] || return 0
    command -v jq >/dev/null 2>&1 || return 1
    local key tmp
    key=$(_lint_cache_key "$repo")
    tmp=$(mktemp "${LINT_CACHE_FILE}.XXXXXX")
    jq --arg k "$key" 'if .repos[$k] then del(.repos[$k]) else . end' "$LINT_CACHE_FILE" > "$tmp" \
        && mv "$tmp" "$LINT_CACHE_FILE" || rm -f "$tmp"
}

_detect_pm() {
    local repo="$1"
    if [ -f "$repo/yarn.lock" ]; then echo yarn
    elif [ -f "$repo/pnpm-lock.yaml" ]; then echo pnpm
    elif [ -f "$repo/package-lock.json" ]; then echo npm
    else echo npm
    fi
}

detect_lint_autofix() {
    local repo="$1"

    # 1. lint-staged (스코프 한정의 de-facto 표준)
    # `has()`로 null-safe 검사 — devDependencies 키 자체가 없는 package.json도 안전하게 처리
    if [ -f "$repo/package.json" ] && command -v jq >/dev/null 2>&1; then
        # 실제 dependency로 선언된 경우만 인식.
        # top-level `"lint-staged"` config key만 있고 dependency 선언이 없으면
        # `npx lint-staged`가 on-demand fetch 또는 실패하여 commit을 조용히 차단할 수 있음.
        if jq -e '
            ((.devDependencies // {}) | has("lint-staged"))
            or ((.dependencies // {}) | has("lint-staged"))
        ' "$repo/package.json" >/dev/null 2>&1; then
            local pm
            pm=$(_detect_pm "$repo")
            case "$pm" in
                yarn) printf 'yarn lint-staged\tfalse\n' ;;
                pnpm) printf 'pnpm lint-staged\tfalse\n' ;;
                npm)  printf 'npx lint-staged\tfalse\n' ;;
            esac
            return 0
        fi
    fi

    # 2. Python — section 헤딩은 정확히 `[tool.ruff]` 또는 `[tool.ruff.*]`만 매칭.
    # `[tool.rufflehandler]` 같은 이름 충돌 방지.
    if [ -f "$repo/pyproject.toml" ]; then
        if grep -Eq '^\[tool\.ruff(\]|\.)' "$repo/pyproject.toml" 2>/dev/null; then
            printf 'ruff check --fix\ttrue\n'
            return 0
        fi
        if grep -Eq '^\[tool\.black(\]|\.)' "$repo/pyproject.toml" 2>/dev/null; then
            printf 'black\ttrue\n'
            return 0
        fi
    fi

    # 3. Go
    if [ -f "$repo/go.mod" ]; then
        printf 'gofmt -w\ttrue\n'
        return 0
    fi

    return 1
}

resolve_lint_command() {
    local repo="$1"
    local hit
    if hit=$(lint_cache_get "$repo"); then
        printf '%s\n' "$hit"
        return 0
    fi
    detect_lint_autofix "$repo"
}
