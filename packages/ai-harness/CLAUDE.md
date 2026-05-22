# ai-harness 패키지 가이드

이 문서는 ai-harness 패키지에서 작업하는 에이전트(또는 인간)를 위한 **완전한 작업 지침서**다.
아키텍처 이해, 새 도구 추가, 스킬/커맨드/에이전트 추가, 테스트, 배포까지 모든 과정을 다룬다.

---

## 1. 아키텍처 개요

### 설계 철학

과거 모놀리식(전체 설치) 방식은 채택률이 낮아 실패했다. 현재는 **모듈형 인스톨러** 방식:
- 각 도구는 `tools/<name>/` 아래 자기완결형 패키지
- 루트 인스톨러는 메뉴 방식으로 원하는 도구만 선택 설치
- 각 도구 인스톨러는 `curl | bash`로 독립 실행 가능
- 컨벤션 기반 발견: `tools/*/tool.sh`가 있으면 설치 가능한 도구로 인식

### 디렉토리 구조

```
packages/ai-harness/
├── install.sh              # 루트 인스톨러 (인터랙티브 메뉴 + --tools/--yes)
├── uninstall.sh            # 루트 제거기 (--tool <name> / --all)
├── lib/
│   └── installer-common.sh # 공유 라이브러리 (16 함수, 영수증 시스템)
├── tools/
│   └── awake/              # 첫 번째 도구 (템플릿 역할)
│       ├── tool.sh          # 매니페스트 (필수)
│       ├── install.sh       # 개별 인스톨러 (필수)
│       ├── uninstall.sh     # 개별 제거기 (필수)
│       ├── scripts/         # 도구 런타임 스크립트
│       │   ├── awake.sh
│       │   └── awake-helper.sh
│       ├── commands/        # Claude/OpenCode 커맨드 정의
│       │   └── awake.md
│       └── tests/           # 스모크 테스트
│           ├── awake.smoke.sh
│           └── awake-helper.smoke.sh
├── skills/                 # 스킬 (install.sh가 심볼릭 링크로 연결)
├── commands/               # 커맨드
│   └── weekly-report.md
├── agents/                 # 에이전트 정의
└── tests/
    └── installer.smoke.sh  # 인스톨러 시스템 통합 테스트 (12개)
```

### 설치 흐름

```
사용자: curl ... | bash (또는 bash install.sh --tools awake)
  │
  ├─ git sparse clone → ~/.config/sazo-ai-harness/
  ├─ source lib/installer-common.sh
  ├─ discover_tools() → tools/*/tool.sh 스캔
  ├─ 인터랙티브 메뉴 또는 --tools 인자로 도구 선택
  ├─ commands/skills/agents → ~/.claude/ 심볼릭 링크
  ├─ tools/<name>/install.sh 실행 (SAZO_ROOT_INSTALL=1 환경변수 전달)
  │    ├─ source lib/installer-common.sh (again, safe)
  │    ├─ check_platform() → 플랫폼 검증
  │    ├─ acquire_lock() → mkdir 기반 락
  │    ├─ 아티팩트 설치 + write_receipt() → 영수증 기록
  │    └─ release_lock()
  └─ 요약 출력
```

### 제거 흐름

```
사용자: bash uninstall.sh --tool awake
  │
  ├─ tools/awake/uninstall.sh 실행
  │    ├─ awake off/reset → 시스템 상태 복원
  │    ├─ remove_receipt_entries() → 영수증 기반 아티팩트 제거
  │    └─ clear_receipt() → 영수증 파일 삭제
  │
  또는: bash uninstall.sh --all
  │
  ├─ [1/8] 각 도구별 uninstall.sh 실행
  ├─ [2/8] awake 레거시 프로세스 정리
  ├─ [3/8] LaunchAgent 정리
  ├─ [4/8] 심볼릭 링크 제거
  ├─ [5/8] settings.json 훅 정리
  ├─ [6/8] CLAUDE.md 관리 블록 제거
  ├─ [7/8] OpenCode 설정 정리
  └─ [8/8] 설치 디렉토리 제거
```

### 환경변수 계약

| 변수 | 용도 | 설정 주체 |
|---|---|---|
| `SAZO_ROOT_INSTALL=1` | 루트 인스톨러가 하위 인스톨러에 전달. set되면 도구 인스톨러가 sparse clone 생략 | 루트 install.sh |
| `SAZO_NON_INTERACTIVE=1` | 모든 대화형 프롬프트 자동 수락. `--tools` 또는 `--yes` 플래그로 설정 | install.sh |
| `SAZO_UNAME` | `uname -s` 오버라이드. 테스트용 | 테스트 스크립트 |
| `SAZO_BASE_DIR` | 기본 설치 디렉토리 오버라이드. 기본값: `~/.config/sazo-ai-harness` | 사용자/테스트 |

