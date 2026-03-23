# AI Harness - 성능 벤치마크 & 최적화

## 성능 목표

| 항목 | 목표 (p95) | 한계 | 근거 |
|------|-----------|------|------|
| **전체 Hook 체인 (Pre)** | < 200ms | < 500ms | 사용자 체감 지연 임계값 |
| **전체 Hook 체인 (Post)** | < 500ms | < 2s | Post는 비동기 가능 |
| **개별 Hook (경량)** | < 10ms | < 50ms | 패턴 매칭 수준 |
| **개별 Hook (중량)** | < 500ms | < 2s | 빌드/분석 수반 |
| **설정 로드** | < 100ms | < 300ms | 세션 시작 시 1회 |
| **감사 로그 쓰기** | < 5ms | < 20ms | 매 액션마다 |

---

## 벤치마크 도구

### CLI 벤치마크

```bash
# 전체 벤치마크 실행
$ ai-harness perf benchmark

  ━━━ 성능 벤치마크 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  [Hook 실행 시간] (100회 반복 측정)

  Hook              p50     p95     p99     max     상태
  ────────────────────────────────────────────────────
  block-dangerous   1ms     3ms     5ms     8ms     ✅
  audit-logger      4ms     8ms     12ms    18ms    ✅
  secret-scanner    22ms    45ms    78ms    120ms   ✅
  sql-review        150ms   280ms   450ms   800ms   ✅
  bundle-size       5.2s    12s     18s     25s     🔴
  api-compat        80ms    150ms   220ms   350ms   ✅

  [설정 로드]
  config 파싱:      12ms
  설정 병합:        8ms
  잠금 정책 검증:    3ms
  전체:             23ms    ✅

  [감사 로그 쓰기]
  단건 쓰기:        0.8ms
  배치 (10건):      2.1ms   ✅

  [전체 Hook 체인]
  PreToolUse:       p95 = 58ms   ✅ (목표: < 200ms)
  PostToolUse:      p95 = 310ms  ✅ (목표: < 500ms)

  ━━━ 결과: 5/6 Hook 목표 달성, 1개 개선 필요 ━━━
```

### 개별 Hook 프로파일링

```bash
# 특정 Hook 상세 분석
$ ai-harness perf profile secret-scanner

  ━━━ secret-scanner 프로파일 ━━━━━━━━━━━━━━━━━

  실행 단계:
  1. 입력 파싱:          0.5ms
  2. Level 4 패턴 검사:  8ms   (12개 패턴)
  3. Level 3 패턴 검사:  15ms  (8개 패턴)
  4. 파일명 패턴 검사:   2ms   (5개 패턴)
  5. allowlist 확인:     1ms
  6. 결과 출력:          0.5ms
  ─────────────────────
  합계:                  27ms

  병목: Level 3 패턴 검사 (복잡한 정규식)

  최적화 제안:
  • 정규식 사전 컴파일 (-40% 예상)
  • 빈도 높은 패턴을 앞으로 정렬 (-15% 예상)
```

### 비교 벤치마크 (하네스 유/무)

```bash
$ ai-harness perf compare

  ━━━ 하네스 유/무 비교 ━━━━━━━━━━━━━━━━━━━━━━━

  시나리오: "package.json 읽고 수정하기"

  하네스 없음:
    Read:  즉시 → 응답 시작
    Edit:  즉시 → 응답 시작

  하네스 있음:
    Read:  +12ms (Pre Hook) → 응답 시작 → +3ms (Post Hook)
    Edit:  +58ms (Pre Hook) → 응답 시작 → +45ms (Post Hook)

  총 오버헤드: ~118ms / 작업
  체감 영향: 미미 (에이전트 사고 시간 2-10초 대비)
```

---

## 실시간 모니터링

### 세션 중 성능 확인

```bash
# 현재 세션의 Hook 성능 통계
$ ai-harness perf live

  ━━━ 실시간 성능 (이번 세션) ━━━━━━━━━━━━━━━━━

  총 Hook 실행: 142회
  평균 지연:    35ms
  최대 지연:    280ms
  서킷 브레이커: 0개 OPEN

  가장 느린 호출 TOP 3:
  1. sql-review    280ms  (Bash: "SELECT * FROM...")
  2. secret-scanner 120ms (Write: config.yaml)
  3. sql-review    195ms  (Bash: "INSERT INTO...")
```

### 일별 성능 추적

```bash
$ ai-harness perf trend --days 7

  날짜        Hook 호출  평균     p95     에러율
  ──────────────────────────────────────────────
  03-18       856       32ms    120ms   0.2%
  03-17       723       35ms    135ms   0.1%
  03-16       912       31ms    118ms   0.0%
  03-15       645       38ms    145ms   0.5%  ⚠
  03-14       801       33ms    125ms   0.1%
  03-13       756       34ms    128ms   0.2%
  03-12       689       36ms    140ms   0.1%

  트렌드: 안정적 ✅
```

