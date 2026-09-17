# 기여 규칙

## 브랜치

| 브랜치 | 역할 | 누가 쓰나 |
|---|---|---|
| `main` | **릴리스된 상태만** 담는다. 사용자가 설치하면 이 브랜치를 받는다. | 릴리스 PR만 머지 |
| `develop` | 통합 브랜치. 머지됐지만 아직 릴리스되지 않은 변경이 쌓인다. | 모든 기능·수정 PR의 base |
| 작업 브랜치 | 변경 하나당 하나. `develop`에서 따고 `develop`으로 PR. | 작업자 |

`main`이 릴리스 상태여야 하는 이유는 설치 경로가 그 브랜치를 그대로 읽기 때문이다.

- `claude plugin marketplace add cano721/ai-harness` / `codex plugin marketplace add ...` 는 기본 브랜치(`main`)를 받는다
- `scripts/check-update.sh`는 `raw.githubusercontent.com/cano721/ai-harness/main/release.json`을 읽어 최신 버전을 판단한다

따라서 `develop`의 미검증 변경이 `main`에 섞이면 사용자가 릴리스하지 않은 코드를 설치하게 된다.

### 작업 브랜치 이름

`<타입>/<한-일-요약>` 형식. 타입은 커밋 타입과 같은 어휘를 쓴다.

```
feat/docs-drift-report
fix/drop-silent-failures-from-error-signal
docs/release-policy
chore/bump-ci-shellcheck
```

### PR

- base는 `develop`이다. `gh pr create --base develop` — 기본값이 `main`이므로 생략하면 릴리스 브랜치로 열린다
- 머지는 **squash**, 머지 후 브랜치 삭제 (`gh pr merge <n> --squash --delete-branch`)
- 여러 PR이 동시에 열려 있으면 머지된 순서대로 나머지를 `develop`에 리베이스한다

## 버전

버전은 `MAJOR.MINOR.PATCH`이고 **사용자 영향 기준**으로 정한다. 내부 구현의 크기가 아니다.

| 올림 | 기준 | 예 |
|---|---|---|
| PATCH | 기존 동작을 고친다. 사용자가 할 일이 없다. | 신호 집계의 오탐 제거, 스크립트 버그 수정 |
| MINOR | 없던 것이 생긴다. 기존 동작은 그대로다. | 새 스킬·스크립트·신호 종류, 워크플로 단계 추가 |
| MAJOR | 쓰던 방식이 깨진다. 사용자가 조치해야 한다. | 생성물 구조 변경, 제거된 커맨드, 호환되지 않는 이벤트 스키마 |

### 기능 PR은 버전을 올리지 않는다

버전 메타데이터는 네 곳(`.claude-plugin/plugin.json`, `.codex-plugin/plugin.json`, `release.json`, `CHANGELOG.md`)에 있다. PR마다 이걸 올리면 동시에 열린 PR이 **반드시** 네 곳에서 충돌한다.

그래서 기능 PR은 `CHANGELOG.md`의 `## Unreleased` 절에만 항목을 남긴다. 버전 파일은 릴리스 커밋 하나만 건드린다.

```markdown
## Unreleased

### 버그 수정

- **무엇이 어떻게 달라지는가** — 왜 그게 문제였는지 한 줄.
```

절의 소제목은 `### 새 기능` / `### 버그 수정` / `### 동작 변경` / `### 업데이트 후 해야 할 일`을 쓴다. 사용자가 읽고 판단할 수 있게 쓰고, 내부 리팩터링만 있는 PR은 항목을 남기지 않아도 된다.

## 릴리스

`develop`의 `## Unreleased`가 릴리스할 만큼 쌓였을 때 한다.

```bash
git switch develop && git pull
scripts/release-prep.sh <version>          # Unreleased 절 확정 + 네 곳 동기화
bash tests/run.sh
git commit -am "chore: release v<version>"
gh pr create --base main --head develop --title "release v<version>"
```

머지 뒤 태그와 릴리스 노트를 발행한다. 노트 없이 태그만 올리면 `release` 워크플로가 실패한다 — `notes_url`이 404가 되고 `/harness-update`가 변경점을 설명하지 못하기 때문이다.

```bash
git switch main && git pull
scripts/changelog-section.sh <version> > /tmp/notes.md
gh release create v<version> --target main --title "v<version>" --notes-file /tmp/notes.md
```

릴리스 후 `main`을 `develop`에 되돌려 머지해 두 브랜치를 맞춘다.

```bash
git switch develop && git merge --ff-only main && git push
```

### 급한 수정 (hotfix)

이미 릴리스된 버전에 치명적 문제가 있으면 `main`에서 브랜치를 따고 `main`으로 PR한 뒤, PATCH 릴리스를 발행하고 `develop`에 되돌려 머지한다. 그 외에는 전부 `develop`을 거친다.

## 검증

PR을 올리기 전에 로컬에서 통과시킨다. CI도 같은 것을 돌린다.

```bash
bash tests/run.sh
bash -n scripts/*.sh tests/*.sh
shellcheck -x scripts/*.sh tests/*.sh     # 미설치 시 npx --yes shellcheck
```

CI의 shellcheck는 **info 레벨도 실패로 다룬다**. 로컬 버전이 CI보다 관대할 수 있으니 경고가 나오면 구조를 바꿔 없앤다 — `# shellcheck disable`은 근거를 주석으로 남길 수 있을 때만 쓴다.

`scripts/release-prep.sh --check`는 네 곳의 버전·태그 URL·CHANGELOG 절이 맞는지만 본다. `## Unreleased`가 있어도 통과하므로 `develop`에서도 그대로 돌릴 수 있다.
