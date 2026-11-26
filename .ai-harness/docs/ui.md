# UI

ai-harness가 사용자에게 보여 주는 화면은 서버나 빌드 없이 열리는 **단일 HTML 화면**이다. 실측한 사실만 적는다. `ui_review` 노드와 `ui-review`·`design-audit` Skill이 런타임에 읽는다.

## 화면

| 화면 | 원본 | 여는 법 |
|---|---|---|
| Harness Board (작업 현황·내 일정·하네스 동작·하네스 설정·하네스 효과·레퍼런스 보드·자동 수정·하네스 안내) | `scripts/board/template.html` (서버 `scripts/board/board-server.py`) | 아래 "보드를 격리해 띄우기" |
| 하네스 효과 리포트 | `skills/harness-impact/report-template.html` | `scripts/impact.sh`가 데이터를 넣어 만든 HTML 파일을 브라우저로 연다 |
| 기준 화면 (디자인 시스템 예시) | `docs/design-system/reference.html` | 파일을 바로 연다(`file://`). `?theme=light|dark`, `?drawer=1`로 상태를 고정한다 |

## 보드를 격리해 띄우기

검토는 사용자의 보드(기본 포트 8765, `~/.ai-harness`)를 건드리지 않는다. 데이터 디렉터리와 포트를 따로 준다.

```bash
export HARNESS_METRICS_DIR="$(mktemp -d)" BOARD_PORT=<비어 있는 포트> BOARD_NO_BROWSER=1 BOARD_IDLE_EXIT=0
bash scripts/board/board.sh open      # 주소(토큰 포함)를 출력한다
bash scripts/board/board.sh status    # running·url
bash scripts/board/board.sh stop      # 끝나면 반드시 끈다 (같은 환경 변수로)
```

