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
- 작업 브랜치 → `develop` 머지는 **squash**, 머지 후 브랜치 삭제 (`gh pr merge <n> --squash --delete-branch`)
- squash 머지 전에 브랜치가 `develop`의 최근 변경을 옛 내용으로 되돌리거나 다른 이슈의 changelog 조각을 지우지 않았는지 검사한다(#594·#601):

  ```bash
  git fetch origin develop
  bash .ai-harness/workflows/workflow-driver.sh revert-check --base develop --issue <이슈>
  ```

  exit 1이면 병합하지 않는다. 출력된 파일 목록을 PR에 남기고 사람이 판단한다(러너의 `user_decision`과 같다). wip 커밋은 `git reset --soft $(git merge-base HEAD origin/develop)`로만 합치고, `develop`을 따라가려면 `git rebase origin/develop`을 쓴다
- `develop` → `main` 릴리스 머지만 **merge commit** (`gh pr merge <n> --merge`). 이유는 [릴리스](#릴리스)에 있다
- 여러 PR이 동시에 열려 있으면 머지된 순서대로 나머지를 `develop`에 리베이스한다

## 버전

버전은 `MAJOR.MINOR.PATCH`이고 **사용자 영향 기준**으로 정한다. 내부 구현의 크기가 아니다.

| 올림 | 기준 | 예 |
|---|---|---|
| PATCH | 기존 동작을 고친다. 사용자가 할 일이 없다. | 신호 집계의 오탐 제거, 스크립트 버그 수정 |
| MINOR | 없던 것이 생긴다. 기존 동작은 그대로다. | 새 스킬·스크립트·신호 종류, 워크플로 단계 추가 |
| MAJOR | 쓰던 방식이 깨진다. 사용자가 조치해야 한다. | 생성물 구조 변경, 제거된 커맨드, 호환되지 않는 이벤트 스키마 |

**1.0 전(`0.x`)에는** 깨지는 변경이라도 영향이 작으면 MINOR로 낸다 — 조치가 이름 바꾸기·`--sync` 한 번처럼 한 줄로 끝나고, CHANGELOG `### 업데이트 후 해야 할 일`에 그 조치를 적는 경우다. 사용자가 손댄 생성물·데이터를 옮겨야 하거나 조치가 여러 단계면 0.x에서도 MAJOR다.

### 기능 PR은 버전을 올리지 않는다

버전 메타데이터는 네 곳(`.claude-plugin/plugin.json`, `.codex-plugin/plugin.json`, `release.json`, `CHANGELOG.md`)에 있다. PR마다 이걸 올리면 동시에 열린 PR이 **반드시** 네 곳에서 충돌한다.

그래서 기능 PR은 `CHANGELOG.md`를 건드리지 않고, PR마다 조각 파일 하나 `changelog.d/<이슈>-<요약>.md`에만 항목을 남긴다. 모든 PR이 같은 `## Unreleased` 줄에 쓰면 동시에 열린 PR끼리 맨 위에서 충돌하기 때문이다. 버전 파일과 CHANGELOG 버전 절은 릴리스 커밋 하나만 건드린다.

```markdown
<!-- changelog.d/38-error-filter.md -->
### 버그 수정

- **무엇이 어떻게 달라지는가** — 왜 그게 문제였는지 한 줄. (#38)
  요약: 사용자가 처음 읽는 한두 문장.
```

조각 규칙(`scripts/release-prep.sh --check`가 검사한다):

- 파일명은 `<이슈번호>-<요약>.md`이고 요약은 영문 소문자·숫자·하이픈(`^[0-9]+-[a-z0-9][a-z0-9-]*\.md$`). 규칙에 맞지 않는 `.md`는 실패다.
- 소제목은 `### 새 기능` / `### 버그 수정` / `### 동작 변경` / `### 업데이트 후 해야 할 일` 넷만 쓴다. 주석·빈 줄을 빼고 첫 줄은 소제목이어야 하고, 소제목마다 항목이 하나 이상 있어야 한다. 한 파일에 소제목을 여러 개 둘 수 있다.
- 항목은 `- `로 시작한다. 항목에 딸린 줄(`요약:`, 이미지, 이어지는 문단, 코드 울타리)은 공백이나 탭으로 들여쓴다. 빈 줄과 HTML 주석(`<!-- … -->`)은 써도 되고 주석은 합칠 때 버린다.
- `## ` 머리, 소제목 없는 항목, 들여쓰지 않은 자유 문단은 형식 오류다.

릴리스 때 `scripts/release-prep.sh <version>`이 조각들과 `## Unreleased`에 남은 항목(옛 방식으로 쓴 PR)을 합쳐 버전 절을 만들고 조각 파일을 지운다. 소제목은 `업데이트 후 해야 할 일` → `새 기능` → `동작 변경` → `버그 수정` 순으로 한 번씩 나오고, 소제목 안에서는 `## Unreleased` 항목이 먼저, 그 뒤에 조각이 파일명 앞 이슈 번호의 숫자 오름차순(같으면 파일명순)으로 온다. 한 파일 안의 항목 순서는 그대로다. 결과 CHANGELOG 형식은 이전과 같다.

사용자가 읽고 판단할 수 있게 쓰고, 내부 리팩터링만 있는 PR은 조각을 남기지 않아도 된다.

항목 바로 아래에 들여쓴 `요약:` 줄을 둔다. 보드 하네스 안내는 항목을 펼치면 이 요약을 먼저 보이고 원문은 "자세히"에 접는다. 요약은 사용자가 처음 읽는 설명이다 — 제목을 되풀이하지 말고, 한두 문장으로 "무엇이 생겼고 어떻게 쓰는지" 또는 "무엇을 해야 하는지"를 말한다. 배경·실측·구현은 원문에 남긴다. 화면을 봐야 이해되는 항목은 `요약:` 아래에 `![무엇을 보여 주는지](assets/release-notes/<버전>-<이름>.png)`를 들여써 두고, 이미지는 `.ai-harness/docs/ui.md`의 격리 보드 절차로 찍어 플러그인 루트 `assets/release-notes/`에 넣는다(png·jpg·webp·gif, SVG는 받지 않는다).

```markdown
- **하네스 안내 카드에서 바로 실행합니다** — 명령이 있는 카드에 "실행" 버튼이 생겨 … (#442)
  요약: 기능 카드의 "실행"을 누르고 저장소를 고르면 보드가 그 명령으로 Claude 세션을 띄웁니다.
  ![카드의 실행 버튼과 새 세션 양식](assets/release-notes/0.87.0-guide-run.png)
```

항목 끝에 닫는 이슈 번호를 단다. 릴리스 노트를 읽는 사람이 "이 버전이 무엇을 해결했나"를 배경까지 따라갈 수 있어야 한다. PR 번호는 적지 않는다 — 아래 `--generate-notes`가 PR 목록을 자동으로 붙인다.

```markdown
- **출력 없는 실패를 `error`에서 제외** — `grep -q`처럼 종료코드를 판정문으로 쓴 호출이 batch 트리거를 밀어올리고 있었습니다. (#38)
```

PR 본문에는 `Closes #38`을 쓴다. 이슈가 자동으로 닫히고, 릴리스 노트의 PR 링크에서 추적된다.

## 릴리스

`develop`에 쌓인 `changelog.d/` 조각(과 `## Unreleased`에 남은 항목)이 릴리스할 만큼 쌓였을 때 한다.

작업은 `develop`에 쌓이고, `main`은 릴리스된 상태만 담는다. 설치(`plugin marketplace add`)와 업데이트 확인(`check-update.sh`)이 모두 `main`을 읽으므로, `main`에 릴리스되지 않은 변경이 섞이면 사용자가 그대로 받는다.

### 러너로 릴리스 (1순위)

```bash
bash .ai-harness/workflows/workflow-driver.sh start --workflow release --version <version>
```

작업 브랜치나 worktree(`main`·`develop`이 아닌 곳)에서 시작한다. 러너가 `origin/develop`에서 `release/v<version>`을 따고 `scripts/release-prep.sh`(= manifest `release_policy.prepare_cmd`)·`chore: release v<version>` 커밋·검증을 한 뒤, `main`으로 PR을 열고 원격 CI를 기다린다. 그 뒤는 개인 배포 단계(`/ai-harness:setup`의 `HM_DELIVERY_LEVEL`)가 정한다.

- `pr`(기본): PR에서 멈추고 남은 절차(아래 수동 절차의 병합·태그 단계)를 보고에 남긴다.
- `merge`: merge commit으로 병합 → 병합 커밋 CI → CHANGELOG 절로 태그·릴리스(`--generate-notes`) → 마일스톤 정리(`scripts/release-milestone.sh`) → `develop` ff 명령 보고.
- `deploy`: 여기에 `scripts/release-verify.sh`(태그의 `release` 워크플로 성공·`origin/main`의 `release.json` 버전)를 더한다.

러너는 `develop`·`main`에 push하지 않는다. 마지막 동기화(`git switch develop && git merge --ff-only origin/main && git push origin develop`)는 보고에 남은 명령을 사람이 실행한다. 이 저장소의 사실은 `.ai-harness/workflows/release.md`에 있다.

### 수동 절차 (대안)

```bash
git switch develop && git pull
scripts/release-prep.sh <version>          # 조각 + Unreleased 절을 합쳐 확정(+ 빈 Unreleased 머리), 조각 삭제, 네 곳 동기화
bash tests/run.sh
git commit -am "chore: release v<version>" && git push
gh pr create --base main --head develop --title "chore: release v<version>" --milestone "v<version>"
gh pr merge <n> --merge                    # squash 아님 — 아래 이유
```

### 릴리스 PR만 merge commit인 이유

squash로 넣으면 `main`에 새 커밋 하나가 생기고 `develop`의 커밋들은 `main`의 조상이 되지 않는다. 그러면 두 브랜치가 **영구히 분기**해서 릴리스 뒤 동기화(`git merge --ff-only main`)가 실패하고, 다음 릴리스 PR마다 이미 나간 변경이 diff에 다시 올라온다.

merge commit이면 `develop`의 tip이 `main`의 조상이 되므로 아래 동기화가 fast-forward로 끝난다. 기능 PR은 이 문제가 없으므로 계속 squash한다 — 작업 브랜치는 머지 후 버리기 때문이다.

머지 뒤 태그와 릴리스 노트를 발행한다. 노트 없이 태그만 올리면 `release` 워크플로가 실패한다 — `notes_url`이 404가 되고 `/harness-update`가 변경점을 설명하지 못하기 때문이다.

태그를 밀거나 릴리스를 발행하면 `release` 워크플로가 태그명과 `release.json`의 버전·태그 URL 일치를 확인하고, 그 태그에 실제로 릴리스 노트가 발행됐는지 검사한다.

```bash
git switch main && git pull
scripts/changelog-section.sh <version> > /tmp/notes.md
gh release create v<version> --target main --title "v<version>" \
  --notes-file /tmp/notes.md --generate-notes --latest
```

`--generate-notes`는 직전 태그 이후 머지된 PR 목록(`What's Changed`)을 CHANGELOG 본문 **아래에 덧붙인다**. 본문은 사람이 쓴 사용자 영향 설명이고, 그 아래가 기계가 모은 추적 링크다.

마일스톤도 닫고 다음 버전을 연다.

```bash
gh api "repos/cano721/ai-harness/milestones?state=all&per_page=100" \
  --jq '.[] | select(.title=="v<version>") | .number'
gh api -X PATCH repos/cano721/ai-harness/milestones/<번호> -f state=closed --silent
gh api -X POST repos/cano721/ai-harness/milestones -f title=v<다음 버전> --silent
```

마지막으로 `main`을 `develop`에 되돌려 두 브랜치를 맞춘다. 위 merge commit 규칙 덕분에 fast-forward로 끝나야 한다 — 여기서 ff가 거부되면 릴리스를 squash로 머지했다는 뜻이다.

```bash
git switch develop && git merge --ff-only main && git push
```

### 급한 수정 (hotfix)

이미 릴리스된 버전에 치명적 문제가 있으면 `main`에서 브랜치를 따고 `main`으로 PR한 뒤, PATCH 릴리스를 발행하고 `develop`에 되돌려 머지한다. 그 외에는 전부 `develop`을 거친다.

## 마일스톤

마일스톤 이름은 릴리스 이름과 같다 (`v0.25.0`). 릴리스가 "무엇이 나갔나"의 사후 기록이라면, 마일스톤은 "무엇을 넣을 건가"의 사전 계획이다. 둘은 GitHub에서 자동으로 연결되지 않으므로 사람이 붙인다.

- 이슈를 잡을 때 다음 릴리스 마일스톤에 단다. 아직 정하지 않았으면 비워 둔다
- PR에도 같은 마일스톤을 단다 — 닫은 이슈가 없는 변경(리팩터링, 문서)도 그 릴리스에 들어갔다는 사실이 남는다
- 릴리스를 발행할 때 그 마일스톤을 닫고, 다음 버전 마일스톤을 연다

진척은 https://github.com/cano721/ai-harness/milestones 에서 보고, 나간 것은 https://github.com/cano721/ai-harness/releases 에서 본다.

## 검증

PR을 올리기 전에 로컬에서 통과시킨다. CI도 같은 것을 돌린다. 작업 중에는 `bash tests/run.sh --changed`(바뀐 영역만)·`bash tests/run.sh --lint`(바뀐 셸 파일만)로 충분하다.

```bash
bash tests/run.sh
bash -n scripts/*.sh scripts/board/*.sh tests/*.sh
shellcheck -x scripts/*.sh scripts/board/*.sh tests/*.sh     # 미설치 시 npx --yes shellcheck
```

CI 필수 체크는 집계 job `test` 하나다. `test`는 `lint`와 `shard (1)`~`shard (4)`(`.github/workflows/test.yml`의 matrix job `shard`)를 `needs`로 묶어 `if: always()`로 돌고, 그중 하나라도 실패·취소·건너뜀이면 실패한다. 브랜치 보호에는 `test`만 필수 체크로 등록하고 `shard (n)`·`lint`는 등록하지 않는다 — 샤드 수를 바꿔도 보호 규칙은 그대로 둔다. 워크플로에 job을 새로 추가하면 `test`의 `needs`에도 넣는다(`tests/core.sh`가 검사).

공개 저장소라 회사명·사용자 ID·실명 같은 식별자를 커밋하지 않는다. `scripts/identifier-scan.sh`가 저장소 밖의 금지어 목록 `HM_IDENTIFIER_DENYLIST`로 추적 파일 전체(`git ls-files`, 바이너리 제외)를 대소문자 무시 고정 문자열로 검사한다. 경로를 인자로 주면 그 파일·디렉토리만 본다. 목록은 소스에 두지 않는다.

- 로컬: `~/.ai-harness/config`에 `HM_IDENTIFIER_DENYLIST="a|b"`(config는 `|` 구분, 따옴표로 감싼다). 환경변수 `HM_IDENTIFIER_DENYLIST`가 있으면 config보다 먼저 쓴다(`|` 또는 줄바꿈 구분).
- CI: 저장소 Settings → Secrets and variables → Actions에 secret `HM_IDENTIFIER_DENYLIST`(값은 `|` 또는 줄바꿈 구분)를 등록하면 `lint` job의 `Identifier scan` 단계가 검사한다. secret이 없으면(fork PR 등) "건너뜀"을 출력하고 통과한다.
- 출력은 `파일:줄`뿐이다. CI 로그도 공개이므로 금지어와 줄 내용은 찍지 않는다. 매치가 있으면 exit 1이다.

CI의 shellcheck는 **info 레벨도 실패로 다룬다**. 로컬 버전이 CI보다 관대할 수 있으니 경고가 나오면 구조를 바꿔 없앤다 — `# shellcheck disable`은 근거를 주석으로 남길 수 있을 때만 쓴다.

`scripts/release-prep.sh --check`는 네 곳의 버전·태그 URL·CHANGELOG 절이 맞는지와 `changelog.d/` 조각 형식을 본다. 형식이 틀린 조각은 `changelog.d/<file>: <이유>`로 알리고 실패한다. `## Unreleased`가 있어도 통과하므로 `develop`에서도 그대로 돌릴 수 있다. `## Unreleased` 머리가 없으면 실패하지 않고 stderr에 경고만 한다.