### 영수증(Receipt) 시스템

영수증은 설치된 아티팩트를 추적하는 제거의 유일한 진실 공급원이다.

```
형식: ~/.config/sazo-ai-harness/receipts/<tool-name>.receipt
각 줄: <type>:<path>

타입:
  symlink:/Users/hk/.local/bin/awake          → 심볼릭 링크
  file:/usr/local/libexec/foo                  → 일반 파일
  sudo:file:/etc/sudoers.d/sazo-ai-harness-x  → sudo로 설치한 파일
  dir:/Users/hk/.config/sazo-ai-harness        → 디렉토리
  state:/Users/hk/.config/sazo-ai-harness/x.state  → 상태 파일
```

제거 시 `remove_receipt_entries()`는 항목을 역순 처리하여 깊은 경로를 먼저 제거한다.

---

## 2. 새 도구 추가 가이드

### Step-by-Step 절차

새 도구 `mytool`을 추가하려면 다음 디렉토리와 파일을 만든다:

#### Step 1: 도구 디렉토리 생성

```bash
mkdir -p packages/ai-harness/tools/mytool/{scripts,commands,tests}
```

#### Step 2: tool.sh 매니페스트 작성

`packages/ai-harness/tools/mytool/tool.sh`:

```bash
# tool.sh - mytool metadata
# Sourced by the root installer to discover available tools.

TOOL_NAME="mytool"
TOOL_DESC="짧은 설명 (인스톨러 메뉴에 표시됨)"
TOOL_VERSION="1.0.0"
TOOL_PLATFORM="any"           # "any" | "darwin" | "linux"
TOOL_REQUIRES_SUDO="no"       # "yes" | "no" | "optional"
```

**주의**: `tool.sh`는 소스되는 파일이므로 **shebang(`#!/bin/bash`)을 넣지 않는다**.

#### Step 3: install.sh 작성

`packages/ai-harness/tools/mytool/install.sh`:

```bash
#!/bin/bash
#
# mytool — Individual tool installer
# Can be run standalone: curl -fsSL .../tools/mytool/install.sh | bash
# Or invoked by the root installer.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HARNESS_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# --- Source shared library ---
LIB_PATH="$HARNESS_DIR/lib/installer-common.sh"
if [ ! -f "$LIB_PATH" ]; then
    echo "Error: installer-common.sh not found at $LIB_PATH" >&2
    exit 1
fi
source "$LIB_PATH"

source "$SCRIPT_DIR/tool.sh"

# --- Platform check ---
check_platform "$TOOL_PLATFORM" || exit $?

# --- Lock ---
LOCK_DIR="${SAZO_BASE_DIR}.lock.d"
if ! acquire_lock "$LOCK_DIR"; then
    log_error "Another installation is in progress"
    exit 1
fi

INSTALL_FAILED=0

cleanup() {
    if [ "$INSTALL_FAILED" = "1" ]; then
        release_lock 2>/dev/null || true
        clear_receipt "$TOOL_NAME" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# --- Clone (standalone mode only) ---
if [ "${SAZO_ROOT_INSTALL:-0}" != "1" ]; then
    sparse_clone_tool "$SAZO_BASE_DIR" "$SAZO_REPO_URL" "packages/ai-harness"
fi

HARNESS_DIR="${SAZO_BASE_DIR}/packages/ai-harness"

# --- Install artifacts ---
RECEIPT_ENTRIES=()

# 예: 심볼릭 링크 설치
mkdir -p "$HOME/.local/bin"
safe_symlink "$HARNESS_DIR/tools/mytool/scripts/mytool.sh" "$HOME/.local/bin/mytool"
RECEIPT_ENTRIES+=("symlink:$HOME/.local/bin/mytool")

# 예: 설정 디렉토리
ensure_dir "$SAZO_BASE_DIR"
RECEIPT_ENTRIES+=("dir:$SAZO_BASE_DIR")
RECEIPT_ENTRIES+=("state:$SAZO_BASE_DIR/mytool.state")

# --- Write receipt ---
if [ ${#RECEIPT_ENTRIES[@]} -gt 0 ]; then
    write_receipt "$TOOL_NAME" "${RECEIPT_ENTRIES[@]}"
fi

# --- Done ---
release_lock
trap - EXIT

log_info "mytool installed successfully!"
exit 0
```