- 로그인·시드 없음. 빈 데이터 디렉터리면 각 화면이 빈 상태로 그려진다. 항목이 있는 상태를 보려면 데이터 디렉터리에 `events/*.jsonl` 등을 넣는다(`tests/run.sh`의 보드 블록이 만드는 형태).
- 보드 서버가 쓰는 것(`board/server.json`·로그)은 `HARNESS_METRICS_DIR` 아래에만 생긴다. 저장소에는 아무것도 쓰지 않는다.
- 화면 쿼리 `?theme=light|dark`로 테마를 고정할 수 있다(보드·기준 화면).
- 보드를 처음 연 브라우저(localStorage `hb-view`·`hb-tab`·`hb-stab`이 모두 없음)는 하네스 안내 화면으로 시작한다. 다른 화면을 검토하려면 사이드바에서 고르거나 이미 쓰던 프로필을 쓴다. 보드 주소에 `&view=guide`를 붙이면 안내 화면이 바로 열린다.
- 안내 화면 맨 위의 "바뀐 것" 패널(#439)은 데이터 디렉터리의 `board/version-seen.json`이 현재 플러그인 버전보다 낮을 때만 보인다. 빈 데이터 디렉터리는 처음 읽을 때 현재 버전으로 기록되므로, 패널을 보려면 보드를 열기 전에 `{"seen":"0.80.0"}`처럼 낮은 버전을 써 둔다. "확인했습니다"를 누르면 그 파일이 바뀌므로 다시 보려면 파일을 되돌린다. 다른 CHANGELOG로 보려면 `HM_PLUGIN_ROOT`에 `CHANGELOG.md`와 `.claude-plugin/plugin.json`이 든 폴더를 준다(테스트 fixture `tests/fixtures/changelog`). 릴리스 이력(#457)은 확인 상태와 무관하게 늘 보인다. `changelog.d/` 조각과 `## Unreleased` 항목은 이력에 나오지 않으므로, 작업 중인 항목과 캡처를 보려면 저장소의 `CHANGELOG.md`·`changelog.d/`·`.claude-plugin/`·`.codex-plugin/`·`release.json`·`assets/release-notes/`를 임시 폴더에 복사하고 `scripts/release-prep.sh <다음버전> --root <복사본>`을 돌려 버전 절을 만든 뒤 그 폴더를 `HM_PLUGIN_ROOT`로 준다. CHANGELOG에 넣을 화면 캡처는 이 격리 보드에서 Playwright로 요소 단위(`locator.screenshot`)로 찍어 `assets/release-notes/<버전>-<이름>.png`로 둔다.
- 안내 카드의 "실행"은 새 세션 양식을 열고 띄우기는 실제로 `claude`를 띄운다. 검토할 때는 가짜 `claude`(예: `tests/fixtures/board-resident/claude`)가 든 폴더를 `PATH` 앞에 두고 보드를 연다. 실행 가능 여부는 `HM_CLAUDE_SKILLS_DIR`(기본 스킬 설치 여부)와 저장소 후보 중 하네스 저장소로 정해진다. 후보는 `orca repo list --json`·`HARNESS_CLAUDE_JSON`(기본 `~/.claude.json`의 `projects` 키)·데이터 디렉터리의 알려진 저장소에서 오므로, 사용자 저장소가 섞이지 않게 하려면 가짜 `orca`(저장소 목록을 돌려주는 스크립트)를 `PATH` 앞에 두고 `HARNESS_CLAUDE_JSON`을 fixture로 바꾼다. 임시 폴더 아래 fixture 저장소는 걸러지므로 `BOARD_TEMP_ROOTS`(콜론 구분, 빈 값이면 거르지 않음)를 함께 준다. 막힌 상태를 보려면 빈 `HM_CLAUDE_SKILLS_DIR`와 빈 데이터 디렉터리로 연다.
- 내 일정(#492) 화면은 일정 소스 선언(`agenda.json`)을 플러그인 `scripts/board/agenda/*/`와 `HM_CLAUDE_SKILLS_DIR`·`HM_CODEX_SKILLS_DIR` 아래 폴더에서 찾는다. 사용자 스킬 폴더를 섞지 않으려면 둘 다 빈 임시 폴더로 주고, 가짜 소스가 필요하면 `tests/fixtures/agenda/skills/`의 폴더(`acme` 답할 것 2건·할 일 1건·연결/끊기/완료 즉시 성공, `cal` 오늘·내일 일정, `broken` 데이터 디렉터리에 `fixture-broken/fail`이 있으면 실패, `localdone` 완료 명령 없음, `slow` 시간 초과, `bad` 선언 오류, `tz` 오프셋이 섞인 같은 날 일정·종일 공유 일정(`shared`)·다음 날 일정 — 시각순 확인은 보드를 `TZ=Asia/Seoul`로 띄운다, `inbox` `created`·`from`이 있는 할 일·쌓인 할 일·기한 있는 할 일·답할 것과 `done`·`reopen` 선언 — 데이터 디렉터리 `fixture-inbox/calls`에 호출 인자, `fixture-inbox/fail-reopen`이 있으면 reopen 실패, `applink` 앱 딥링크 `msteams:` url을 단 오늘 일정·답할 것과 `javascript:` url을 단 답할 것 — 앱 링크 버튼은 `target` 없이 '앱에서 열기', 완료함에서는 '앱에서 다시 열기'이고 javascript 항목엔 열기 버튼이 없다. 실제로 누르면 OS 프로토콜 대화상자가 뜨므로 검토에서는 DOM으로만 본다, #592)를 `HM_CLAUDE_SKILLS_DIR`에 복사한다(#567). 구글 캘린더는 플러그인에 든 공용 클라이언트로 늘 [연결]이 보이고, 누르면 실제 구글 동의 화면을 연다 — 검토에서는 누르지 않는다. 계정을 여럿 잇는 소스의 화면(계정 줄·'다시 연결 필요'·[계정 추가])은 `tests/fixtures/agenda/skills/duo`(데이터 디렉터리에 `fixture-duo-ready`를 두면 연결 가능, `fixture-duo/next`에 다음 계정, `fixture-duo/expired-<계정>`으로 만료)를 복사해 본다. '설정 필요' 소스의 [설정하기](#525)는 `agenda.json`에 `setup_prompt`가 있으면 실제로 `claude --bg`로 설정 세션을 띄우므로 아래 스킬 탭과 같은 가짜 `claude`를 `PATH` 앞에 둔다(`setup_prompt` 없는 소스는 안내 한 줄만 펼친다). 진행 줄은 가짜 `agents`가 세션을 busy로 돌려주는 동안 보이고, 세션 기록은 데이터 디렉터리의 `board/skill-sessions.json`(`agenda:<id>`)에 생긴다. 시간 초과 상태를 빨리 보려면 테스트 전용 `BOARD_AGENDA_FETCH_TIMEOUT=<초>`를 함께 준다. 연결 상태·캐시·할 일은 데이터 디렉터리의 `board/agenda/` 아래에만 생긴다. 할 일은 같은 환경 변수로 `bash scripts/board/board.sh todo add [--due YYYY-MM-DD] <내용>`으로도 넣는다. 아침 요약 카드는 `printf '...' | bash scripts/board/board.sh brief set --source 이름`으로 넣는다(오늘 받은 것만 보인다). '새로' 표시는 localStorage `hb-ag-seen`(`{항목 키: 처음 본 epoch(ms)}`, #567. 예전 배열 값은 모두 0으로 옮김) 기준이라, 첫 화면은 전부 본 것(0)으로 두고 그 뒤에 들어온 항목에만 붙는다. `created`가 없는 할 일은 이 처음 본 시각으로 '새로 맡겨진 요청'(24시간 이내)을 가르므로, 그 절을 보려면 보드를 한 번 연 뒤에 할 일을 더하거나 `created`가 있는 `inbox`를 쓴다. 완료함은 데이터 디렉터리의 `board/agenda/completed.json`(최근 7일), 쌓인 요청 [전체|요청자별]은 localStorage `hb-ag-group`(`1`=요청자별), 접힘 상태와 할 일·완료함 제목 펼침(#590)은 페이지를 새로 고치기 전까지만 남는다.
- 하네스 설정 > 스킬(#494) 탭은 `scripts/setup.sh list`·`design list`로 상태를 읽으므로 스킬 폴더 `HM_CLAUDE_SKILLS_DIR`·`HM_CODEX_SKILLS_DIR`를 빈 임시 폴더로 주고(전부 미설치), 키는 `HARNESS_CLAUDE_SETTINGS`에 fixture 파일을 준다(사용자 셸에 든 `JIRA_BASE_URL` 같은 카탈로그 키는 `env -u`로 뺀다). 상태별 줄을 보려면 같은 환경 변수로 `bash scripts/setup.sh install --tool claude jira`를 돌리거나 이름이 같은 폴더를 직접 둔다(직접 둔 폴더 표시). [설치]·[설정하기]·[제거]는 실제로 `claude --bg`를 띄우므로 가짜 `claude`(`--bg`면 `backgrounded`를 찍고, `agents`는 그 세션을 busy로 돌려주는 스크립트 — `tests/board.sh`의 스킬 블록과 같은 모양)를 `PATH` 앞에 둔다. [연결 확인]은 외부 API를 부르므로 검토에서는 누르지 않거나 `JIRA_BASE_URL`을 로컬 가짜 서버로 둔다. 상태 캐시를 바로 다시 읽게 하려면 `BOARD_SKILLS_TTL=0`. 기록은 데이터 디렉터리의 `board/skill-checks.json`·`board/skill-sessions.json`에만 생긴다.

## 브라우저

Playwright Chromium. 저장소에 의존성이 없고, `scripts/landing-browser.mjs`의 `launchBrowser()`가 npx 캐시(`~/.npm/_npx/*/node_modules/playwright`) 또는 `LANDING_PLAYWRIGHT`에서 찾는다. 없으면 설치는 사용자 승인 뒤에만 한다.

## 뷰포트·테마

- 뷰포트: 최소 360px(`--size-viewport-min`), 중단점 760px(`--breakpoint-narrow`)·1024px(`--breakpoint-wide`). 검토는 360·760 근처·1280 세 폭을 본다.
- 테마: light·dark. OS 설정(`prefers-color-scheme`)을 따르고 `<html data-theme>`가 이긴다.

## 기계 검사

글자로 확인할 수 있는 디자인 규칙은 스크립트가 본다. 화면을 고친 뒤 전부 통과해야 한다.

```bash
bash scripts/design-system.sh check      # 화면에 실은 토큰·부품 사본이 원본과 같은지
bash scripts/design-system.sh contrast   # 규칙 문서가 허용한 전경/배경 쌍의 대비(라이트·다크)
bash scripts/design-system.sh lint       # 중단점 폭·disabled 커서와 흐림·강조 면 글자색·danger 알림 문구
```

토큰·부품 원본(`docs/design-system/tokens.css`·`components.css`)을 고쳤으면 `bash scripts/design-system.sh sync`로 세 화면의 사본을 맞춘 뒤 검사한다.

## 디자인 점검

- 디자인 규칙 문서: `docs/design-system.md` (상태 `draft` — `## 메타`)
- 축 대응: 규칙 문서가 `design-audit` 필수 절 이름을 그대로 쓴다 — A `## 레이아웃`, B `## 색과 상태`, C `## 컴포넌트`, D `## 형제 목록`, E `## 문구`
- 화면 분류와 형제: 규칙 문서 `## 레이아웃`의 분류 표(목록·요약·설정·상세)와 `## 형제 목록`
- 기준 화면: `docs/design-system/reference.html`
- 값의 근거 파일: `docs/design-system/tokens.css`(토큰), `docs/design-system/components.css`(공용 부품), `docs/design-system/contrast-pairs.tsv`(대비 쌍)
- 공용 부품을 함께 쓰는 화면: 보드·리포트·기준 화면은 같은 `tokens.css`(리포트는 토큰만)와 `components.css` 사본을 싣는다. 공용 부품이나 토큰을 바꾸면 세 화면을 모두 다시 본다
- 디자인 시스템 스캐폴드 도구: `/ai-harness:design-system-builder`