---

## 최적화 기법

### 1. Hook 캐싱

```yaml
# 같은 입력에 대한 반복 검사 캐싱
hooks:
  secret-scanner:
    cache:
      enabled: true
      ttl_seconds: 300           # 5분 캐시
      max_entries: 1000
      key: "tool_name + input_hash"
```

```
예시: 같은 파일을 여러 번 읽을 때
1회차: secret-scanner 실행 (45ms)
2회차: 캐시 히트 (0.5ms)
```

### 2. 도구별 Hook 최소화

> **주의**: `audit-logger`는 hook_routing과 무관하게 **항상 실행**된다 (잠금 정책, 10-audit-logging.md 참조). 아래 라우팅에서 audit-logger를 생략해도 감사 로깅은 별도 경로로 실행된다.

```yaml
# 모든 도구에 모든 Hook을 실행할 필요 없음
# ※ audit-logger는 라우팅 대상이 아님 (항상 실행)
hook_routing:
  Read:                          # 읽기는 경량 검사만
    pre: ["block-dangerous"]     # 위험 경로 차단만
    post: []                     # Post 불필요 (감사 로깅은 별도)

  Grep:
    pre: []                      # 검색은 Pre 불필요
    post: []                     # (감사 로깅은 별도)

  Write:                         # 쓰기는 전체 검사
    pre: ["block-dangerous", "secret-scanner"]
    post: ["lint-check"]

  Edit:
    pre: ["block-dangerous", "secret-scanner"]
    post: ["lint-check"]

  Bash:                          # Bash는 가장 위험 → 전체
    pre: ["block-dangerous", "secret-scanner", "sql-review"]
    post: []
```

### 3. 비동기 Post Hook

```yaml
# 즉시 결과가 불필요한 Post Hook은 비동기 실행
hooks:
  bundle-size:
    async: true                  # 백그라운드 실행
    notify_on_issue: true        # 문제 시 다음 프롬프트에서 알림

  audit-logger:
    async: false                 # 감사 로깅은 동기 (데이터 손실 방지)
    batch: true                  # 단, 배치로 모아서 쓰기
    batch_size: 10
    flush_interval_ms: 5000
```

### 4. 정규식 최적화

```
느린 패턴:
  (?i)(api[_-]?key|apikey|api[_-]?secret)\s*[=:]\s*['"][A-Za-z0-9]{16,}

빠른 패턴 (2단계 필터링):
  1단계: 빠른 문자열 검색 — "api" 포함 여부 (< 0.1ms)
  2단계: 1단계 통과 시에만 정규식 실행 (< 5ms)

→ 대부분의 입력은 1단계에서 걸러져 정규식 실행 불필요
```

### 5. 웜업 (Cold Start 방지)

```
세션 시작 시:
1. 설정 파일 로드 & 파싱 (1회)
2. Hook 스크립트 존재 확인 (1회)
3. 정규식 사전 컴파일 (1회)
4. 캐시 초기화 (1회)

→ 첫 도구 호출 전에 완료
→ 이후 호출은 웜 상태로 빠르게 실행
```

---

## 성능 예산 (Performance Budget)

```yaml
# global/performance-budget.yaml

budget:
  # Hook 체인 전체
  pre_tool_use_chain:
    target_p95_ms: 200
    alert_p95_ms: 500
    max_p95_ms: 1000             # 이 이상이면 서킷 브레이커 고려

  # 개별 Hook
  individual_hook:
    lightweight:                 # block-dangerous, audit-logger
      target_p95_ms: 10
      max_p95_ms: 50
    standard:                    # secret-scanner, sql-review
      target_p95_ms: 200
      max_p95_ms: 500
    heavy:                       # bundle-size, lighthouse
      target_p95_ms: 5000
      max_p95_ms: 30000
      require_async: true        # 반드시 비동기

  # 감사 로그 쓰기
  audit_write:
    target_p95_ms: 5
    max_p95_ms: 20

# 예산 초과 시 알림
on_budget_exceeded:
  action: "alert"
  notify: "harness_owner"
  auto_actions:
    - "서킷 브레이커 후보로 등록"
    - "ai-harness perf profile <hook> 자동 실행"
```

---

## CI에서 성능 회귀 방지

```yaml
# .github/workflows/perf-test.yml

name: Performance Regression
on: [pull_request]
jobs:
  perf:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: npm ci
      - run: npm run perf:benchmark
      - run: |
          # 성능 예산 초과 시 PR 실패
          npm run perf:check-budget
          # p95가 목표의 150% 이상이면 실패
```
