# 모듈형 인스톨러 시스템: awake로 구조 추상화

## TL;DR

> **Quick Summary**: ai-harness의 모놀리식 인스톨러를 개별 도구 단위 인스톨러 + 루트 인스톨러(인터랙티브 메뉴) 구조로 전환. `awake`를 첫 번째 도구로 패키지화하여 아키텍처를 검증.
> 
> **Deliverables**:
> - `tools/awake/` 자기완결형 도구 패키지 (스크립트 + 커맨드 + 테스트)
> - `tools/awake/install.sh` 독립 실행 가능한 개별 인스톨러
> - `tools/awake/uninstall.sh` 수령증 기반 개별 제거기
> - `lib/installer-common.sh` 공통 인스톨러 유틸리티
> - `install.sh` 루트 인스톨러 (인터랙티브 메뉴)
> - `uninstall.sh` 루트 제거기
> - 기존 smoke test 이전 + 인스톨러 테스트 추가
> 
> **Estimated Effort**: Medium
> **Parallel Execution**: YES - 4 waves
> **Critical Path**: Task 1 → Task 2 → Task 4 → Task 7 → Task 9 → F1-F4

---

## Context

### Original Request
ai-harness를 하나로 통합해서 전체 팀에게 제공하는 접근이 실패했다. 이제 개별 도구별 인스톨러 + 선택적 루트 인스톨러 구조로 전환한다. awake를 첫 대상으로 구조를 추상화한다.

### Interview Summary
**Key Discussions**:
- 도구의 범위: 스크립트 + 관련 커맨드/스킬을 하나의 패키지로 묶음
- 디렉토리: `packages/ai-harness/tools/` 하위에 도구별 디렉토리
- 독립 인스톨러: 각 도구는 `curl | bash`로 단독 설치 가능
- 루트 인스톨러: 인터랙티브 메뉴로 도구 목록 제시
- 네이밍: `sazo-ai-harness` 유지 (경로 마이그레이션 불필요)
- 스코프: awake만 패키지화 + 기존 install.sh를 루트 인스톨러로 전환

**Research Findings**:
- 현재 awake: CLI 450줄 + root helper 346줄, smoke test 28개
- 현재 install.sh: 278줄, sparse git clone, 심링크, 대화형 sudo 프롬프트
- 현재 uninstall.sh: 345줄, 전체 아티팩트 정리
- install.smoke.sh 이미 존재 (기존 인스톨러 테스트)

### Oracle Review
**Identified Gaps (addressed in plan)**:
- 인스톨러 계약 정의 필요 (멱등성, exit code, 비대화형 모드)
- 트랜잭션 설치 패턴 (스테이징 → 검증 → 원자적 커밋)
- 프로세스 잠금 (동시 설치 방지)
- 권한 단계 분리 (user-space / sudo 분리)
- 수령증(receipt) 기반 제거 (설치된 파일 목록 기록)
- 실패 모드 테스트 (sudo 거부, 중단, 재설치)

---

## Work Objectives

### Core Objective
awake를 자기완결형 도구 패키지로 재구성하고, 개별/루트 인스톨러 프레임워크를 만들어 향후 다른 도구 추가 시 패턴을 따르기만 하면 되는 구조를 확립한다.

### Concrete Deliverables
- `packages/ai-harness/tools/awake/` - 완전한 도구 패키지
- `packages/ai-harness/lib/installer-common.sh` - 공통 라이브러리
- `packages/ai-harness/install.sh` - 루트 인스톨러 (기존 것 대체)
- `packages/ai-harness/uninstall.sh` - 루트 제거기 (기존 것 대체)
- 인스톨러 smoke test

### Definition of Done
- [ ] `curl -fsSL .../tools/awake/install.sh | bash`로 awake만 단독 설치 가능
- [ ] `curl -fsSL .../install.sh | bash`로 인터랙티브 메뉴에서 awake 선택 설치 가능
- [ ] 설치 후 `awake status` 정상 동작
- [ ] 개별 uninstall 후 awake 관련 아티팩트 전부 제거 확인
- [ ] 기존 28개 smoke test 전부 통과
- [ ] 인스톨러 자체 smoke test 통과

### Must Have
- 개별 인스톨러 독립 실행 가능 (루트 없이)
- 루트 인스톨러 인터랙티브 메뉴
- 멱등 설치 (재실행 안전)
- 수령증 기반 정밀 제거
- 권한 단계 분리 (user-space 설치 실패 없이 sudo 거부 가능)
- 기존 `sazo-ai-harness` 경로 유지

### Must NOT Have (Guardrails)
- 다른 도구(weekly-report, 스킬, 에이전트) 패키지화 - 이번 스코프 아님
- 새로운 경로 네이밍 도입 - `sazo-ai-harness` 유지
- 보존된 `agents/`, `skills/`, `commands/` 디렉토리 수정 - 그대로 유지
- manifest.json을 설치 진실의 원천(source of truth)으로 사용 - 수령증이 진실
- Go 패키지(translate-bot 등)에 영향 - 완전 독립

---

## Verification Strategy

> **ZERO HUMAN INTERVENTION** - ALL verification is agent-executed. No exceptions.

### Test Decision
- **Infrastructure exists**: YES (bash smoke tests)
- **Automated tests**: Tests-after (기존 테스트 이전 + 인스톨러 테스트 추가)
- **Framework**: bash smoke tests (기존 패턴 따름)

### QA Policy
Every task MUST include agent-executed QA scenarios.
Evidence saved to `.sisyphus/evidence/task-{N}-{scenario-slug}.{ext}`.

- **CLI**: Use Bash - Run commands, assert exit codes + output
- **Installer**: Use Bash in isolated temp environment - Install, verify artifacts, uninstall, verify cleanup
- **Interactive Menu**: Use interactive_bash (tmux) - Run installer, send keypresses, verify menu display

---

## Execution Strategy

### Parallel Execution Waves

```
Wave 1 (Foundation - start immediately):
├── Task 1: 공통 라이브러리 (lib/installer-common.sh) [quick]
├── Task 2: 디렉토리 재구조화 + tool.sh 매니페스트 [quick]
└── Task 3: 수령증(receipt) 시스템 설계 및 구현 [quick]

Wave 2 (awake 패키지 - depends on Wave 1):
├── Task 4: awake 개별 인스톨러 (tools/awake/install.sh) [deep]
├── Task 5: awake 개별 제거기 (tools/awake/uninstall.sh) [unspecified-high]
└── Task 6: 기존 smoke test 이전 + 경로 수정 [quick]

Wave 3 (루트 인스톨러 - depends on Wave 2):
├── Task 7: 루트 인스톨러 (install.sh) [deep]
├── Task 8: 루트 제거기 (uninstall.sh) [unspecified-high]
└── Task 9: 인스톨러 smoke test 작성 [unspecified-high]

Wave 4 (정리 - depends on Wave 3):
└── Task 10: README 업데이트 + 기존 파일 정리 [writing]

Wave FINAL (After ALL tasks — 4 parallel reviews):
├── Task F1: Plan compliance audit (oracle)
├── Task F2: Code quality review (unspecified-high)
├── Task F3: Real manual QA (unspecified-high)
└── Task F4: Scope fidelity check (deep)
-> Present results -> Get explicit user okay

Critical Path: Task 1 → Task 2 → Task 4 → Task 7 → Task 9 → F1-F4 → user okay
Parallel Speedup: ~50% faster than sequential
Max Concurrent: 3 (Waves 1, 2, 3)
```

