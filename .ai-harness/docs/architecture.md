# Architecture

ai-harness는 Claude Code·Codex CLI 공용 플러그인의 **원본 저장소**다. 빌드 단계가 없다 — 사용자는 `main` 브랜치를 그대로 설치하고, 셸 스크립트·Skill 지시·템플릿이 그대로 실행된다. 상세 구조는 `README.md`의 "저장소 구조 · 요구사항" 절이 원본이며 이 문서는 에이전트가 변경 위치를 고르는 데 필요한 지도만 담는다.

## 기술 스택 (실측)

- bash + `jq`가 본체. macOS 기본 `/bin/bash` 3.2와 Linux(CI `ubuntu-latest`) 양쪽에서 돈다.
- Python 3 **표준 라이브러리만**: `scripts/board/*.py`(`/board` 로컬 서버), `catalog/langfuse/scripts/*.py`, `evals/ab/`의 검사기.
- Node.js 18+: `/diagram`(`vendor/archify/`)만.
- 외부 패키지 매니저 파일(`package.json`·`pyproject.toml` 등)이 저장소 루트에 없다.

## 디렉토리와 책임

| 경로 | 책임 | 누가 읽나 |
|---|---|---|
| `.claude-plugin/` | Claude Code 플러그인 매니페스트(`plugin.json`)·마켓플레이스 | Claude Code 설치 |
| `.codex-plugin/plugin.json` | Codex 플러그인 매니페스트(`skills: ./skills/`) | Codex 설치 |
| `.agents/plugins/marketplace.json` | Codex 마켓플레이스 | Codex 설치 |
| `release.json` | 배포 버전·릴리스 URL. `scripts/check-update.sh`가 `main`의 이 파일로 최신 버전을 판단 | 업데이트 확인 |
| `hooks/hooks.json` | SessionStart(`session-start.sh`)·Stop(`tick.sh`)·PreToolUse(`member-edit-guard.sh`, `db-scan-guard.sh`, `background-watchdog-hook.sh`) | Claude Code |
| `skills/<name>/SKILL.md` | 플러그인 전역 Skill. Claude·Codex가 같은 파일을 읽는다(`agents/openai.yaml`은 Codex 표시용, 일부 Skill만) | 두 도구 |
| `agents/` | 플러그인 전역 에이전트(`harvest-reviewer`, `design-reviewer`) | Claude Code |
| `scripts/` | 수집·집계·보관·업데이트·sync·그래프 검증. `scripts/lib.sh`가 공용 변수·함수(데이터 디렉토리 `~/.ai-harness`, 설정 로드, `project_id_for_cwd`) | hook·Skill |
| `scripts/board/` | `/board` 로컬 서버(Python 표준 라이브러리 + 셸 진입점) | `/board` |
| `templates/` | `/harness-init`이 **다른 프로젝트**에 생성하는 진입점·그래프·러너 원본. `templates/managed-files.json`이 관리 생성물 카탈로그의 단일 출처 | `/harness-init`, sync |
| `catalog/` | `/setup`이 사용자 전역에 선택 설치하는 기본 스킬 원본(`catalog.json`, `design-skills.json`) | `/setup` |
| `mods/harness-delegations/` | 선택 설치 Claude Code mod(마켓플레이스의 별도 플러그인). 맡긴 Orca 탭 상태를 프롬프트 위 한 줄로 보이고 조율 세션에 알린다. 판정 문구는 `scripts/wait-delegation.sh`와 같게(`tests/automation.sh` 검사), 검증은 `claude plugin validate`·`claude plugin test` | Claude Code (mod를 켠 사용자) |
| `vendor/archify/` | `/diagram` 엔진 고정 사본과 `vendor/archify.lock.json`. `scripts/vendor-archify.sh`로만 갱신 | `/diagram` |
| `evals/` | Skill 평가 과제(`evals/<skill>/<case>/`)와 A/B 통제 실험(`evals/ab/`, `scripts/ab.sh`가 사용) | 메인테이너 |
| `tests/` | 회귀 테스트: 진입점 `run.sh`(영역 선택·`--changed`·`--lint`), 공용 `lib.sh`, 영역 파일 `<영역>.sh`, `fixtures/` | 로컬·CI |
| `docs/design/` | 설계 문서 | 사람 |

## 이 저장소 자신의 하네스

`AGENTS.md`·`CLAUDE.md`·`.ai-harness/`·`.agents/skills/`·`.claude/`·`.codex/`는 이 저장소를 개발하는 에이전트용 **생성물**이다(`templates/`에서 렌더링). 플러그인 기능을 바꾸려면 생성물이 아니라 `templates/`·`skills/`·`scripts/`를 고친다. 생성물 갱신은 `/ai-harness:harness-init --sync`로 한다.

## 데이터 흐름 (요약)

