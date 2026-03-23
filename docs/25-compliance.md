# AI Harness - 컴플라이언스 & 데이터 거버넌스

## 문제 정의

하네스의 감사 로그에는 다음이 포함될 수 있다:

| 데이터 | 예시 | 민감도 |
|--------|------|--------|
| 사용자 식별자 | khb1122, 이메일 | 개인정보 |
| 코드 내용 | 파일 내용 스니펫 | 영업비밀 |
| API 호출 내용 | curl 명령의 URL, 헤더 | 자격증명 |
| 프로젝트 구조 | 파일 경로, 디렉토리명 | 내부 정보 |
| AI 프롬프트/응답 | 사용자 요청 내용 | 혼합 |

이를 관리하지 않으면 개인정보보호법, GDPR, 사내 보안 정책에 위반될 수 있다.

---

## 적용 법규 & 정책

### 주요 규제

| 규제 | 적용 조건 | 핵심 요구사항 |
|------|----------|-------------|
| **개인정보보호법 (한국)** | 한국 내 사용 시 | 수집 목적 명시, 보유 기간 제한, 삭제 권리 |
| **GDPR (EU)** | EU 직원/고객 데이터 포함 시 | 합법적 근거, 데이터 최소화, 삭제 요청 대응 |
| **사내 보안 정책** | 항상 | 데이터 분류, 접근 통제, 보존 정책 |

### 하네스에서의 대응

```
규제 요구사항               →   하네스 대응
───────────────────────────────────────────
수집 목적 명시              →   감사 로그 수집 목적 문서화
데이터 최소화               →   필요 최소한의 정보만 로깅
보유 기간 제한              →   자동 삭제 정책 (기본 30일)
삭제 요청 대응              →   사용자별 로그 삭제 CLI
접근 통제                  →   로그 파일 권한 제한
민감 정보 보호              →   자동 마스킹 (10번 문서 확장)
```

---

## 데이터 분류 체계

### 감사 로그 내 데이터 등급

```
┌──────────────────────────────────────────────────┐
│ Level 4: 극비 (Restricted)                        │
│  - 절대 로깅 금지                                  │
│  - 비밀번호, 개인키, 인증 토큰 평문                  │
│  - 주민등록번호, 카드번호                            │
├──────────────────────────────────────────────────┤
│ Level 3: 기밀 (Confidential)                      │
│  - 마스킹 후 로깅                                  │
│  - API 키, DB 연결 문자열                           │
│  - 이메일, 전화번호                                 │
│  - 소스코드 내용 (스니펫)                            │
├──────────────────────────────────────────────────┤
│ Level 2: 내부 (Internal)                          │
│  - 로깅 허용, 외부 전송 시 주의                      │
│  - 파일 경로, 프로젝트 구조                          │
│  - 사용자 ID (사번/계정명)                           │
│  - 도구 사용 패턴                                   │
├──────────────────────────────────────────────────┤
│ Level 1: 공개 (Public)                            │
│  - 자유 로깅                                       │
│  - 타임스탬프, Hook 이름, 결과(pass/block)           │
│  - 하네스 버전, 팀 프로필명                          │
└──────────────────────────────────────────────────┘
```

### 등급별 처리 규칙

```yaml
# global/guardrails/data-classification.yaml

classification:
  level_4_restricted:
    action: "never_log"
    patterns:
      - '(?i)password\s*[=:]\s*["\'][^"\']+["\']'
      - '\b\d{6}-\d{7}\b'          # 주민등록번호
      - '\b\d{4}[\s-]?\d{4}[\s-]?\d{4}[\s-]?\d{4}\b'  # 카드번호
      - '-----BEGIN.*PRIVATE KEY-----'

  level_3_confidential:
    action: "mask_then_log"
    patterns:
      - 'AKIA[0-9A-Z]{16}'         # AWS Key
      - '(?i)bearer\s+[A-Za-z0-9._~+/=-]+'
      - '[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}'

  level_2_internal:
    action: "log_locally"
    retention_days: 30

  level_1_public:
    action: "log_freely"
```

---

## 마스킹 정책

### 자동 마스킹 엔진

```
로그 기록 전 파이프라인:

원본 데이터
    ↓
[Level 4 스캔] → 매칭 시 해당 필드 자체 삭제
    ↓
[Level 3 스캔] → 매칭 시 마스킹 처리
    ↓
[크기 제한] → 200자 초과 내용 truncate
    ↓
마스킹된 로그 저장
```

