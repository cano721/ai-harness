# AI Harness - 에러 핸들링 & 복원력

## 문제 정의

하네스는 AI 에이전트의 모든 액션에 Hook을 개입시킨다. Hook 자체가 실패하면:
- 에이전트가 아무 것도 할 수 없는 **데드락** 발생
- 한 Hook의 실패가 다른 Hook으로 전파되는 **캐스케이딩 실패**
- 타임아웃으로 작업 흐름이 끊기는 **UX 저하**

이 문서는 하네스의 장애 대응 전략을 정의한다.

---

## 에러 분류

### 심각도 기준

| 레벨 | 분류 | 예시 | 기본 대응 |
|------|------|------|----------|
| **P0** | 하네스 자체 크래시 | Hook 브릿지 프로세스 죽음 | 바이패스 + 긴급 알림 |
| **P1** | 잠금 Hook 실패 | audit-logger 실행 불가 | 재시도 → 실패 시 차단 |
| **P2** | 일반 Hook 실패 | bundle-size 체크 타임아웃 | 경고 후 통과 |
| **P3** | 비핵심 기능 실패 | 비용 추적 집계 오류 | 로깅 후 무시 |

### 에러 유형

```
┌─────────────────────────────────────────────────────┐
│                  에러 유형 분류                        │
├─────────────────────────────────────────────────────┤
│                                                      │
│  실행 에러                                            │
│  ├── Hook 스크립트 not found                         │
│  ├── Hook 스크립트 실행 권한 없음                      │
│  ├── Hook 스크립트 런타임 에러 (exit code ≠ 0,2)      │
│  └── Hook 스크립트 비정상 출력                         │
│                                                      │
│  타임아웃                                             │
│  ├── 개별 Hook 타임아웃 (기본 10초)                    │
│  ├── Hook 체인 전체 타임아웃 (기본 30초)               │
│  └── 외부 의존성 타임아웃 (API, DB 등)                 │
│                                                      │
│  설정 에러                                            │
│  ├── config.yaml 파싱 실패                            │
│  ├── 잠금 정책 파일 손상                               │
│  └── 설정 패키지 로드 실패                             │
│                                                      │
│  환경 에러                                            │
│  ├── Node.js 미설치/버전 불일치                        │
│  ├── 디스크 공간 부족 (로그 저장 불가)                  │
│  └── 네트워크 불가 (원격 로깅 실패)                     │
│                                                      │
└─────────────────────────────────────────────────────┘
```

---

## Hook 실행 에러 처리

### 개별 Hook 에러 대응 플로우

```
Hook 실행
    │
    ├─ 정상 종료 (exit 0) → 통과
    ├─ 차단 (exit 2) → 차단 (정상 동작)
    │
    ├─ 에러 (exit 1, 그 외) → 에러 처리 진입
    │   │
    │   ├─ 잠금 Hook인가?
    │   │   ├─ YES → 재시도 (최대 2회)
    │   │   │   ├─ 재시도 성공 → 계속
    │   │   │   └─ 재시도 실패 → 🔴 차단 (fail-closed)
    │   │   │       └─ 사유: "보안 Hook 실행 불가, 안전을 위해 차단"
    │   │   │
    │   │   └─ NO → 경고 후 통과 (fail-open)
    │   │       └─ 감사 로그에 기록
    │   │
    │   └─ P0 에러 (프로세스 크래시)?
    │       └─ 비상 바이패스 + 긴급 알림
    │
    └─ 타임아웃 → 타임아웃 처리
        ├─ 잠금 Hook → 재시도 1회 → 실패 시 차단
        └─ 일반 Hook → 경고 후 통과
```

### fail-closed vs fail-open 정책

```yaml
# global/error-policy.yaml

hooks:
  # 잠금 Hook: fail-closed (실패 시 차단)
  locked:
    on_error: "block"
    retry_count: 2
    retry_delay_ms: 1000
    message: "보안 Hook 실행에 실패했습니다. 안전을 위해 작업을 차단합니다."

  # 일반 Hook: fail-open (실패 시 경고 후 통과)
  free:
    on_error: "warn_and_pass"
    retry_count: 0
    message: "Hook '{hook_name}' 실행에 실패했습니다. 경고와 함께 계속 진행합니다."

  # bounded Hook: 설정에 따라 선택
  bounded:
    on_error: "configurable"  # 프로젝트에서 block/warn_and_pass 선택
    default: "warn_and_pass"
```

---

## 타임아웃 설계

### 계층별 타임아웃