### Dependency Matrix

| Task | Depends On | Blocks | Wave |
|------|-----------|--------|------|
| 1 | - | 4, 5, 7, 8 | 1 |
| 2 | - | 4, 5, 6, 7 | 1 |
| 3 | - | 4, 5, 7, 8 | 1 |
| 4 | 1, 2, 3 | 7, 9 | 2 |
| 5 | 1, 2, 3 | 8, 9 | 2 |
| 6 | 2 | 9 | 2 |
| 7 | 1, 3, 4 | 9, 10 | 3 |
| 8 | 1, 3, 5 | 9, 10 | 3 |
| 9 | 4, 5, 6, 7, 8 | F1-F4 | 3 |
| 10 | 7, 8 | F1-F4 | 4 |

### Agent Dispatch Summary

- **Wave 1**: **3** - T1 → `quick`, T2 → `quick`, T3 → `quick`
- **Wave 2**: **3** - T4 → `deep`, T5 → `unspecified-high`, T6 → `quick`
- **Wave 3**: **3** - T7 → `deep`, T8 → `unspecified-high`, T9 → `unspecified-high`
- **Wave 4**: **1** - T10 → `writing`
- **FINAL**: **4** - F1 → `oracle`, F2 → `unspecified-high`, F3 → `unspecified-high`, F4 → `deep`

---

## TODOs

- [ ] 1. 공통 라이브러리 (`lib/installer-common.sh`)

  **What to do**:
  - `packages/ai-harness/lib/installer-common.sh` 생성
  - 현재 `install.sh`와 `uninstall.sh`에서 공통 함수 추출:
    - `log_info()`, `log_warn()`, `log_error()` - 컬러 로깅
    - `ask_yes_no()` - 대화형 yes/no 프롬프트 (비대화형 모드 지원: `--yes` 플래그 시 자동 yes)
    - `ensure_dir()` - 디렉토리 생성 + 권한 확인
    - `safe_symlink()` - 기존 심링크 확인 후 생성/갱신
    - `check_platform()` - OS 호환성 확인 (darwin 등)
    - `acquire_lock()` / `release_lock()` - mkdir 기반 프로세스 잠금
    - `sparse_clone_tool()` - 특정 도구만 sparse checkout하는 git 래퍼
    - `write_receipt()` / `read_receipt()` / `clear_receipt()` - 수령증 관리 (Task 3에서 설계)
  - 모든 함수에 `# Usage:` 주석 포함
  - 인스톨러 계약 상수 정의: `EXIT_OK=0`, `EXIT_ALREADY_INSTALLED=0`, `EXIT_FAIL=1`, `EXIT_SUDO_DENIED=2`, `EXIT_PLATFORM_UNSUPPORTED=3`

  **Must NOT do**:
  - awake 관련 로직 포함하지 않음 (도구 독립적이어야 함)
  - 외부 의존성 추가 (jq 등) - 순수 bash + coreutils만

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: 기존 코드에서 함수 추출 + 정리 작업. 복잡한 설계 불필요.
  - **Skills**: []
  - **Skills Evaluated but Omitted**:
    - `develop`: 단순 추출 작업이라 TDD 불필요

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 1 (with Tasks 2, 3)
  - **Blocks**: [4, 5, 7, 8]
  - **Blocked By**: None

  **References**:

  **Pattern References**:
  - `packages/ai-harness/install.sh:1-278` - `log()`, `ask_yes_no()`, sparse clone, symlink 생성 패턴 추출 원본
  - `packages/ai-harness/uninstall.sh:1-345` - 정리 유틸리티, 상태 확인 패턴 추출 원본
  - `packages/ai-harness/scripts/awake/awake.sh:1-50` - `acquire_lock()` / `release_lock()` 패턴 (mkdir 기반 잠금)

  **WHY Each Reference Matters**:
  - `install.sh` - 로깅, 프롬프트, sparse clone, symlink 함수의 실제 구현이 여기 있음. 이걸 추출해서 공통화
  - `uninstall.sh` - 정리 패턴, 안전한 삭제 패턴이 여기 있음
  - `awake.sh` - 프로세스 잠금 패턴(mkdir -p lock.d)이 이미 구현되어 있음. 이를 일반화

  **Acceptance Criteria**:

  **QA Scenarios (MANDATORY):**

  ```
  Scenario: lib sourcing 및 함수 존재 확인
    Tool: Bash
    Preconditions: lib/installer-common.sh 파일 존재
    Steps:
      1. `bash -n packages/ai-harness/lib/installer-common.sh` 실행 → exit 0
      2. `source packages/ai-harness/lib/installer-common.sh && type log_info` → "is a function"
      3. `source packages/ai-harness/lib/installer-common.sh && type safe_symlink` → "is a function"
      4. `source packages/ai-harness/lib/installer-common.sh && type acquire_lock` → "is a function"
      5. `source packages/ai-harness/lib/installer-common.sh && type sparse_clone_tool` → "is a function"
    Expected Result: 모든 함수가 정의됨, 문법 오류 없음
    Failure Indicators: "is not a function" 또는 bash -n 에러
    Evidence: .sisyphus/evidence/task-1-lib-functions.txt

  Scenario: 비대화형 모드 동작
    Tool: Bash
    Preconditions: lib sourced
    Steps:
      1. `SAZO_NON_INTERACTIVE=1 bash -c 'source packages/ai-harness/lib/installer-common.sh && ask_yes_no "test?" y && echo YES || echo NO'`
    Expected Result: 프롬프트 없이 "YES" 출력 (기본값 y 사용)
    Failure Indicators: stdin 대기 또는 프롬프트 출력
    Evidence: .sisyphus/evidence/task-1-non-interactive.txt
  ```

  **Commit**: YES (groups with 2, 3)
  - Message: `refactor(ai-harness): extract installer common library and tool structure`
  - Files: `packages/ai-harness/lib/installer-common.sh`
  - Pre-commit: `bash -n packages/ai-harness/lib/installer-common.sh`

