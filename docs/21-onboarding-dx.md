# AI Harness - 온보딩 & 개발자 경험 (DX)

## 설계 원칙

> **하네스는 투명해야 한다.** 개발자가 하네스의 존재를 의식하지 않고 자연스럽게 보호받는 것이 이상적.

1. **Zero Config 시작**: `ai-harness init` 한 번이면 끝
2. **방해 최소화**: 정상 작업은 지연 없이 통과
3. **차단 시 명확한 안내**: 왜 차단됐는지, 어떻게 해결하는지
4. **점진적 학습**: 처음부터 모든 기능을 알 필요 없음

---

## 신규 팀원 온보딩

### 자동 셋업

```bash
# 프로젝트 클론 후 첫 실행 시 자동 감지
$ claude

  ┌──────────────────────────────────────────────┐
  │ 이 프로젝트는 AI Harness가 설정되어 있습니다. │
  │ 초기 설정을 진행할까요? (약 30초)             │
  │                                               │
  │ 설정 내용:                                    │
  │ • 회사 규칙 적용 (보안, 코딩 컨벤션)           │
  │ • 팀별 Hook 활성화 (backend)                  │
  │ • MCP 서버 연결 (Jira, Confluence)            │
  │                                               │
  │ (Y/n): Y                                      │
  └──────────────────────────────────────────────┘

  ✔ 30초 만에 설정 완료. 평소처럼 사용하세요.
```

### 프로젝트 .ai-harness/config.yaml이 있으면

```
프로젝트 클론
    ↓
.ai-harness/config.yaml 감지
    ↓
하네스 코어 설치 여부 확인
    ├─ 설치됨 → ai-harness sync 자동 실행
    └─ 미설치 → 설치 안내 메시지
```

---

## DX 최적화: 차단 메시지 설계

### 나쁜 예 (불친절)

```
BLOCKED: Policy violation.
```

### 좋은 예 (하네스 기본)

```
[하네스] ⛔ 차단: force push는 회사 정책에 의해 차단됩니다.

  명령: git push --force origin main
  정책: block-dangerous (Global, 잠금)
  이유: force push는 팀원의 커밋을 덮어쓸 수 있습니다.

  대안:
  • git push origin main (일반 push)
  • git push --force-with-lease origin main (안전한 force push)

  예외 필요 시: 팀 리드에게 문의하세요.
```

### 차단 메시지 구조

```
1. 무엇이 차단됐는지 (명령어)
2. 어떤 정책에 의해 (Hook명, 레이어)
3. 왜 차단하는지 (이유)
4. 어떻게 해결하는지 (대안)
5. 예외 처리 방법 (필요 시)
```

---

## DX 최적화: Hook 지연 체감 최소화

### 경량 Hook 우선

```
빈번한 도구 (Read, Grep):
  → 경량 Hook만 실행 (< 50ms)
  → 보안 체크는 필수, 나머지 스킵

변경 도구 (Write, Edit, Bash):
  → 전체 Hook 실행
  → 그래도 < 500ms 목표
```

### 비동기 Hook

```
Post Hook 중 시간이 오래 걸리는 것:
  → 비동기로 실행, 결과를 나중에 알림

예: bundle-size 체크
  → Write 후 즉시 반환
  → 백그라운드에서 빌드 + 사이즈 체크
  → 문제 있으면 다음 프롬프트에서 경고
```

---

## 헬프 시스템

### 상황별 도움말

```bash
# 전체 도움말
$ ai-harness help

# 차단당했을 때
$ ai-harness why
  마지막 차단 사유:
  Hook: block-dangerous
  명령: rm -rf build/
  대안: rm -r build/ (또는 rimraf build/)

# 특정 규칙 설명
$ ai-harness explain no-console-log
  규칙: 프로덕션 코드에서 console.log 금지
  근거: 운영 환경에서 불필요한 로그가 성능에 영향
  적용: PostToolUse (Write, Edit)
  예외: __tests__/, *.test.*, scripts/ 디렉토리

# 현재 적용 중인 규칙 목록
$ ai-harness rules
  [Global - 잠금]
  • 위험 명령 차단 (rm -rf, DROP, force push)
  • 민감 정보 유출 방지
  • 감사 로깅

  [Backend 팀]
  • SQL 파라미터 바인딩 필수
  • API 버저닝 규칙
  ...
```

---

## 피드백 수집

### 인라인 피드백

```
[하네스] ⛔ 차단: console.log 감지됨

  이 차단이 도움이 됐나요? (y/n/무시하려면 Enter): n
  → 피드백 기록됨. 감사합니다.
  → 오탐으로 분류되어 Champion에게 전달됩니다.
```

### 주간 미니 서베이 (선택)

```
[하네스] 이번 주 하네스 경험은 어땠나요? (1-5): _
→ 3점 이하 시: 불편했던 점을 한 줄로 알려주세요: _
```

---

## /company-onboard 스킬

```
$ /company-onboard

  ━━━ 프로젝트 온보딩 ━━━━━━━━━━━━━━━━━━━━━━━━━━

  1. 프로젝트 구조 분석...
     ✔ Spring Boot 3.2 + React 18 (fullstack)

  2. 관련 문서 확인...
     ✔ Confluence: 프로젝트 개요 페이지 발견
     ✔ Jira: 현재 스프린트 이슈 5건

  3. 하네스 설정...
     ✔ backend + frontend 팀 프로필 적용

  4. 요약:
     이 프로젝트는 [ATS 채용 시스템]입니다.
     현재 스프린트에서 로그인 기능 개선 작업 중입니다.
     BE는 Spring Boot, FE는 Next.js를 사용합니다.

     시작하기: "PROJ-100 이슈 작업해줘"
```