```
전체 Hook 체인 타임아웃: 30초
    │
    ├─ 개별 Hook 타임아웃: 10초 (기본)
    │   ├─ block-dangerous.sh:  5초 (빠른 패턴 매칭)
    │   ├─ audit-logger.sh:     5초
    │   ├─ secret-scanner.sh:   10초
    │   ├─ bundle-size.sh:      30초 (빌드 필요, 예외적 확장)
    │   └─ sql-review.sh:       15초
    │
    └─ 외부 호출 타임아웃: 5초
        ├─ 원격 로그 전송
        ├─ Teams 알림
        └─ MCP 서버 호출
```

### 타임아웃 설정

```yaml
# .ai-harness/config.yaml

timeouts:
  hook_chain_max_ms: 30000       # Hook 체인 전체
  hook_default_ms: 10000         # 개별 Hook 기본값
  hook_overrides:                # Hook별 커스텀
    bundle-size: 30000
    sql-review: 15000
  external_call_ms: 5000         # 외부 API 호출
  graceful_shutdown_ms: 3000     # 타임아웃 후 정리 시간
```

### 타임아웃 발생 시

```
[하네스] ⚠ Hook 'bundle-size' 타임아웃 (30초 초과)
  상태: 경고 후 통과 (free Hook)
  원인 추정: 빌드 시간이 길어졌을 수 있습니다
  조치: ai-harness config set timeouts.hook_overrides.bundle-size 60000
```

---

## 서킷 브레이커

특정 Hook이 반복적으로 실패하면 자동으로 비활성화한다.

### 동작 원리

```
┌──────────────────────────────────────────────────┐
│              서킷 브레이커 상태 머신                │
│                                                    │
│   CLOSED (정상)                                    │
│   └─ 연속 실패 ≥ 3회 → OPEN                       │
│                                                    │
│   OPEN (비활성화)                                   │
│   └─ 5분 경과 → HALF-OPEN                         │
│                                                    │
│   HALF-OPEN (시험)                                 │
│   ├─ 1회 성공 → CLOSED (복귀)                      │
│   └─ 1회 실패 → OPEN (다시 비활성화, 대기 시간 2배)  │
│                                                    │
└──────────────────────────────────────────────────┘
```

### 설정

```yaml
# .ai-harness/config.yaml

circuit_breaker:
  enabled: true
  failure_threshold: 3           # 연속 N회 실패 시 개방
  recovery_timeout_ms: 300000    # 5분 후 반개방 시도
  max_recovery_timeout_ms: 3600000  # 최대 1시간까지 백오프

  # 잠금 Hook은 서킷 브레이커 적용 불가
  # (잠금 Hook이 반복 실패하면 차단을 유지하고 관리자에게 알림)
  exclude_locked: true
```

### 서킷 브레이커 알림

```
[하네스] 🔴 서킷 브레이커 개방: Hook 'lighthouse'
  연속 실패: 3회
  마지막 에러: "Lighthouse binary not found"
  자동 복구 시도: 5분 후
  수동 복구: ai-harness hook reset lighthouse
```

---

## 캐스케이딩 방지

### Hook 격리 원칙

```
각 Hook은 독립적인 프로세스로 실행한다.

┌──────────┐  ┌──────────┐  ┌──────────┐
│ Hook A   │  │ Hook B   │  │ Hook C   │
│ (격리)   │  │ (격리)   │  │ (격리)   │
└────┬─────┘  └────┬─────┘  └────┬─────┘
     │             │             │
     ↓             ↓             ↓
  결과 A        결과 B        결과 C
     │             │             │
     └─────────────┼─────────────┘
                   ↓
            ┌──────────┐
            │ 결과 집계 │
            └──────────┘

- Hook A가 크래시해도 Hook B, C는 영향 없음
- 결과 집계에서 하나라도 "차단"이면 최종 차단
- 환경 변수, 파일 시스템 변경은 Hook 간 공유하지 않음
```

### 병렬 실행 옵션

```yaml
# 성능을 위해 독립적인 Hook은 병렬 실행 가능

hook_execution:
  pre_tool_use:
    # 순차 실행 (기본): 앞 Hook이 차단하면 뒤 Hook 실행 안 함
    strategy: "sequential"

    # 병렬 실행: 모든 Hook 동시 실행, 결과 집계
    # strategy: "parallel"

  post_tool_use:
    strategy: "parallel"         # Post Hook은 병렬 실행 안전
```

---

## 비상 바이패스 (Emergency Bypass)