- [ ] 2. 디렉토리 재구조화 + tool.sh 매니페스트

  **What to do**:
  - `packages/ai-harness/tools/awake/` 디렉토리 생성
  - 기존 파일을 새 위치로 이동 (`git mv`):
    - `scripts/awake/awake.sh` → `tools/awake/scripts/awake.sh`
    - `scripts/awake/awake-helper.sh` → `tools/awake/scripts/awake-helper.sh`
    - `commands/awake.md` → `tools/awake/commands/awake.md`
    - `scripts/tests/awake.smoke.sh` → `tools/awake/tests/awake.smoke.sh`
    - `scripts/tests/awake-helper.smoke.sh` → `tools/awake/tests/awake-helper.smoke.sh`
  - 각 도구 디렉토리에 `tool.sh` 매니페스트 생성 (JSON 대신 bash로, jq 의존성 없이):
    ```bash
    # tool.sh - awake tool metadata
    TOOL_NAME="awake"
    TOOL_DESC="macOS 닫힌 뚜껑 실행 유지 도구"
    TOOL_VERSION="1.0.0"
    TOOL_PLATFORM="darwin"  # "any" 또는 특정 OS
    TOOL_REQUIRES_SUDO="optional"  # "yes" | "no" | "optional"
    ```
  - `tools/awake/` 디렉토리에 `.gitkeep` 제거 확인 (파일이 있으므로 불필요)

  **Must NOT do**:
  - 기존 `commands/awake.md`를 원본 위치에 복사본으로 남기지 않음 (git mv로 이동)
  - `commands/weekly-report.md`는 건드리지 않음
  - `agents/`, `skills/` 디렉토리는 건드리지 않음

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: git mv + 작은 파일 생성. 단순 구조 작업.
  - **Skills**: [`git-master`]
    - `git-master`: git mv로 파일 이동 시 히스토리 보존 필요
  - **Skills Evaluated but Omitted**:
    - `develop`: 코드 작성 아닌 구조 변경

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 1 (with Tasks 1, 3)
  - **Blocks**: [4, 5, 6, 7]
  - **Blocked By**: None

  **References**:

  **Pattern References**:
  - `packages/ai-harness/scripts/awake/` - 이동할 원본 스크립트 위치
  - `packages/ai-harness/commands/awake.md` - 이동할 커맨드 정의
  - `packages/ai-harness/scripts/tests/awake.smoke.sh` - 이동할 테스트
  - `packages/ai-harness/scripts/tests/awake-helper.smoke.sh` - 이동할 테스트

  **WHY Each Reference Matters**:
  - 이동 대상 파일들의 현재 위치. git mv의 source로 사용

  **Acceptance Criteria**:

  **QA Scenarios (MANDATORY):**

  ```
  Scenario: 디렉토리 구조 확인
    Tool: Bash
    Preconditions: git mv 완료
    Steps:
      1. `ls packages/ai-harness/tools/awake/scripts/awake.sh` → 존재
      2. `ls packages/ai-harness/tools/awake/scripts/awake-helper.sh` → 존재
      3. `ls packages/ai-harness/tools/awake/commands/awake.md` → 존재
      4. `ls packages/ai-harness/tools/awake/tests/awake.smoke.sh` → 존재
      5. `ls packages/ai-harness/tools/awake/tool.sh` → 존재
      6. `ls packages/ai-harness/scripts/awake/` → 디렉토리 없음 (이동됨)
    Expected Result: 새 위치에 모든 파일 존재, 원본 위치는 비어있음
    Failure Indicators: 파일 누락 또는 원본 위치에 잔존
    Evidence: .sisyphus/evidence/task-2-directory-structure.txt

  Scenario: tool.sh 매니페스트 유효성
    Tool: Bash
    Preconditions: tool.sh 생성됨
    Steps:
      1. `source packages/ai-harness/tools/awake/tool.sh && echo "$TOOL_NAME"` → "awake"
      2. `source packages/ai-harness/tools/awake/tool.sh && echo "$TOOL_PLATFORM"` → "darwin"
    Expected Result: 매니페스트 변수가 올바르게 설정됨
    Failure Indicators: 변수 미정의 또는 잘못된 값
    Evidence: .sisyphus/evidence/task-2-tool-manifest.txt
  ```

  **Commit**: YES (groups with 1, 3)
  - Message: `refactor(ai-harness): extract installer common library and tool structure`
  - Files: `packages/ai-harness/tools/awake/`, removed originals
  - Pre-commit: `test -f packages/ai-harness/tools/awake/scripts/awake.sh`

- [ ] 3. 수령증(receipt) 시스템 설계 및 구현

  **What to do**:
  - `lib/installer-common.sh`에 수령증 함수 구현 (Task 1이 스켈레톤, 이 태스크가 구체 구현):
    - 수령증 위치: `~/.config/sazo-ai-harness/receipts/{tool-name}.receipt`
    - 수령증 형식 (한 줄에 하나의 설치된 아티팩트):
      ```
      # Receipt for awake (installed: 2025-05-21T10:00:00)
      # version=1
      symlink:~/.local/bin/awake
      symlink:~/.claude/commands/awake.md
      symlink:~/.config/opencode/commands/awake.md
      dir:~/.config/sazo-ai-harness/tools/awake
      sudo:file:/usr/local/libexec/sazo-ai-harness/awake-helper
      sudo:file:/etc/sudoers.d/sazo-ai-harness-awake
      sudo:dir:/var/db/sazo-ai-harness
      state:~/.config/sazo-ai-harness/awake.state
      ```
    - `write_receipt()`: 아티팩트 추가 (append)
    - `read_receipt()`: 수령증 읽기 (카테고리 필터 지원)
    - `clear_receipt()`: 수령증 삭제
    - `receipt_exists()`: 설치 여부 확인
  - 수령증은 인스톨러가 실제로 생성한 아티팩트만 기록 (설치 시점에 append)
  - 제거기가 수령증을 읽어서 정확히 그 파일들만 삭제

  **Must NOT do**:
  - 매니페스트(tool.sh)를 수령증 대체로 사용하지 않음 - 매니페스트는 메타데이터, 수령증은 실제 설치 기록
  - 수령증에 상대 경로 사용하지 않음 - 항상 절대 경로 또는 `~` 확장

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: 파일 I/O 중심의 간단한 bash 함수 구현
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 1 (with Tasks 1, 2)
  - **Blocks**: [4, 5, 7, 8]
  - **Blocked By**: None (Task 1과 같은 파일이지만, 이 태스크가 receipt 전용 섹션을 추가하는 것이므로 실질적으로 병렬 가능. 또는 Task 1 이후 순차로 실행하되, Wave 1 내에서 처리)

  **References**:

  **Pattern References**:
  - `packages/ai-harness/uninstall.sh:1-345` - 현재 제거 로직이 제거할 아티팩트를 하드코딩하고 있음. 수령증으로 대체할 패턴

  **WHY Each Reference Matters**:
  - `uninstall.sh`는 현재 삭제 대상을 코드에 하드코딩하고 있음. 수령증 시스템은 이를 데이터 기반으로 전환

  **Acceptance Criteria**:

  **QA Scenarios (MANDATORY):**

  ```
  Scenario: 수령증 쓰기/읽기 라운드트립
    Tool: Bash
    Preconditions: lib sourced, 임시 HOME 설정
    Steps:
      1. `export HOME=$(mktemp -d)`
      2. `source packages/ai-harness/lib/installer-common.sh`
      3. `write_receipt "awake" "symlink:$HOME/.local/bin/awake"`
      4. `write_receipt "awake" "dir:$HOME/.config/sazo-ai-harness/tools/awake"`
      5. `read_receipt "awake"` → 두 줄 출력
      6. `receipt_exists "awake"` → exit 0
      7. `clear_receipt "awake"` → 파일 삭제
      8. `receipt_exists "awake"` → exit 1
    Expected Result: 쓰기→읽기→확인→삭제→확인 사이클 완료
    Failure Indicators: 수령증 파일 미생성 또는 읽기 실패
    Evidence: .sisyphus/evidence/task-3-receipt-roundtrip.txt

  Scenario: 카테고리 필터 읽기
    Tool: Bash
    Preconditions: 수령증에 symlink, dir, sudo 항목 혼합
    Steps:
      1. 여러 종류의 아티팩트를 write_receipt로 기록
      2. `read_receipt "awake" "sudo"` → sudo: 접두사 항목만 출력
      3. `read_receipt "awake" "symlink"` → symlink: 접두사 항목만 출력
    Expected Result: 카테고리별 필터링 동작
    Evidence: .sisyphus/evidence/task-3-receipt-filter.txt
  ```

  **Commit**: YES (groups with 1, 2)
  - Message: `refactor(ai-harness): extract installer common library and tool structure`
  - Files: `packages/ai-harness/lib/installer-common.sh` (receipt 섹션)
  - Pre-commit: `bash -n packages/ai-harness/lib/installer-common.sh`

