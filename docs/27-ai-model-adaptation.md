# AI Harness - AI 모델 변화 대응

## 문제 정의

AI 모델은 빠르게 진화한다:

| 변화 유형 | 예시 | 하네스 영향 |
|----------|------|-----------|
| **모델 업그레이드** | Claude 4 → Claude 5 | 행동 패턴 변화, 새 기능 등장 |
| **프롬프트 해석 변화** | 같은 CLAUDE.md를 다르게 해석 | 규칙 준수율 변동 |
| **도구 사용 패턴 변화** | 도구 호출 빈도/방식 변경 | Hook 오탐률 변동 |
| **새 에이전트 등장** | 새로운 AI 코딩 도구 출시 | 어댑터 추가 필요 |
| **비용 구조 변경** | 토큰 가격 인상/인하, 새 과금 모델 | 비용 추적 조정 |

하네스가 특정 모델 버전에 하드코딩되면 모델이 바뀔 때마다 깨진다.

---

## 설계 원칙

```
1. 모델에 독립적인 설계 (Model-Agnostic)
   - 특정 모델의 행동을 가정하지 않는다
   - 규칙은 "무엇을 하지 마라"가 아닌 "이런 패턴이면 차단"

2. 행동 기반 검증 (Behavior-Based)
   - "Claude가 이렇게 응답할 것이다"가 아닌
   - "도구 호출이 이 패턴이면 위험하다"

3. 점진적 적응 (Gradual Adaptation)
   - 모델 변경 시 즉시 enforce가 아닌
   - observe → warn → enforce 단계적 전환
```

---

## 모델 변경 시 대응 플로우

```
새 모델 출시 (예: Claude 5)
    ↓
[Phase 1: 감지]
하네스가 모델 버전 변경을 자동 감지
    ↓
[Phase 2: 관찰]
1주간 observe 모드로 전환
- Hook 오탐률 모니터링
- 규칙 준수율 변화 추적
- 도구 사용 패턴 비교
    ↓
[Phase 3: 분석]
자동 리포트 생성
- 이전 모델 대비 변화 분석
- 조정 필요 항목 도출
    ↓
[Phase 4: 조정]
규칙/Hook 조정 후 enforce 복귀
```

### 자동 감지

```yaml
# Hook에서 모델 버전 추적
# 감사 로그에 모델 정보 기록

{
  "event_type": "model_change",
  "previous_model": "claude-sonnet-4-6",
  "new_model": "claude-sonnet-5-0",
  "timestamp": "2026-06-01T00:00:00Z",
  "action": "observe_mode_activated"
}
```

### 모델 전환 리포트

```bash
$ ai-harness model report

  ━━━ 모델 전환 리포트 ━━━━━━━━━━━━━━━━━━━━━━━━━

  이전: claude-sonnet-4-6 (30일간 데이터)
  현재: claude-sonnet-5-0 (7일간 관찰)

  [Hook 오탐률 비교]
  block-dangerous:  2.1% → 1.8% (개선)
  secret-scanner:   0.5% → 3.2% (악화 ⚠)
    → 새 모델이 .env.example을 더 자주 참조
    → allowlist 조정 권장
  sql-review:       1.0% → 0.8% (개선)

  [도구 사용 패턴 변화]
  Read 호출:        -12% (더 효율적으로 읽음)
  Bash 호출:        +8% (명령 분할 경향)
  Edit 호출:        +15% (한번에 많이 수정 대신 작은 단위)

  [비용 변화]
  토큰 효율:        +18% (같은 작업에 토큰 덜 사용)
  평균 세션 비용:    $4.12 → $3.38 (-18%)

  [권장 조정]
  1. secret-scanner allowlist에 .env.example 추가
  2. max_files_changed 25로 상향 (Edit 빈도 증가 반영)
  3. cost-rates.yaml 업데이트 (새 모델 가격)
```

---

## 모델 독립적 Hook 설계

### 좋은 예: 패턴 기반 (모델 무관)

