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

## 팀별 상세 컨벤션
- Backend: /convention-backend
- Frontend: /convention-frontend
- Design: /convention-design
- Planning: /convention-planning
- QA: /convention-qa
- DevOps: /convention-devops