- [ ] 4. awake 개별 인스톨러 (`tools/awake/install.sh`)

  **What to do**:
  - `packages/ai-harness/tools/awake/install.sh` 생성
  - **인스톨러 계약 준수**:
    - 비대화형 기본 지원 (`--yes` 또는 `SAZO_NON_INTERACTIVE=1`)
    - 멱등성 (재실행 안전 - 이미 설치된 경우 스킵 또는 갱신)
    - 명확한 exit code (EXIT_OK, EXIT_ALREADY_INSTALLED, EXIT_FAIL, EXIT_SUDO_DENIED, EXIT_PLATFORM_UNSUPPORTED)
    - 프로세스 잠금 (acquire_lock/release_lock 사용)
  - **설치 흐름**:
    1. Platform 확인 (macOS only)
    2. 프로세스 잠금 획득
    3. sparse clone: `packages/ai-harness/tools/awake/` + `packages/ai-harness/lib/` 만 checkout
    4. CLI 심링크 생성: `~/.local/bin/awake` → sparse clone 내 `awake.sh`
    5. 커맨드 심링크: `~/.claude/commands/awake.md` (claude 설치 시), `~/.config/opencode/commands/awake.md` (opencode 설치 시)
    6. 각 아티팩트 생성 시 `write_receipt()` 호출
    7. **권한 분리**: sudo 필요 컴포넌트는 별도 단계로 분리
       - 사용자에게 물어봄: "Install root helper for closed-lid support?"
       - YES → helper 복사 + sudoers 설정
       - NO → user-space만으로 완전히 동작 (caffeinate fallback 또는 기능 제한)
    8. 설치 완료 요약 출력
  - **트랜잭션 설계**: trap cleanup으로 실패 시 생성된 아티팩트 롤백
  - **기존 설치 감지**: 이미 awake가 설치되어 있으면 갱신 모드 (기존 수령증 기반)
  - `lib/installer-common.sh`를 source하여 공통 함수 사용

  **Must NOT do**:
  - 다른 도구(weekly-report 등) 설치 로직 포함하지 않음
  - 루트 인스톨러 의존하지 않음 (완전 독립 실행)
  - awake.sh, awake-helper.sh 내용 수정하지 않음 (설치만 담당)

  **Recommended Agent Profile**:
  - **Category**: `deep`
    - Reason: 트랜잭션 설치, 권한 분리, 멱등성, 잠금 등 복잡한 로직. 신중한 구현 필요.
  - **Skills**: []
  - **Skills Evaluated but Omitted**:
    - `develop`: 인스톨러는 TDD보다 통합 테스트(smoke test)가 적합

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 2 (with Tasks 5, 6)
  - **Blocks**: [7, 9]
  - **Blocked By**: [1, 2, 3]

  **References**:

  **Pattern References**:
  - `packages/ai-harness/install.sh:1-278` - 현재 인스톨러 전체. sparse clone 패턴, symlink 생성, sudo 프롬프트, cleanup trap 패턴 모두 여기서 참조
  - `packages/ai-harness/tools/awake/scripts/awake.sh:1-50` - (Task 2에서 이동됨) shebang, 상수 정의, PATH 설정 패턴
  - `packages/ai-harness/lib/installer-common.sh` - (Task 1에서 생성됨) source하여 사용할 공통 함수

  **API/Type References**:
  - `packages/ai-harness/tools/awake/tool.sh` - (Task 2에서 생성됨) TOOL_PLATFORM 확인용

  **WHY Each Reference Matters**:
  - `install.sh`는 실제 동작하는 인스톨러. 여기서 검증된 패턴을 추출/리팩터링하여 개별 인스톨러에 적용
  - `tools/awake/scripts/awake.sh` 상단의 상수/경로 정의를 참조하여 설치 대상 경로를 정확히 맞춤 (Task 2에서 이동된 후 경로)

  **Acceptance Criteria**:

  **QA Scenarios (MANDATORY):**

  ```
  Scenario: 클린 환경에서 개별 설치
    Tool: Bash
    Preconditions: 임시 HOME, awake 미설치 상태
    Steps:
      1. `export HOME=$(mktemp -d) && export PATH="$HOME/.local/bin:$PATH"`
      2. `bash packages/ai-harness/tools/awake/install.sh --yes`
      3. `test -L "$HOME/.local/bin/awake"` → exit 0 (심링크 존재)
      4. `test -f "$HOME/.config/sazo-ai-harness/receipts/awake.receipt"` → exit 0 (수령증 존재)
      5. `"$HOME/.local/bin/awake" status` → exit 0, 상태 출력
    Expected Result: CLI 심링크 생성, 수령증 기록, awake 실행 가능
    Failure Indicators: 심링크 미생성, 수령증 누락, awake 실행 실패
    Evidence: .sisyphus/evidence/task-4-clean-install.txt

  Scenario: 멱등 재설치
    Tool: Bash
    Preconditions: awake 이미 설치된 상태
    Steps:
      1. 첫 번째 설치 실행
      2. 두 번째 설치 실행 `bash packages/ai-harness/tools/awake/install.sh --yes`
      3. exit code 확인 → 0
      4. 심링크가 여전히 유효한지 확인
    Expected Result: 에러 없이 완료, 기존 설치 유지 또는 갱신
    Failure Indicators: exit code != 0, 심링크 깨짐
    Evidence: .sisyphus/evidence/task-4-idempotent-reinstall.txt

  Scenario: macOS 아닌 환경에서 플랫폼 거부
    Tool: Bash
    Preconditions: (macOS에서 테스트 시) 플랫폼 체크 우회 테스트
    Steps:
      1. `SAZO_FAKE_UNAME=Linux bash packages/ai-harness/tools/awake/install.sh --yes` (또는 플랫폼 체크 함수가 환경변수로 오버라이드 가능하도록)
    Expected Result: "Platform not supported" 메시지와 EXIT_PLATFORM_UNSUPPORTED exit code
    Evidence: .sisyphus/evidence/task-4-platform-reject.txt

  Scenario: sudo 거부 시 user-space만 설치
    Tool: Bash
    Preconditions: 클린 환경
    Steps:
      1. sudo 프롬프트에 "no" 응답 (또는 --no-sudo 플래그)
      2. CLI 심링크 확인 → 존재
      3. root helper 확인 → 미존재
      4. 수령증에 sudo 항목 없음 확인
    Expected Result: user-space 아티팩트만 설치, sudo 관련 없음
    Evidence: .sisyphus/evidence/task-4-no-sudo.txt
  ```

  **Commit**: YES (groups with 5, 6)
  - Message: `feat(ai-harness): add awake individual installer and uninstaller`
  - Files: `packages/ai-harness/tools/awake/install.sh`
  - Pre-commit: `bash -n packages/ai-harness/tools/awake/install.sh`