```bash
# 도구 입력값의 패턴만 검사 — 어떤 모델이든 동작
if echo "$TOOL_INPUT" | grep -qE 'rm\s+(-[a-zA-Z]*f|-[a-zA-Z]*r){2}'; then
  echo "BLOCKED: rm -rf"
  exit 2
fi
```

### 나쁜 예: 모델 행동 가정

```bash
# ❌ "Claude는 항상 이렇게 호출한다"고 가정
# 모델이 바뀌면 깨질 수 있음
if echo "$TOOL_INPUT" | grep -q "I'll help you"; then
  # 모델 응답 패턴에 의존 — 모델마다 다름
fi
```

---

## 비용 구조 변경 대응

### 자동 가격 업데이트

```yaml
# global/cost-rates.yaml

# 모델별 가격 (중앙 관리)
rates:
  claude-opus-4-6:
    input_per_million: 15.00
    output_per_million: 75.00
  claude-sonnet-4-6:
    input_per_million: 3.00
    output_per_million: 15.00

  # 새 모델 추가 시 이 파일만 업데이트
  claude-sonnet-5-0:
    input_per_million: 3.00
    output_per_million: 15.00

# 미등록 모델 처리
unknown_model:
  fallback_rate:
    input_per_million: 10.00     # 보수적으로 높게 설정
    output_per_million: 50.00
  alert: true                    # 관리자에게 알림
```

### 새 모델 감지 시

```
[하네스] ⚠ 미등록 모델 감지: claude-opus-5-0
  현재 보수적 요금($10/$50 per 1M)으로 추적 중.
  정확한 비용 추적을 위해:
  $ ai-harness update   (cost-rates.yaml 업데이트)
```

---

## 프롬프트 드리프트 대응

### 프롬프트 드리프트란?

모델 업데이트 후 같은 CLAUDE.md 규칙을 다르게 해석하는 현상.

```
예시:
규칙: "프로덕션 코드에서 console.log 금지"

Claude 4: console.log를 거의 사용하지 않음 (규칙 준수)
Claude 5: console.log 대신 console.info를 사용 (규칙의 "정신"은 위반)
```

### 대응: 규칙 명확화 가이드라인

```markdown
# CLAUDE.md 규칙 작성 가이드

## 좋은 규칙 (구체적, 모델 무관)
- "console.log, console.info, console.warn, console.debug를 프로덕션 코드에서 사용하지 마라. __tests__/ 디렉토리는 예외."
- "SQL 쿼리에서 문자열 결합(+, concat, f-string) 대신 파라미터 바인딩(?, :param)을 사용하라."

## 나쁜 규칙 (모호, 모델 해석에 의존)
- "불필요한 로깅을 하지 마라"  ← "불필요"의 기준이 모델마다 다름
- "보안에 주의하라"  ← 너무 추상적
```

### 규칙 효과 모니터링

```bash
$ ai-harness rules effectiveness

  규칙                    준수율 (4주)   트렌드
  ─────────────────────────────────────────
  no-console-log          97.2%         stable
  sql-param-binding       99.1%         stable
  dto-separation          88.5%         ↓ declining  ⚠
  test-coverage-80        92.3%         ↑ improving

  ⚠ dto-separation 준수율이 하락 중입니다.
  → 규칙 문구를 더 구체적으로 개선하거나
  → PostToolUse Hook으로 자동 검증을 추가하세요.
```

---

## 새 에이전트 대응

14번 문서(멀티 에이전트 추상화)의 어댑터 패턴에 따라:

```
새 에이전트 출시
    ↓
Tier 판단
    ├─ Hook 지원? → Tier 1~2
    └─ 컨텍스트만? → Tier 3
    ↓
어댑터 구현
    ↓
커뮤니티 또는 공식 배포
    $ ai-harness adapter install @community/new-agent-adapter
```

---

## 버전 호환 매트릭스 업데이트

```yaml
# 모델 변경 시 자동 테스트 실행

model_compat_tests:
  on_model_change:
    - "hook_false_positive_rate < 5%"
    - "hook_false_negative_rate == 0%"
    - "rule_compliance_rate > 85%"
    - "avg_session_cost_change < 50%"

  if_failed:
    action: "observe_mode"
    notify: "harness_owner"
    duration_days: 7
```
