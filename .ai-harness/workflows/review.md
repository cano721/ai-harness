# Review — ai-harness

노드·전이·수리 한도의 계약은 `.ai-harness/workflows/review-graph.json`이 단일 출처다. 러너(`.ai-harness/workflows/workflow-driver.sh --workflow review`)가 있으면 러너로 실행한다. 초기 검토는 read-only이고 reviewer 페르소나(`.ai-harness/agents/reviewer.md`)의 체크 항목을 쓴다.

## 범위

- PR: `gh pr view <n>`·`gh pr diff <n>`. 기준은 `develop`(릴리스 PR이면 `main`).
- 로컬 변경: `git diff origin/develop...HEAD`.

## blocking으로 보는 것 (이 저장소 기준)

- `bash tests/run.sh`·`bash -n`·`npx --yes shellcheck -S style -x scripts/*.sh scripts/board/*.sh tests/*.sh` 중 하나라도 실패
- 새 동작에 `tests/run.sh` 단언이 없음(TDD 정책)
- macOS `/bin/bash` 3.2 또는 Linux에서 깨지는 구문
- 사용자 데이터(`~/.ai-harness`·`~/.claude`·사용자 저장소)를 확인 없이 지우거나 덮음, 무인 실행이 병합·force push함
- 회사·개인 식별자, 토큰, 사내 URL
- 기능 PR이 버전 파일(`.claude-plugin/plugin.json`·`.codex-plugin/plugin.json`·`release.json` `version`, CHANGELOG 버전 절)을 바꿈
- 템플릿 원본을 바꿨는데 `templates/managed-files.json`·바이트 동일 사본·`skills/harness-init/SKILL.md` 서술이 어긋남
- 사용자 영향이 있는데 `CHANGELOG.md` `## Unreleased` 항목이 없음

## 수리

blocking finding의 수리는 사람이 동의한 뒤(또는 `approval:auto` 정책)만 시작한다. 테스트는 test-engineer, 제품 코드는 developer 범위를 지킨다. 수리 뒤 위 검증 명령과 재검토를 거친다. 수리는 PR의 작업 브랜치에 일반 push로 올리고, 새 PR을 열거나 병합하지 않는다.
