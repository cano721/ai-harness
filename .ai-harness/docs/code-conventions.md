# Code Conventions

실측한 규칙만 적는다. 여기에 없는 것은 주변 코드를 source of truth로 확인한다.

## 셸 스크립트 (`scripts/*.sh`, `scripts/board/*.sh`, `tests/*.sh`)

- 첫 줄 `#!/usr/bin/env bash`, 다음 줄 `set -euo pipefail`. 파일 머리에 무엇을 왜 하는지 한국어 주석을 둔다.
- 인자 오류는 `usage()`가 stderr에 사용법을 찍고 `exit 2`. 하위 명령형 스크립트는 첫 인자를 `case`로 나눈다(`harness-sync-state.sh <status|record|plan|...>`).
- 같은 디렉토리의 스크립트·자원은 `DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"` 기준으로 찾는다. 공용 변수·함수는 `scripts/lib.sh`를 source한다(`# shellcheck source=scripts/lib.sh`).
- 사용자 데이터는 `~/.ai-harness`(`HM_DATA_DIR`, 테스트는 `HARNESS_METRICS_DIR`로 바꾼다). 설정 파일은 source하지 않고 `hm_load_config`로 `HM_`·`HARNESS_` 키만 읽는다.
- JSON 생성·가공은 `jq`(`jq -cn --arg ...`). 키가 없거나 null일 수 있으면 `.items[]?` 또는 `(.items // [])[]`.
- **macOS `/bin/bash` 3.2 호환**: 연관 배열·`mapfile`·`$'\u…'` 금지. 반복 안의 한 줄 읽기는 `read ... < <(...)` 대신 here-string(`<<<"$(...)"`) — 3.2가 프로세스 치환 fd를 닫지 않아 fd 한도에 닿는다(`tests/run.sh`가 `scripts/`·`templates/`·`hooks/`를 grep으로 검사).
- BSD·GNU 차이를 감싼다: 해시는 `shasum -a 256 || sha256sum`, `sed -i`·`date` 옵션 차이에 주의.
- shellcheck 경고는 구조를 바꿔 없앤다. `# shellcheck disable=SCxxxx`는 같은 줄에 근거 주석을 남길 때만 쓴다(예: `# shellcheck disable=SC2016  # 정규식·백틱을 문자 그대로 쓴다`).
- 가드 hook의 차단 메시지 첫 줄은 `[Direct edit guard] `처럼 대괄호 접두어로 시작한다 — `extract-claude.jq`·`extract-codex.sh`가 이 접두어로만 차단을 집계한다.

## Python (`scripts/board/*.py`, `catalog/langfuse/scripts/*.py`)

- 표준 라이브러리만 쓴다. 모듈 머리에 한국어 docstring으로 책임과 근거를 적는다.
- 외부 프로세스는 `subprocess.run([...], capture_output=True, text=True, timeout=...)` — 셸 문자열을 만들지 않는다.

## Skill·템플릿 (`skills/**`, `templates/**`)

- Skill은 `skills/<name>/SKILL.md`(frontmatter `name`·`description`)와 선택적 `references/`·`agents/openai.yaml`. Claude·Codex가 같은 파일을 읽으므로 한쪽 도구 전용 문법을 본문에 쓰지 않는다.
- 다른 프로젝트에 생성되는 파일은 `templates/`에 두고 `templates/managed-files.json`에 등록한다(`mode: copy`는 바이트 그대로, `render`는 렌더링). 같은 내용을 여러 곳에 두는 사본(예: `design-handoff.md`, `design-skills.md`, `figma-mcp.md`)은 바이트 동일을 유지한다 — `tests/run.sh`가 검사한다.
- 생성물 계약(그래프 노드·러너 동작)을 바꾸면 `skills/harness-init/SKILL.md`·README 서술도 함께 맞춘다.

## 듀얼 매니페스트

- `.claude-plugin/plugin.json`과 `.codex-plugin/plugin.json`의 `version`·`license`는 같아야 한다(`release.json`의 `version`과도). 버전은 릴리스 커밋에서 `scripts/release-prep.sh <version>`만 올린다 — 기능 PR은 건드리지 않는다.
- `.agents/plugins/marketplace.json`의 `policy.authentication`은 `ON_INSTALL`(테스트가 검사).

## 공개 저장소

- 회사명·사내 도메인·사내 URL·개인 이름·이메일·토큰을 코드·예시·fixture·문서·CHANGELOG에 넣지 않는다. 예시는 `acme`, `example.com`, 가짜 UUID를 쓴다. 일부 경로는 `tests/run.sh`가 조직 식별자를 grep으로 막는다.

## 커밋·PR

- Conventional Commits: `feat:`, `fix(<scope>):`, `docs(<scope>):`, `chore:`. 요약은 한국어·영어 모두 쓰인다. 끝에 이슈 번호 `(#<n>)`.
- 브랜치 `<타입>/<한-일-요약>`(예: `feat/docs-drift-report`, `fix/...`, `chore/...`). 이슈가 있으면 번호를 넣기도 한다(`feat/256-board-impact`).
- 사용자 영향이 있으면 `CHANGELOG.md`의 `## Unreleased`에 `### 새 기능`·`### 버그 수정`·`### 동작 변경`·`### 업데이트 후 해야 할 일` 소제목으로 항목을 남기고 끝에 닫는 이슈 번호를 단다(PR 번호는 쓰지 않는다). 내부 리팩터링만이면 생략할 수 있다.