#### Step 4: uninstall.sh 작성

`packages/ai-harness/tools/mytool/uninstall.sh`:

```bash
#!/bin/bash
#
# mytool — Individual tool uninstaller
# Removes all mytool artifacts using receipt-based tracking.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HARNESS_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# --- Source shared library (with fallback) ---
LIB_PATH="$HARNESS_DIR/lib/installer-common.sh"
if [ ! -f "$LIB_PATH" ]; then
    echo "Error: installer-common.sh not found at $LIB_PATH" >&2
    exit 1
fi
source "$LIB_PATH"

source "$SCRIPT_DIR/tool.sh"

removed=0
skipped=0

echo "Uninstalling mytool..."

# --- Receipt-based cleanup ---
if is_tool_installed "$TOOL_NAME"; then
    remove_receipt_entries "$TOOL_NAME"
    removed=$((removed + 1))
    clear_receipt "$TOOL_NAME"
else
    log_warn "No receipt found for $TOOL_NAME"
fi

# --- Any manual cleanup not covered by receipts ---

echo ""
echo "mytool uninstall complete"
echo "  Removed: ${removed} items"
echo "  Skipped: ${skipped} items (already absent)"
```

#### Step 5: 스모크 테스트 작성

`packages/ai-harness/tools/mytool/tests/mytool.smoke.sh`:

```bash
#!/bin/bash
# Smoke tests for mytool installer/uninstaller
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT_DIR/lib/installer-common.sh"
source "$ROOT_DIR/tools/mytool/tool.sh"

PASS=0 FAIL=0

ok() { PASS=$((PASS + 1)); printf "\033[32mok\033[0m - %s\n" "$1"; }
fail() { FAIL=$((FAIL + 1)); printf "\033[31m✗\033[0m %s\n" "$1"; }

# Test: tool.sh manifest is valid
[ -n "$TOOL_NAME" ] && ok "TOOL_NAME is set" || fail "TOOL_NAME missing"

# Test: installer exists and is valid bash
bash -n "$ROOT_DIR/tools/mytool/install.sh" && ok "installer syntax valid" || fail "installer syntax error"

# Test: uninstaller exists and is valid bash
bash -n "$ROOT_DIR/tools/mytool/uninstall.sh" && ok "uninstaller syntax valid" || fail "uninstaller syntax error"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
```

#### Step 6: 인스톨러 통합 테스트에 도구 발견 테스트 추가

`packages/ai-harness/tests/installer.smoke.sh`에 추가:

```bash
# Test: discover_tools finds mytool
result="$(discover_tools)"  # discover_tools는 HARNESS_DIR을 필요로 함
echo "$result" | grep -q "mytool" && ok "discover_tools finds mytool" || fail "discover_tools cannot find mytool"
```

#### 체크리스트

- [ ] `tools/mytool/tool.sh` — 매니페스트 (sheban 금지)
- [ ] `tools/mytool/install.sh` — 인스톨러 (shebang 필수, `set -euo pipefail`)
- [ ] `tools/mytool/uninstall.sh` — 제거기 (shebang 필수, `set -uo pipefail`)
- [ ] `tools/mytool/scripts/` — 런타임 스크립트
- [ ] `tools/mytool/commands/` — Claude/OpenCode 커맨드 (선택)
- [ ] `tools/mytool/tests/mytool.smoke.sh` — 스모크 테스트
- [ ] `lib/installer-common.sh`의 함수만 사용 (새 외부 의존성 금지)
- [ ] 영수증 기반 제거: 모든 설치 아티팩트를 `write_receipt()`으로 기록
- [ ] `bash -n` 구문 검증 통과
- [ ] `bash tests/installer.smoke.sh` 통과

### 필수 규칙

1. **`lib/installer-common.sh` 외부 의존성 금지** — jq, python 등 순수 bash + coreutils만 사용
2. **`tool.sh`에 sheban 금지** — 소스되는 파일이므로 `#!/bin/bash` 없음
3. **영수증은 제거의 유일한 진실 공급원** — 제거기는 영수증을 읽어서 제거한다
4. **각 인스톨러는 독립 실행 가능** — `curl | bash`로 단독 실행 시 `sparse_clone_tool()`로 레포를 클론한다
5. **`SAZO_ROOT_INSTALL=1` 확인** — 루트 인스톨러에서 호출 시 클론을 건너뛴다
6. **cleanup trap** — 실패 시 락 해제 + 영수증 삭제
7. **`set -euo pipefail`** — 인스톨러, `set -uo pipefail`** — 제거기 (부분 제거 허용)
8. **`safe_symlink()`** 사용 — 기존 파일 덮어쓰지 않음
9. **`check_platform()`** 호출 — `TOOL_PLATFORM`이 `any`가 아니면 반드시 검증
10. **sudo 아티팩트는 `sudo:file:` 영수증 타입** 으로 기록

