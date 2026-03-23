---
name: prd
description: Jira 이슈번호를 받아 Confluence 문서를 조회하고 ATS 도메인 PRD 초안을 작성
team: planning
trigger: "prd|PRD|기획서|product requirements"
---

# PRD 작성 Skill

## 사용법
/harness prd [Jira 이슈번호]

예시: `/harness prd ATS-123`

## 실행 내용

주어진 Jira 이슈번호를 기반으로 다음 단계를 수행하라:

1. Jira API로 이슈 상세 정보(제목, 설명, 첨부파일, 링크)를 조회하라.
2. Confluence에서 해당 이슈와 연결된 문서 또는 관련 페이지를 검색하라.
3. 조회한 정보를 바탕으로 아래 구조의 PRD 초안을 작성하라.

ATS(Applicant Tracking System) 도메인 컨텍스트:
- 핵심 엔티티: 채용공고(JobPosting), 지원자(Applicant), 면접(Interview), 평가(Evaluation)
- 주요 사용자: 채용담당자, 지원자, 면접관, HR관리자

---

## PRD 출력 형식

### 1. 배경 (Background)
이 기능이 필요한 비즈니스 배경과 현재 문제점을 서술하라.

### 2. 목적 (Objective)
이 기능을 통해 달성하려는 목표를 명확하게 기술하라. 측정 가능한 성공 지표(KPI)를 포함하라.

### 3. 범위 (In Scope)
이번 개발에 포함되는 기능과 시스템 경계를 명시하라.

### 4. 비범위 (Out of Scope)
이번 개발에서 제외되는 항목과 그 이유를 명시하라.

### 5. 타겟 사용자 (Target Users)
주요 사용자 페르소나를 나열하고, 각 페르소나가 이 기능을 사용하는 맥락을 설명하라.
- 채용담당자: 채용 프로세스 운영 및 지원자 관리
- 지원자: 공고 검색, 지원서 제출, 진행상황 확인
- 면접관: 면접 일정 확인, 평가표 작성
- HR관리자: 전체 채용 현황 모니터링 및 리포트

### 6. 유저 스토리 (User Stories)
각 타겟 사용자별 핵심 유저 스토리를 작성하라.
형식: "As a [사용자], I want to [행동], so that [목적]"

### 7. 수용 기준 (Acceptance Criteria)
각 유저 스토리에 대한 수용 기준을 Given-When-Then 형식으로 작성하라.

### 8. 기술 제약 (Technical Constraints)
- 성능 요구사항 (응답 시간, 처리량)
- 보안 요구사항 (인증, 인가, 데이터 암호화)
- 호환성 (지원 브라우저, OS)
- 외부 시스템 연동 제약

### 9. 일정 (Timeline)
- 기획 완료:
- 디자인 완료:
- 개발 완료:
- QA 완료:
- 배포 목표:

---

작성 완료 후 Confluence에 페이지를 생성하거나 기존 페이지를 업데이트하겠습니까?
