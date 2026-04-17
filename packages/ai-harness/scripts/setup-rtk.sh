#!/bin/bash
# RTK (Rust Token Killer) 셋업 — 팀 공용, 멱등 실행
#
# 호출 모드:
#   setup-rtk.sh           # 대화형 (install.sh에서 호출)
#   setup-rtk.sh --quiet   # 비대화형, 조용한 검증/복구 (auto-update.sh에서 호출)
#
# 동작 (우선순위 순):
#   1) opt-out 마커 존재            → exit 0
#   2) settings.json 손상            → 건드리지 않고 exit 0 (사용자 설정 파괴 방지)
#   3) rtk 바이너리 없음:
#      - quiet 모드                  → exit 0 (자동 유도 금지)
#      - 대화형 + TTY 없음           → exit 0 (curl|bash/CI에서 무단 설치 방지)
#      - 대화형 + TTY + brew 없음    → 수동 안내 후 exit 0
#      - 대화형 + TTY + brew 있음    → Y/n 물어 설치 (N이면 opt-out 마커)
#   4) init-done 마커 존재 + hook OK → exit 0
#   5) hook 이미 등록됨              → init-done 마커 생성 후 exit 0
#   6) 그 외                         → rtk init 실행, 성공 시 init-done 마커
#
# 설계 원칙:
# - opt-out / init-done 마커는 **user-level 상태**로 ai-harness 설치 경로와 독립.
#   사용자가 ai-harness를 재설치해도 이 결정은 유지된다.
# - hook 등록은 rtk 공식 CLI (`rtk init --auto-patch --global`)에 위임.
#   직접 settings.json을 수정하지 않음 — rtk가 자신의 hook schema를 소유.
# - 비대화형 환경에서 사용자 동의 없이 brew install을 실행하지 않음 (trust boundary).
#
# 재활성화:
#   rm ~/.config/sazo-ai-harness/.rtk-optout       # 다시 설치 안내를 받고 싶을 때
#   rm ~/.config/sazo-ai-harness/.rtk-init-done    # hook 재등록을 강제하고 싶을 때

set -u

QUIET=0
[ "${1:-}" = "--quiet" ] && QUIET=1

MARKER_DIR="$HOME/.config/sazo-ai-harness"
OPTOUT_MARKER="$MARKER_DIR/.rtk-optout"
INIT_DONE_MARKER="$MARKER_DIR/.rtk-init-done"
SETTINGS="$HOME/.claude/settings.json"

msg() { [ "$QUIET" -eq 0 ] && echo "$@"; }

# ─── 1. opt-out ───
if [ -f "$OPTOUT_MARKER" ]; then
    msg "⏭️  RTK 셋업 opt-out (마커: $OPTOUT_MARKER)"
    exit 0
fi

# ─── 2. settings.json 손상 방어 ───
# 유효한 JSON이 아니면 이후 모든 분기가 위험해짐 — 건드리지 않고 종료.
if [ -f "$SETTINGS" ] && command -v jq >/dev/null 2>&1; then
    if ! jq empty "$SETTINGS" >/dev/null 2>&1; then
        msg "⚠️  $SETTINGS 이 유효한 JSON이 아님 — RTK hook 검증/복구 건너뜀"
        exit 0
    fi
fi