- [ ] 5. awake 개별 제거기 (`tools/awake/uninstall.sh`)

  **What to do**:
  - `packages/ai-harness/tools/awake/uninstall.sh` 생성
  - **수령증 기반 제거**: 수령증에 기록된 아티팩트만 삭제
    - `symlink:` 항목 → 심링크 삭제
    - `dir:` 항목 → 디렉토리 삭제 (비어있을 때만, 또는 강제 옵션)
    - `sudo:file:` / `sudo:dir:` 항목 → sudo로 삭제 (사용자 확인 후)
    - `state:` 항목 → 상태 파일 삭제
  - **권한 분리 제거**: sudo 아티팩트는 별도 단계, sudo 실패해도 user-space는 정리
  - **실행 중인 awake 감지**: `awake status`가 active면 먼저 `awake off` 실행 권고
  - **수령증 없을 때**: fallback으로 알려진 경로 스캔 (레거시 호환)
  - **제거 완료 후**: 수령증 파일 자체도 삭제 (`clear_receipt()`)
  - 비대화형 모드 지원 (`--yes`)
  - `lib/installer-common.sh` source

  **Must NOT do**:
  - 다른 도구의 아티팩트 삭제하지 않음
  - 공유 디렉토리 (`~/.config/sazo-ai-harness/`) 삭제하지 않음 (다른 도구가 사용할 수 있음)
  - awake.sh, awake-helper.sh 실행하지 않음 (제거만 담당)

  **Recommended Agent Profile**:
  - **Category**: `unspecified-high`
    - Reason: 수령증 파싱 + 안전한 삭제 로직 + sudo 처리. 중간 난이도.
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 2 (with Tasks 4, 6)
  - **Blocks**: [8, 9]
  - **Blocked By**: [1, 2, 3]

  **References**:

  **Pattern References**:
  - `packages/ai-harness/uninstall.sh:1-345` - 현재 제거기 전체. 삭제 순서, sudo 처리, 레거시 정리 패턴
  - `packages/ai-harness/tools/awake/scripts/awake.sh` - (Task 2에서 이동됨) `awake off` / `awake status` 인터페이스 (활성 세션 감지용)

  **WHY Each Reference Matters**:
  - `uninstall.sh`는 현재 전체 제거 로직. 여기서 awake 관련 부분만 추출하고, 하드코딩된 경로를 수령증 기반으로 전환
  - `tools/awake/scripts/awake.sh`는 Task 2에서 이동된 후의 경로. 활성 세션 감지를 위해 이 경로를 사용

  **Acceptance Criteria**:

  **QA Scenarios (MANDATORY):**

  ```
  Scenario: 설치 후 제거 사이클
    Tool: Bash
    Preconditions: Task 4의 설치가 완료된 상태
    Steps:
      1. `bash packages/ai-harness/tools/awake/uninstall.sh --yes`
      2. `test -L "$HOME/.local/bin/awake"` → exit 1 (심링크 없음)
      3. `test -f "$HOME/.config/sazo-ai-harness/receipts/awake.receipt"` → exit 1 (수령증 없음)
      4. `test -d "$HOME/.config/sazo-ai-harness/"` → exit 0 (공유 디렉토리는 유지)
    Expected Result: awake 아티팩트 전부 제거, 공유 디렉토리 보존
    Failure Indicators: 아티팩트 잔존 또는 공유 디렉토리 삭제
    Evidence: .sisyphus/evidence/task-5-uninstall-cycle.txt

  Scenario: 수령증 없이 레거시 제거
    Tool: Bash
    Preconditions: 수령증 없이 레거시 방식으로 설치된 awake
    Steps:
      1. 수동으로 심링크 생성 (수령증 없이)
      2. `bash packages/ai-harness/tools/awake/uninstall.sh --yes`
      3. 알려진 경로들이 정리되었는지 확인
    Expected Result: fallback 스캔으로 레거시 아티팩트 제거
    Evidence: .sisyphus/evidence/task-5-legacy-uninstall.txt
  ```

  **Commit**: YES (groups with 4, 6)
  - Message: `feat(ai-harness): add awake individual installer and uninstaller`
  - Files: `packages/ai-harness/tools/awake/uninstall.sh`
  - Pre-commit: `bash -n packages/ai-harness/tools/awake/uninstall.sh`

- [ ] 6. 기존 smoke test 이전 + 경로 수정

  **What to do**:
  - Task 2에서 `git mv`로 이동된 테스트 파일들의 내부 경로 참조 수정:
    - `tools/awake/tests/awake.smoke.sh` - 스크립트 경로 참조를 `../../scripts/awake/awake.sh`에서 `../scripts/awake.sh`로 변경
    - `tools/awake/tests/awake-helper.smoke.sh` - 동일하게 경로 수정
  - 테스트의 `source` 또는 경로 변수가 새 디렉토리 구조를 반영하는지 확인
  - 기존 `scripts/tests/install.smoke.sh`는 이동하지 않음 (루트 인스톨러 테스트이므로 Task 9에서 재작성)
  - 이동된 테스트가 새 위치에서 통과하는지 실행하여 확인

  **Must NOT do**:
  - 테스트 로직/케이스 변경하지 않음 (경로만 수정)
  - install.smoke.sh를 이동하지 않음 (Task 9에서 새로 작성)

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: 경로 문자열 치환 + 실행 확인. 단순 작업.
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 2 (with Tasks 4, 5)
  - **Blocks**: [9]
  - **Blocked By**: [2]

  **References**:

  **Pattern References**:
  - `packages/ai-harness/tools/awake/tests/awake.smoke.sh` - (Task 2에서 이동됨) 내부 경로 참조 확인
  - `packages/ai-harness/tools/awake/tests/awake-helper.smoke.sh` - (Task 2에서 이동됨) 내부 경로 참조 확인

  **WHY Each Reference Matters**:
  - 이동된 테스트 파일 내부에서 awake.sh/awake-helper.sh를 참조하는 경로가 새 구조에 맞아야 함

  **Acceptance Criteria**:

  **QA Scenarios (MANDATORY):**

  ```
  Scenario: 이동된 smoke test 실행
    Tool: Bash
    Preconditions: Task 2 완료, 테스트 파일 이동됨
    Steps:
      1. `bash packages/ai-harness/tools/awake/tests/awake.smoke.sh` → 16/16 통과
      2. exit code 0
    Expected Result: 모든 기존 테스트 통과
    Failure Indicators: 테스트 실패 또는 경로 에러
    Evidence: .sisyphus/evidence/task-6-smoke-test-pass.txt

  Scenario: helper smoke test 실행
    Tool: Bash
    Preconditions: Task 2 완료
    Steps:
      1. `bash packages/ai-harness/tools/awake/tests/awake-helper.smoke.sh` → 12/12 통과
    Expected Result: 모든 helper 테스트 통과
    Evidence: .sisyphus/evidence/task-6-helper-smoke-test-pass.txt
  ```

  **Commit**: YES (groups with 4, 5)
  - Message: `feat(ai-harness): add awake individual installer and uninstaller`
  - Files: modified test files
  - Pre-commit: `bash packages/ai-harness/tools/awake/tests/awake.smoke.sh`

