# AI Harness - 크로스팀 워크플로우

## 기능 개발 파이프라인

```
┌─────────┐    ┌─────────┐    ┌──────────────┐    ┌─────────┐
│  기획    │ →  │  디자인  │ →  │  개발 (FE+BE) │ →  │  QA     │ → 배포
│ planning │    │ design  │    │  FE | BE     │    │  qa     │
└─────────┘    └─────────┘    └──────────────┘    └─────────┘
```

## 단계별 핸드오프

### A: 기획 → 디자인

산출물: PRD, Jira 이슈, 유저 스토리. Jira 상태를 "디자인 대기"로 변경 또는 `/handoff design`.

### B: 디자인 → 개발

산출물: Figma 링크, 디자인 토큰, 컴포넌트 스펙, 접근성 결과. `/handoff dev`.

### C: 개발 (FE + BE 병렬)

FE 트랙: 디자인 토큰 적용 → 컴포넌트 → 페이지 → API 연동 → E2E
BE 트랙: API 설계 → Entity/DTO → 비즈니스 로직 → 마이그레이션 → 테스트
통합: 통합 테스트 → 코드 리뷰 → PR 생성

### D: QA → 배포

AC 기반 시나리오 → 자동/수동 테스트 → 버그 시 Phase C 회귀 → QA 승인 → 배포

## 승인 게이트

| 유형 | 설명 |
|------|------|
| **자동 통과** | 테스트 전부 통과, lint 클린 |
| **자동 차단** | 보안 취약점 발견, 테스트 실패 |
| **수동 승인** | 코드 리뷰, PM 기획 확인 |

## 핸드오프 데이터

```yaml
# .ai-harness/handoffs/PROJ-100.yaml
issue_key: "PROJ-100"
current_phase: "development"
history:
  - phase: "planning"
    completed_at: "2026-03-15T10:00:00Z"
    artifacts:
      prd_page_id: "12345"
  - phase: "design"
    completed_at: "2026-03-16T15:00:00Z"
    artifacts:
      figma_url: "https://figma.com/file/..."
```

## /handoff 스킬 정의

`/handoff`는 **Global 스킬**로, 모든 팀에서 사용 가능하다. 특정 팀에 속하지 않고 `global/skills/handoff.md`에 정의된다.

### 동작 정의

```
/handoff <target_phase>

입력:
  - target_phase: 다음 단계 (design | dev | qa | deploy)
  - 현재 단계의 산출물이 .ai-harness/handoffs/ 에 기록되어 있어야 함

처리:
  1. 현재 단계 산출물 검증 (필수 아티팩트 존재 확인)
  2. 핸드오프 데이터 생성 (.ai-harness/handoffs/{issue_key}.yaml)
  3. Jira 이슈 상태 변경 (예: "디자인 대기", "개발 대기")
  4. Teams/Slack 알림 전송 (다음 단계 담당 팀 멘션)
  5. 핸드오프 이력 기록

출력:
  - 핸드오프 완료 메시지 + 다음 단계 정보
  - 실패 시: 누락된 산출물 목록 + 해결 방법 안내
```

### 트리거

```
키워드: "핸드오프", "handoff", "다음 단계로"
또는 직접 호출: /handoff design
```

---

## OMC 연동

크로스팀 워크플로우는 OMC의 `pipeline` 모드 및 `team` 모드와 자연스럽게 연동.