# ─── 3. rtk 바이너리 부재 처리 ───
if ! command -v rtk >/dev/null 2>&1; then
    # quiet 모드는 조용히 통과 (auto-update는 설치 유도하지 않음)
    if [ "$QUIET" -eq 1 ]; then
        exit 0
    fi

    # Prompt 가능 여부 확인 — 비대화형(CI, nohup, 파이프)에서 brew install +
    # hook 등록 유도 방지. `[ -e /dev/tty ]`만으로는 불충분 — CI 환경에서도
    # device file은 존재. 실제로 controlling terminal을 **열 수 있는지** 검증.
    # (exec <)를 서브쉘로 감싸 stdin 재지정 side effect 없이 가능 여부만 본다.
    can_prompt() {
        [ -t 0 ] || (exec </dev/tty) 2>/dev/null
    }
    if ! can_prompt; then
        echo "ℹ️  RTK 미설치, 비대화형 환경 — 설치 안내를 건너뜁니다."
        echo "    대화형 터미널에서 재실행: bash $0"
        exit 0
    fi

    if ! command -v brew >/dev/null 2>&1; then
        echo ""
        echo "ℹ️  RTK는 Homebrew로 설치 가능하지만 brew가 없습니다."
        echo "    수동 설치 참고: https://www.rtk-ai.app/"
        echo "    RTK 없이 계속 진행합니다 (보고서는 정상 동작)."
        echo ""
        exit 0
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  RTK (Rust Token Killer) 설치 안내"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  Claude Code의 bash 출력을 압축해 LLM 토큰을"
    echo "  60-90% 절감해주는 CLI 프록시입니다."
    echo "  - 출처: https://www.rtk-ai.app/ (Apache-2.0, Homebrew 공식)"
    echo "  - 동작: PreToolUse(Bash) 훅이 자동으로 rtk 경유 실행"
    echo ""
    echo "  설치 단계: brew install rtk  →  rtk init --auto-patch --global"
    echo ""

    # TTY에서 read. /dev/tty 우선 (stdin 리다이렉션 상황 대비)
    # 기본값은 N — `brew install` + `rtk init --auto-patch --global`은 사용자 설정을
    # 수정하는 trust boundary 변경이므로 **명시적 y**를 요구한다. Enter 연타나 CI에서
    # 빈 응답이 들어와도 자동 설치되지 않도록.
    printf "  지금 설치할까요? [y/N]: "
    if [ -e /dev/tty ]; then
        read -r answer </dev/tty || answer=""
    else
        read -r answer || answer=""
    fi

    # 빈 응답(Enter만) 또는 명시적 n/no → skip (opt-out 마커는 생성하지 않음 —
    # "나중에 다시 묻기" 허용). 명시적 y/yes만 설치로 진행.
    case "${answer:-N}" in
        [yY]|[yY][eE][sS])
            ;;  # 아래 설치 진행
        *)
            echo ""
            echo "  → 이번 실행은 설치 건너뜀. 영구 거부를 원하면 다음 실행 시 'n' 입력."
            echo "     (명시적 opt-out: touch $OPTOUT_MARKER)"
            echo ""
            # 명시적 n 이면 opt-out 마커 생성
            if [ -n "$answer" ] && { [ "$answer" = "n" ] || [ "$answer" = "N" ] || [ "$answer" = "no" ] || [ "$answer" = "NO" ]; }; then
                mkdir -p "$MARKER_DIR"
                touch "$OPTOUT_MARKER"
                echo "  → 명시적 거부 감지 — 다시 묻지 않습니다. 재활성화: rm $OPTOUT_MARKER"
                echo ""
            fi
            exit 0
            ;;
    esac

    echo ""
    echo "  → brew install rtk 실행 중..."
    if ! brew install rtk; then
        echo ""
        echo "  ❌ brew install rtk 실패. RTK 없이 계속 진행합니다."
        echo "     수동 설치 후 재시도: bash $0"
        exit 0
    fi
    echo "  ✅ RTK 바이너리 설치 완료"
fi

# ─── 4. init-done 마커 + hook 이중 확인 ───
# 마커만 있고 hook이 사라진 경우(사용자가 settings.json 리셋) 재등록한다.
if [ -f "$INIT_DONE_MARKER" ]; then
    if [ ! -f "$SETTINGS" ]; then
        # settings.json 부재 = hook 확정 부재 → 마커 신뢰 불가, 재등록 경로로 폴백
        msg "ℹ️  init 마커는 있지만 $SETTINGS 부재 — hook 재등록 시도"
        rm -f "$INIT_DONE_MARKER"
        # 아래 rtk init 경로로 진행
    elif command -v jq >/dev/null 2>&1; then
        HAS_RTK_HOOK=$(jq '
            [.hooks.PreToolUse[]?.hooks[]? | select((.command // "") | tostring | contains("rtk"))]
            | length > 0
        ' "$SETTINGS" 2>/dev/null)
        if [ "$HAS_RTK_HOOK" = "true" ]; then
            msg "✅ RTK hook 등록됨 (마커 + hook 검증 완료)"
            exit 0
        fi
        msg "ℹ️  init 마커는 있지만 hook이 사라짐 — 재등록 시도"
        rm -f "$INIT_DONE_MARKER"
        # 아래 rtk init 재실행 경로로 폴백
    else
        # settings.json은 있으나 jq 없어 검증 불가 — 마커를 신뢰하고 skip
        # (rtk init을 매 세션 무조건 실행하면 멱등이 깨질 수 있어 방어적으로 skip)
        msg "✅ RTK init 마커 확인 (jq 없어 hook 검증 생략)"
        exit 0
    fi
fi

# ─── 5. hook 이미 등록된 경우 감지 (마커 없는 상태에서) ───
if command -v jq >/dev/null 2>&1 && [ -f "$SETTINGS" ]; then
    HAS_RTK_HOOK=$(jq '
        [.hooks.PreToolUse[]?.hooks[]? | select((.command // "") | tostring | contains("rtk"))]
        | length > 0
    ' "$SETTINGS" 2>/dev/null)

    if [ "$HAS_RTK_HOOK" = "true" ]; then
        mkdir -p "$MARKER_DIR"
        touch "$INIT_DONE_MARKER"
        msg "✅ RTK hook 이미 등록됨 — init-done 마커 생성"
        exit 0
    fi
fi

# ─── 6. rtk init 실행 ───
# jq 부재 + 마커 부재인 경우 여기 도달. 미설치는 이미 3에서 걸렀으므로 rtk는 있다.
msg "🔧 rtk init --auto-patch --global 실행 중..."
if rtk init --auto-patch --global >/dev/null 2>&1; then
    mkdir -p "$MARKER_DIR"
    touch "$INIT_DONE_MARKER"
    msg "✅ RTK Claude Code hook 등록 완료"
    msg "   새 Claude Code 세션부터 토큰 절감이 자동 적용됩니다."
else
    msg "⚠️  rtk init 실패 — 수동 실행 필요: rtk init --auto-patch --global"
fi

exit 0