- [ ] 7. 루트 인스톨러 (`install.sh`)

  **What to do**:
  - 기존 `packages/ai-harness/install.sh`를 루트 인스톨러로 전환 (전면 재작성)
  - **인터랙티브 메뉴 UX**:
    ```
    ╔══════════════════════════════════════════╗
    ║    SAZO AI Harness - Tool Installer      ║
    ╠══════════════════════════════════════════╣
    ║                                          ║
    ║  Available tools:                        ║
    ║                                          ║
    ║  [1] awake - macOS 닫힌 뚜껑 실행 유지   ║
    ║                                          ║
    ║  [a] Install all                         ║
    ║  [q] Quit                                ║
    ║                                          ║
    ╚══════════════════════════════════════════╝
    Select tools to install (e.g., 1 2 3 or a):
    ```
  - **도구 발견 (convention-based)**: `tools/*/tool.sh` 존재하는 디렉토리를 스캔하여 메뉴 자동 생성
    - 각 tool.sh에서 TOOL_NAME, TOOL_DESC, TOOL_PLATFORM 읽기
    - 현재 플랫폼과 호환되지 않는 도구는 메뉴에서 `(unsupported)` 표시
  - **설치 흐름**:
    1. sparse clone: `packages/ai-harness/` 전체 checkout
    2. `tools/*/tool.sh` 스캔하여 메뉴 구성
    3. 사용자 선택 받기
    4. 선택된 각 도구의 `tools/{name}/install.sh` 호출 (이미 checkout된 로컬 경로에서)
    5. 설치 결과 요약 출력
  - **CLI 플래그 지원**: `--tools awake` (비대화형 특정 도구 설치)
  - 기존 install.sh의 레거시 설치 감지 → 마이그레이션 안내 메시지 출력
  - `lib/installer-common.sh` source

  **Must NOT do**:
  - 도구별 설치 로직을 루트에 직접 구현하지 않음 (각 도구의 install.sh에 위임)
  - 도구 목록을 하드코딩하지 않음 (convention-based 발견)
  - 기존 에이전트/스킬을 자동 설치하지 않음 (향후 별도 도구로 패키지화할 때)

  **Recommended Agent Profile**:
  - **Category**: `deep`
    - Reason: 인터랙티브 메뉴 UX, 도구 발견 로직, CLI 플래그 파싱, 레거시 감지. 복합적.
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 3 (with Tasks 8, 9)
  - **Blocks**: [9, 10]
  - **Blocked By**: [1, 3, 4]

  **References**:

  **Pattern References**:
  - `packages/ai-harness/install.sh:1-278` - 기존 인스톨러 전체. sparse clone, 레거시 감지, 설치 흐름의 원본
  - `packages/ai-harness/tools/awake/tool.sh` - (Task 2에서 생성) 매니페스트 형식. 메뉴 구성 시 파싱 대상
  - `packages/ai-harness/tools/awake/install.sh` - (Task 4에서 생성) 개별 인스톨러 인터페이스. 루트가 호출할 대상

  **WHY Each Reference Matters**:
  - 기존 `install.sh`의 sparse clone 로직과 레거시 감지를 재활용
  - `tool.sh` 매니페스트에서 메뉴 표시 정보를 읽음
  - 개별 인스톨러의 인터페이스(exit code, 플래그)를 알아야 올바르게 호출

  **Acceptance Criteria**:

  **QA Scenarios (MANDATORY):**

  ```
  Scenario: 인터랙티브 메뉴 표시
    Tool: interactive_bash (tmux)
    Preconditions: 클린 환경
    Steps:
      1. tmux 세션에서 `bash packages/ai-harness/install.sh` 실행
      2. 메뉴 출력 확인: "awake" 도구가 목록에 표시
      3. "1" 입력 후 Enter
      4. awake 설치 진행 확인
      5. 설치 완료 메시지 확인
    Expected Result: 메뉴에 awake 표시, 선택 후 설치 진행
    Failure Indicators: 메뉴 미표시, 선택 무반응
    Evidence: .sisyphus/evidence/task-7-interactive-menu.txt

  Scenario: CLI 플래그로 비대화형 설치
    Tool: Bash
    Preconditions: 클린 환경
    Steps:
      1. `bash packages/ai-harness/install.sh --tools awake --yes`
      2. exit code 0
      3. awake 심링크 존재 확인
    Expected Result: 프롬프트 없이 awake만 설치
    Failure Indicators: stdin 대기, 설치 실패
    Evidence: .sisyphus/evidence/task-7-cli-flag-install.txt

  Scenario: 플랫폼 비호환 도구 표시
    Tool: Bash
    Preconditions: awake의 TOOL_PLATFORM="darwin" 이외의 도구가 있다고 가정 (또는 awake를 비호환으로 테스트)
    Steps:
      1. 임시로 TOOL_PLATFORM을 "linux"로 변경한 더미 도구 생성
      2. 메뉴에서 "(unsupported)" 라벨 확인
    Expected Result: 비호환 도구에 표시, 선택 불가
    Evidence: .sisyphus/evidence/task-7-platform-filter.txt
  ```

  **Commit**: YES (groups with 8)
  - Message: `feat(ai-harness): add root installer with interactive menu`
  - Files: `packages/ai-harness/install.sh` (대체)
  - Pre-commit: `bash -n packages/ai-harness/install.sh`