하네스 자체가 완전히 고장난 극단적 상황을 위한 탈출구.

### 바이패스 방법

```bash
# 방법 1: 환경 변수 (현재 세션만)
$ HARNESS_BYPASS=true claude

# 방법 2: CLI 명령
$ ai-harness bypass --reason "Hook 브릿지 크래시, 긴급 배포 필요"

# 방법 3: 설정 파일
# .ai-harness/config.yaml에 bypass: true 추가 (임시)
```

### 바이패스 제약

```
바이패스 시에도:
✅ 감사 로그는 기록된다 (별도 경로로 기록 시도)
✅ 바이패스 사유가 로깅된다
✅ 바이패스 시작/종료 시간이 기록된다
✅ 바이패스 시작 즉시 관리자에게 알림 전송
❌ 잠금 Hook도 비활성화됨 (의도적)
🔒 최대 1시간 후 자동 만료 (하드코딩, 설정 변경 불가)
```

### 바이패스 자동 만료

```yaml
bypass:
  max_duration_minutes: 60       # 하드코딩, 설정으로 변경 불가
  auto_expire: true              # 1시간 후 자동 해제
  on_expire: "restore_all_hooks" # 만료 시 모든 Hook 복원
  notify_on_start: true          # 시작 즉시 관리자 알림 (1시간 후가 아님)
```

### 에이전트의 바이패스 악용 차단

에이전트가 Bash 도구로 `HARNESS_BYPASS` 환경변수를 설정하거나, `ai-harness bypass` 명령을 직접 호출하는 것을 차단한다.

```bash
# block-dangerous.sh에 추가되는 패턴
if echo "$TOOL_INPUT" | grep -qE 'HARNESS_BYPASS|ai-harness\s+bypass|ai-harness\s+hook\s+disable'; then
  echo "BLOCKED: 에이전트의 하네스 비활성화 시도가 차단되었습니다."
  exit 2
fi
```

이 차단은 잠금(locked) 정책으로, 프로젝트 레벨에서 해제할 수 없다.

### 바이패스 감사 로그

```json
{
  "timestamp": "2026-03-18T14:32:15Z",
  "event_type": "bypass",
  "action": "bypass_start",
  "reason": "Hook 브릿지 크래시, 긴급 배포 필요",
  "user": "khb1122",
  "bypass_method": "cli",
  "all_hooks_disabled": true
}
```

---

## 설정 에러 복원

### config.yaml 파싱 실패

```
$ claude

  [하네스] ❌ 설정 파일 파싱 실패: .ai-harness/config.yaml
  에러: YAML 문법 오류 (line 23, column 5)

  복구 옵션:
  1. 마지막 정상 설정으로 복원 (2026-03-17 백업)
  2. 기본값으로 초기화
  3. 하네스 없이 계속 (이번 세션만)

  선택: _
```

### 자동 백업

```
설정 변경 시마다 이전 설정을 자동 백업한다.

.ai-harness/
├── config.yaml              # 현재 설정
├── backups/
│   ├── config.2026-03-18T14:00:00.yaml
│   ├── config.2026-03-17T09:30:00.yaml
│   └── config.2026-03-16T11:15:00.yaml   # 최대 10개 보존
```

---

## 모니터링 & 알림

### Hook 건강도 대시보드

```bash
$ ai-harness health

  ━━━ Hook 건강도 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Hook                상태         성공률    평균 시간
  ─────────────────────────────────────────────────
  block-dangerous     ✅ CLOSED    100%     2ms
  audit-logger        ✅ CLOSED    99.8%    8ms
  secret-scanner      ✅ CLOSED    99.5%    45ms
  bundle-size         ⚠ HALF-OPEN  85%     12500ms
  sql-review          ✅ CLOSED    97%      230ms
  lighthouse          🔴 OPEN      0%       타임아웃

  서킷 브레이커 개방: 1개 (lighthouse)
  최근 24시간 에러: 7건
```

### 관리자 알림 트리거

| 이벤트 | 알림 대상 | 채널 |
|--------|----------|------|
| 잠금 Hook 연속 실패 3회 | 하네스 관리자 | Teams/Slack 즉시 |
| 서킷 브레이커 개방 | 팀 채널 | Teams/Slack |
| 비상 바이패스 시작 | 하네스 관리자 | Teams/Slack 즉시 |
| 바이패스 1시간 초과 | 하네스 관리자 + 보안팀 | Teams/Slack |
| 설정 파일 손상 | 해당 사용자 | CLI 메시지 |
