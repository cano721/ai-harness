---
name: convention
description: 전체 공통 코드 컨벤션 — 모든 팀 공통 규칙
trigger: "컨벤션|convention|코드 규칙"
---

# 공통 코드 컨벤션

## 코딩 원칙
- 기존 코드 컨벤션을 먼저 파악하고 따른다
- 변경 범위를 최소화한다 (요청받은 것만 수정)
- 보안 취약점 주의 (인젝션, XSS, CSRF 등)
- 에러 발생 시 근본 원인을 분석한다

## Git
- 커밋 메시지에 Jira 이슈번호 포함
- PR은 기능 단위로 분리

## 코드 리뷰
- 네이밍 명확성, 단일 책임 원칙
- 테스트 존재 여부
- 보안 취약점 확인
- 이름 변경 시 다중 검색 검증 (직접 호출, 타입 참조, 문자열 리터럴, 동적 import, re-export, 테스트/mock)

## 리팩토링
- 300 LOC 이상 파일은 리팩토링 전 죽은 코드 정리 먼저 (별도 커밋)
- 멀티파일 변경 시 Phase별 최대 5개 파일, 검증 후 다음 Phase 진행

## 팀별 상세 컨벤션
- Backend: /convention-backend
- Frontend: /convention-frontend
- Design: /convention-design
- Planning: /convention-planning
- QA: /convention-qa
- DevOps: /convention-devops
