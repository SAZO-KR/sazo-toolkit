#!/bin/bash
# Claude Sleep Guard 셋업 — macOS 전용, opt-in, 멱등.
#
# 호출 모드:
#   setup.sh            # 대화형 (install.sh에서 호출)
#   setup.sh --quiet    # 비대화형 검증/복구 (auto-update.sh에서 호출)
#
# 설치 항목:
#   1) ~/.claude/hooks/sazo-caffeinate-session.sh → 이 저장소 스크립트 심볼릭 링크
#   2) ~/.claude/hooks/sazo-sleep-watchdog.sh     → 심볼릭 링크
#   3) ~/Library/LaunchAgents/shop.sazo.claude-sleep-guard.plist
#   4) /etc/sudoers.d/sazo-claude-pmset-$USER (pmset disablesleep 0|1 NOPASSWD)
#      (파일명에 $USER 포함 — 공유 머신에서 다른 팀원 sudoers 덮어쓰기 방지)
#   5) ~/.claude/settings.json 의 UserPromptSubmit / PostToolUse / Stop 훅
#
# Marker:
#   ~/.config/sazo-ai-harness/.sleep-guard-optout    — opt-out (대화형에서 'n' 입력 시)
#   ~/.config/sazo-ai-harness/.sleep-guard-init-done — 설치 완료 후 생성
#
# 재활성화:
#   rm ~/.config/sazo-ai-harness/.sleep-guard-optout
#   rm ~/.config/sazo-ai-harness/.sleep-guard-init-done

set -u

QUIET=0
[ "${1:-}" = "--quiet" ] && QUIET=1

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MARKER_DIR="$HOME/.config/sazo-ai-harness"
OPTOUT_MARKER="$MARKER_DIR/.sleep-guard-optout"
INIT_DONE_MARKER="$MARKER_DIR/.sleep-guard-init-done"

SETTINGS="$HOME/.claude/settings.json"
HOOKS_DIR="$HOME/.claude/hooks"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
PLIST_PATH="$LAUNCH_AGENTS_DIR/shop.sazo.claude-sleep-guard.plist"
# 멀티유저/공유 머신에서 다른 사용자가 setup.sh를 돌릴 때 기존 사용자의
# NOPASSWD 엔트리를 덮어쓰지 않도록 파일명에 $USER를 포함한다.
# 단, sudoers(5) 명시: "/etc/sudoers.d 안의 파일이 '.' 또는 '~'를 포함하면 sudo가 무시"
# (패키지 매니저/에디터 백업 파일과 충돌 방지). macOS 'firstname.lastname' username
# 환경에서 dot이 그대로 들어가면 룰 자체가 로드 안 되어 NOPASSWD 미동작 → 'sudo -n
# pmset' 실패 → sleep-guard 사실상 미동작. 따라서 파일명에 들어가는 username은
# alphanumeric/_/- 외 문자를 '_'로 치환한다.
SUDOERS_FILENAME_USER=$(printf '%s' "${USER:-$(id -un)}" | LC_ALL=C tr -c 'A-Za-z0-9_-' '_')
SUDOERS_FILE="/etc/sudoers.d/sazo-claude-pmset-${SUDOERS_FILENAME_USER}"
# 멀티유저 collision 한계: 두 사용자 short name이 non-alphanumeric만 다르면 (예:
# 'foo.bar' vs 'foo_bar') 둘 다 'sazo-claude-pmset-foo_bar'로 매핑되어 두 번째
# 설치가 첫 번째의 NOPASSWD 룰을 덮는다. 결과적으로 첫 번째 사용자의 sleep-guard는
# 다음 'sudo -n pmset' 호출에서 조용히 실패한다 (룰의 username 필드가 두 번째 사용자
# 이므로 첫 번째 사용자에는 매칭 안 됨). macOS 개인 dev machine에선 드문 시나리오고,
# 권한 상승 없음(overwriting 사용자도 pmset NOPASSWD만 얻음).
# 동일 사용자가 이전 버전(파일명에 dot 포함)으로 만든 stale 파일이 남아 있으면
# 새 파일과 공존하게 된다(sudo는 dot 파일 무시이므로 룰 충돌은 없지만 cleanup 권장).
LEGACY_SUDOERS_FILE="/etc/sudoers.d/sazo-claude-pmset-${USER:-$(id -un)}"

