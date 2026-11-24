# Release — ai-harness

노드·전이의 계약은 `.ai-harness/workflows/release-graph.json`이 단일 출처다. 이 문서는 그 그래프를 이 저장소에서 실행할 때 쓰는 **프로젝트 사실**만 적는다. 저장소 사실(브랜치·접두어·확장점 명령)은 `.ai-harness/harness.json`의 `release_policy`에 있고, 러너(`.ai-harness/workflows/workflow-driver.sh start --workflow release --version <x.y.z>`)가 읽는다. 사람 절차의 원본은 `CONTRIBUTING.md` "릴리스"다.

## 1. 버전

- SemVer. `CHANGELOG.md`의 `## Unreleased`에 `### 새 기능`이나 `### 동작 변경`이 있으면 MINOR, 버그 수정·문서만이면 PATCH. MAJOR는 사람이 정한다(`--version`).
- 버전 파일 네 곳(`.claude-plugin/plugin.json`·`.codex-plugin/plugin.json`·`release.json`의 `version`, `CHANGELOG.md` 버전 절)은 릴리스 커밋의 `scripts/release-prep.sh <version>`(= `prepare_cmd`)만 바꾼다. Unreleased가 비어 있으면 `release-prep.sh`가 실패하고 러너는 사람에게 넘긴다.

## 2. 검증 명령

plan이 낼 `checks`(릴리스 커밋마다, develop이 움직여 따라잡을 때마다):

```bash
scripts/release-prep.sh --check
bash tests/run.sh --lint
```

`final_checks`(같은 시점에 한 번 — 이 저장소의 PR 직전 검사와 같다):

```bash
bash tests/run.sh -j 2
bash -n scripts/*.sh scripts/board/*.sh tests/*.sh
npx --yes shellcheck -S style -x scripts/*.sh scripts/board/*.sh tests/*.sh
```

## 3. publish 노드가 쓸 사실

- 릴리스 브랜치: 러너가 `origin/develop`에서 딴 `release/v<x.y.z>`. 커밋은 러너가 만든 `chore: release v<x.y.z>` 그대로 둔다.
- PR: `gh pr create --base main --title "chore: release v<x.y.z>" --milestone "v<x.y.z>"`(마일스톤이 열려 있을 때). 본문에 plan과 `결정 사항`을 싣는다.
- 원격 CI: GitHub Actions `test` 워크플로 — `gh pr checks <PR> --watch`.

## 4. 병합은 merge commit만

릴리스 PR만 merge commit으로 병합한다(`gh pr merge --merge`). squash로 넣으면 `develop`의 커밋이 `main`의 조상이 되지 않아 두 브랜치가 영구히 갈라지고, 릴리스 뒤 `develop`의 fast-forward 동기화가 실패하며 다음 릴리스 PR마다 이미 나간 변경이 다시 올라온다. 러너는 병합 방식을 `merge`로 고정하고, 저장소가 merge commit을 허용하지 않으면 병합하지 않는다.

## 5. 태그·확인·기록

- 노트: `scripts/changelog-section.sh <version>`(= `notes_cmd`) + `--generate-notes`(PR 목록). 노트가 비면 태그를 만들지 않는다 — 노트 없이 태그만 오르면 `release` 워크플로가 실패한다.
- 확인(단계 `deploy`): `scripts/release-verify.sh <version>`(= `verify_cmd`) — 태그 `v<x.y.z>`의 `release` 워크플로가 성공했고 `origin/main`의 `release.json`이 그 버전인지. 진행 중이면 실패하고 러너가 60분까지 resume으로 다시 본다.
- 기록: `scripts/release-milestone.sh <version>`(= `record_cmds`) — 마일스톤 `v<x.y.z>`를 닫고 다음 MINOR(`v<x>.<y+1>.0`)가 없으면 연다.
- 동기화: 러너는 `develop`에 push하지 않는다. 보고에 남긴 `git switch develop && git merge --ff-only origin/main && git push origin develop`을 사람이 실행한다. ff가 거부되면 릴리스를 squash로 병합했거나 `develop`이 그 뒤 움직였다는 뜻이다.
