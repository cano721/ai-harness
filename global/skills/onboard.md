---
name: company-onboard
description: 프로젝트 온보딩 — 구조 분석, 하네스 설정, 시작 가이드
trigger: "온보딩|onboard|프로젝트 소개"
---

# /company-onboard

## 실행 내용
1. **프로젝트 구조 분석**: package.json, build.gradle, tsconfig.json 등에서 스택 감지
2. **하네스 상태 확인**: .ai-harness/ 존재 여부, 적용된 팀, 활성 Hook
3. **관련 문서 안내**: Confluence 프로젝트 페이지, Jira 현재 스프린트
4. **도메인 요약**: ATS 채용 시스템 주요 엔티티, API 구조, 아키텍처
5. **시작 가이드**: 첫 작업 추천 (현재 스프린트 이슈 기반)

## 출력
- 프로젝트명, 스택, 팀 구성
- 적용된 하네스 규칙 요약
- 핵심 디렉토리 구조
- "시작하기: {추천 작업}" 안내
