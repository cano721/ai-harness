# A/B 실험 과제

`scripts/ab.sh`가 쓰는 통제 실험 과제. `claude plugin eval` 케이스가 아니다(그 도구는 작업 폴더의 CLAUDE.md를 로드하지 않고 명령 채점기가 없어 프로젝트 하네스 효과를 잴 수 없다).

- `fixtures/<이름>/base` — 합성 저장소 코드. `harness` — 그 위에 덮는 하네스 파일(AGENTS.md·CLAUDE.md·`.ai-harness/`).
- `cases/<이름>/task.md` — 두 조건에 똑같이 주는 요청. `check.py <작업 폴더>` — 숨긴 검사, JSON 한 줄(`checks[]: name·kind·pass`). `fixture` — 쓸 fixture 이름(없으면 `orders-service`).
- fixture: `orders-service`(주문 도메인 규칙 — `apply-coupon`·`cancel-order`), `docs-archive`(SQLite 배치 잡의 대량 조회 메모리 규칙 — `archive-stale-docs`. 판정이 Python 정책 함수(`policy.is_stale`)라 SQL 한 줄 UPDATE로 끝나지 않고 행을 읽어야 한다. 실행된 SQL을 추적해 판정 조회가 본문 컬럼·`SELECT *`를 읽는지, 다건 조회에 LIMIT이 있는지 본다).
- 검사 종류: `correct`(요청만으로 알 수 있는 동작), `project_rule`(하네스 문서에만 있는 규칙), `convention`, `process`(테스트 추가 등 절차).

과제를 추가하면 `tests/fixtures/ab/`의 정답·규칙 모르는 구현으로 검사가 둘을 가르는지 먼저 확인한다.
