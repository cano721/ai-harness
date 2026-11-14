# Fix Bug — ai-harness

노드·전이·수리 한도의 계약은 `.ai-harness/workflows/bug-fix-graph.json`이 단일 출처다. 이 문서는 이 저장소의 프로젝트 사실만 적는다. 러너(`.ai-harness/workflows/workflow-driver.sh --workflow bug-fix`)가 있으면 러너로 실행한다.

## 1. 증거 수집 (편집 금지)

- `/investigate`의 조사 보고 파일을 받으면 그 보고가 증거 수집 결과다. 다시 재현하지 않고 2절 Brief부터 쓴다(러너는 `--investigation <보고 파일>`). 보고에 재현도 동등한 근거도 없으면 평소대로 수집한다.
- 재현은 사용자 홈을 건드리지 않게 격리한다: `HARNESS_METRICS_DIR=<임시 폴더>`, 필요하면 `HM_AUTO_WORKTREE_DIR`·`HM_CLAUDE_SKILLS_DIR`·`HM_CODEX_SKILLS_DIR`도 임시 경로로. 사용자 데이터(`~/.ai-harness`, `~/.claude`)를 지우거나 덮는 명령은 재현에 쓰지 않는다.
- 플랫폼 차이를 먼저 의심한다: macOS `/bin/bash` 3.2 vs Linux bash 5, BSD vs GNU `sed`·`date`, `jq` 버전. 재현 환경(OS·bash·jq 버전)을 기록한다.
- 세션 기록 추출 버그는 `tests/fixtures/claude/`·`tests/fixtures/codex/` 형식의 최소 fixture로 재현한다(실제 대화 내용·식별자를 fixture에 넣지 않는다).

## 2. Bug Fix Brief (승인 게이트)

관찰된 동작 / 기대 동작, 영향(누가·어떤 설정에서), 재현 증거, 원인 가설과 반증 방법, 회귀 검증, 최소 변경 범위, `CHANGELOG.md` `## Unreleased`의 `### 버그 수정` 항목 초안. 승인은 사용자 설정 `~/.ai-harness/config`의 `HM_APPROVAL_REPOS`(저장소별 매칭) > `HM_APPROVAL` > 기본 `human` 순으로 결정한다. manifest의 기존 `approval` 값은 무시하며, 값이 있으면 개인 설정으로 옮기라는 안내를 한 번 남긴다. 재현도 안전한 관측 계획도 없으면 고치지 않고 필요한 환경·로그·기대 동작을 요청한다.

## 3. 회귀 → 수정

- **회귀 테스트는 test-engineer**(`tests/run.sh` 블록, 수정 전 실패 확인), **수정은 developer**(`scripts/`·`skills/`·`templates/` 등). developer는 `tests/**`를 고치지 않는다.
- 리뷰 → 원인별 수정 → 검증 → 재리뷰. 한도는 그래프 수리 한도, 넘거나 제품·환경 판단이 필요하면 사용자에게 넘긴다.

## 4. 검증 명령

```bash
bash tests/run.sh
bash -n scripts/*.sh scripts/board/*.sh tests/*.sh
npx --yes shellcheck -S style -x scripts/*.sh scripts/board/*.sh tests/*.sh
scripts/release-prep.sh --check
```

## 5. publish 노드가 쓸 사실

`implement-feature.md` 5절과 같다: 기준 `develop`, 브랜치 `fix/<요약>`(이슈가 있으면 `fix/<이슈번호>-<요약>`), 커밋 `fix(<scope>): ... (#<이슈>)`, `gh pr create --base develop`(일반 PR, 본문 `Closes #<이슈>`), 원격 CI `gh pr checks <PR> --watch`. 버전 파일은 올리지 않는다. 이미 릴리스된 버전의 치명적 문제(hotfix)만 `main`에서 따고 `main`으로 PR한다 — 이 판단은 사람에게 묻는다.

## 6. 이슈 트래커

GitHub Issues(`gh issue view <n>`). 상태 전환은 하지 않는다.
