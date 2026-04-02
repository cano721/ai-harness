# AI Harness 기획 문서

AI 에이전트(Claude Code, Codex 등)를 안전하게 통제하고 효율을 높이는 회사 전용 제어/검증 프레임워크.

## 문서 목차

| # | 문서 | 내용 |
|---|------|------|
| 01 | [개요](01-overview.md) | AI 하네스 정의, 핵심 목표, 기존 도구와의 관계 |
| 02 | [아키텍처](02-architecture.md) | 전체 구조, 5대 구성요소, 레이어 상속 모델 |
| 03 | [디렉토리 구조](03-directory-structure.md) | 프로젝트 파일/폴더 구조 상세 |
| 04 | [OMC/OMX 연동](04-omc-integration.md) | Hook 체이닝, 모드별 설정, 커스텀 에이전트/스킬 |
| 05 | [팀별 커스터마이징](05-team-customization.md) | 기획/디자인/FE/BE/QA/DevOps 팀 설정, 충돌 해소, 팀 전환 |
| 06 | [로드맵](06-roadmap.md) | Phase 1~3 단계별 작업 항목 및 완료 기준 |
| 07 | [설정 관리 & 업데이트](07-configuration.md) | 버전 업데이트, 로컬 설정 변경, 잠금 정책, CLI 명령어 |
| 08 | [배포 & 패키지 구조](08-distribution.md) | 하이브리드 배포, 공개 프레임워크 + 사내 설정 분리, npm/GitHub 구성 |
| 09 | [Init 플로우 상세](09-init-flow.md) | 6단계 설치 플로우, 환경 감지, OMC 확인, 팀 선택, 비파괴적 설치 |
| 10 | [감사 로깅 설계](10-audit-logging.md) | 로그 포맷(JSONL), 저장/보존 정책, 조회/분석, 민감 정보 마스킹 |
| 11 | [크로스팀 워크플로우](11-cross-team-workflow.md) | 기획→디자인→개발→QA 파이프라인, 핸드오프, 승인 게이트 |
| 12 | [비용 추적 모델](12-cost-tracking.md) | 토큰 비용 산출, 3단계 한도, 실시간 추적, 리포트, 최적화 제안 |
| 13 | [플러그인 개발 가이드](13-plugin-guide.md) | 설정 패키지 만드는 법, 인터페이스 구현, Hook 작성, 검증, 배포 |

### 설계 보강 문서 (v2)

| # | 문서 | 내용 |
|---|------|------|
| 14 | [멀티 에이전트 추상화](14-multi-agent-abstraction.md) | 에이전트별 설정 차이 추상화, 어댑터 패턴, 지원 범위 |
| 15 | [에러 핸들링 & 복원력](15-error-handling.md) | Hook 실패/타임아웃, 캐스케이딩 방지, 폴백 전략, 서킷 브레이커 |
| 16 | [하네스 테스트 전략](16-testing-strategy.md) | Hook 단위 테스트, config 병합 테스트, E2E 시나리오, CI 통합 |
| 17 | [롤백 & 복구](17-rollback-recovery.md) | 업데이트 롤백, 설정 스냅샷, 복구 절차, 안전망 설계 |
| 18 | [거버넌스 모델](18-governance.md) | 관리 주체, 규칙 변경 프로세스, RFC, 의사결정 매트릭스 |
| 19 | [품질 & 채택 메트릭](19-quality-metrics.md) | 생산성/품질/채택률 메트릭, 대시보드 설계, KPI |
| 20 | [마이그레이션 경로](20-migration-path.md) | 기존 프로젝트 점진적 전환, 호환성 보장, 단계별 마이그레이션 |
| 21 | [온보딩 & 개발자 경험](21-onboarding-dx.md) | 신규 팀원 온보딩, DX 최적화, 마찰 최소화 설계 |
| 22 | [모노레포 지원](22-monorepo-support.md) | 모노레포 구조 감지, 서비스별 팀 매핑, 설정 상속 |
| 23 | [보안 모델 심화](23-security-deep-dive.md) | 네트워크 접근 제어, 샌드박싱, 권한 에스컬레이션, 위협 모델 |
| 24 | [설정 호환성 전략](24-config-compatibility.md) | core↔config 버전 매트릭스, 하위호환 규칙, 마이그레이션 스크립트 |
| 25 | [컴플라이언스 & 데이터 거버넌스](25-compliance.md) | 데이터 분류, GDPR/개인정보보호법 대응, 마스킹, 보존/삭제 정책 |
| 26 | [트러블슈팅 가이드](26-troubleshooting.md) | 증상별 해결법, 수동 복구, doctor 해석, FAQ |
| 27 | [AI 모델 변화 대응](27-ai-model-adaptation.md) | 모델 업그레이드 대응, 프롬프트 드리프트, 비용 구조 변경, 관찰 모드 |
| 28 | [성능 벤치마크 & 최적화](28-performance-benchmark.md) | Hook 프로파일링, 성능 예산, 캐싱/비동기/라우팅 최적화, CI 회귀 방지 |
| 29 | [다음 작업](29-next-steps.md) | 현재 완료 상태, 남은 큰 일, 다음 구현 순서 |
| 30 | [Execution V2](30-execution-v2.md) | queue/worker/orchestration 기반 실행 계층 확장 설계 |