HOOK_CAFFEINATE_SRC="$SCRIPT_DIR/caffeinate-session.sh"
HOOK_WATCHDOG_SRC="$SCRIPT_DIR/watchdog.sh"
HOOK_CAFFEINATE_DST="$HOOKS_DIR/sazo-caffeinate-session.sh"
HOOK_WATCHDOG_DST="$HOOKS_DIR/sazo-sleep-watchdog.sh"
PLIST_TEMPLATE="$SCRIPT_DIR/launchd.plist.template"

msg() { [ "$QUIET" -eq 0 ] && echo "$@"; }
err() { echo "$@" >&2; }

# ─── 0. macOS 가드 ───
if [ "$(uname -s)" != "Darwin" ]; then
    msg "⏭️  sleep-guard는 macOS 전용 — 건너뜀"
    exit 0
fi

# ─── 1. opt-out ───
if [ -f "$OPTOUT_MARKER" ]; then
    msg "⏭️  sleep-guard opt-out (마커: $OPTOUT_MARKER)"
    exit 0
fi

# ─── 2. 소스 파일 존재 확인 ───
for f in "$HOOK_CAFFEINATE_SRC" "$HOOK_WATCHDOG_SRC" "$PLIST_TEMPLATE"; do
    if [ ! -f "$f" ]; then
        err "❌ sleep-guard 소스 파일 누락: $f"
        exit 1
    fi
done

chmod +x "$HOOK_CAFFEINATE_SRC" "$HOOK_WATCHDOG_SRC" 2>/dev/null || true

# ─── 3. 이미 설치됨 & 검증 통과 → 조기 종료 ───
# 훅 3개(UserPromptSubmit/heartbeat, PostToolUse/heartbeat, Stop/stop)가 모두 등록됐는지
# 개별 확인. 어느 하나라도 누락되면 재설치 경로로 폴백하여 누락 훅을 등록한다.
verify_installed() {
    [ -L "$HOOK_CAFFEINATE_DST" ] || return 1
    [ -L "$HOOK_WATCHDOG_DST" ] || return 1
    [ -f "$PLIST_PATH" ] || return 1
    [ -f "$SUDOERS_FILE" ] || return 1
    # jq 부재 또는 settings.json 부재는 "검증 불가" → 재설치 경로로 폴백.
    # 기존에는 이 케이스에서 return 0 (installed)로 오판되어 --quiet 복구가 스킵됐음.
    command -v jq >/dev/null 2>&1 || return 1
    [ -f "$SETTINGS" ] || return 1
    local want_heartbeat want_stop
    want_heartbeat="$HOOK_CAFFEINATE_DST heartbeat"
    want_stop="$HOOK_CAFFEINATE_DST stop"
    # 3개 훅 이벤트에 대해 정확한 command 문자열 등록 여부 각각 검증
    jq --arg c "$want_heartbeat" '
        [.hooks.UserPromptSubmit[]?.hooks[]? | select(.command == $c)] | length > 0
    ' "$SETTINGS" 2>/dev/null | grep -q true || return 1
    jq --arg c "$want_heartbeat" '
        [.hooks.PostToolUse[]?.hooks[]? | select(.command == $c)] | length > 0
    ' "$SETTINGS" 2>/dev/null | grep -q true || return 1
    jq --arg c "$want_stop" '
        [.hooks.Stop[]?.hooks[]? | select(.command == $c)] | length > 0
    ' "$SETTINGS" 2>/dev/null | grep -q true || return 1
    return 0
}

if [ -f "$INIT_DONE_MARKER" ] && verify_installed; then
    msg "✅ sleep-guard 이미 설치됨 (검증 통과)"
    exit 0
fi

