---
name: develop
description: Use when implementing any feature or bugfix — Kent Beck TDD (one test at a time) + Tidy First (structural/behavioral separation) + test type decision gate
---

<required>
*CRITICAL* Add the following steps to your Todo list using TodoWrite:

1. Classify the task's test needs using the Test Type Decision Gate → unit / integration / combination
2. Write ONE failing test (RED)
3. Verify the test fails because the feature is missing, NOT because the test is broken
4. Write the minimal code to make the test pass (GREEN)
5. Verify the test passes
6. Refactor if needed — keep tests green, do not add behavior
7. Commit (structural and behavioral changes in separate commits)
8. Repeat from step 2 for the next test
    - If you go through three RED-GREEN loops without progress, switch to `~/.claude/skills/debug/SKILL.md`
</required>

# Test Type Decision Gate

**Before writing any test, classify the task.**

```
What am I testing?
├── Pure function / utility / helper?          → Unit test
├── Single class with no side effects?         → Unit test
├── Service orchestrating other services?      → Integration test
├── API endpoint behavior?                     → Integration test
├── Database query / transaction?              → Integration test
├── External API interaction?                  → Integration test (mock external boundary only)
├── Message queue / event handling?            → Integration test
├── Middleware / interceptor chain?             → Integration test
├── Module wiring / DI resolution?             → Integration test
├── Would I need 3+ mocks to unit test this?   → Integration test
└── Mix of utility + boundary logic?           → Unit (utilities) + Integration (boundaries)
```

**The default is integration test.** Unit tests are the exception, reserved for pure logic with no dependencies. When in doubt, write an integration test.

---

# Red → Green → Refactor

Always write **one test at a time**. Make it pass. Then write the next.

## RED — Write One Failing Test

Write the simplest test that defines the next small increment of functionality.

- Use meaningful test names that describe behavior
- Make test failures clear and informative
- One test. Not two. Not "all the tests for this feature."

**For unit tests:**

```typescript
test('retries failed operations 3 times', async () => {
  let attempts = 0;
  const operation = () => {
    attempts++;
    if (attempts < 3) throw new Error('fail');
    return 'success';
  };

  const result = await retryOperation(operation);

  expect(result).toBe('success');
  expect(attempts).toBe(3);
});
```

**For integration tests:**

Test real system behavior through actual boundaries — API endpoints, database, service interactions.

```typescript
// API endpoint test (framework-agnostic pattern)
test('POST /orders returns 201 and persists order', async () => {
  // Arrange: seed data through the real system
  await seedProduct({id: 'prod-1', stock: 10});

  // Act: call the real endpoint
  const response = await request(app)
    .post('/orders')
    .send({productId: 'prod-1', quantity: 3});

  // Assert: check observable system behavior
  expect(response.status).toBe(201);
  expect(response.body.productId).toBe('prod-1');

  // Assert: verify side effects in real DB
  const product = await db.query('SELECT stock FROM products WHERE id = $1', ['prod-1']);
  expect(product.rows[0].stock).toBe(7);
});
```

## Verify RED

**MANDATORY. Never skip.**

```bash
# Use the project's test command: npm test, pytest, cargo test, go test, etc.
<project-test-cmd> path/to/test
```

- Test must **fail** (not error)
- Failure message must be expected
- Must fail because the feature is missing

**Test passes?** You're testing existing behavior. Fix the test.
**Test errors?** Fix the error first. Re-run until it fails correctly.

## GREEN — Minimal Code

Write the simplest code to make the test pass. No more.

- Don't add features the test doesn't require
- Don't refactor yet
- Don't "improve" beyond what the test demands

## Verify GREEN

**MANDATORY.**

```bash
# Use the project's test command: npm test, pytest, cargo test, go test, etc.
<project-test-cmd> path/to/test
```

- Test must pass
- All other tests must still pass

**Test fails?** Fix code, not test.

## REFACTOR — Clean Up

Only after GREEN:

- Remove duplication
- Improve names
- Extract helpers

