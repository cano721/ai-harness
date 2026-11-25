# Implement Feature — ai-harness

노드·전이·수리 한도의 계약은 `.ai-harness/workflows/feature-delivery-graph.json`이 단일 출처다. 이 문서는 그 그래프를 이 저장소에서 실행할 때 쓰는 **프로젝트 사실**만 적는다. 러너(`.ai-harness/workflows/workflow-driver.sh --workflow feature`)가 있으면 러너로 실행한다. 실행 중인 런은 `workflow-driver.sh stop [--run <id>]`로만 멈춘다(그 런이 기록한 프로세스만 끈다). `pkill`·`killall`·`pgrep -f` 같은 패턴 kill은 다른 런·세션까지 끄므로 쓰지 않는다. 멈춘 런(stopped)과 밖에서 끊긴 런(stale)은 `status`에 보이고 `resume`으로 잇는다.

## 1. Implementation Brief (승인 게이트)

파일을 고치기 전에 아래를 Brief로 낸다. 승인은 개인 설정 `HM_APPROVAL_REPOS`(저장소별) > `HM_APPROVAL` > 기본 `human` 순으로 결정한다. manifest의 기존 `approval`은 무시하고 러너가 개인 설정으로 옮기라는 안내를 남긴다 — 판단이 갈리는 점은 추천안·근거와 함께 `결정 사항`에 남기고, 범위를 바꾸는 제품 판단·되돌리기 어려운 선택·외부 시스템 쓰기는 사람에게 묻는다.

- 범위 / 비범위
- 검증 케이스: 관찰 가능한 동작 단위(입력 → 기대 출력·종료 코드·생성 파일)
- 예상 변경 영역: `scripts/`·`skills/`·`templates/`·`catalog/`·`hooks/` 중 어디, 템플릿이면 `templates/managed-files.json`·바이트 동일 사본 영향
- 사용자 영향과 CHANGELOG 조각 `changelog.d/<이슈>-<요약>.md` 초안(형식은 `CONTRIBUTING.md`, 소제목 `### 새 기능`/`### 버그 수정`/`### 동작 변경`/`### 업데이트 후 해야 할 일`, 끝에 닫는 이슈 번호). 사용자 영향이 없으면 없다고 적는다
- 검증 명령(아래 4절)

## 2. Delivery slice

승인 뒤 검증 케이스를 1~3개씩 slice로 나눈다. slice마다:

1. **Red** — test-engineer가 영역 파일 `tests/<영역>.sh`에 블록을 추가하고 `bash tests/run.sh <영역>`이 그 블록에서 실패함을 확인한다.
2. **Green** — developer가 최소 변경으로 통과시킨다.
3. **Refactor** — 테스트를 바꾸지 않고 정리, `bash tests/run.sh --changed` 재통과.

러너의 deliver 노드는 Red/Green 대상 영역(`bash tests/run.sh <영역>`)만 돌린다. 전체 회귀(`final_checks`)는 deliver가 직접 돌리지 않는다. 이 저장소는 러너가 push하고 GitHub Actions(`.github/workflows/test.yml`)가 있으므로 원격 CI가 최종 관문이고, 러너는 `final_checks`를 로컬에서 돌리지 않는다(원격 CI가 없거나 push하지 않는 런만 리뷰가 깨끗해진 뒤 로컬에서 한 번 돈다).

역할 분리는 작업 위험이 뒷받침할 때만 쓴다. 역할 도구가 없으면 현재 세션에서 페르소나(`.ai-harness/agents/`)를 바꿔 가며 진행한다.

## 3. 리뷰·수리

모든 slice 뒤 reviewer가 검토하고, blocking finding이 0개가 될 때까지 **리뷰 → 원인별 수정 → 검증 → 재리뷰**를 반복한다. 한도는 그래프 수리 한도를 따르고, 넘으면 사용자 판단으로 올린다.

## 4. 검증 명령

라운드마다(리뷰·수리 때마다, Brief의 `checks`). 러너는 모든 검사에 동시 실행 수 `HM_TEST_JOBS`를 넘기므로 `-j`에 그 값을 준다(러너 밖에서는 2):

```bash
bash tests/run.sh -j "${HM_TEST_JOBS:-2}" --changed
bash tests/run.sh --lint
```

리뷰가 깨끗해진 뒤 한 번(완료 증거 — PR 직전, Brief의 `final_checks`. 러너가 push하는 런은 원격 CI `test` 워크플로가 같은 전체 회귀·shellcheck를 돌리는 최종 관문이라 러너는 로컬에서 돌리지 않는다):

```bash
bash tests/run.sh
bash -n scripts/*.sh scripts/board/*.sh tests/*.sh
npx --yes shellcheck -S style -x scripts/*.sh scripts/board/*.sh tests/*.sh
scripts/release-prep.sh --check
```

버전 파일(`.claude-plugin/plugin.json`·`.codex-plugin/plugin.json`·`release.json`의 `version`, CHANGELOG 버전 절)이 diff에 있으면 실패로 본다 — 기능 PR은 버전을 올리지 않는다. 검사는 merge-base 기준이다: `git diff --quiet origin/develop...HEAD -- .claude-plugin/plugin.json .codex-plugin/plugin.json release.json`(점 세 개). base 최신 커밋과 비교하면 런 도중 develop에 들어온 릴리스를 브랜치 변경으로 세므로, 세 점으로 브랜치가 바꾼 것만 센다. CHANGELOG 버전 절도 같은 기준으로 `git diff origin/develop...HEAD -- CHANGELOG.md`에 `## v` 줄 추가가 없어야 한다. "이 파일들을 건드리지 않았다" 형태의 다른 검사도 `origin/develop...HEAD`로 쓴다.

## 5. publish 노드가 쓸 사실

- 기준 브랜치: `develop` (`main`은 릴리스 PR만)
- 작업 브랜치: `develop`에서 딴 `<타입>/<한-일-요약>` (예: `feat/docs-drift-report`, 이슈가 있으면 `feat/<이슈번호>-<요약>`)
- 커밋: Conventional Commits(`feat:`·`fix(<scope>):`·`docs(<scope>):`·`chore:`), 끝에 `(#<이슈>)`
- PR: `gh pr create --base develop` (기본값이 `main`이라 `--base` 생략 금지). draft가 아닌 일반 PR. 본문에 `Closes #<이슈>`, 열린 다음 릴리스 마일스톤이 있으면 `--milestone`으로 단다
- 원격 CI: GitHub Actions `test` 워크플로 — `gh pr checks <PR> --watch`
- 병합: 하지 않는다(사람, 또는 개인 자동화 단계를 고른 사용자의 러너 `merge` 노드). 기능 PR은 squash 병합이 저장소 규칙이다
- 기준 브랜치 충돌: 병합이 `develop`과의 충돌만으로 막히면 러너의 `sync_base` 노드가 `origin/develop`을 일반 merge로 들이고(충돌은 에이전트가 풀되 커밋·push하지 않는다), 4절 검사를 다시 통과해야 일반 push한 뒤 원격 CI → 병합을 다시 거친다. rebase·force push는 하지 않는다. 한도(`limits.max_base_syncs`)·풀지 못한 충돌·검사 실패는 사람에게 넘긴다

## 6. 이슈 트래커

GitHub Issues(`gh issue view <n>`). 이슈 상태 전환은 하지 않는다(manifest에 `issue_policy` 없음).