### 마스킹 예시

```json
// 마스킹 전
{
  "action": "curl -H 'Authorization: Bearer eyJhbGc...' https://api.company.com/users",
  "metadata": {
    "file_content": "DB_PASSWORD=SuperSecret123\nDB_HOST=prod-db.company.com"
  }
}

// 마스킹 후
{
  "action": "curl -H 'Authorization: Bearer ***REDACTED***' https://api.company.com/users",
  "metadata": {
    "file_content": "DB_PASSWORD=***REDACTED_L4***\nDB_HOST=***REDACTED_L3***"
  }
}
```

---

## 데이터 보존 & 삭제

### 보존 정책

```yaml
# .ai-harness/config.yaml

compliance:
  retention:
    local_logs:
      default_days: 30           # 정본: 10-audit-logging.md 참조
      min_days: 7                # 최소 7일 (bounded)
      max_days: 365              # 최대 365일

    remote_logs:
      policy: "company_standard" # 회사 표준 정책 따름

  # 자동 삭제
  auto_purge:
    enabled: true
    schedule: "daily"            # 매일 자정에 실행
    dry_run: false
```

### 삭제 요청 대응

```bash
# 특정 사용자의 로그 삭제 (GDPR 삭제권)
$ ai-harness compliance purge-user --user "khb1122" --confirm
  ✔ 로컬 로그에서 khb1122 관련 142건 삭제
  ✔ 삭제 이력 기록 (삭제한 사실만 기록, 내용은 비복원)

# 특정 기간 로그 삭제
$ ai-harness compliance purge --before 2026-01-01 --confirm

# 삭제 이력 확인
$ ai-harness compliance purge-history
  2026-03-18: user purge (khb1122) - 142건
  2026-03-01: date purge (before 2025-12-01) - 3,420건
```

---

## 접근 통제

### 로그 파일 권한

```
.ai-harness/logs/
├── 2026-03-18.jsonl     # 파일 권한: 600 (소유자만 읽기/쓰기)
├── 2026-03-17.jsonl.gz  # 압축 파일도 동일
```

```bash
# init 시 자동 설정
chmod 700 .ai-harness/logs/
chmod 600 .ai-harness/logs/*.jsonl
```

### 원격 전송 시 암호화

```yaml
compliance:
  remote:
    encryption: "tls_1_3"        # 전송 중 암호화
    at_rest_encryption: true     # 저장 시 암호화 (원격 서버 책임)
```

---

## 동의 & 고지

### 하네스 설치 시 동의

```
$ ai-harness init

  ━━━ 데이터 수집 동의 ━━━━━━━━━━━━━━━━━━━━━━━━━

  AI Harness는 다음 데이터를 수집합니다:

  [수집 항목]
  • AI 에이전트의 도구 사용 기록 (도구명, 결과, 시간)
  • Hook 차단/경고 이력
  • 비용 추적 정보 (토큰 수, 모델명)
  • 사용자 ID (계정명)

  [수집하지 않는 항목]
  • 코드 내용 전체 (스니펫만 truncate하여 기록)
  • 비밀번호, 인증 토큰 (자동 마스킹)
  • AI 프롬프트/응답 전문

  [보존 기간]
  • 로컬: 30일 (설정 변경 가능)
  • 원격: 회사 정책에 따름

  [삭제 요청]
  • ai-harness compliance purge-user로 언제든 삭제 가능

  동의하시겠습니까? (Y/n): _
```

---

## 컴플라이언스 감사 리포트

```bash
$ ai-harness compliance report

  ━━━ 컴플라이언스 리포트 ━━━━━━━━━━━━━━━━━━━━━━

  [데이터 보존]
  ✔ 보존 기간: 30일
  ✔ 만료 로그 자동 삭제: 활성
  ✔ 최근 삭제: 2026-03-17 (28건)

  [마스킹]
  ✔ Level 4 패턴: 12개 등록
  ✔ Level 3 패턴: 8개 등록
  ✔ 마스킹 적용률: 100%
  ⚠ 최근 7일 마스킹 건수: 23건 (시크릿 노출 시도)

  [접근 통제]
  ✔ 로그 파일 권한: 600
  ✔ 로그 디렉토리 권한: 700

  [삭제 요청 이력]
  최근 삭제 요청: 없음

  결과: 컴플라이언스 준수 ✅
```