---

## 3. 스킬/커맨드/에이전트 추가 가이드

스킬, 커맨드, 에이전트는 도구 인스톨러와 무관하게 **루트 인스톨러가 심볼릭 링크로 연결**한다.

### 스킬 추가

```
packages/ai-harness/skills/
└── my-skill/
    └── SKILL.md          # 스킬 정의 파일 (필수)
```

**규칙**:
- 디렉토리 이름 = 스킬 이름
- `SKILL.md` 파일이 반드시 있어야 함 (루트 인스톨러가 이를 기준으로 링크)
- 스킬 디렉토리 아래에 `scripts/` 등을 둘 수 있음
- `install.sh`의 `link_files()`가 `skills/` 하위 디렉토리를 `~/.claude/skills/`에 자동 연결
- `_` 또는 `.` 으로 시작하는 파일/디렉토리는 링크에서 제외

### 커맨드 추가

```
packages/ai-harness/commands/
└── my-command.md         # 커맨드 정의 파일
```

**규칙**:
- 파일 이름 = 커맨드 이름 (`/my-command`으로 호출)
- `install.sh`의 `link_files()`가 `commands/` 하위 파일을 `~/.claude/commands/`에 자동 연결
- OpenCode가 설치된 경우 `~/.config/opencode/commands/`에도 연결

### 에이전트 추가

```
packages/ai-harness/agents/
└── my-agent.md           # 에이전트 정의 파일
```

**규칙**:
- 파일 이름 = 에이전트 이름
- `install.sh`의 `link_files()`가 `agents/` 하위 파일을 `~/.claude/agents/`에 자동 연결

### 추가 후 확인

스킬/커맨드/에이전트를 추가한 후:

1. **`bash -n packages/ai-harness/install.sh`** — 구문 검증 (install.sh가 심볼릭 링크 로직을 포함하므로)
2. **루트 인스톨러 재실행** — `link_files()`가 새 항목을 자동 발견하는지 확인
3. **기존 심볼릭 링크 충돌** — `safe_symlink()`가 기존 로컬 파일을 덮어쓰지 않는지 확인

---

## 4. 공유 라이브러리 (`lib/installer-common.sh`) API

### 변수

| 변수 | 기본값 | 설명 |
|---|---|---|
| `EXIT_OK` | 0 | 성공 |
| `EXIT_ALREADY_INSTALLED` | 0 | 이미 설치됨 (성공과 동일) |
| `EXIT_FAIL` | 1 | 일반 오류 |
| `EXIT_SUDO_DENIED` | 2 | sudo 거부 |
| `EXIT_PLATFORM_UNSUPPORTED` | 3 | 지원하지 않는 플랫폼 |
| `SAZO_BASE_DIR` | `~/.config/sazo-ai-harness` | 설치 기본 디렉토리 |
| `SAZO_RECEIPT_DIR` | `$SAZO_BASE_DIR/receipts` | 영수증 디렉토리 |
| `SAZO_REPO_URL` | GitHub 레포 URL | sparse clone용 |

### 함수

| 함수 | 시그니처 | 설명 |
|---|---|---|
| `log_info` | `log_info "msg"` | 녹색 ✓ 접두사 로깅 |
| `log_warn` | `log_warn "msg"` | 노란색 ⚠ 접두사 로깅 (stderr) |
| `log_error` | `log_error "msg"` | 빨간색 ✗ 접두사 로깅 (stderr) |
| `ask_yes_no` | `ask_yes_no "prompt" [y\|n]` | 대화형 y/n 프롬프트. `SAZO_NON_INTERACTIVE=1`이면 자동 수락 |
| `ensure_dir` | `ensure_dir "path"` | `mkdir -p` + 실패 시 에러 |
| `safe_symlink` | `safe_symlink "src" "dst"` | 기존 파일 덮어쓰지 않는 심볼릭 링크 |
| `remove_harness_symlinks` | `remove_harness_symlinks "dir" "label"` | sazo-ai-harness/sazo-ai-prompts 타겟 심볼릭만 제거 |
| `check_platform` | `check_platform "darwin"` | 플랫폼 검증. `any`/`darwin`/`linux` |
| `acquire_lock` | `acquire_lock "lock_dir"` | mkdir 기반 원자적 락. 최대 50회 재시도 |
| `release_lock` | `release_lock` | 락 해제 |
| `sparse_clone_tool` | `sparse_clone_tool "dir" "url" "path"` | shallow sparse git clone |
| `write_receipt` | `write_receipt "tool" "entries..."` | 영수증에 항목 추가 |
| `read_receipt` | `read_receipt "tool"` | 영수증 내용 출력 |
| `clear_receipt` | `clear_receipt "tool"` | 영수증 파일 삭제 |
| `is_tool_installed` | `is_tool_installed "tool"` | 영수증 존재 여부 확인 (0=설치됨) |
| `remove_receipt_entries` | `remove_receipt_entries "tool"` | 영수증 기반 아티팽트 제거 (역순) |

