# 가드와 수집 데이터

[← README](../README.md)

<a id="db-scan-guard"></a>

## DB 스캔 가드 (opt-in)

스키마 조건 없는 information_schema 조회는 서버의 모든 스키마를 훑어 공유 DB를 멈춰 세울 수 있습니다. `HM_DB_SCAN_GUARD=1`을 [설정](configuration.md#configuration)하면 Claude Code의 Bash 실행 전에 `PreToolUse` hook(`scripts/db-scan-guard.sh`)이 이런 조회를 막습니다. 기본은 꺼져 있습니다.

- 대상: 명령 위치(맨 앞이나 `;`·`&&`·`|` 뒤, 변수 대입·`sudo`·`env` 등은 건너뜀)에 DB 클라이언트(`mysql`·`psql` 등)가 오거나, 인터프리터(`python`·`node` 등)가 드라이버(`pymysql`·`psycopg` 등)를 쓰는 파이프라인. `git commit -m`·`grep`·`echo`·heredoc 문서 작성은 대상이 아닙니다
- 차단: 구문(`;`)이나 `UNION` 분기가 `VIEWS`·`ROUTINES`·`TRIGGERS`·`EVENTS`·`PARAMETERS`를 읽는데(MySQL 계열은 `TABLES`·`COLUMNS` 등 메타 테이블도 포함), 문자열 리터럴·주석을 지운 WHERE 최상위에 `*_schema =`·`IN (...)` 조건이 없거나 `OR`가 있을 때
- 한계: 명령 문자열에 보이는 쿼리만 검사합니다. 스크립트 파일, `bash -c`·`docker exec`·`ssh` 안의 명령은 보지 않습니다

<a id="stale-reset-guard"></a>

## stale reset 가드

`git reset --soft <ref>`는 인덱스(옛 트리)를 그대로 두고 브랜치만 옮깁니다. `<ref>`가 그사이 앞서간 기준 브랜치(예: fetch한 `origin/develop`)면 다음 커밋이 그 새 커밋들을 옛 내용으로 되돌립니다. 부모가 최신이라 merge-base 기준 검사로는 보이지 않습니다(#594). Claude Code의 Bash 실행 전에 `PreToolUse` hook(`scripts/stale-reset-guard.sh`)이 이런 reset을 막습니다. 기본으로 켜져 있습니다.

- 판정: 명령 위치의 `git`(전역 옵션 `-C <dir>`·`-c k=v` 등은 건너뜀) `reset --soft <ref>`에서 `<ref>`가 커밋으로 풀리는데 HEAD의 조상이 아니면 막고 `git rebase <ref>`를 안내합니다. `;`·`&&`·`||`·`|`·`&`·줄바꿈으로 이은 명령도 하나씩 봅니다
- 허용: 자기 커밋을 합치는 `git reset --soft $(git merge-base HEAD <ref>)`·merge-base sha·`HEAD~N`, `git rebase`, `--hard`·`--mixed`, 치환(`$(...)`·백틱)이라 정적으로 풀 수 없는 ref, 없는 ref, git 저장소가 아닌 위치, `--` 뒤 경로 인자가 있는 형태. 판정할 수 없으면 통과합니다(fail-open)
- 끄기: `HM_STALE_RESET_GUARD=0`을 [설정](configuration.md#configuration)하거나 환경변수로 줍니다
- 한계: Claude Code의 플러그인 hook이라 Codex 세션은 막지 못합니다. 그래프 러너는 publish 전후와 병합 직전에 [되돌림 검사](workflows.md#merge-policy)로 같은 결과를 잡습니다

<a id="data-retention"></a>

## 수집 데이터와 보관

수집은 `jq` 기반이며 LLM 비용이 들지 않습니다. transcript 전문을 복사하지 않습니다.

- 수집 항목: 세션 메타(토큰·모델·턴), workflow/command 사용, 역할 위임, 하네스 문서 읽기, 편집 파일, bash 명령, MCP 도구, 이슈 키, 오류·가드·권한 거부·컨텍스트 압축 횟수
- Claude와 Codex 모두 위 항목을 관측합니다. Codex는 native function call과 desktop/runtime bridge의 custom tool call을 해석하며, bridge가 경로를 노출하지 않는 편집은 파일별 핫스팟 대신 집계에서 제외될 수 있습니다. 미지원은 0회와 구분하므로, 관측하지 못한 데이터로 삭제 근거를 만들지 않습니다.

| 데이터 | 기본 위치 | 보관 방식 |
|---|---|---|
| 압축 이벤트 | `~/.ai-harness/events/` | 일반 180일, 교정·오류·차단·권한 거부가 있으면 365일 |
| 통계 rollup | `~/.ai-harness/rollups/` | 상세 보관 기간 후 transcript 경로와 교정 문구를 제거해 전환 |
| harvest 큐·검토 이력 | `~/.ai-harness/harvest-queue/` | pending, 현재 batch, 완료 marker, `review-history.jsonl` |
| 자동 수정 상태 | `~/.ai-harness/autofix/` | 시그니처별 진행 상태(PR·배포·관찰·재발), 실행 기록, 최근 50개 실행 로그 |
| 상태 | `~/.ai-harness/health.json`, `update-check.json` | 수집 건강 상태와 릴리스 확인 캐시만 기록 |

상세 이벤트 삭제가 중단되면 원 marker를 유지해 다음 실행에서 재시도합니다. 같은 세션이 실제로 갱신되면 rollup 뒤에도 새 revision을 수집합니다. 프로젝트 ID는 `.ai-harness/harness.json`을 우선하고, 없으면 git origin/common-dir로 정규화해 worktree를 하나의 프로젝트로 묶습니다. 이미 삭제된 worktree는 Codex가 기록한 저장소 URL, 그다음 경로 규칙(`<repo>/feature-NJ-1`, `<repo>/NJ-1-설명` → `<repo>`)으로 판정하고, 한글 등 비ASCII 이름은 NFC로 맞춥니다. 규칙이 바뀌어 재추출된 세션은 이전 프로젝트 큐의 검토 상태를 그대로 가져갑니다.