Keep tests green throughout. Do not add behavior.

## Fixing a Defect

When fixing a bug, do NOT jump to the fix. Follow this sequence:

1. Write an API-level failing test that exposes the bug from the user's perspective
2. Write the smallest possible test that isolates the root cause
3. Get both tests to pass
4. Verify the fix doesn't break other tests

## Then: Next Test

Go back to RED with the next increment. One test at a time, each building on the last.

---

# Tidy First

Separate all changes into two types:

1. **STRUCTURAL** — rearranging code without changing behavior (rename, extract method, move code)
2. **BEHAVIORAL** — adding or modifying functionality

**Rules:**

- Never mix structural and behavioral changes in the same commit
- Make structural changes first when both are needed
- Validate structural changes don't alter behavior: run tests before and after
- Commit messages must state whether the change is structural or behavioral

---

# Commit Discipline

Only commit when:

1. ALL tests are passing
2. ALL compiler/linter warnings resolved
3. The change is a single logical unit
4. Commit message states structural vs behavioral

Small, frequent commits. Not large, infrequent ones.

## Commit message style (압축 포맷)

Commit subject와 body는 **짧을수록 좋다**. git log를 읽는 건 주로 AI·개발자이며, diff가 "what"은 설명한다 — commit message는 "why"에 집중한다.

**Subject 규칙**:
- 포맷: `<type>(<scope>): <imperative summary>` — scope은 optional, 이 repo에서는 패키지명 (예: `feat(ai-harness): ...`)
- Types: `feat`, `fix`, `refactor`, `perf`, `docs`, `test`, `chore`, `build`, `ci`, `style`, `revert`
- 명령형 시제: "add", "fix", "remove" (✅) — "added", "adds", "adding" (❌)
- ≤50자 권장, 하드 캡 72자
- 끝에 마침표 붙이지 말 것
- 콜론 뒤 첫 글자는 프로젝트 컨벤션 따르기 (이 repo는 소문자 한국어 자연스러운 대로)

**Body 규칙** (필요할 때만):
- Subject만으로 자명하면 body 생략
- Body 포함 조건: 비자명 "why", breaking change, migration 노트, 연결 이슈, revert
- 72자에서 wrap
- Bullet은 `-` (not `*`)
- 이슈/PR 참조는 맨 끝: `Closes #42`, `Refs #17`
- **Body 필수**: breaking change, security fix, data migration, 이전 커밋 revert — subject-only로 압축 금지

**금지 (commit message에 절대 넣지 말 것)**:
- "이 커밋은 X를 한다" / "This commit does X" — diff가 말한다
- "나는/우리가/지금/현재" — imperative로 써라
- "As requested by..." — `Co-authored-by` trailer 사용
- "Generated with Claude Code" 류 AI attribution — **절대 금지**
- Emoji (프로젝트 컨벤션 필수인 경우 제외)
- scope에 이미 있는 파일명 반복

**한국어 body 규칙**:
- 조사(은/는/이/가/을/를/의) 자명할 때 drop
- 종결어미(~입니다/~합니다) → 체언/명사 종결
- 접속어(그리고/또한/따라서) drop
- 한자어 단축 (방법론→방식, 비동기적으로→비동기로)

**예시 (이 repo 관례: 한국어 subject)**:

❌
```
feat: 사용자 프로필 API 추가

이 커밋은 사용자의 프로필 정보를 조회할 수 있는 새로운 API 엔드포인트를
추가합니다. 모바일 클라이언트에서 요청된 기능입니다.

🤖 Generated with Claude Code
```

✅
```
feat(ai-harness): GET /users/:id/profile 엔드포인트 추가

모바일 클라이언트가 full user payload 없이 profile 필요 — 콜드 런치 LTE
대역 절감.

Closes #128
```

**예시 (영어 subject도 가능)**:

```
feat(api): add GET /users/:id/profile

Mobile 클라이언트가 profile 데이터를 full user payload 없이 필요 — 콜드
런치 LTE 대역 절감.

Closes #128
```

