---
name: user-story
description: PRD 또는 기능 설명을 입력받아 ATS 페르소나 기반 유저 스토리와 수용 기준 생성
team: planning
trigger: "user-story|유저스토리|user story|Given-When-Then"
---

# 유저 스토리 생성 Skill

## 사용법
/harness user-story [PRD 내용 또는 기능 설명]

예시: `/harness user-story "채용공고에 지원서를 제출하는 기능"`

## 실행 내용

입력받은 PRD 또는 기능 설명을 분석하여 ATS 도메인 페르소나 기반의 유저 스토리와 수용 기준을 생성하라.

### ATS 페르소나 정의

**채용담당자 (Recruiter)**
- 역할: 채용 프로세스 설계, 채용공고 등록, 지원자 스크리닝
- 목표: 적합한 인재를 빠르고 효율적으로 채용

**지원자 (Applicant)**
- 역할: 채용공고 검색, 지원서 제출, 채용 진행 상황 확인
- 목표: 원하는 직무에 쉽게 지원하고 결과를 투명하게 확인

**면접관 (Interviewer)**
- 역할: 면접 일정 확인, 면접 진행, 평가표 작성
- 목표: 효율적으로 면접을 진행하고 객관적인 평가를 기록

**HR관리자 (HR Manager)**
- 역할: 채용 현황 모니터링, 리포트 생성, 채용 정책 관리
- 목표: 전사 채용 프로세스의 효율성과 품질 향상

---

## 출력 형식

각 페르소나에 대해 관련 유저 스토리를 작성하라.

### 유저 스토리 형식
```
[US-001] As a [페르소나],
I want to [구체적인 행동],
so that [달성하려는 목적/가치].

우선순위: Must Have / Should Have / Nice to Have
스토리 포인트: [1 / 2 / 3 / 5 / 8 / 13]
```

### 수용 기준 (Acceptance Criteria) 형식
각 유저 스토리에 대해 최소 3개의 수용 기준을 작성하라.

**정상 케이스 (Happy Path)**
```
Given [사전 조건]
When [사용자 행동]
Then [기대 결과]
```

**예외 케이스 (Edge Case)**
```
Given [예외 상황]
When [사용자 행동]
Then [예외 처리 결과]
```

**경계값 케이스 (Boundary Case)**
```
Given [경계 조건]
When [사용자 행동]
Then [경계 처리 결과]
```

---

## 품질 체크리스트

생성된 유저 스토리가 다음 기준을 충족하는지 검토하라:
- [ ] INVEST 원칙 준수 (Independent, Negotiable, Valuable, Estimable, Small, Testable)
- [ ] 비즈니스 가치가 명확하게 표현되었는가
- [ ] 기술적 구현 방법이 아닌 사용자 관점으로 작성되었는가
- [ ] 수용 기준이 테스트 가능한 형태인가
- [ ] ATS 도메인 용어가 일관되게 사용되었는가
