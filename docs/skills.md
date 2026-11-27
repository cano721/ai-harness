# Skills 상세

[← README](../README.md)

### 플러그인에 기본 제공

| Skill | 언제 쓰나 | 하는 일 | 자동 실행 여부 |
|---|---|---|---|
| `/harness-init` | 새 프로젝트를 시작하거나 기존 하네스 설정·생성물을 최신화할 때 | 코드베이스를 실측하고, 테스트·Git 정책과 도구 통합에 맞춰 `AGENTS.md`, `.ai-harness`, 역할 agent를 생성·변경·동기화합니다. | 사용자 실행 |
| `/metrics` | 사용 현황이나 특정 세션의 병목을 확인할 때 | 세션·토큰·문서 읽힘·워크플로·오류/가드 신호를 조회합니다. 로컬 event cache는 갱신하지만 프로젝트 파일은 수정하지 않습니다. | 사용자 실행, 읽기 전용 |
| `/harness-impact` | 하네스를 도입하고 무엇이 나아졌는지 보고 싶을 때 ("하네스 효과 보여줘") | `/harvest`가 반영한 개선마다 근거가 된 세션과 반영 뒤 세션에서 같은 실수가 나온 비율을 비교해 사라짐·줄어듦·재발·판단 보류로 보여주고(같은 시기 비교라 모델 교체 영향이 작습니다), 편집 가드가 무엇을 막았는지(가드 종류·도구·대상, 경로·비밀값 가림), 에이전트가 프로젝트 사실을 몰라 생긴 문제의 추이를 함께 담습니다. 설치일 직전 기간과 최근 기간의 비교(같은 지적을 다시 하게 된 횟수, 작업당 턴, 툴 오류, 선택 시 재작업 PR 비율)는 오프라인 HTML 리포트 한 파일에 같이 들어가고, 턴·시간·토큰은 보조 지표로 내려 모델이 바뀌었거나 표본이 적으면 그 숫자 옆에 경고를 붙입니다. 변화를 원인으로 단정하지 않습니다. 원인을 확인하려면 `--ab`로 같은 과제를 합성 저장소에서 하네스 유무로 실제 에이전트에 돌려 숨긴 검사로 채점합니다(확인 후 실행, 비용 상한, Claude Code 전용). 설치 30일 뒤 세션 시작 때 한 번 안내합니다. | 요청 시 자동 선택·사용자 실행, 읽기 전용 |
| `/harvest` | analysis batch가 생겼거나 하네스 개선을 검토할 때 | 축적된 활동·교정 신호를 분석해 행동을 바꿀 만한 개선안만 제안하고, 승인된 경우 PR을 만듭니다. | 사용자 실행 |
| `/autofix` | 운영 에러(Sentry·Datadog·사용자 어댑터)를 근거로 버그를 고치고, 고친 뒤 정말 멈췄는지 확인할 때 | 저장소의 `monitor` 설정을 만들고, 에러 묶음을 프로젝트 `fix-bug` 절차로 고쳐 draft PR을 엽니다. 병합·배포 뒤 같은 에러가 다시 나오는지 지켜봐 해결·재발을 판정합니다. | 사용자 실행, `HM_AUTOFIX_AUTO=1`이면 정기 실행 |
| `/harness-update` | 설치 버전을 확인하거나 최신 버전을 적용할 때 | `--check`으로 확인하고, `--apply`가 명시된 경우에만 현재 호스트의 플러그인을 업데이트합니다. | 사용자 실행 |
| `/understand-change` | AI가 만든 변경이나 낯선 PR·브랜치를 사람이 이해해야 할 때 | 변경의 배경·직관·실행 흐름·위험·직접 검증을 설명하고, 필요하면 이해 확인 문제를 냅니다. 하네스가 있으면 `.ai-harness/workflows/understand-change.md`의 프로젝트 정책을 우선합니다. | 사용자 실행, 읽기 전용 |
| `/explain-for` | 이미 이해한 내용을 다른 청자(매니저·PM·주니어·비개발 직군·가족·친구)에게 전달해야 할 때 | 청자의 역할과 숙련도에 맞춰 프레이밍·용어·깊이를 조정해 다시 씁니다. 청자를 적지 않으면 어린아이도 이해할 수준으로 설명합니다. 사실은 그대로 두고 전달 방식만 바꿉니다. | 사용자 실행, 읽기 전용 |
| `/board` | 작업 세션·하네스 자동 실행·개인 자동화 설정을 한 화면에서 보고 답하고 싶을 때 ("보드 열어줘") | [Harness Board](board.md#board)를 필요할 때 띄워 브라우저로 엽니다. 이미 떠 있으면 그 주소를 다시 열고, `stop`·`status`로 끄거나 확인합니다. 세션 대화 보기·입력 보내기·질문과 권한 요청 답하기·끝난 세션 정리, 자동 harvest·sync 결과와 대기 harvest 실행, `~/.ai-harness/config` 개인 설정 변경, 저장소별 하네스 효과(반영한 개선의 재발 여부·설치 전후 지표)와 `/autofix` 진행·실행 이력 보기를 합니다. 데몬 없이 `127.0.0.1`에만 뜹니다. Python 3(표준 라이브러리)이 필요합니다. | 사용자 실행 |
| `/handsfree` | 손을 쓸 수 없을 때(아이를 안고 있을 때 등) 말로 Claude Code 세션을 부리고 싶을 때 ("핸즈프리 켜줘") | "헤이 클로드, ~"로 시작한 말만 기기 안에서 받아써(whisper.cpp) 승인·거절·번호·중단·세션 이동·읽어 주기 같은 조작을 하고, 나머지는 현재 Orca 세션에 프롬프트로 보냅니다. 입력 칸이 보일 때만 보내고, "앞으로 묻지 않음" 선택지와 위험 명령은 음성 한마디로 통과시키지 않습니다. `setup`이 녹음 도구·받아쓰기 서버·모델을 설치하고, `hooks`·`statusline`(선택)이 읽어 주기 훅과 상태 표시줄을 넣습니다. macOS·Orca·Python 3이 필요합니다. | 사용자 실행 |
| `/handsfree-ui` | 핸즈프리가 무엇을 들었는지 보거나 설정을 바꿀 때 ("핸즈프리 화면 열어줘") | 듣기 프로그램이 `127.0.0.1`에 띄운 상태 화면을 Orca 탭으로 엽니다. 지금 상태·마이크 음량·방금 들은 말과 결과·세션별 상태·기록을 보고, 말 끝 기다림·읽어 주기·소리·조용한 시간·호출어(알아듣지 못한 호출 추천)·세션 별명·단축 명령을 바꿉니다. | 사용자 실행 |
| `/setup` | 플러그인을 처음 설치했거나 기본 스킬을 추가·제거할 때 | [기본 스킬 카탈로그](#skill-catalog)(datadog·sentry·jira·confluence·langfuse·ga)에서 고른 것만 사용자 전역 스킬 폴더에 설치하고, 토큰 발급·저장·연결 확인을 안내하며, 회사·팀 전용 값을 사용자 규칙 파일로 남기고, 선택형 자동화 옵션을 켭니다. | 사용자 실행 (설치 후 첫 세션에 한 번 안내) |
| `/diagram` | 시스템 구조·요청 흐름·API 시퀀스·데이터 파이프라인·상태 전이를 그림으로 봐야 할 때 | 내장된 [Archify](https://github.com/tt-a1i/archify) 엔진으로 타입 검증된 다이어그램을 인터랙티브 HTML로 만듭니다. 실제 코드를 그릴 때는 커밋된 소스를 근거로 검증합니다. Node.js 18+가 필요하고, 브라우저 검증 단계는 Chrome/Chromium을 씁니다. | 사용자 실행, `.archify/`에 산출물 생성 |
| `/landing-page` | 소개 페이지·랜딩·회사 홈페이지·캠페인 페이지 같은 마케팅용 웹 페이지를 만들거나 다듬을 때, 또는 그 시안(Figma·이미지·HTML·영상)을 코드로 옮길 때 | 브리프 → 방향 → 레이아웃·타이포(한글 포함) → 모션 → 브라우저 검증 순서로 진행합니다. 저장소 디자인 시스템이 있으면 항상 그 값을 우선하고, 감소 모션·스크립트 실패 시에도 콘텐츠가 보이게 하며, 외부 컴포넌트 코드는 기억이 아니라 원본에서 받아옵니다. 하네스가 있으면 `.ai-harness/workflows/landing-page.md`를 우선합니다. 업무 화면(제품 UI)이나 디자인 시스템 생성에는 쓰지 않습니다. | 요청 시 자동 선택·사용자 실행 |
| `/design-references` | 페이지·화면·모바일 청첩장·인쇄물·그래픽을 만들기 전에 같은 분야 사이트·경쟁사·인터랙션 레퍼런스를 모아 보고 싶을 때 ("경쟁사랑 레퍼런스 모아줘", "모바일 청첩장 레퍼런스 모아줘") | 검색을 한 턴에 동시에 보내고, 모든 페이지를 한 번에 캡처하며(봇 확인 화면은 실제 브라우저로 다시 열어 바꾸거나 다른 사이트로 교체), 톤·구성요소·레이아웃·인터랙션·경쟁사 다섯 종류로 나눠 테이크 라인과 경쟁사 분석을 붙입니다. 매체(`--medium web-page|mobile-page|print|graphic`, 기본 웹페이지)에 따라 캡처 폭·종류별 최소치·탭 이름이 바뀌고, 이미지 원본 주소를 그대로 레퍼런스로 쓰며, Pinterest·Behance 같은 모음 사이트는 작품 단위로 셉니다. 한 사이트는 한 종류에만, 캡처가 비거나 막힌 레퍼런스는 남기지 않는 검사(`scripts/design-refs.sh check`)를 통과해야 보드를 http로 띄웁니다. `/landing-page`의 레퍼런스 단계도 같은 절차·검사를 씁니다. Node.js와 Playwright Chromium이 필요합니다. | 요청 시 자동 선택·사용자 실행 |
| `/design-system-builder` | 프로젝트의 디자인 시스템을 처음 만들거나, 흩어진 값을 정리하거나, 시안에서 토큰을 뽑을 때 | 기존 코드 추출(같은 의도로 3회 이상 쓰인 값만, 기존 이름 유지)·새로 설계(질문 라운드당 3개 이하, 추천 기본값 제시)·시안 추출(확인 전까지 draft) 중 하나로 디자인 규칙 문서·스택별 토큰 파일(CSS 변수·Tailwind·theme.ts·Flutter·Compose·SwiftUI)·반복된 공통 컴포넌트·기준 화면을 만듭니다. 규칙 문서의 필수 절이 `design-audit`의 채점 입력입니다. 기존 문서는 덮어쓰지 않고 refresh/merge를 묻고, 하네스 보호 파일은 diff 승인 후에만 고칩니다. 요청하면 토큰 파일을 원본으로 Figma 라이브러리(Variables·Text style·컴포넌트 variant)를 생성하고, 이후에는 Figma와 토큰 값의 어긋남을 보고합니다(Figma 원격 MCP 쓰기 권한 필요). 랜딩·업무 화면 구현에는 쓰지 않습니다. | 사용자 실행, 하네스 없이도 동작 |
| `/design-screen` | 디자인 시스템으로 새 화면 시안을 그리거나 기존 화면에 요구사항을 붙일 때 — Figma든 코드든 | 디자인 시스템이 가진 것(Figma 라이브러리·코드 토큰과 공통 컴포넌트)과 요청으로 그릴 곳을 고릅니다. 둘 다 있고 요청이 말하지 않으면 한 번 묻습니다. 기획을 화면 분류·형제·상태(빈·로딩·에러 등)·컴포넌트 매핑으로 정리한 뒤, Figma면 라이브러리 인스턴스와 Variables만으로 프레임을, 코드면 프로젝트 스택으로 토큰·공통 컴포넌트만 쓴 화면과 상태별 목 데이터를 만들어 브라우저로 캡처합니다. 디자인 시스템에 없는 요소는 `제안 / …`으로 따로 둡니다. 그 다음 `design-audit` 기준으로 독립 채점하고 감점 순으로 고쳐 다시 재는 루프를 통과(90+·절반 미만 축 없음)까지, 최대 3회 돕니다. 요구사항을 깎거나 디자인 시스템을 고쳐 점수를 올리지 않습니다. 코드 시안은 커밋하지 않고, 실데이터 연동·테스트·PR은 프로젝트 기능 워크플로(`implement-feature`)로 넘깁니다. 규칙 문서가 필요하고, Figma 대상은 Figma 라이브러리와 Figma 원격 MCP 쓰기 권한이 필요합니다. | 요청 시 자동 선택·사용자 실행 |
| `/design-polish` | 이미 동작하는 화면을 전반적으로 다듬을 때 — 위계·간격·색·형제 화면과의 일관성 | 화면을 실제 브라우저로 뷰포트·테마마다 캡처하고 독립 비평으로 근거(캡처·규칙 문서 절) 달린 고칠 목록을 냅니다. 하네스에 `design-polish` 워크플로가 있으면 그 진입점으로 넘겨 고른 항목을 고치고 다시 측정·검토하며, 없으면 비평과 고칠 목록까지만 하고 파일을 바꾸지 않습니다. | 요청 시 자동 선택·사용자 실행 |
| `/ux-writing-builder` | 화면 문구 규칙(말투·해요체/합니다체·원칙·용어집·버튼/토스트/에러 등 컴포넌트별 규칙)을 처음 정하거나 다시 정리할 때 | 기존 코드의 문구를 실측해(`scripts/ux-writing-lint.py extract`) 섞인 종결 어미와 같은 뜻 다른 단어를 보여 주고, 라운드당 3개 이하 질문(추천 기본값 포함)으로 정해 `.ai-harness/docs/ux-writing.md`를 만듭니다. 일반 원칙 12개를 기본안으로 제안하고, 규칙마다 근거(코드 위치·작성자 결정·참고 자료)를 남깁니다. 기존 문서는 refresh/merge/leave 중 고르게 합니다. 장문 윤문에는 쓰지 않습니다. | 사용자 실행, 하네스 없이도 동작 |
| `/ux-writing-audit` | 변경분·화면·기획서 문구가 규칙에 맞는지 볼 때, UI 문구를 바꾼 PR 전 | 용어집 금지어·금지 표현·종결 어미는 스크립트가 결정적으로 잡고(수정안의 조사까지 맞춤), 버튼이 결과를 말하는지·에러가 원인과 다음 행동을 주는지 같은 맥락은 규칙 문서 기준으로 판단해 `위치·원문·수정안·위반 규칙` 표와 점수(90점·주요 위반 없음이면 통과)를 냅니다. 규칙 문서가 없으면 채점하지 않습니다. 하네스의 `implement-feature`·`fix-bug`는 문서가 있으면 UI 문구를 쓸 때 읽고 PR 전에 이 감사를 돌립니다. | 요청 시 자동 선택·사용자 실행 |

### 프론트엔드 코드 판단 Skill (프론트 프로젝트에서 `/harness-init`이 생성)

React/TypeScript 저장소에서 **판단**이 필요할 때 여는 Skill입니다. 전역 플러그인 Skill이 아니라, `/harness-init`이 프로젝트를 실측해 **프론트엔드로 감지된 저장소에서만** 프로젝트 로컬 Skill로 생성합니다 — 백엔드 전용 저장소에는 노출되지 않습니다. 모두 읽기 전용 판단 지침이고, 프로젝트 고유 사실(디자인 시스템·선언 사다리·FSD 여부)은 `/harness-init`이 `.ai-harness/docs/frontend.md`에 실측으로 채워 Skill이 런타임에 읽습니다.

| Skill | 언제 쓰나 | 생성 조건 |
|---|---|---|
| `frontend-fundamentals` | 코드 품질을 리뷰할 때. Toss Frontend Fundamentals의 가독성·예측 가능성·응집도·결합도 4축으로 분석하고 트레이드오프까지 씁니다. | 프론트 감지 |
| `declarative-code` | 추상화를 올릴지(공용 컴포넌트 승격·훅 추출·래퍼 도입) 판단하거나 컴포넌트 props/이벤트 API를 설계할 때, 그리고 추상화가 새서 디버깅할 때. | 프론트 감지 |
| `frontend-testing` | 이 변경에 테스트를 쓸지, 쓴다면 어느 층위·레이어인지, 깨진 테스트를 고칠지 지울지 정할 때. | 프론트 감지 |
| `no-unnecessary-effects` | `useEffect`를 쓰기 직전에. 정말 외부 시스템 동기화인지 결정 트리로 거릅니다. | 프론트 감지 |
| `feature-sliced-design` | FSD v2.1로 구조를 잡거나 코드 위치·공개 API·cross-import를 정할 때. | **FSD 감지/opt-in일 때만** |
| `frontend-team` | 파일을 만들거나 고치기 전에. 산출물이 생기는 자리로 `fe-architect`(구조·추상화·UX 디테일·리뷰)·`fe-implementer`(요구사항 구현·API 연동)·`fe-designer`(디자인 규칙 산출물·채점)에게 담당을 나누고 "다음 담당"으로 잇습니다. 범용 developer·reviewer·test-engineer 페르소나 대신 이 역할 셋이 생성됩니다. | **프론트 팀 구성 opt-in일 때만** |
| `design-audit` | 페이지·블록·컴포넌트가 디자인 규칙 문서를 지키는지 다섯 축(골격·색·컴포넌트 문법·형제 정합·톤)으로 채점할 때. `fe-designer`의 루프가 씁니다. | **디자인 규칙 문서 + 기준 화면(스토리북 또는 서버 렌더링 예시 페이지)이 있을 때 opt-in** (`stacks`에 `design-system`). 서버 렌더링 저장소도 대상이며, `fe-designer`는 프론트 팀 구성까지 있을 때만 |

### UI 검토 계약 (화면이 있는 프로젝트에서 `/harness-init`이 생성)

코드 리뷰와 기능 테스트를 통과한 UI 변경도 "사람이 그 화면을 보고 쓸 수 있는가"는 검증되지 않은 채 남습니다. `ui-review`는 바뀐 화면을 **실제로 렌더링하고 조작**해 디자인 시스템 일관성과 사용성을 검토하고, 주요 문제를 고친 뒤 다시 검증하는 계약입니다. React·Vue 같은 프론트 패키지뿐 아니라 Flask/Jinja·Thymeleaf·JSP 같은 서버 렌더링 화면도 대상입니다.

| 생성물 | 역할 | 생성 조건 |
|---|---|---|
| `ui-review` Skill + `references/checklist.md` | 요청 분석 → 디자인 시스템 확인 → 디자인 시스템 검토 → 실제 조작 UX 검토 → 수정·재검증 → 근거·한계 보고. 클릭 성공·클래스 존재·스크린샷 파일을 통과 근거로 쓰지 않습니다. 단독으로 기존 화면이나 UI PR을 점검할 때도 씁니다. | UI 감지 + opt-in (`stacks`에 `ui`) |
| `.ai-harness/workflows/ui-review-graph.json` | 단독 UI 검토의 노드·전이 계약 | 위와 같음 |
| `ui-review` `references/design-handoff.md` | 시안 처리 규칙. 구현 전 시안 값을 토큰과 대조하고(허용 오차 안이면 토큰으로 맞추고 목록, 새 값·새 패턴은 추천 기본값과 함께 화면당 한 번 질문), 검토 때 시안과 구현을 나란히 캡처해 차이를 일치·조정·누락·상충·승인 없이 추가로 나눕니다. `/landing-page`의 같은 파일과 내용이 같고, 프론트 팀 구성이면 `frontend-team`에도 들어갑니다. | 위와 같음 |
| `.ai-harness/docs/ui.md` | 앱 실행·로그인·지원 뷰포트·테마·기준 화면 등 프로젝트 고유 사실 (보호 파일) | 위와 같음 |

기능·버그·리뷰 그래프에는 선택 노드 `ui_review`가 있습니다. Brief가 화면 검증 시나리오를 내면(리뷰는 변경이 화면을 바꿀 때) 코드 리뷰 뒤 이 노드가 작업 트리를 바꾸지 않고 `.ai-harness/docs/ui.md`가 화면마다 선언한 렌더 대상(`chromium`·`webkit`·`firefox`·시뮬레이터/에뮬레이터, 선언이 없으면 chromium)으로 화면을 검증하고 쓴 엔진을 증거에 남깁니다. 선언한 엔진을 쓸 수 없으면 다른 엔진으로 대신하지 않고 미검증으로 넘깁니다. 주요 문제는 repair → 재리뷰 → `ui_review`로 다시 돌고, 검증하지 못하면 done이 아니라 "구현 완료, 화면 미검증"으로 사람에게 넘깁니다. 프로젝트의 디자인 문서·토큰·공통 컴포넌트·기준 화면이 계약보다 우선하고, 설치된 외부 디자인 Skill은 선택 보조로만 씁니다.

시안이 있으면 값의 기준은 여전히 토큰이고 점수(`design-audit`)도 규칙 문서·형제 페이지로만 매깁니다. 구조·흐름은 시안을 따르고, 시안과의 차이는 점수 밖 차이표로 보고합니다. 체크리스트는 모션(감소 모션 렌더 확인·전환 중 조작·반복 정지·깜빡임), 대비 4.5:1/3:1, 색 단독 상태, 200% 확대·320px 리플로, 터치 24px 하한과 44px 권장, 상태 알림(`aria-live`), 입력 효율, 빈 상태 유형, 401/403/404/429/500/오프라인 구분, 증거 출처(에뮬레이션·실기기)까지 봅니다.

### 네이티브 UI 검토 (네이티브 앱에서 `/harness-init`이 생성)

React Native·Expo(`package.json`), Flutter(`pubspec.yaml`), iOS(`*.xcodeproj`·`Podfile`), Android(`build.gradle`의 `com.android.application`·`com.android.library` 플러그인) 저장소를 네이티브 앱으로 감지합니다. 백엔드 Gradle 저장소는 감지하지 않고, React Native는 웹 프론트로 잡지 않습니다(`react-native-web`이면 둘 다).

| 생성물 | 역할 | 생성 조건 |
|---|---|---|
| `native-ui` Skill + `references/checklist.md`·`platforms.md` | UI 검토 계약의 단계·판정·거짓 통과를 그대로 쓰고, 브라우저 대신 시뮬레이터·에뮬레이터로 렌더링·조작합니다. 안전 영역, 44pt/48dp 터치 영역, Dynamic Type·`sp`, 다크, 스크린리더 이름·역할·상태, 감소 모션, 뒤로 가기 상태 유지, 플랫폼별 탐색(iOS 탭 바·가장자리 스와이프, Android 내비게이션 바·레일·predictive back·edge-to-edge)과 `xcrun simctl`·`adb` 캡처 방법을 담습니다. 수치는 Apple HIG·Material 3·WCAG 2.2를 출처로 적습니다. | 네이티브 감지 + opt-in (`stacks`에 `native`) |
| `native-ui` `references/ui-review-contract.md`·`design-handoff.md` | UI 검토 계약과 시안 처리 규칙의 사본. 웹 계약이 바뀌면 sync가 함께 갱신합니다. | 위와 같음 |

대상 플랫폼·실행 명령·기기는 `.ai-harness/docs/ui.md`에 적습니다. 빌드·실행 도구가 없으면 `unverified`로 보고합니다.

`feature-sliced-design`과 `no-unnecessary-effects`는 각각 [feature-sliced/skills](https://github.com/feature-sliced/skills), [Cst2989/react-tips-skill](https://github.com/Cst2989/react-tips-skill)의 사본으로, 둘 다 MIT 라이선스입니다. 전역 Skill `/explain-for`는 [dreambigou/eli5](https://github.com/dreambigou/eli5)(MIT)의 파생물입니다. 전역 Skill `/landing-page`는 [mengto/skills](https://github.com/mengto/skills)·[greensock/gsap-skills](https://github.com/greensock/gsap-skills)·[philotheephilix/reactbits.dev-skill](https://github.com/philotheephilix/reactbits.dev-skill)·[KumarSashank/motiscope](https://github.com/KumarSashank/motiscope)(모두 MIT)에서 일부 규칙을 가져와 다시 쓴 파생물이며, 원문이나 컴포넌트 코드는 담지 않습니다. 전역 Skill `web-design-guidelines`의 규칙 본문은 [vercel-labs/web-interface-guidelines](https://github.com/vercel-labs/web-interface-guidelines)(MIT)의 고정 커밋 사본이고, `emil-design-eng`은 [emilkowalski/skill](https://github.com/emilkowalski/skill)(MIT)의 사본, `/design-system-builder`의 `references/theme-and-components.md`는 [wshobson/agents](https://github.com/wshobson/agents)의 `design-system-patterns`(MIT)에서 일부를 다시 쓴 파생물입니다. `/diagram`이 쓰는 `vendor/archify/`는 [tt-a1i/archify](https://github.com/tt-a1i/archify)(MIT) 릴리스 패키지의 고정 사본이며, 갱신은 `scripts/vendor-archify.sh <version>`으로만 합니다. 저작권·라이선스 전문은 [`THIRD-PARTY-LICENSES.md`](../THIRD-PARTY-LICENSES.md)에 있습니다.

<a id="skill-catalog"></a>

### 기본 스킬 카탈로그 (`/setup`으로 선택 설치)

외부 도구를 curl(langfuse·ga는 표준 라이브러리만 쓰는 Python 스크립트)로 다루는 범용 Skill입니다. 플러그인 Skill로 넣으면 쓰지 않는 도구의 설명까지 모든 세션에 실리므로, 플러그인은 원본(`catalog/`)만 들고 있고 `/setup`에서 고른 것만 사용자 전역 폴더(Claude `~/.claude/skills/`, Codex `~/.agents/skills/`)에 복사합니다.

| Skill | 하는 일 | 필요한 환경변수 |
|---|---|---|
| `datadog` | 로그·메트릭·모니터·인시던트·이벤트 조회 (읽기 전용) | `DATADOG_API_KEY`, `DATADOG_APP_KEY` (`DD_*`도 인식), 선택 `DATADOG_SITE` |
| `sentry` | 이슈·최근 이벤트(스택트레이스)·릴리스 조회 (읽기 전용) | `SENTRY_AUTH_TOKEN`, `SENTRY_ORG`, 선택 `SENTRY_URL` |
| `jira` | 이슈 조회·JQL 검색·생성·수정·상태 전환·코멘트 | `JIRA_BASE_URL`, `ATLASSIAN_USER`, `ATLASSIAN_API_TOKEN` |
| `confluence` | 페이지 조회·CQL 검색·생성·수정·코멘트·첨부 | `CONFLUENCE_BASE_URL`, `ATLASSIAN_USER`, `ATLASSIAN_API_TOKEN` |
| `langfuse` | trace·비용·지연·프롬프트·점수·데이터셋 조회, 변경은 확인 뒤 (공식 MCP 도구를 서버 등록 없이 Python 스크립트로 호출, 여러 프로젝트는 별칭) | `LANGFUSE_PUBLIC_KEY`, `LANGFUSE_SECRET_KEY` (프로젝트 키) 또는 그 키를 비밀 저장소(AWS SSM·Vault 등)에서 꺼내는 명령 `LANGFUSE_PUBLIC_KEY_CMD`, `LANGFUSE_SECRET_KEY_CMD`, 선택 `LANGFUSE_HOST` (등록 스크립트가 리전 자동 탐지) |
| `ga` | Google Analytics 4 사용자·세션·이벤트·전환·실시간 지표 조회 (읽기 전용, Data API를 서비스 계정 키로 호출, 여러 속성은 별칭) | `GA_KEY_FILE` (서비스 계정 JSON 키 경로 — `/setup`이 `~/.ai-harness/keys/ga.json`(600)으로 복사해 저장, 원본은 사용자가 삭제), `GA_PROPERTY_ID` (숫자 속성 ID), 선택 `GA_PROPERTY_<별칭>` |

- **접속 정보**: `/setup`이 키마다 발급 주소·순서·필요한 읽기 scope를 안내합니다. base URL·이메일 같은 값은 대화로 받아 저장하고, 토큰은 대화에 남지 않도록 사용자가 별도 터미널에서 `scripts/setup.sh set --tool claude <KEY>`(숨김 입력)로 넣습니다. Claude Code는 `~/.claude/settings.json`의 `env`, Codex는 `~/.ai-harness/secrets.env`(권한 600, 셸 프로파일에서 source)에 저장됩니다. 저장 뒤 `setup.sh check <skill>`이 읽기 전용 호출 하나로 연결과 접속 계정을 확인하고, 401·403·404면 원인을 짚습니다. 각 Skill은 자격 증명을 명령 인자가 아니라 stdin(`curl -K -`)으로 넘깁니다.
- **회사·팀 전용 값**: 기본 프로젝트·스페이스·필터, Jira 스프린트·에픽 필드 ID, 이슈 생성 필수 항목, 작성 관례는 Skill 본문이 아니라 `~/.ai-harness/skills/<name>.md`에 둡니다. `/setup`이 계정에서 선택지를 읽어 와(`setup.sh detect`) 묻고 저장하며, 같은 이름의 개인 Skill이 있으면 거기서 회사 전용 값을 뽑아 초안으로 제안합니다. 카탈로그 Skill은 호출 전에 이 파일을 먼저 읽으므로, 본문을 고치지 않아 자동 갱신이 유지됩니다. 조직이 규칙을 한 곳(git 저장소나 공유 폴더의 `skills/<name>.md`)에 두면 `/setup team`이 개인 설정 `HM_TEAM_RULES` 또는 저장소 표식(`harness.json`·`workspace.json`의 `team_rules`)으로 원본을 찾아, 개인 파일과의 차이를 보여 주고 확인받은 뒤 팀 블록으로 넣습니다. 다시 가져오면 팀 블록만 바뀌고 개인 블록은 그대로이며, 원본이 바뀌면 세션 시작 안내가 알립니다(자동으로 덮어쓰지 않음).
- 설치한 사본은 해시로 추적합니다. 손대지 않은 사본은 플러그인이 업데이트되면 SessionStart가 새 버전으로 갱신하고 알립니다. 직접 고친 사본과, 원래 있던 같은 이름의 Skill은 건드리지 않습니다 — 교체는 `/setup`에서 명시했을 때만, 기존 폴더를 `~/.ai-harness/setup/backups/`로 옮긴 뒤 합니다.
- 카탈로그에 새 Skill이 추가되면 SessionStart가 한 번 알립니다. 안내를 끄려면 `HM_SETUP_HINT=0`.

<a id="design-skills"></a>

### 디자인 스킬 (내장 3종 + `/setup design`으로 선택 설치)

ai-harness는 디자인 데이터셋(팔레트·폰트·사이트 갤러리)을 담지 않고 절차만 둡니다. 그 빈자리는 외부 디자인 스킬이 채우고 작고 안정적인 3종(`web-design-guidelines`·`emil-design-eng`·`design-system-patterns`)은 고정 사본으로 내장했는데, 여러 개가 깔리면 모두 "UI 다듬어"에 반응해 결과가 PC마다 달라집니다. 그래서 **디자인 스킬 지도**(`templates/ui-review/references/design-skills.md`)가 작업마다 주도 스킬 하나와 영역별 보조 스킬을 정합니다. 프로젝트 디자인 규칙 > ai-harness 계약 > 지도 순으로 따르고, 설치되지 않은 스킬은 건너뜁니다.

| 작업 | 주도 | 보조(영역) |
|---|---|---|
| 지표 리포트·대시보드 | `impeccable` | `dataviz`(차트·지표 카드·차트 색), `ui-ux-pro-max`(토큰 없을 때 팔레트·폰트) |
| 랜딩·소개 | `/landing-page` | `design-references`(레퍼런스 수집), `design-taste-frontend`(방향 후보), `motion`(모션 API), `web-design-guidelines`(최종 점검) |
| 디자인 시스템 | `/design-system-builder` | 내장 `references/theme-and-components.md`(테마 전환·컴포넌트 구조, `design-system-patterns` 흡수), `awesome-design`(참고 명세) |
| 제품 화면 다듬기 | `/design-polish` | `impeccable`(비평), `emil-design-eng`(마감), `motion` |
| 하네스 저장소 화면 변경 | `ui-review`·`frontend-team` | `impeccable`(비평), `web-design-guidelines`(접근성) |
| 독립 디자인 검토 | 새 검토 세션 또는 `ai-harness:design-reviewer` 에이전트 | 새 검토 세션에서만 `impeccable`(비평), `web-design-guidelines`(점검) — 에이전트는 외부 스킬을 쓰지 않고 내장 가이드라인 규칙 파일만 읽는다 |

- **내장**: `web-design-guidelines`(규칙 본문을 [vercel-labs/web-interface-guidelines](https://github.com/vercel-labs/web-interface-guidelines) 고정 커밋 사본으로 담아 실행 때 받지 않음 — 플러그인 스킬 `ai-harness:web-design-guidelines`와 생성물 `ui-review/references/web-interface-guidelines.md`)·`emil-design-eng`(플러그인 스킬 `ai-harness:emil-design-eng`)은 네트워크 없이 동작하고, `design-system-patterns`는 겹치지 않는 테마 전환·컴포넌트 구조만 `/design-system-builder`의 참고 문서로 흡수했습니다. `/setup design`은 이 셋을 설치하지 않고, 예전에 받은 사본은 `design list`에 `superseded`로 보여 `design remove`로 지울 수 있게 합니다(사용자가 직접 둔 같은 이름 폴더는 건드리지 않습니다).
- **설치**: `/ai-harness:setup design`이 `catalog/design-skills.json`의 원본 저장소·고정 커밋에서 스킬 폴더만 받아(부분 클론) Claude `~/.claude/skills/`, Codex `~/.agents/skills/`에 둡니다. 외부 스킬은 사본을 재배포하지 않고, 라이선스와 실행 스크립트·네트워크 호출 검토 결과를 카탈로그에 적었습니다. 필수 묶음은 `impeccable`과 Claude 내장 `dataviz`(Codex 대응 없음)입니다. 원본을 고정할 수 없는 `awesome-design`·`motion`은 안내만 합니다. SessionStart는 외부 디자인 스킬을 자동 갱신하지 않습니다.
- **권유 시점**: `/harness-init`이 웹 UI 계약(`ui`·`frontend-team`·`design-system`)을 생성해 지도가 있는 저장소에서만, 필수 묶음이 없을 때 한 줄로 권합니다.
- **독립 검토**: `ai-harness:design-reviewer`(Claude 플러그인 에이전트)는 하네스 없는 저장소·단일 HTML 리포트도 실제로 렌더링·조작해 비평합니다. 편집 도구가 없고 Bash는 렌더링(저장소 밖 임시 디렉터리)에만 쓰며, 외부 디자인 스킬은 쓰지 않습니다(Skill 도구 없음). 인터페이스 가이드라인은 내장 규칙 파일을 읽어 기준에 더합니다. `ui-review` 계약이 있는 저장소에서는 그 계약이 우선합니다.

하네스 라이프사이클 Skill(`/harness-init`·`/setup`·`/board`·`/handsfree`·`/handsfree-ui`·`/harness-update`·`/harvest`·`/metrics`·`/harness-impact`·`/understand-change`·`/explain-for`·`/diagram`·`/design-system-builder`·`/ux-writing-builder`·`/ux-writing-audit`)과 `/landing-page`·`/design-references`·`/design-screen`·`/design-polish`, 내장 디자인 스킬 `web-design-guidelines`·`emil-design-eng`은 플러그인 설치만으로 사용할 수 있습니다. `/understand-change`와 `/explain-for`는 코드를 수정하지 않는 설명 전용이라 프로젝트 계약을 담지 않으므로 하네스가 없는 저장소에서도 그대로 동작합니다. `/landing-page`도 프로젝트에 파일을 깔지 않고, 저장소의 디자인 시스템·브랜드를 실행 시점에 읽어 쓰므로 하네스가 없어도 동작합니다. 반면 코드를 바꾸는 기능 개발·버그 수정·검토 Skill은 프로젝트 규칙(테스트 정책·Git 정책·검증 명령) 없이는 노출하지 않고, 아래처럼 `/harness-init`이 생성합니다.

### `/harness-init`이 프로젝트에 생성하는 진입점

`standard` 수준에서만 생성합니다. 선택하지 않은 도구의 파일은 만들지 않습니다. Codex는 프로젝트 로컬 Skill을, Claude는 같은 목적의 slash command 어댑터를 만듭니다.

| 프로젝트 기능 | Codex (`Codex` 또는 `둘 다` 선택) | Claude (`Claude` 또는 `둘 다` 선택) | 역할 |
|---|---|---|---|
| 기능 개발 | `.agents/skills/implement-feature/SKILL.md` | `.claude/commands/implement-feature.md` | 내부 템플릿을 프로젝트 정책으로 구체화해 생성합니다. `.ai-harness/workflows/implement-feature.md`와 프로젝트 docs를 먼저 읽는 진입점입니다. |
| 버그 수정 | `.agents/skills/fix-bug/SKILL.md` | `.claude/commands/fix-bug.md` | 내부 템플릿을 프로젝트의 재현·수정·회귀 검증 규칙으로 구체화해 생성합니다. |
| 원인 조사 | `.agents/skills/investigate/SKILL.md` | `.claude/commands/investigate.md` | 코드를 바꾸지 않고 원격 기준 코드·도메인 문서·재현 근거로 원인 보고를 씁니다. 수정이 필요하면 보고를 `/fix-bug`에 넘깁니다. |
| 기존 화면 품질 개선 | `.agents/skills/design-polish/SKILL.md` | `.claude/commands/design-polish.md` | 이미 동작하는 화면을 브라우저로 측정·채점하고, 독립 비평의 고칠 목록에서 사람이 고른 항목만 고친 뒤 다시 측정·검토합니다. |
| 코드 검토 | `.agents/skills/review/SKILL.md` | `.claude/commands/review.md` | 내부 템플릿의 risk 기반 검토·수정·재검토 규칙으로 구체화해 생성합니다. |
| 릴리스 | `.agents/skills/release/SKILL.md` | `.claude/commands/release.md` | 태그 방식 릴리스(manifest `release_policy`)를 러너로 실행합니다. 버전 확정 → 릴리스 브랜치·PR → 개인 단계에 따라 merge commit 병합·태그·노트·기록과 `main` → `develop` ff 안내까지 갑니다. |

`AGENTS.md`, `.ai-harness/workflows/`, `.ai-harness/docs/`, 역할 agent 설정도 함께 생성되며, 이들이 프로젝트 특화 규칙의 단일 출처입니다. 프로젝트 진입점은 내부 템플릿을 프로젝트에 맞게 연결한 결과물이며, 전역으로 제공되는 공용 Skill이 아닙니다.

변경 이해(`/understand-change`)는 여기에 없습니다 — 프로젝트 사본 없이 플러그인이 직접 제공하며, 초기화는 프로젝트별 설명 정책 파일 `.ai-harness/workflows/understand-change.md`만 만듭니다(사람 소유, 동기화 대상 아님).

Skill과 별개로 `SessionStart`·`Stop` hook이 정기 backfill을 깨웁니다(OS 스케줄러 불필요). 이 경로는 **기록, 누적량 판정, 알림**까지만 담당하며 `/harvest` 실행·코드 수정·PR 생성·업데이트를 자동으로 수행하지 않습니다. `HM_HARVEST_AUTO=1`을 켠 경우에만 batch가 생긴 시점에 `/harvest`를 백그라운드로 띄우고([자동 harvest](automation.md#auto-harvest)), `HM_SYNC_AUTO=1`을 켠 경우에만 뒤처진 저장소의 `/harness-init --sync`를 띄웁니다([자동 sync](automation.md#auto-sync)). `HM_DB_SCAN_GUARD=1`을 켜면 Bash 실행 전에 [DB 스캔 가드](guards-and-data.md#db-scan-guard)가 스키마 조건 없는 information_schema 조회를 막습니다. [stale reset 가드](guards-and-data.md#stale-reset-guard)는 기본으로 켜져 있어, HEAD의 조상이 아닌 커밋 위로 옮기는 `git reset --soft <ref>`를 막습니다.
