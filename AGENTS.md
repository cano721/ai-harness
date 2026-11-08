# AGENTS.md — ai-harness

Claude Code·Codex CLI 공용 플러그인 ai-harness의 원본 저장소다. `scripts/`·`skills/`·`templates/`가 곧 제품 코드이고, 이 파일과 `.ai-harness/`·`.agents/skills/`·`.claude/`·`.codex/`는 이 저장소를 개발하는 에이전트용 하네스 생성물이다(`/ai-harness:harness-init`이 `templates/`에서 만들었다). 플러그인 동작을 바꾸려면 생성물이 아니라 원본을 고친다.

## Preflight

1. 작업 유형을 고른다: 기능 → `/implement-feature`, 버그 → `/fix-bug`, 변경 검토 → `/review`. 단순 질문·탐색은 워크플로 없이 답한다.
2. 소스를 고치기 전에 `.ai-harness/docs/code-conventions.md`를 Read한다. 테스트를 쓰면 `.ai-harness/docs/testing.md`, 구조를 바꾸면 `.ai-harness/docs/architecture.md`도 Read한다.
3. 기준 브랜치는 `develop`이다. 작업은 `origin/develop`에서 딴 작업 브랜치(가능하면 worktree)에서 한다. 사용자의 현재 체크아웃을 바꾸지 않는다.

## Hard constraints

<!-- 실측으로 검증된 룰만 추가. 추측 금지. /harvest가 근거와 함께 채운다. -->

## 워크플로

| 진입점 | 종류 | Claude | Codex | 본문 |
|---|---|---|---|---|
| `/implement-feature` | 프로젝트 로컬 | `.claude/commands/implement-feature.md` | `.agents/skills/implement-feature/` | `.ai-harness/workflows/implement-feature.md` + `feature-delivery-graph.json` |
| `/fix-bug` | 프로젝트 로컬 | `.claude/commands/fix-bug.md` | `.agents/skills/fix-bug/` | `.ai-harness/workflows/fix-bug.md` + `bug-fix-graph.json` |
| `/review` | 프로젝트 로컬 | `.claude/commands/review.md` | `.agents/skills/review/` | `.ai-harness/workflows/review.md` + `review-graph.json` |
| `/ai-harness:understand-change` | 플러그인 제공 스킬 | 플러그인 설치로 제공 | 플러그인 설치로 제공 | `.ai-harness/workflows/understand-change.md` (선택 정책) |
| `/ai-harness:explain-for` | 플러그인 제공 스킬 | 플러그인 설치로 제공 | 플러그인 설치로 제공 | — |

그래프 러너: `bash .ai-harness/workflows/workflow-driver.sh start --workflow feature|bug-fix|review --request "<요청>"`. 승인 정책은 `.ai-harness/harness.json`의 `approval`(이 저장소는 `auto` — Brief와 `결정 사항`을 PR 본문에 남기고 진행, 사람만 정할 수 있는 것만 멈춤).

## 페르소나

역할 정의의 단일 출처는 `.ai-harness/agents/<role>.md`다. `.claude/agents/`·`.codex/agents/`는 그 파일을 가리킨다.

| 역할 | 쓰기 범위 | Claude | Codex |
|---|---|---|---|
| explorer | 없음 (read-only) | haiku | gpt-5.6-terra · low |
| test-engineer | `tests/**` | sonnet | gpt-5.6-terra · medium |
| developer | `scripts/**`·`skills/**`·`templates/**`·`agents/**`·`hooks/**`·`catalog/**`·`evals/**`·`docs/**`·README·CONTRIBUTING·`CHANGELOG.md`(`## Unreleased`만) 등 | sonnet | gpt-5.6 · medium |
| reviewer | 없음 (read-only) | opus | gpt-5.6 · high |
| docs-updater | `.ai-harness/docs/**` | sonnet | gpt-5.6-terra · medium |

TDD: test-engineer가 Red(실패 확인) → developer가 Green → Refactor. 위임은 독립적이고 범위가 좁은 작업에만 쓴다.

## Docs

| 문서 | 내용 |
|---|---|
| `.ai-harness/docs/architecture.md` | 디렉토리 책임, 기술 스택, 데이터 흐름, 브랜치·배포 |
| `.ai-harness/docs/code-conventions.md` | 셸(bash 3.2 호환)·Python·Skill/템플릿·듀얼 매니페스트·공개 저장소·커밋 규칙 |
| `.ai-harness/docs/testing.md` | `tests/run.sh` 실행·작성 규칙, CI와 같은 shellcheck |
| `.ai-harness/docs/domain.md` | 도메인 문서 인덱스 |
| `CONTRIBUTING.md` | 브랜치·버전·릴리스 규칙의 원본 |

## Quick Commands

```bash
bash tests/run.sh                                                             # 회귀 테스트 (CI와 같음)
bash -n scripts/*.sh scripts/board/*.sh tests/*.sh                            # 문법
npx --yes shellcheck -S style -x scripts/*.sh scripts/board/*.sh tests/*.sh   # CI와 같은 수준 (apt shellcheck는 SC2015도 실패)
scripts/release-prep.sh --check                                               # 버전 네 곳 정합성
```

## Git

- `main`은 릴리스된 상태만, `develop`이 통합 브랜치. 작업 브랜치 `<타입>/<한-일-요약>`은 `develop`에서 따고 `gh pr create --base develop`으로 PR한다(`--base` 생략 시 `main`으로 열린다).
- 커밋은 Conventional Commits(`feat:`·`fix(<scope>):`·`docs(<scope>):`·`chore:`), 끝에 `(#<이슈>)`. PR 본문에 `Closes #<이슈>`.
- **기능 PR은 버전 파일을 올리지 않는다**: `.claude-plugin/plugin.json`·`.codex-plugin/plugin.json`·`release.json`의 `version`과 CHANGELOG 버전 절은 릴리스 커밋의 `scripts/release-prep.sh <version>`만 바꾼다. 기능 PR은 사용자 영향이 있으면 `CHANGELOG.md`의 `## Unreleased`에만 항목을 남긴다.
- 듀얼 매니페스트: `.claude-plugin/plugin.json`과 `.codex-plugin/plugin.json`(그리고 `release.json`)의 버전·라이선스를 같이 유지한다.
- 공개 저장소다: 회사·개인 식별자(회사명·사내 도메인·이름·이메일)·토큰을 커밋하지 않는다.
- 에이전트는 커밋·일반 push·PR 생성까지(`git_policy: pr-only`). 병합은 사람, 또는 사용자가 개인 자동화 단계를 고른 경우 러너의 `merge` 노드. force push와 `develop`·`main` 직접 push는 하지 않는다.
- 릴리스(`develop` → `main`, merge commit)·태그·릴리스 노트는 `CONTRIBUTING.md`의 "릴리스" 절차를 사람이 진행한다.
