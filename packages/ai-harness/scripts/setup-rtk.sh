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
#   rm ~/.config/sazo-ai-harness/.rtk-optout           # 다시 설치 안내를 받고 싶을 때
#   rm ~/.config/sazo-ai-harness/.rtk-init-done        # hook 재등록을 강제하고 싶을 때
#   rm ~/.config/sazo-ai-harness/.rtk-allowlist-done   # allowlist 재주입을 강제하고 싶을 때

set -u

QUIET=0
[ "${1:-}" = "--quiet" ] && QUIET=1

MARKER_DIR="$HOME/.config/sazo-ai-harness"
OPTOUT_MARKER="$MARKER_DIR/.rtk-optout"
INIT_DONE_MARKER="$MARKER_DIR/.rtk-init-done"
ALLOWLIST_MARKER="$MARKER_DIR/.rtk-allowlist-done"
UPGRADE_MARKER="$MARKER_DIR/.rtk-last-upgrade"
SETTINGS="$HOME/.claude/settings.json"

# BG 업그레이드 throttle: 24h. 너무 자주 brew update 돌리면 tap metadata 받느라 네트워크
# I/O 오버헤드 + rate limit 리스크. 주 1회는 너무 긴 주기라 hotfix 지연 우려.
UPGRADE_THROTTLE_SECS=86400

msg() { [ "$QUIET" -eq 0 ] && echo "$@"; }

# ─── BG brew upgrade (quiet 모드 전용, 24h throttle) ───
# auto-update.sh가 세션 시작 시 호출하는 quiet 경로에서만 동작. rtk와 brew가 모두 있고
# 마지막 시도로부터 24시간 경과했을 때, brew update + brew upgrade rtk를 백그라운드로
# detach하여 실행. 새 버전은 **다음 세션**부터 반영 (현 세션 진입을 블로킹하지 않음).
#
# 마커는 BG 실행 **전에** 즉시 갱신 — 동시에 시작된 여러 세션이 중복 brew를 돌리지
# 않도록. brew 실패(네트워크/lock)는 조용히 무시, 다음 24h 사이클에 재시도.
#
# 알려진 잔여 race (비블로킹): 두 세션이 정확히 같은 초(date +%s)에 진입하고 모두
# 마커 존재 여부 체크를 통과한 뒤 동시 마커 갱신 + 동시 BG brew fork가 가능. 이 창은
# 약 1초이며 24h에 한 번만 발생. worst case는 중복 brew upgrade 호출인데 brew 자체
# 파일 락(locks/)이 serialize하므로 데이터 손상 없음. bash로 완전 atomic CAS를
# 구현하는 복잡도 대비 이득이 없어 의도적으로 수용.
rtk_bg_upgrade() {
    [ "$QUIET" -eq 1 ] || return 0
    [ -f "$OPTOUT_MARKER" ] && return 0
    command -v rtk >/dev/null 2>&1 || return 0
    command -v brew >/dev/null 2>&1 || return 0

    local now last=0
    now=$(date +%s)
    if [ -f "$UPGRADE_MARKER" ]; then
        last=$(cat "$UPGRADE_MARKER" 2>/dev/null || echo 0)
        case "$last" in *[!0-9]*|'') last=0 ;; esac
    fi
    [ $((now - last)) -lt "$UPGRADE_THROTTLE_SECS" ] && return 0

    mkdir -p "$MARKER_DIR"
    echo "$now" > "$UPGRADE_MARKER"

    (
        brew update >/dev/null 2>&1 || true
        brew upgrade rtk >/dev/null 2>&1 || true
    ) </dev/null >/dev/null 2>&1 &
    disown 2>/dev/null || true
}

