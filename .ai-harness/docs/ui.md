# UI

ai-harness가 사용자에게 보여 주는 화면은 서버나 빌드 없이 열리는 **단일 HTML 화면**이다. 실측한 사실만 적는다. `ui_review` 노드와 `ui-review`·`design-audit` Skill이 런타임에 읽는다.

## 화면

| 화면 | 원본 | 여는 법 |
|---|---|---|
| Harness Board (작업 현황·하네스 동작·하네스 설정·하네스 효과·레퍼런스 보드·자동 수정·하네스 안내) | `scripts/board/template.html` (서버 `scripts/board/board-server.py`) | 아래 "보드를 격리해 띄우기" |
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
- 안내 카드의 "실행"은 새 세션 양식을 열고 띄우기는 실제로 `claude`를 띄운다. 검토할 때는 가짜 `claude`(예: `tests/fixtures/board-resident/claude`)가 든 폴더를 `PATH` 앞에 두고 보드를 연다. 실행 가능 여부는 `HM_CLAUDE_SKILLS_DIR`(기본 스킬 설치 여부)와 보드가 아는 하네스 저장소로 정해지므로, 막힌 상태를 보려면 빈 `HM_CLAUDE_SKILLS_DIR`와 빈 데이터 디렉터리로 연다.

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
