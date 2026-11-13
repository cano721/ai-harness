# Implement Feature — ai-harness

노드·전이·수리 한도의 계약은 `.ai-harness/workflows/feature-delivery-graph.json`이 단일 출처다. 이 문서는 그 그래프를 이 저장소에서 실행할 때 쓰는 **프로젝트 사실**만 적는다. 러너(`.ai-harness/workflows/workflow-driver.sh --workflow feature`)가 있으면 러너로 실행한다.

## 1. Implementation Brief (승인 게이트)

파일을 고치기 전에 아래를 Brief로 낸다. 승인은 개인 설정 `HM_APPROVAL_REPOS`(저장소별) > `HM_APPROVAL` > 기본 `human` 순으로 결정한다. manifest의 기존 `approval`은 무시하고 러너가 개인 설정으로 옮기라는 안내를 남긴다 — 판단이 갈리는 점은 추천안·근거와 함께 `결정 사항`에 남기고, 범위를 바꾸는 제품 판단·되돌리기 어려운 선택·외부 시스템 쓰기는 사람에게 묻는다.

- 범위 / 비범위
- 검증 케이스: 관찰 가능한 동작 단위(입력 → 기대 출력·종료 코드·생성 파일)
- 예상 변경 영역: `scripts/`·`skills/`·`templates/`·`catalog/`·`hooks/` 중 어디, 템플릿이면 `templates/managed-files.json`·바이트 동일 사본 영향
- 사용자 영향과 `CHANGELOG.md` `## Unreleased` 항목 초안(소제목 `### 새 기능`/`### 버그 수정`/`### 동작 변경`/`### 업데이트 후 해야 할 일`, 끝에 닫는 이슈 번호). 사용자 영향이 없으면 없다고 적는다
- 검증 명령(아래 4절)

## 2. Delivery slice

승인 뒤 검증 케이스를 1~3개씩 slice로 나눈다. slice마다:

1. **Red** — test-engineer가 `tests/run.sh`에 블록을 추가하고 `bash tests/run.sh`가 그 블록에서 실패함을 확인한다.
2. **Green** — developer가 최소 변경으로 통과시킨다.
3. **Refactor** — 테스트를 바꾸지 않고 정리, `bash tests/run.sh` 재통과.

역할 분리는 작업 위험이 뒷받침할 때만 쓴다. 역할 도구가 없으면 현재 세션에서 페르소나(`.ai-harness/agents/`)를 바꿔 가며 진행한다.

## 3. 리뷰·수리

모든 slice 뒤 reviewer가 검토하고, blocking finding이 0개가 될 때까지 **리뷰 → 원인별 수정 → 검증 → 재리뷰**를 반복한다. 한도는 그래프 수리 한도를 따르고, 넘으면 사용자 판단으로 올린다.

## 4. 검증 명령 (완료 증거)

```bash
bash tests/run.sh
bash -n scripts/*.sh scripts/board/*.sh tests/*.sh
npx --yes shellcheck -S style -x scripts/*.sh scripts/board/*.sh tests/*.sh
scripts/release-prep.sh --check
```

버전 파일(`.claude-plugin/plugin.json`·`.codex-plugin/plugin.json`·`release.json`의 `version`, CHANGELOG 버전 절)이 diff에 있으면 실패로 본다 — 기능 PR은 버전을 올리지 않는다.

## 5. publish 노드가 쓸 사실

- 기준 브랜치: `develop` (`main`은 릴리스 PR만)
- 작업 브랜치: `develop`에서 딴 `<타입>/<한-일-요약>` (예: `feat/docs-drift-report`, 이슈가 있으면 `feat/<이슈번호>-<요약>`)
- 커밋: Conventional Commits(`feat:`·`fix(<scope>):`·`docs(<scope>):`·`chore:`), 끝에 `(#<이슈>)`
- PR: `gh pr create --base develop` (기본값이 `main`이라 `--base` 생략 금지). draft가 아닌 일반 PR. 본문에 `Closes #<이슈>`, 열린 다음 릴리스 마일스톤이 있으면 `--milestone`으로 단다
- 원격 CI: GitHub Actions `test` 워크플로 — `gh pr checks <PR> --watch`
- 병합: 하지 않는다(사람, 또는 개인 자동화 단계를 고른 사용자의 러너 `merge` 노드). 기능 PR은 squash 병합이 저장소 규칙이다

## 6. 이슈 트래커

GitHub Issues(`gh issue view <n>`). 이슈 상태 전환은 하지 않는다(manifest에 `issue_policy` 없음).