1. hook(`session-start.sh`, `tick.sh`)이 Claude·Codex 세션 기록을 추출(`extract-claude.jq`·`extract-codex.sh`)해 `~/.ai-harness/events/`에 쌓는다.
2. `/metrics`(`stats.sh`·`stats.jq`)가 집계, `/harvest`가 개선 PR을 만든다. 무인 실행은 `harvest-auto.sh`·`sync-auto.sh`·`autofix-auto.sh`(opt-in).
3. `/harness-init`이 템플릿을 대상 프로젝트로 복사·렌더링하고 `harness-sync-state.sh`로 해시를 기록, 이후 sync가 차이를 계획한다.

`PreToolUse(Bash)`의 `background-watchdog-hook.sh`는 `run_in_background: true` 입력마다 `background-watchdog.sh`를 자기 프로세스 그룹에서 출력과 분리해 띄우고 아무것도 출력하지 않는다. 명령을 바꾸지 않으므로 권한 판정·출력·종료 코드가 그대로다 — `updatedInput`으로 명령을 감싸면 Claude Code가 바뀐 명령으로 권한을 다시 판정해 allow 규칙이 맞지 않는다(실측). 감시자는 에이전트(hook의 `$PPID`)의 자식으로 hook 뒤에 새로 뜬 프로세스 그룹 리더 중 인자에 명령 첫 줄이 든 것을 찾아 (그룹 pid를 `~/.ai-harness/bg-watchdog/`에 선점, 첫 줄이 공백 빼고 4자 미만이면 감시하지 않음) 그룹이 남아 있는 동안 지켜본다. 에이전트가 사라지면 그룹 전체를 TERM → 최대 5초(비면 바로) → KILL로 끄고, 그룹이 비면 끝난다. 찾지 못하거나 에이전트를 처음부터 볼 수 없으면 아무것도 하지 않는다. 끄기: `HM_BACKGROUND_WATCHDOG=0`. 한계: `setsid`로 새 세션을 만든 자손, 명령 안에서 `&`로 띄우고 곧바로 끝나는 리더 셸의 그룹(`npm run dev > log &` 형태 — dev 서버는 `&` 없이 `run_in_background`로 띄운다), 포그라운드로 시작했다가 백그라운드로 넘어간 명령, 권한 확인을 120초 넘게 기다린 뒤 승인된 명령은 정리하지 못한다. `nohup x &`처럼 명령 안에서 다시 `&`로 띄운 것은 감시자가 리더 셸을 잡았는지에 따라 정리되기도 남기도 한다 — 세션 뒤에도 살려야 하는 프로세스는 `setsid`로 띄운다.

`heavy-slot-hook.sh`는 `PreToolUse(Bash)`(timeout 600초)와 `PostToolUse(Bash)`에 붙는다(opt-in `HM_HEAVY_SLOTS`). 세그먼트 머리가 무거운 명령 패턴(패키지 매니저 build·dev·start·test:ci·e2e, next·vite·playwright·jest, gradle·mvn, compose up)이면 `~/.ai-harness/heavy-slots/<tool_use_id>.json`을 lock 안에서 만들고, 상한(메모리 여유에 따라 줄인다)이 차 있으면 2초 간격으로 기다리다 `HM_HEAVY_WAIT` 뒤 `deny`한다 — hook timeout을 넘기면 Claude Code가 명령을 그냥 실행하므로(실측) 대기는 그 전에 끝낸다. 반환은 포그라운드 PostToolUse·PostToolUseFailure(실패한 명령은 PostToolUse가 없다 — 실측), 그리고 획득 때마다 회수: 에이전트 pid가 없거나, transcript에 그 `tool_use_id`의 `tool_result`가 있거나(Esc로 끊긴 호출은 PostToolUse가 없다 — 실측), TTL을 넘긴 슬롯. 백그라운드 명령은 PostToolUse가 띄운 직후 오므로(실측) 반환하지 않고, `background-watchdog.sh`가 찾은 그룹의 선점 디렉토리에 남긴 `tool_use_id`가 있고 그 그룹이 살아 있는 동안 쥔다(그룹을 찾는 120초 동안은 유예, 백그라운드 대기는 `HM_HEAVY_BG_WAIT` 60초로 줄여 감시자가 그룹을 놓치지 않게 한다). 한도를 이 에이전트의 백그라운드 슬롯만 쥐고 있으면 기다리지 않고 바로 `deny`한다.

## 브랜치·배포

- `main` = 릴리스된 상태만(설치 경로가 그대로 읽는다). `develop` = 통합 브랜치. 작업 브랜치는 `develop`에서 따고 `develop`으로 PR.
- 배포 단계는 없다: 릴리스 PR(`develop` → `main`, merge commit) 머지 뒤 태그·GitHub 릴리스 발행이 곧 배포다. 절차는 `CONTRIBUTING.md`의 "릴리스".
- CI: `.github/workflows/test.yml`(push·PR마다 bash 문법·shellcheck·`tests/run.sh`), `.github/workflows/release.yml`(태그·릴리스 메타데이터 검증).
