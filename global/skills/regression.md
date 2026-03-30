---
name: regression
description: 변경된 코드/기능을 입력받아 영향 범위 분석 + 회귀 테스트 목록 생성
team: global
trigger: "regression|회귀|영향 범위|impact analysis|회귀 테스트"
---

# 회귀 테스트 분석 Skill

## 사용법
/harness regression [변경된 파일 경로 또는 기능 설명]

예시: `/harness regression src/features/application/ApplicationService.java`
예시: `/harness regression "지원서 상태 전이 로직 변경 (PENDING → REVIEWING 단계 추가)"`
예시: `/harness regression [PR URL 또는 Jira 이슈번호]`

## 실행 내용

입력받은 변경 정보를 분석하여 영향을 받을 수 있는 기능 범위를 파악하고, 우선순위가 부여된 회귀 테스트 목록을 생성하라.

### 분석 단계

1. **변경 범위 파악**: 변경된 파일/클래스/함수를 목록화하라.
2. **직접 영향**: 변경된 코드를 직접 호출하는 기능을 찾아라.
3. **간접 영향**: 변경된 기능에 의존하는 상위/하위 기능을 분석하라.
4. **공유 컴포넌트**: 변경된 공유 컴포넌트/유틸리티가 있는 경우 전체 사용처를 확인하라.
5. **데이터 영향**: DB 스키마 변경이 포함된 경우 데이터 정합성 영향을 분석하라.

### ATS 기능 의존성 맵

```
채용공고(JobPosting)
  └── 지원서(Application)
        ├── 지원자(Applicant)
        ├── 면접(Interview)
        │     ├── 면접 일정(InterviewSchedule)
        │     └── 평가(Evaluation)
        └── 첨부파일(Attachment)

지원자 상태 전이:
APPLIED → REVIEWING → INTERVIEW_SCHEDULED → INTERVIEWED → OFFERED → HIRED / REJECTED
```

---

## 출력 형식

### 1. 변경 영향 분석

**변경 내용 요약**
- 변경된 파일/클래스/API 목록
- 변경의 성격: 버그 수정 / 기능 추가 / 리팩토링 / 스키마 변경

**직접 영향 범위**
| 영향 기능 | 영향 유형 | 위험도 |
|---------|---------|-------|
| [기능명] | 로직 변경 / UI 변경 / API 변경 | High/Medium/Low |

**간접 영향 범위**
| 영향 기능 | 영향 경로 | 위험도 |
|---------|---------|-------|
| [기능명] | [변경 → 중간 → 영향 기능] | High/Medium/Low |

### 2. 회귀 테스트 목록 (우선순위 순)

#### Critical (즉시 실행 필수)
- [ ] [TC-001] [테스트 항목 설명] - 예상 소요 시간: Xmin
- [ ] [TC-002] [테스트 항목 설명] - 예상 소요 시간: Xmin

#### High (배포 전 필수)
- [ ] [TC-010] [테스트 항목 설명] - 예상 소요 시간: Xmin

#### Medium (배포 후 24시간 내)
- [ ] [TC-020] [테스트 항목 설명] - 예상 소요 시간: Xmin

#### Low (다음 스프린트 내)
- [ ] [TC-030] [테스트 항목 설명] - 예상 소요 시간: Xmin

### 3. 자동화 실행 명령

기존 자동화 테스트 중 실행해야 할 스위트를 명시하라:
```bash
# E2E 테스트 실행 (Playwright)
npx playwright test --grep "@regression" --grep "@{affected-feature}"

# 단위 테스트 실행
./gradlew test --tests "com.company.ats.{affected.package}.*"
```

### 4. 회귀 테스트 결과 요약 템플릿
| 구분 | 총 케이스 | 통과 | 실패 | 미실행 |
|------|---------|------|------|------|
| Critical | | | | |
| High | | | | |
| Medium | | | | |
