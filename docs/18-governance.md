# AI Harness - 거버넌스 모델

## 관리 조직

### 역할 정의

| 역할 | 인원 | 책임 |
|------|------|------|
| **Harness Owner** | 1명 (DevOps/Platform팀) | 전체 방향, 잠금 정책, 릴리즈 승인 |
| **Team Champion** | 팀당 1명 | 팀 규칙 관리, 팀원 지원, 피드백 수집 |
| **Contributor** | 누구나 | 규칙/Hook/Skill 제안 및 PR |

### 조직 구조

```
Harness Owner (1명)
├── Team Champion: 기획팀
├── Team Champion: 디자인팀
├── Team Champion: FE팀
├── Team Champion: BE팀
├── Team Champion: QA팀
├── Team Champion: DevOps팀
└── Contributors (전 직원)
```

---

## 규칙 변경 프로세스 (RFC)

### 변경 유형별 프로세스

| 변경 유형 | 프로세스 | 승인자 | 리드타임 |
|----------|---------|--------|---------|
| **잠금 정책 변경** | RFC → 전체 리뷰 → Owner 승인 | Harness Owner + 보안팀 | 2주 |
| **Global 규칙 변경** | RFC → 리뷰 → Owner 승인 | Harness Owner | 1주 |
| **팀 규칙 변경** | PR → Champion 리뷰 | Team Champion | 2~3일 |
| **버그 수정/오탈자** | PR → 리뷰어 1명 | 아무 Contributor | 1일 |
| **보안 패치** | 긴급 PR → Owner 즉시 승인 | Harness Owner | 즉시 |

### RFC 템플릿

```markdown
# RFC: [제목]

## 배경
왜 이 변경이 필요한가?

## 제안
무엇을 변경하는가?

## 영향 범위
- 영향받는 팀: [전체 / 특정 팀]
- 기존 프로젝트 호환성: [호환 / 마이그레이션 필요]
- 잠금 정책 변경 여부: [예 / 아니오]

## 대안
검토한 다른 방법과 선택하지 않은 이유

## 롤아웃 계획
Canary → Early Adopter → GA 일정
```

### 의사결정 매트릭스

```
변경 요청 도착
    │
    ├─ 잠금(locked) 관련?
    │   ├─ YES → RFC 필수, Owner + 보안팀 승인
    │   └─ NO ↓
    │
    ├─ Global 레이어?
    │   ├─ YES → RFC 권장, Owner 승인
    │   └─ NO ↓
    │
    ├─ Team 레이어?
    │   ├─ YES → PR, Champion 승인
    │   └─ NO ↓
    │
    └─ 문서/오탈자 → PR, 리뷰어 1명
```

---

## 피드백 루프

### 수집 채널

| 채널 | 용도 | 주기 |
|------|------|------|
| **GitHub Issues** | 버그 리포트, 기능 요청 | 상시 |
| **월간 서베이** | 만족도, 불편사항, 개선 제안 | 월 1회 |
| **Champion 미팅** | 팀별 현황 공유, 우선순위 조율 | 격주 |
| **감사 로그 분석** | 차단률, 에러율, 사용 패턴 | 주 1회 자동 |

### 개선 사이클

```
수집 (Issues + 서베이 + 로그 분석)
    ↓
분석 (Champion 미팅에서 우선순위 결정)
    ↓
실행 (RFC/PR → 리뷰 → 머지)
    ↓
검증 (Canary → GA)
    ↓
측정 (메트릭 변화 확인)
    ↓
(다음 사이클)
```

---

## 규칙 수명 관리

### Deprecation 프로세스

```
1. 규칙에 @deprecated 태그 추가 + 대체 규칙 안내
2. 2주간 경고 메시지 표시 (Hook에서)
3. 다음 minor 버전에서 제거
4. 제거 후에도 1 버전 동안 마이그레이션 가이드 유지
```

### 규칙 효과 측정

```yaml
# 규칙별 메타데이터
rules:
  no-console-log:
    added: "2026-01-15"
    author: "khb1122"
    reason: "프로덕션에 console.log 잔류 방지"
    effectiveness:
      blocked_count_30d: 47       # 최근 30일 차단 횟수
      false_positive_rate: 2.1%   # 오탐률
    status: "active"              # active / deprecated / removed
```
