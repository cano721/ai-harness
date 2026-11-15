# Investigate — ai-harness

노드·전이의 계약은 `.ai-harness/workflows/investigate-graph.json`이 단일 출처다. 이 문서는 이 저장소에서 원인을 조사할 때 쓰는 **프로젝트 사실**만 적는다. 코드·문서·생성물은 고치지 않는다.

## 1. 기준 코드 (baseline)

- 기준 브랜치는 `develop`, 릴리스된 상태는 `main`. `git fetch origin` 뒤 체크아웃이 `origin/develop`보다 뒤처졌으면 `git show origin/develop:<경로>`·`git grep <패턴> origin/develop`으로 읽는다.
- 사용자가 겪는 문제는 설치된 플러그인 버전 기준일 수 있다. 보고에 버전이 있으면 그 태그(`v<버전>`)를 같은 방식으로 읽고, `CHANGELOG.md`의 이후 절에서 이미 고친 문제인지 먼저 본다.

## 2. 도메인 문서 (domain_docs)

- `.ai-harness/docs/domain.md`의 표, 그리고 사용자에게 보이는 동작의 원본인 `README.md`와 해당 `skills/<name>/SKILL.md`. 생성물 계약은 `templates/managed-files.json`과 각 `templates/<워크플로>/references/*-graph.json`.

## 3. 재현 (reproduce)

- `fix-bug.md` 1절의 격리 규칙을 그대로 따른다: `HARNESS_METRICS_DIR`·`HM_AUTO_WORKTREE_DIR`·`HM_CLAUDE_SKILLS_DIR`·`HM_CODEX_SKILLS_DIR`를 임시 경로로, 사용자 데이터(`~/.ai-harness`, `~/.claude`)를 지우거나 덮지 않는다. 재현 스크립트·로그는 저장소 밖 임시 폴더에 둔다.
- 읽어도 되는 근거: `~/.ai-harness/events/*.jsonl`(활동 이벤트), `~/.ai-harness/runs/`(러너 실행 상태·노드 로그), 사용자가 붙인 세션 기록. 대화 내용·식별자를 보고에 옮기지 않는다.
- 플랫폼 차이(macOS bash 3.2·BSD 도구 vs Linux)를 먼저 의심하고 재현 환경(OS·bash·jq 버전)을 적는다.

## 4. 보고 (report)

- 위치: `~/.ai-harness/investigations/ai-harness/<YYYYMMDD-HHMM>-<요약>.md`. 이슈 댓글 초안은 같은 이름에 `.comment.md`를 붙인다. 공개 저장소이므로 초안에 회사·개인 식별자를 넣지 않는다.
- 수정이 필요하면 `/fix-bug <보고 파일>` 또는 `bash .ai-harness/workflows/workflow-driver.sh start --workflow bug-fix --request "<요약>" --investigation <보고 파일>`로 넘긴다.

## 5. 이슈 트래커

GitHub Issues(`gh issue view <n>`로 읽기만). 댓글은 초안 파일로만 만들고 사람이 올린다. 상태 전환은 하지 않는다.
