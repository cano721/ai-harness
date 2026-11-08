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
| `hooks/hooks.json` | SessionStart(`session-start.sh`)·Stop(`tick.sh`)·PreToolUse(`member-edit-guard.sh`, `db-scan-guard.sh`) | Claude Code |
| `skills/<name>/SKILL.md` | 플러그인 전역 Skill. Claude·Codex가 같은 파일을 읽는다(`agents/openai.yaml`은 Codex 표시용, 일부 Skill만) | 두 도구 |
| `agents/` | 플러그인 전역 에이전트(`harvest-reviewer`, `design-reviewer`) | Claude Code |
| `scripts/` | 수집·집계·보관·업데이트·sync·그래프 검증. `scripts/lib.sh`가 공용 변수·함수(데이터 디렉토리 `~/.ai-harness`, 설정 로드, `project_id_for_cwd`) | hook·Skill |
| `scripts/board/` | `/board` 로컬 서버(Python 표준 라이브러리 + 셸 진입점) | `/board` |
| `templates/` | `/harness-init`이 **다른 프로젝트**에 생성하는 진입점·그래프·러너 원본. `templates/managed-files.json`이 관리 생성물 카탈로그의 단일 출처 | `/harness-init`, sync |
| `catalog/` | `/setup`이 사용자 전역에 선택 설치하는 기본 스킬 원본(`catalog.json`, `design-skills.json`) | `/setup` |
| `vendor/archify/` | `/diagram` 엔진 고정 사본과 `vendor/archify.lock.json`. `scripts/vendor-archify.sh`로만 갱신 | `/diagram` |
| `evals/` | Skill 평가 과제(`evals/<skill>/<case>/`)와 A/B 통제 실험(`evals/ab/`, `scripts/ab.sh`가 사용) | 메인테이너 |
| `tests/run.sh` | 단일 회귀 테스트 스크립트 + `tests/fixtures/` | 로컬·CI |
| `docs/design/` | 설계 문서 | 사람 |

## 이 저장소 자신의 하네스

`AGENTS.md`·`CLAUDE.md`·`.ai-harness/`·`.agents/skills/`·`.claude/`·`.codex/`는 이 저장소를 개발하는 에이전트용 **생성물**이다(`templates/`에서 렌더링). 플러그인 기능을 바꾸려면 생성물이 아니라 `templates/`·`skills/`·`scripts/`를 고친다. 생성물 갱신은 `/ai-harness:harness-init --sync`로 한다.

## 데이터 흐름 (요약)

1. hook(`session-start.sh`, `tick.sh`)이 Claude·Codex 세션 기록을 추출(`extract-claude.jq`·`extract-codex.sh`)해 `~/.ai-harness/events/`에 쌓는다.
2. `/metrics`(`stats.sh`·`stats.jq`)가 집계, `/harvest`가 개선 PR을 만든다. 무인 실행은 `harvest-auto.sh`·`sync-auto.sh`·`autofix-auto.sh`(opt-in).
3. `/harness-init`이 템플릿을 대상 프로젝트로 복사·렌더링하고 `harness-sync-state.sh`로 해시를 기록, 이후 sync가 차이를 계획한다.

## 브랜치·배포

- `main` = 릴리스된 상태만(설치 경로가 그대로 읽는다). `develop` = 통합 브랜치. 작업 브랜치는 `develop`에서 따고 `develop`으로 PR.
- 배포 단계는 없다: 릴리스 PR(`develop` → `main`, merge commit) 머지 뒤 태그·GitHub 릴리스 발행이 곧 배포다. 절차는 `CONTRIBUTING.md`의 "릴리스".
- CI: `.github/workflows/test.yml`(push·PR마다 bash 문법·shellcheck·`tests/run.sh`), `.github/workflows/release.yml`(태그·릴리스 메타데이터 검증).