### 사용 규칙

- **이 파일은 소스(`source`)로만 사용** — 직접 실행하지 않음
- **`set -uo pipefail`** (not `-e`) — 소스되는 스크립트가 `set -e`를 제어
- **새 함수 추가 시** `tests/installer.smoke.sh`에 테스트 추가 필수

---

## 5. 테스트

### 실행 방법

```bash
# 인스톨러 시스템 통합 테스트 (12개)
bash packages/ai-harness/tests/installer.smoke.sh

# awake 도구 스모크 테스트
bash packages/ai-harness/tools/awake/tests/awake.smoke.sh
bash packages/ai-harness/tools/awake/tests/awake-helper.smoke.sh

# 루트 인스톨러 구문 검증
bash -n packages/ai-harness/install.sh
bash -n packages/ai-harness/uninstall.sh

# 전체 CI 검증 (CLAUDE.md에 정의됨)
bash -n packages/ai-harness/install.sh && \
bash -n packages/ai-harness/uninstall.sh && \
bash packages/ai-harness/tests/installer.smoke.sh
```

### 테스트 작성 규칙

1. **`bash`만 사용** — shfmt, bats 등 외부 테스트 프레임워크 없음
2. **`SAZO_UNAME` 환경변수** — 플랫폼 검증을 오버라이드하려면 사용
3. **실제 설치/제거는 하지 않음** — 스모크 테스트는 구문 검증과 단위 테스트만 수행
4. **`ROOT_DIR`** — 테스트 파일 위치에서 상대 경로로 패키지 루트를 찾음:
   - `tests/installer.smoke.sh` → `ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"`
   - `tools/<name>/tests/*.smoke.sh` → `ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"`

---

## 6. 커밋 & PR 규칙

### 커밋 메시지 형식

```
feat(ai-harness): 새로운 도구/기능 추가
fix(ai-harness): 버그 수정
docs(ai-harness): 문서만 수정
refactor(ai-harness): 리팩토링 (기능 변경 없음)
test(ai-harness): 테스트 추가/수정
chore(ai-harness): 빌드/설정 변경
```

### PR 체크리스트

- [ ] `bash -n` 모든 셸 스크립트 통과
- [ ] `bash packages/ai-harness/tests/installer.smoke.sh` 통과
- [ ] 새 도구 추가 시 `discover_tools()`가 자동으로 인식하는지 확인
- [ ] 영수증 기반 제거가 정상 작동하는지 확인
- [ ] `lib/installer-common.sh`에 새 의존성(jq, python 등)을 추가하지 않았는지 확인
- [ ] `tool.sh`에 sheban이 없는지 확인

---

## 7. 빠른 참조

### 새 도구 추가 (최소 요구사항)

```
tools/<name>/
├── tool.sh          # 매니페스트 (TOOL_NAME, TOOL_DESC, TOOL_VERSION, TOOL_PLATFORM, TOOL_REQUIRES_SUDO)
├── install.sh       # 인스톨러 (shebang + set -euo pipefail)
└── uninstall.sh      # 제거기 (shebang + set -uo pipefail)
```

### 새 스킬 추가

```
skills/<name>/
└── SKILL.md          # 스킬 정의 (자동으로 ~/.claude/skills/에 링크)
```

### 새 커맨드 추가

```
commands/<name>.md    # 커맨드 정의 (자동으로 ~/.claude/commands/에 링크)
```

### 영수증 타입

| 타입 | 설명 | 제거 방식 |
|---|---|---|
| `symlink:` | 심볼릭 링크 | `rm -f` (대상이 심볼릭인 경우만) |
| `file:` | 일반 파일 | `rm -f` |
| `sudo:file:` | sudo로 설치한 파일 | `sudo rm -f` |
| `dir:` | 디렉토리 | `rmdir` (빈 경우만) |
| `state:` | 상태 파일 | `rm -f` |