# ─── 4. quiet 모드: 설치는 안 하지만 손상된 항목 복구 시도 ───
# 단, sudoers는 복구 불가 (sudo 필요) → quiet 모드는 건너뜀.
# settings.json hook / symlink / plist는 복구 가능.

# ─── 5. 대화형: opt-in 질문 ───
if [ "$QUIET" -eq 0 ] && [ ! -f "$INIT_DONE_MARKER" ]; then
    # install.sh의 ask_yes_no 패턴과 일관: stdin이 tty이거나 /dev/tty 존재
    can_prompt() {
        [ -t 0 ] || [ -e /dev/tty ]
    }
    if ! can_prompt; then
        echo "ℹ️  sleep-guard 비대화형 환경 — 설치 안내 생략 (대화형 재실행: bash $0)"
        exit 0
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Sleep Guard 설치 안내 (macOS, opt-in)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  Claude Code가 응답 생성/툴 실행 중일 때만 노트북"
    echo "  뚜껑을 닫아도 sleep으로 들어가지 않도록 막아줍니다."
    echo ""
    echo "  구성:"
    echo "    - UserPromptSubmit/PostToolUse/Stop 훅에 heartbeat 등록"
    echo "    - launchd watchdog (10초 주기, stale 마커 정리)"
    echo "    - sudoers NOPASSWD 엔트리 (pmset disablesleep 0|1 만 허용)"
    echo ""
    echo "  sudoers 수정에 sudo 비밀번호가 1회 필요합니다."
    echo "  (엔트리: $SUDOERS_FILE)"
    echo ""

    printf "  지금 설치할까요? [y/N]: "
    if [ -e /dev/tty ]; then
        read -r answer </dev/tty || answer=""
    else
        read -r answer || answer=""
    fi

    case "${answer:-N}" in
        [yY]|[yY][eE][sS]) ;;  # 진행
        *)
            echo ""
            if [[ "$answer" =~ ^[nN][oO]?$ ]]; then
                mkdir -p "$MARKER_DIR"
                touch "$OPTOUT_MARKER"
                echo "  → 명시적 거부 감지 — 다시 묻지 않습니다. 재활성화: rm $OPTOUT_MARKER"
            else
                echo "  → 이번 실행은 설치 건너뜀. (영구 거부는 'n' 입력)"
            fi
            echo ""
            exit 0
            ;;
    esac
fi

# quiet 모드에서 init-done 마커 없으면 = 아직 opt-in 안 됨 → 건너뜀
if [ "$QUIET" -eq 1 ] && [ ! -f "$INIT_DONE_MARKER" ]; then
    exit 0
fi

# ─── 6. 훅 스크립트 심볼릭 링크 ───
mkdir -p "$HOOKS_DIR"
ln -sfn "$HOOK_CAFFEINATE_SRC" "$HOOK_CAFFEINATE_DST"
ln -sfn "$HOOK_WATCHDOG_SRC" "$HOOK_WATCHDOG_DST"
msg "  ✓ hooks 심볼릭 링크: $HOOK_CAFFEINATE_DST, $HOOK_WATCHDOG_DST"

# ─── 7. launchd plist 생성 ───
# launchd는 사용자 쉘 프로파일의 env를 상속하지 않으므로 STALE_SECS와 USER를
# plist의 EnvironmentVariables로 명시적으로 주입한다. STALE_SECS는 install-time
# 환경변수가 있으면 그 값, 없으면 900(15분) 기본.
mkdir -p "$LAUNCH_AGENTS_DIR"
plist_stale_secs="${CLAUDE_AWAKE_STALE_SECS:-900}"
# $USER가 unset인 --quiet 컨텍스트(set -u)에서 unbound variable로 죽지 않도록
# watchdog.sh와 동일한 fallback 적용.
plist_user="${USER:-$(id -un)}"
sed \
    -e "s|__WATCHDOG__|$HOOK_WATCHDOG_DST|g" \
    -e "s|__STALE_SECS__|$plist_stale_secs|g" \
    -e "s|__USER__|$plist_user|g" \
    "$PLIST_TEMPLATE" > "$PLIST_PATH"