- [ ] 8. 루트 제거기 (`uninstall.sh`)

  **What to do**:
  - 기존 `packages/ai-harness/uninstall.sh`를 루트 제거기로 전환 (전면 재작성)
  - **제거 모드**:
    - `uninstall.sh` (인자 없음) → 설치된 도구 목록 표시, 선택 제거
    - `uninstall.sh --tool awake` → 특정 도구만 제거
    - `uninstall.sh --all` → 모든 도구 + 공유 디렉토리 + sparse clone 전체 제거
  - **도구 발견**: `~/.config/sazo-ai-harness/receipts/*.receipt` 스캔하여 설치된 도구 목록 구성
  - 각 도구 제거 시 해당 도구의 `tools/{name}/uninstall.sh` 호출 (checkout이 있으면)
  - checkout이 없으면 (수동 삭제 등) 수령증 기반 직접 제거
  - `--all` 모드에서만 공유 디렉토리(`~/.config/sazo-ai-harness/`) 및 sparse clone 삭제
  - 레거시 아티팩트 정리 (기존 uninstall.sh의 레거시 정리 로직 유지)
  - `lib/installer-common.sh` source

  **Must NOT do**:
  - 개별 도구 제거 시 공유 디렉토리 삭제하지 않음
  - 수령증에 없는 파일 임의 삭제하지 않음 (--all 제외)

  **Recommended Agent Profile**:
  - **Category**: `unspecified-high`
    - Reason: 수령증 파싱, 도구별 위임, 레거시 정리. 중간 복잡도.
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 3 (with Tasks 7, 9)
  - **Blocks**: [9, 10]
  - **Blocked By**: [1, 3, 5]

  **References**:

  **Pattern References**:
  - `packages/ai-harness/uninstall.sh:1-345` - 기존 제거기. 레거시 정리, sudo 처리, LaunchAgent 제거 패턴
  - `packages/ai-harness/tools/awake/uninstall.sh` - (Task 5에서 생성) 개별 제거기 인터페이스

  **WHY Each Reference Matters**:
  - 기존 `uninstall.sh`의 레거시 정리 로직을 보존해야 함 (LaunchAgent, sudoers, 상태파일 등)
  - 개별 제거기의 인터페이스를 알아야 올바르게 호출

  **Acceptance Criteria**:

  **QA Scenarios (MANDATORY):**

  ```
  Scenario: 특정 도구만 제거
    Tool: Bash
    Preconditions: awake 설치 완료
    Steps:
      1. `bash packages/ai-harness/uninstall.sh --tool awake --yes`
      2. awake 심링크 없음 확인
      3. 수령증 없음 확인
      4. 공유 디렉토리 존재 확인 (삭제되면 안됨)
    Expected Result: awake만 제거, 공유 구조 유지
    Evidence: .sisyphus/evidence/task-8-tool-specific-uninstall.txt

  Scenario: 전체 제거
    Tool: Bash
    Preconditions: awake 설치 완료
    Steps:
      1. `bash packages/ai-harness/uninstall.sh --all --yes`
      2. `~/.config/sazo-ai-harness/` 디렉토리 없음 확인
      3. `~/.local/bin/awake` 없음 확인
    Expected Result: 모든 아티팩트 + 공유 디렉토리 완전 제거
    Evidence: .sisyphus/evidence/task-8-full-uninstall.txt
  ```

  **Commit**: YES (groups with 7)
  - Message: `feat(ai-harness): add root installer with interactive menu`
  - Files: `packages/ai-harness/uninstall.sh` (대체)
  - Pre-commit: `bash -n packages/ai-harness/uninstall.sh`

- [ ] 9. 인스톨러 smoke test 작성

  **What to do**:
  - `packages/ai-harness/tools/awake/tests/install.smoke.sh` 생성
  - 기존 `scripts/tests/install.smoke.sh`의 패턴을 참고하되 새 구조에 맞게 재작성
  - **테스트 케이스** (임시 HOME 사용, 실제 시스템 영향 없음):
    1. 개별 인스톨러 클린 설치 → 아티팩트 확인
    2. 개별 인스톨러 멱등 재설치 → 에러 없음
    3. 개별 제거기 → 아티팩트 전부 제거
    4. 수령증 생성/삭제 확인
    5. 루트 인스톨러 `--tools awake --yes` → 설치 확인
    6. 루트 제거기 `--tool awake --yes` → 제거 확인
    7. 루트 전체 제거 `--all --yes` → 완전 제거
    8. 권한 분리: sudo 거부 시 user-space만 설치
    9. 플랫폼 체크: 비호환 플랫폼 거부
    10. 동시 실행 잠금: 두 번째 인스톨러가 잠금 감지
  - 테스트 프레임워크: 기존 smoke test 패턴 따름 (함수 기반, 카운터, 컬러 출력)
  - 모든 테스트는 임시 디렉토리에서 실행 후 정리

  **Must NOT do**:
  - 실제 시스템 디렉토리에 설치/제거하지 않음 (임시 HOME 사용)
  - 기존 awake smoke test 수정하지 않음 (별도 파일)

  **Recommended Agent Profile**:
  - **Category**: `unspecified-high`
    - Reason: 10개 테스트 케이스, 격리 환경 설정, 다양한 시나리오. 중간 이상.
  - **Skills**: [`Testing-Anti-Patterns`]
    - `Testing-Anti-Patterns`: 테스트가 실제 동작을 검증하도록 (mock 남용 방지)

  **Parallelization**:
  - **Can Run In Parallel**: NO
  - **Parallel Group**: Wave 3 (after 7, 8 complete)
  - **Blocks**: [F1-F4]
  - **Blocked By**: [4, 5, 6, 7, 8]

  **References**:

  **Pattern References**:
  - `packages/ai-harness/scripts/tests/install.smoke.sh` - 기존 인스톨러 테스트. 테스트 구조, 임시환경 설정, 함수 기반 테스트 패턴
  - `packages/ai-harness/tools/awake/tests/awake.smoke.sh` - 기존 awake 테스트. 테스트 프레임워크 패턴 (카운터, 컬러 출력, pass/fail)

  **WHY Each Reference Matters**:
  - `install.smoke.sh`에서 임시 HOME 설정, cleanup, 테스트 격리 패턴을 가져옴
  - `awake.smoke.sh`에서 테스트 결과 리포팅 패턴을 일관되게 유지

  **Acceptance Criteria**:

  **QA Scenarios (MANDATORY):**

  ```
  Scenario: 전체 인스톨러 테스트 스위트 실행
    Tool: Bash
    Preconditions: Wave 1-3 태스크 모두 완료
    Steps:
      1. `bash packages/ai-harness/tools/awake/tests/install.smoke.sh`
      2. 출력에서 "X/10 tests passed" 확인
      3. exit code 0
    Expected Result: 10/10 테스트 통과
    Failure Indicators: 1개 이상 실패, 또는 임시 디렉토리 미정리
    Evidence: .sisyphus/evidence/task-9-installer-smoke.txt

  Scenario: 테스트 격리 확인
    Tool: Bash
    Preconditions: 테스트 실행 전후
    Steps:
      1. 테스트 전 `~/.local/bin/awake` 상태 기록
      2. 테스트 실행
      3. 테스트 후 `~/.local/bin/awake` 상태가 변하지 않았는지 확인
    Expected Result: 실제 시스템에 영향 없음
    Evidence: .sisyphus/evidence/task-9-isolation-check.txt
  ```

  **Commit**: YES (standalone)
  - Message: `test(ai-harness): add installer smoke tests for modular system`
  - Files: `packages/ai-harness/tools/awake/tests/install.smoke.sh`
  - Pre-commit: `bash -n packages/ai-harness/tools/awake/tests/install.smoke.sh`