이 repo는 `feat(패키지명): 한국어 설명` 관례가 우세함 (`b7d2310 fix(ai-harness): worktree 브랜치가 origin/main tracking 하는 버그 차단`). 동일 type의 연속 커밋은 스타일 일관되게 유지. 영어/한국어 subject 선택은 프로젝트 git log 최근 5-10개 톤에 맞추되, 혼용 금지 원칙 아님.

**Breaking change 예시**:

```
feat(api)!: rename /v1/orders to /v1/checkout

BREAKING CHANGE: /v1/orders 클라이언트는 2026-06-01 전에 /v1/checkout으로
마이그레이션 필수. 이후 구 route는 410 반환.
```

**Auto-Clarity (압축 해제)**:
- Breaking change는 **반드시 body 포함** — subject-only 금지
- Security fix는 body에 이전 취약 조건 설명 필수
- Data migration은 rollback 절차 포함
- Revert commit은 왜 되돌리는지 body 필수

---

> **출처:** Commit message 규칙은 [JuliusBrussee/caveman](https://github.com/JuliusBrussee/caveman) (MIT)의 caveman-commit SKILL을 참고했으며, 한국어 특화 규칙을 추가했습니다.

**중요**: 이 압축 규칙은 **commit message에만** 적용된다. **PR 본문(Summary/Test plan), 문서, 팀 커뮤니케이션은 평소 문체 유지** — 사람이 읽는 영역이다.

---

# Integration vs Unit Tests

| Aspect | Unit Test | Integration Test |
|--------|-----------|------------------|
| Dependencies | All mocked | Real (mock only external boundaries) |
| Setup | Instantiate class directly | Bootstrap module/app context |
| Assertions | Return values, state | Observable system behavior |
| Speed | Milliseconds | Seconds (acceptable) |
| What to mock | Everything except SUT | Only things you don't own |

## When to Mock in Integration Tests

**Mock only what you don't own:**
- External HTTP APIs
- Third-party services (payment, email)
- System clock (time-dependent behavior)

**Never mock in integration tests:**
- Your own services, repositories, or modules
- Database connections (use a test database)
- Internal events or message passing

---

# Testing Anti-Patterns — DO NOT DO THESE

## Never test mock behavior

```typescript
// ❌ Testing that the mock exists
expect(screen.getByTestId('sidebar-mock')).toBeInTheDocument();

// ✅ Test real component behavior
expect(screen.getByRole('navigation')).toBeInTheDocument();
```

## Never add test-only methods to production classes

```typescript
// ❌ destroy() only used in tests
class Session {
  async destroy() { /* test cleanup */ }
}

// ✅ Test utilities handle cleanup
// In test-utils/
export async function cleanupSession(session: Session) { /* ... */ }
```

## Never mock without understanding dependencies

Before mocking any method:
1. What side effects does the real method have?
2. Does this test depend on any of those side effects?
3. If yes → mock at a lower level, not the method itself

## Never create incomplete mocks

Mock the COMPLETE data structure as it exists in reality, not just fields your immediate test uses.

## Warning Signs — Switch to Integration Test

- Mock setup is longer than test logic
- Mocking 3+ dependencies
- Mocks missing methods real components have
- Test breaks when mock interface changes

---

# Red Flags — STOP and Start Over

- Code before test
- Test after implementation
- Test passes immediately (you're testing existing behavior)
- Multiple failing tests at once (you wrote too many tests before GREEN)
- Can't explain why test failed
- "I already manually tested it"
- "I'll add tests later"
- "This is too simple to test"
- "TDD is slowing me down"

**All of these mean: delete code, start over with one failing test.**

---

# Scope Discipline

- Do not touch code outside the task's scope. No "while I'm here" fixes.
- If you spot something worth improving outside scope, propose it as a separate task.

# Code Quality

- Eliminate duplication ruthlessly
- Express intent through naming
- Make dependencies explicit
- Keep methods small, single responsibility
- Minimize state and side effects
- Use the simplest solution that could possibly work