msg "  ✓ launchd plist: $PLIST_PATH"

# ─── 8. settings.json 훅 등록 ───
register_hook() {
    # $1 = event ("UserPromptSubmit"|"PostToolUse"|"Stop")
    # $2 = command path
    # $3 = matcher (default "*")
    local event="$1" cmd="$2" matcher="${3:-*}"

    [ -f "$SETTINGS" ] || { mkdir -p "$(dirname "$SETTINGS")"; echo '{}' > "$SETTINGS"; }
    command -v jq >/dev/null 2>&1 || { err "❌ jq 필요 (brew install jq)"; return 1; }
    jq empty "$SETTINGS" >/dev/null 2>&1 || { err "❌ $SETTINGS 이 유효한 JSON이 아님"; return 1; }

    # 이미 같은 command가 등록됐으면 skip
    local exists
    exists=$(jq --arg e "$event" --arg c "$cmd" '
        [.hooks[$e][]?.hooks[]? | select(.command == $c)] | length > 0
    ' "$SETTINGS")
    if [ "$exists" = "true" ]; then
        return 0
    fi

    local tmp
    tmp=$(mktemp)
    if jq --arg e "$event" --arg c "$cmd" --arg m "$matcher" '
        .hooks //= {}
        | .hooks[$e] //= []
        | (.hooks[$e] | map(select(.matcher == $m)) | length) as $has_matcher
        | if $has_matcher > 0 then
            .hooks[$e] = (.hooks[$e] | map(
                if .matcher == $m then
                    .hooks = ((.hooks // []) + [{type:"command", command:$c}])
                else . end
            ))
          else
            .hooks[$e] += [{matcher: $m, hooks: [{type:"command", command:$c}]}]
          end
    ' "$SETTINGS" > "$tmp"; then
        mv "$tmp" "$SETTINGS"
    else
        rm -f "$tmp"
        err "❌ settings.json 훅 등록 실패 ($event)"
        return 1
    fi
}

# 하나라도 실패하면 즉시 중단. 이어서 sudoers/plist를 설치하고 init-done 마커를
# 생성하면, 실제로는 훅이 미등록인데도 "설치됨"으로 오판되어 다음 --quiet 실행이
# 복구 경로로 진입하지 않는다.
register_hook "UserPromptSubmit" "$HOOK_CAFFEINATE_DST heartbeat" "*" || exit 1
register_hook "PostToolUse" "$HOOK_CAFFEINATE_DST heartbeat" "*" || exit 1
register_hook "Stop" "$HOOK_CAFFEINATE_DST stop" "*" || exit 1
msg "  ✓ settings.json 훅 등록"

# ─── 9. sudoers 엔트리 설치 ───
install_sudoers() {
    # set -u + USER unset 환경에서도 unbound variable로 죽지 않도록 폴백.
    local sudo_user="${USER:-$(id -un)}"
    # sudoers 문법: User_List에서 username 중 alphanumeric/_/- 외 문자(예: dot)는
    # backslash escape 필요. 미escape 시 sudo가 룰을 무시 → NOPASSWD 매칭 실패
    # → watchdog의 `sudo -n pmset` 실패 → sleep-guard 사실상 미작동.
    # macOS 'firstname.lastname' username 환경에서 특히 자주 노출되는 버그.
    local sudo_user_spec
    sudo_user_spec=$(printf '%s' "$sudo_user" | LC_ALL=C sed 's/[^A-Za-z0-9_-]/\\&/g')
    if [ -f "$SUDOERS_FILE" ]; then
        # 기존 파일이 기대 내용과 같으면 skip
        local expected="$sudo_user_spec ALL=(ALL) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1"
        # `--`로 옵션 종료 명시: $expected가 hyphen으로 시작하는 username으로
        # 빌드되면 grep이 옵션으로 해석할 수 있다 (defensive).
        if grep -Fxq -- "$expected" "$SUDOERS_FILE" 2>/dev/null; then
            msg "  ✓ sudoers 엔트리 이미 설치됨: $SUDOERS_FILE"
            return 0
        fi
    fi

    msg ""
    msg "  → sudoers 엔트리 설치 (sudo 비밀번호 1회 필요)"

    local tmp
    tmp=$(mktemp)
    cat > "$tmp" <<EOF
# sazo ai-harness sleep-guard — Claude Code 세션 활성 중에만 pmset 제어
# 범위: pmset -a disablesleep 0|1 두 명령만 허용
$sudo_user_spec ALL=(ALL) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1
EOF

    # visudo로 문법 검증 먼저
    if ! sudo /usr/sbin/visudo -c -f "$tmp" >/dev/null 2>&1; then
        err "  ❌ sudoers 파일 문법 검증 실패"
        rm -f "$tmp"
        return 1
    fi

    if sudo install -m 440 -o root -g wheel "$tmp" "$SUDOERS_FILE"; then
        rm -f "$tmp"
        msg "  ✓ sudoers 설치 완료: $SUDOERS_FILE"
        # legacy 파일(이전 버전이 남긴 dot 포함 파일명)이 있으면 cleanup.
        # sudo는 어차피 dot 파일을 무시하므로 보안/동작 영향 없지만 stale 파일 잔존
        # 방지를 위해 제거. 새 설치가 성공한 뒤에만 시도.
        # Path traversal 방어: $USER가 '../...' 같은 슬래시를 포함하면
        # LEGACY_SUDOERS_FILE 정규화 결과가 sudoers.d 밖을 가리킬 수 있다. basename이
        # 'sazo-claude-pmset-' prefix이고, full path가 정확히 '/etc/sudoers.d/<basename>'
        # 인 경우만 cleanup 진행 — 슬래시가 끼어든 입력은 mismatch로 안전 skip.
        local legacy_basename="${LEGACY_SUDOERS_FILE##*/}"
        if [ "$LEGACY_SUDOERS_FILE" != "$SUDOERS_FILE" ] \
            && [ -f "$LEGACY_SUDOERS_FILE" ] \
            && [ "$LEGACY_SUDOERS_FILE" = "/etc/sudoers.d/$legacy_basename" ] \
            && case "$legacy_basename" in sazo-claude-pmset-*) true ;; *) false ;; esac
        then
            # stderr 보존 — sudo rm 실패 시 사용자가 수동 cleanup 가능하도록 안내.
            if sudo rm -f "$LEGACY_SUDOERS_FILE"; then
                msg "  ✓ legacy sudoers 제거: $LEGACY_SUDOERS_FILE"
            else
                msg "  ⚠️  legacy sudoers 제거 실패 — 수동 제거: sudo rm $LEGACY_SUDOERS_FILE"
            fi
        fi
    else
        rm -f "$tmp"
        err "  ❌ sudoers 설치 실패"
        return 1
    fi
}

if [ "$QUIET" -eq 1 ]; then
    # quiet 모드는 sudoers 설치 시도하지 않음 (sudo 프롬프트 불가)
    if [ ! -f "$SUDOERS_FILE" ]; then
        msg "  ⚠️  sudoers 미설치 — 대화형 재실행 필요: bash $0"
    fi
else
    install_sudoers || exit 1
fi

# ─── 10. launchd 로드 ───
if command -v launchctl >/dev/null 2>&1; then
    launchctl unload "$PLIST_PATH" >/dev/null 2>&1 || true
    if launchctl load "$PLIST_PATH" >/dev/null 2>&1; then
        msg "  ✓ launchd watchdog 로드 완료"
    else
        msg "  ⚠️  launchctl load 실패 (수동: launchctl load $PLIST_PATH)"
    fi
fi

# ─── 11. 완료 마커 ───
mkdir -p "$MARKER_DIR"
touch "$INIT_DONE_MARKER"
msg ""
msg "✅ sleep-guard 설치 완료."
msg "   다음 Claude Code 세션부터 자동 동작합니다."

exit 0
