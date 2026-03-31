# Frontend 팀

## 필수 규칙
- moment.js 금지 (dayjs 사용)
- lodash 전체 import 금지 (개별 import)
- 번들 초기 로드 < 300KB (gzip)

## 테스트 규칙
- 커버리지 80% 이상 (Vitest + Testing Library)
- 사용자 행동 기반 테스트 (구현 세부사항 테스트 지양)
- E2E: Playwright, 핵심 유저 플로우 100% 커버리지
- 테스트 데이터 격리 필수, 프로덕션 데이터 사용 금지
- /test-scenario, /regression, /smoke-test 글로벌 스킬 활용 가능

## 코드 작성 시
코드 컨벤션 상세는 /convention-frontend 스킬을 참고하라