# RTK 재작성 hook이 깔린 뒤 Claude Code의 permission allow 리스트에 read-only RTK
# 호출 패턴을 union-merge 한다. 목적은 `rtk rewrite`가 exit 3(ask)으로 돌려보내는
# 명령 중 **명백히 read-only인 접두사**만 프롬프트 없이 통과시키는 것.
#
# - aws, kubectl은 registry가 subcommand 단위 read/write 구분 없이 전체 ask 판정.
#   우리가 read-only 접두사만 allow로 뚫어 UX 고통을 낮추되, mutation(`aws s3 rm`,
#   `kubectl delete` 등)은 여전히 rtk의 ask 게이트에 걸린다.
# - Claude Code는 Bash(...) 패턴의 모든 위치에서 * glob 지원. 중간 `*`는 서비스명
#   같은 임의 토큰, 접미 `:*`는 임의 인자 꼬리를 의미.
#   (cf. docs.code.claude.com/docs/en/permissions)
# - exit-0(auto-allow) rewrite는 hook 자체가 permissionDecision=allow를 주므로
#   allowlist에 넣어도 중복일 뿐. 여기서는 ask 경로만 다룬다.
inject_rtk_allowlist() {
    command -v jq >/dev/null 2>&1 || return 0
    [ -f "$SETTINGS" ] || return 0
    jq empty "$SETTINGS" >/dev/null 2>&1 || return 0
    # 마커를 "관찰용"으로만 사용한다 (gate 아님). 매 호출마다 union-merge를
    # 계산하되, jq 결과가 원본과 동일하면 mv 없이 skip → idempotent + 저비용.
    # 이전 설계(마커로 early return + canonical 1개만 검증)는 사용자가 일부
    # RTK 항목만 드롭했을 때 재주입이 발동하지 않는 edge case가 있었다.
    # 항상 union-merge하면 10개 엔트리 중 하나라도 빠졌을 때 자동 회복.

    # 의도적으로 `aws * get-*`는 **제외**한다:
    #   - `aws sts get-session-token`, `aws iam get-session-token` → 임시 자격증명 발급
    #   - `aws secretsmanager get-secret-value`, `aws ssm get-parameter` → 비밀 조회
    #   - `aws ecr get-login-password` → 레지스트리 자격증명
    # 접두사만으로는 mutation/민감성 분리가 불가능하므로 보수적으로 `describe-*`,
    # `list-*`에 한정. 개별 `get-*`는 필요 시 사용자가 세션 내 승인.
    # 마찬가지로 `kubectl config view`는 현재 context의 token/client-cert를 노출할 수
    # 있으므로 allowlist에서 제외.
    # `aws s3 ls`도 read-only지만 `aws * ls:*` 패턴의 중간 `*` 매칭 범위가
    # Claude Code 런타임 기준으로 단일 토큰 보장되지 않아 `describe-*`/`list-*`
    # 접두사만 유지. `aws s3 ls`는 세션 내 1회 승인으로 충분.
    local entries
    entries='[
      "Bash(rtk aws * describe-*:*)",
      "Bash(rtk aws * list-*:*)",
      "Bash(rtk kubectl get:*)",
      "Bash(rtk kubectl describe:*)",
      "Bash(rtk kubectl logs:*)",
      "Bash(rtk kubectl top:*)",
      "Bash(rtk kubectl explain:*)",
      "Bash(rtk kubectl version:*)",
      "Bash(rtk kubectl cluster-info:*)",
      "Bash(rtk kubectl api-resources:*)"
    ]'

    # mktemp는 **대상과 같은 디렉토리**에 — cross-device mv는 copy+unlink로 퇴화해
    # atomic 하지 않다 (부분 기록 위험). 대상 디렉토리 부재 시 굳이 만들지 않고 skip
    # (상위 로직이 $SETTINGS 존재를 이미 보장).
    # `.permissions`가 object가 아닌 비표준 값(예: 문자열)이면 우리가 덮어쓰면
    # 사용자 의도를 잃는다. object/null일 때만 union-merge 수행.
    local perms_type
    perms_type=$(jq -r '.permissions | type' "$SETTINGS" 2>/dev/null)
    case "$perms_type" in
        object|null) ;;
        *)
            msg "ℹ️  .permissions 타입이 object가 아님 ($perms_type) — allowlist 주입 건너뜀"
            return 0
            ;;
    esac

    # `.permissions.allow`도 array/null만 허용. 아래 jq의 `+ $adds`는 array
    # concat이라 scalar/object와 만나면 `<type> and array cannot be added`로
    # 실패하고, 현재 stderr 억제 때문에 no-op silent가 된다 →  주입 실패가
    # 사용자에게 보이지 않아 "프롬프트 재발" 증상으로만 드러나게 된다.
    # merge-permissions.sh의 가드와 동일 패턴으로 타입을 사전 점검한다.
    local allow_type
    allow_type=$(jq -r '.permissions.allow | type' "$SETTINGS" 2>/dev/null)
    case "$allow_type" in
        array|null) ;;
        *)
            msg "⚠️  .permissions.allow 타입이 array가 아님 ($allow_type) — allowlist 주입 건너뜀. 수동 확인 필요."
            return 0
            ;;
    esac

    local settings_dir
    settings_dir=$(dirname "$SETTINGS")
    local tmp
    tmp=$(mktemp "$settings_dir/.rtk-allowlist.XXXXXX") || return 0
    if jq --argjson adds "$entries" '
        .permissions = (.permissions // {})
        | .permissions.allow = (((.permissions.allow // []) + $adds) | unique)
    ' "$SETTINGS" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
        # 결과가 원본과 동일하면 설정 파일에 변화 없음 — mv 생략, 마커만 갱신.
        # (사용자의 다른 편집 시각 메타데이터가 불필요하게 바뀌지 않도록.)
        if cmp -s "$tmp" "$SETTINGS"; then
            rm -f "$tmp"
            mkdir -p "$MARKER_DIR"
            [ -f "$ALLOWLIST_MARKER" ] || touch "$ALLOWLIST_MARKER"
        elif mv "$tmp" "$SETTINGS"; then
            mkdir -p "$MARKER_DIR"
            touch "$ALLOWLIST_MARKER"
            msg "✅ RTK read-only allowlist 주입/보강 완료 (aws/kubectl read ops)"
        else
            rm -f "$tmp"
            msg "⚠️  allowlist 주입 실패: settings.json 교체(mv) 오류 — 원본 보존"
        fi
    else
        rm -f "$tmp"
    fi
}

# ─── 1. opt-out ───
if [ -f "$OPTOUT_MARKER" ]; then
    msg "⏭️  RTK 셋업 opt-out (마커: $OPTOUT_MARKER)"
    exit 0
fi

# ─── 1b. quiet 모드에서 BG brew upgrade 시도 (24h throttle) ───
# opt-out이 아닌 경우에만 진입. 이미 설치된 rtk를 배경에서 최신화. 설치 자체는 유도하지
# 않음 (해당 책임은 대화형 경로).
rtk_bg_upgrade

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
            # 명시적 n / no 이면 opt-out 마커 생성 (대소문자 변형 모두 수용: n/N/no/No/nO/NO)
            if [[ "$answer" =~ ^[nN][oO]?$ ]]; then
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
        # settings.json 부재 = hook 확정 부재 → 마커 신뢰 불가, 재등록 경로로 폴백.
        # allowlist 마커도 함께 제거 — settings 재생성 후 inject_rtk_allowlist가
        # 실행되지 않으면 프롬프트가 다시 튀어나와 이 스크립트의 목적 자체가 무효화됨.
        msg "ℹ️  init 마커는 있지만 $SETTINGS 부재 — hook 재등록 시도"
        rm -f "$INIT_DONE_MARKER" "$ALLOWLIST_MARKER"
        # 아래 rtk init 경로로 진행
    elif command -v jq >/dev/null 2>&1; then
        HAS_RTK_HOOK=$(jq '
            [.hooks.PreToolUse[]?.hooks[]? | select((.command // "") | tostring | contains("rtk"))]
            | length > 0
        ' "$SETTINGS" 2>/dev/null)
        if [ "$HAS_RTK_HOOK" = "true" ]; then
            msg "✅ RTK hook 등록됨 (마커 + hook 검증 완료)"
            inject_rtk_allowlist
            exit 0
        fi
        msg "ℹ️  init 마커는 있지만 hook이 사라짐 — 재등록 시도"
        # hook 소실은 settings.json 리셋을 시사 → allowlist 항목도 지워졌을 가능성.
        # 마커를 함께 제거해 재주입 경로를 연다 (jq union-merge는 idempotent).
        rm -f "$INIT_DONE_MARKER" "$ALLOWLIST_MARKER"
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
        inject_rtk_allowlist
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
    inject_rtk_allowlist
else
    msg "⚠️  rtk init 실패 — 수동 실행 필요: rtk init --auto-patch --global"
fi

exit 0