- [ ] 10. README 업데이트 + 기존 파일 정리

  **What to do**:
  - `packages/ai-harness/README.md` 업데이트:
    - 새로운 모듈형 인스톨러 시스템 설명
    - 개별 설치 방법: `curl -fsSL .../tools/awake/install.sh | bash`
    - 루트 인스톨러 사용법: `curl -fsSL .../install.sh | bash`
    - 도구 추가 가이드 (새 도구 만드는 법):
      1. `tools/{name}/` 디렉토리 생성
      2. `tool.sh` 매니페스트 작성
      3. `install.sh`, `uninstall.sh` 작성 (lib/installer-common.sh source)
      4. 테스트 작성
    - 기존 보존된 에이전트/스킬/커맨드 목록 유지
  - 기존 `scripts/awake/` 디렉토리 삭제 확인 (Task 2에서 git mv로 이동 완료)
  - 기존 `scripts/tests/install.smoke.sh` 정리 (새 테스트로 대체됨)
  - 기존 `commands/awake.md` 삭제 확인 (Task 2에서 이동 완료)

  **Must NOT do**:
  - 보존된 `agents/`, `skills/` 디렉토리 정리하지 않음
  - `commands/weekly-report.md` 이동하지 않음
  - CLAUDE.md (루트) 수정하지 않음

  **Recommended Agent Profile**:
  - **Category**: `writing`
    - Reason: 문서 작성 중심.
  - **Skills**: [`document`]
    - `document`: 문서 업데이트 패턴

  **Parallelization**:
  - **Can Run In Parallel**: NO
  - **Parallel Group**: Wave 4 (after Wave 3)
  - **Blocks**: [F1-F4]
  - **Blocked By**: [7, 8]

  **References**:

  **Pattern References**:
  - `packages/ai-harness/README.md` - 현재 README. 기존 구조 설명을 새 구조로 교체

  **WHY Each Reference Matters**:
  - 기존 README의 보존된 에이전트/스킬 목록을 유지하면서 인스톨러 섹션만 교체

  **Acceptance Criteria**:

  **QA Scenarios (MANDATORY):**

  ```
  Scenario: README 내용 확인
    Tool: Bash
    Preconditions: README 업데이트 완료
    Steps:
      1. `grep -c "curl.*install.sh" packages/ai-harness/README.md` → 2 이상 (개별 + 루트)
      2. `grep -c "tools/awake" packages/ai-harness/README.md` → 1 이상
      3. `grep -c "tool.sh" packages/ai-harness/README.md` → 1 이상 (도구 추가 가이드)
    Expected Result: 새 인스톨러 시스템 문서화 완료
    Evidence: .sisyphus/evidence/task-10-readme-check.txt

  Scenario: 잔존 파일 없음 확인
    Tool: Bash
    Preconditions: 정리 완료
    Steps:
      1. `test -d packages/ai-harness/scripts/awake/` → exit 1 (삭제됨)
      2. `test -f packages/ai-harness/commands/awake.md` → exit 1 (이동됨)
      3. `test -f packages/ai-harness/agents/architect-advisor.md` → exit 0 (보존됨)
      4. `test -f packages/ai-harness/commands/weekly-report.md` → exit 0 (보존됨)
    Expected Result: 이동된 파일 원본 없음, 보존 대상은 존재
    Evidence: .sisyphus/evidence/task-10-cleanup-check.txt
  ```

  **Commit**: YES (standalone)
  - Message: `docs(ai-harness): update README for modular installer system`
  - Files: `packages/ai-harness/README.md`, removed orphan files
  - Pre-commit: `test -f packages/ai-harness/README.md`

---

## Final Verification Wave

> 4 review agents run in PARALLEL. ALL must APPROVE. Present consolidated results to user and get explicit "okay" before completing.

- [ ] F1. **Plan Compliance Audit** — `oracle`
  Read the plan end-to-end. For each "Must Have": verify implementation exists (read file, run command). For each "Must NOT Have": search codebase for forbidden patterns. Check evidence files in .sisyphus/evidence/. Compare deliverables against plan.
  Output: `Must Have [N/N] | Must NOT Have [N/N] | Tasks [N/N] | VERDICT: APPROVE/REJECT`

- [ ] F2. **Code Quality Review** — `unspecified-high`
  Run `bash -n` on all .sh files. Review for: unquoted variables, missing error handling, hardcoded paths, POSIX compatibility issues. Check shellcheck if available. Verify idempotency of installers.
  Output: `Syntax [PASS/FAIL] | Style [N clean/N issues] | VERDICT`

- [ ] F3. **Real Manual QA** — `unspecified-high`
  Start from clean state. Run individual installer → verify artifacts → run awake status → uninstall → verify cleanup. Run root installer → select awake → verify → uninstall. Test failure modes: sudo denied, re-install over existing.
  Output: `Scenarios [N/N pass] | Integration [N/N] | Edge Cases [N tested] | VERDICT`

- [ ] F4. **Scope Fidelity Check** — `deep`
  For each task: read "What to do", read actual diff. Verify nothing outside scope was modified. Check `agents/`, `skills/`, `commands/` directories are untouched. Verify Go packages unaffected. Flag unaccounted changes.
  Output: `Tasks [N/N compliant] | Scope [CLEAN/N issues] | VERDICT`

---

## Commit Strategy

- **Wave 1**: `refactor(ai-harness): extract installer common library and tool structure` - lib/installer-common.sh, tools/awake/ structure
- **Wave 2**: `feat(ai-harness): add awake individual installer and uninstaller` - tools/awake/install.sh, tools/awake/uninstall.sh, migrated tests
- **Wave 3**: `feat(ai-harness): add root installer with interactive menu` - install.sh, uninstall.sh, installer tests
- **Wave 4**: `docs(ai-harness): update README for modular installer system` - README.md

---

## Success Criteria

### Verification Commands
```bash
# Individual install
curl -fsSL https://raw.githubusercontent.com/SAZO-KR/sazo-toolkit/main/packages/ai-harness/tools/awake/install.sh | bash
# Expected: awake CLI installed at ~/.local/bin/awake

awake status
# Expected: shows current state (active or inactive)

# Individual uninstall
curl -fsSL https://raw.githubusercontent.com/SAZO-KR/sazo-toolkit/main/packages/ai-harness/tools/awake/uninstall.sh | bash
# Expected: all awake artifacts removed

# Root install
curl -fsSL https://raw.githubusercontent.com/SAZO-KR/sazo-toolkit/main/packages/ai-harness/install.sh | bash
# Expected: interactive menu showing available tools

# Smoke tests
bash packages/ai-harness/tools/awake/tests/awake.smoke.sh
# Expected: 16/16 tests pass

bash packages/ai-harness/tools/awake/tests/awake-helper.smoke.sh
# Expected: 12/12 tests pass
```

### Final Checklist
- [ ] All "Must Have" present
- [ ] All "Must NOT Have" absent
- [ ] All 28 existing smoke tests pass in new location
- [ ] Installer smoke tests pass
- [ ] Individual install/uninstall cycle works end-to-end
- [ ] Root install/uninstall cycle works end-to-end
