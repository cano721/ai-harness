# 자가학습과 자동화

[← README](../README.md)

<a id="self-learning"></a>

## 자가학습: 기록 → 분석 → 개선

### 자동으로 일어나는 일

| 시점 | hook | 하는 일 | 하지 않는 일 |
|---|---|---|---|
| 응답이 끝날 때마다 | `Stop` → `scripts/tick.sh` → `scripts/backfill-due.sh` | 마지막 backfill이 6시간(`HM_BACKFILL_INTERVAL_HOURS`) 넘었는지만 확인(수 ms). 넘었으면 세션과 분리된 저우선순위 작업으로 backfill → (사용자가 쉬는 동안) LLM 정리·자동 harvest sweep → 릴리스 정보 갱신 | 세션을 막는 작업 |
| 세션 시작 | `SessionStart` → `scripts/session-start.sh` | 캐시된 릴리스 정보로 analysis batch·새 버전·버전 스큐·저장소 하네스 버전 차이·자동 적용 내역을 알림 (네트워크 조회 없음). 같은 `backfill-due.sh` 확인 | `/harvest` 실행, 플러그인 설치·업데이트 |

수집은 세션 종료 hook에도, OS 스케줄러에도 기대지 않습니다. 종료 hook은 터미널·탭을 그냥 닫으면 실행되지 않아 실측 43%를 놓쳤고, launchd·cron·작업 스케줄러는 OS마다 따로 설치해야 합니다. 대신 Claude Code·Codex 공통 hook(세션 시작과 응답마다)이 주기를 확인하고, transcript 전체를 훑는 backfill이 유일한 수집 경로입니다. 며칠 이어지는 세션 하나만 켜 둬도 응답마다 확인하므로 주기대로 돕니다. 세션이 전혀 없으면 새로 쌓일 기록도 없습니다.

- **LLM 단계는 쉬는 동안만**: 수집은 바로 하고, LLM 정리·자동 harvest는 최근 `HM_IDLE_MINUTES`(20)분간 Claude·Codex 기록에 시각이 찍힌 줄(대화·도구 호출)이 남지 않을 때까지 최대 `HM_IDLE_WAIT_HOURS`(4)시간 기다렸다가 돕니다. 열린 세션이 덧붙이는 시각 없는 줄(`last-prompt`·`cost-state`)은 활동으로 보지 않습니다. 작업과 사용량 한도가 겹치지 않게 하기 위해서입니다. 회차마다 돌았는지·넘긴 이유는 `~/.ai-harness/logs/schedule.jsonl`에 남습니다
- **사용량 한도 휴지**: 자동 harvest가 사용량 한도로 실패한 뒤 `HM_LLM_BACKOFF_HOURS`(5)시간은 LLM 단계를 쉽니다
- **로그인 만료**: 무인 실행이 로그인 만료(`auth_expired`)로 실패하면 실패 횟수에 넣지 않고 같은 회차의 남은 LLM 실행을 멈춥니다. 보드 카드 한 장과 세션 시작 안내로 `claude auth login`(또는 무인 실행용 `claude setup-token` + `CLAUDE_CODE_OAUTH_TOKEN`)을 알리고, 다음 실행이 정상으로 돌면 사라집니다

`scripts/collect.sh`는 세션 1개를 즉시 수집하는 수동 진입점으로 남아 있습니다. 세션을 거의 열지 않는데도 정해진 시각에 돌리고 싶다면 OS 스케줄러에 `HM_BACKFILL_FOREGROUND=1 <플러그인>/scripts/backfill-due.sh`를 등록할 수 있고, macOS는 `scripts/schedule.sh install`(선택 사항)이 이를 대신합니다.

### 언제 `/harvest`를 안내하나

기본적으로 아래 중 하나면 pending 세션을 analysis batch로 묶고 다음 세션 시작에 `/harvest`를 안내합니다.

- 세션 10개 누적
- 서로 다른 2개 이상 세션에서 사용자 교정 2개
- 서로 다른 2개 이상 세션에서 오류 5개, 가드 차단 3개, 권한 거부 3개 중 하나

한 batch는 최대 50개 세션입니다. 단, 트리거 판정은 전체 pending을 기준으로 하며 신호가 있는 세션을 우선 포함합니다. 분석 중 새로 종료된 세션은 다음 batch에 보존됩니다. 첫 알림을 놓치면 기본 24시간마다 다시 알립니다.

<a id="auto-apply"></a>

### workspace·전역 지침 자동 적용

팀이 공유하는 저장소는 draft PR로 사람이 머지하지만, workspace 루트 `AGENTS.md`와 전역 지침(`~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md`)은 개인 소유라 자동 harvest가 직접 적용합니다(`HM_HARVEST_AUTO=1`일 때).

- **workspace**: workspace 루트에서 한 세션들의 batch를 같은 기준(2개 이상 세션에서 반복)으로 분석해 workspace `AGENTS.md`에 적용합니다. 끄려면 `HM_HARVEST_AUTO_WORKSPACE=0`
- **전역**: 7일(`HM_HARVEST_GLOBAL_DAYS`, 0이면 끔)마다 한 번 전체를 가로질러, **2개 이상 프로젝트·5개 이상 세션**에서 반복된 저장소 무관 실수(셸·도구 사용 습관)만 전역 지침에 넣습니다
- **안전장치**
  - 편집 도구 없이 `scripts/auto-apply.sh`로만 바꿉니다. 이 스크립트는 `<!-- ai-harness:auto:start -->` 블록 안의 규칙만 넣고 빼며, 블록 밖(직접 쓴 내용)은 건드리지 않습니다. 한 줄·400자·주석 금지로 입력을 제한합니다
  - 적용마다 이전 파일을 `~/.ai-harness/applied/`에 남기고, `auto-apply.sh revert --rule-id <id>`로 규칙 단위로 되돌립니다. `auto-apply.sh list --active`로 현재 규칙을 봅니다
  - 규칙마다 기대효과를 기록하고, 다음 실행이 적용 이후 재발 여부로 효과를 판정해 강화하거나 스스로 되돌립니다
  - 다음 세션 시작에 무엇을 적용·되돌렸는지 한 번 알립니다
  - 적용 전에 규칙 문구를 [독립 검토](#auto-harvest)에 넣고, 통과한 것만 적용합니다
  - 한 실행에 최대 2건, Claude Code로만 실행합니다

<a id="llm-digest"></a>

### LLM 세션 정리 (opt-in)

사용자 교정은 문구 규칙으로 줍지 않고 이 LLM 정리로만 판정합니다 — 문구 규칙은 표현이 조금만 달라도 놓쳤습니다. 끄면 교정 신호가 없습니다. `~/.ai-harness/config`에 `HM_DIGEST=1`을 두면 하루 한 번 도는 백그라운드 backfill 뒤에 `scripts/digest.sh`가 최근 세션을 저비용 모델(`HM_DIGEST_MODEL`, 기본 `haiku`)로 읽어 마찰을 `category / summary / evidence(원문 인용) / harness_fix / confidence`로 남깁니다.

- **대상**: 최근 14일(`HM_DIGEST_LOOKBACK_DAYS`), 3턴 이상, 끝난 지 30분 지난 세션을 최신순으로 하루 20개(`HM_DIGEST_DAILY_MAX`). 재개된 세션만 다시 정리합니다
- **입력**: 사용자 발화 전체(턴당 600자), 응답·도구 오류는 짧게 잘라 최대 4만 자. 실측 세션당 약 $0.003~0.01
- **신호**: medium 이상 finding 수가 큐의 `insights`가, 그중 `correction`이 `corrections`가 됩니다. 기본으로 여러 세션에 걸쳐 3건이면 batch를 만듭니다(`HM_HARVEST_INSIGHT_THRESHOLD`, `HM_HARVEST_INSIGHT_SESSION_THRESHOLD`)
- **사용**: `/harvest`가 `digest.sh show`로 batch 세션의 findings를 받아, 2개 이상 세션에서 반복되는 것만 개선 근거로 씁니다
- 정리 세션은 `HM_INTERNAL_SESSION=1`·`--no-session-persistence`로 실행돼 수집·알림 대상이 아닙니다. 기록은 `~/.ai-harness/digests/`

<a id="auto-harvest"></a>

### 자동 harvest (opt-in)

`~/.ai-harness/config`에 `HM_HARVEST_AUTO=1`을 두면 정기 backfill이 끝날 때마다 analysis batch가 있는 프로젝트를 오래된 순으로 확인해(sweep, 한 번에 하나) `/harvest <프로젝트> --auto`를 세션과 분리된 headless 프로세스(`claude -p`, Codex 세션이면 `codex exec`)로 실행합니다.

- **대상**: `.ai-harness/harness.json`이 있는 git 저장소의, 교정·오류·차단·권한 거부 신호가 있는 batch만. 세션 수만 넘은 batch(`HM_HARVEST_AUTO_SESSIONS_ONLY=1`로 포함 가능)와 하네스가 없는 폴더·workspace의 batch는 기존처럼 알림으로 남깁니다
- **에이전트**: 세션을 만든 도구와 무관하게 `claude`가 있으면 Claude Code로 실행합니다(`HM_HARVEST_AUTO_AGENT=auto|claude|codex`). Codex 샌드박스는 쓰기 허용 경로에서도 `.git`을 읽기 전용으로 두어 커밋·push를 할 수 없으므로, Codex로 돌면 분석·보고까지만 하고 batch를 사람에게 넘깁니다
- **무인 규칙**: 사용자에게 묻지 않습니다. worker가 origin 기본 브랜치 최신 커밋으로 작업 전용 worktree(`~/.ai-harness/harvest-auto/worktrees/`)를 만들고 그 안에서만 에이전트를 실행한 뒤 지웁니다 — 사용자 체크아웃은 건드릴 수 없습니다. 결과는 **draft PR**까지이며 `scripts/open-pr.sh`가 원격을 보고 GitHub(`gh`) 또는 Bitbucket Cloud(REST, `ATLASSIAN_USER`·`BITBUCKET_API_TOKEN`)로 엽니다. 확인이 필요한 분기나 PR을 열 수 없는 원격이면 batch를 소비하지 않고 끝내 수동 `/harvest`로 넘깁니다
- **독립 검토**: 반영 전에 읽기 전용 검토 에이전트(`agents/harvest-reviewer.md`)가 개선안만 보고 문구가 근거보다 넓은지·근거가 주장을 뒷받침하는지·저장소 규칙과 충돌하는지 판정합니다. `revise`면 고쳐서 새 검토자에게 다시 넘기고(최대 2회), 끝까지 통과하지 못한 개선안은 뺍니다. 판정은 PR 본문 `## 독립 검토` 절에 남습니다. 이슈 키를 요구하는 저장소는 새 이슈를 만들지 않고 git 기록의 무이슈 관례 키(예: `NJ-00000`)로 브랜치·제목을 만듭니다
- **비용 제한**: batch당 1회, 하루 `HM_HARVEST_AUTO_DAILY_MAX`회(기본 2), 동시 1개, 실행당 `HM_HARVEST_AUTO_BUDGET_USD`(기본 5, Claude만)
- **재귀 방지**: 자동 실행 세션은 `HM_HARVEST_RUNNING=1`·`HM_INTERNAL_SESSION=1`로 표시되어 그 안에서 다시 harvest를 띄우거나 수집되지 않습니다
- **제거도 개선입니다**: 없는 경로·명령을 가리키거나 코드와 모순되는 줄, 교정을 유발한 규칙, 여러 파일에 반복된 지시, 사용 0회 자산을 제거 후보로 봅니다("최근 재발 없음"은 제거 근거가 아닙니다). 무인 실행은 줄 단위 제거까지만 draft PR로 내고, 파일·관리 생성물 삭제는 사람에게 넘깁니다. 개인 지침 블록의 자동 규칙은 블록 밖에 같은 문구가 생기면(`auto-apply.sh duplicates`) 되돌립니다
- **기록**: `~/.ai-harness/harvest-auto/runs.jsonl`에 `started`/`finished`/`skipped`(사유), 결과(`improved`·`partial`(sync 일부 적용)·`no-change`·`left_for_user`·`failed`), 비용, PR URL을 남기고, 실행별 출력은 `logs/`(최근 50개)에 둡니다. `scripts/harvest-auto.sh runs`로 최근 기록을 봅니다

`/harvest`는 batch와 30/90일 baseline을 분리해 비교한 뒤 아래 중 하나를 결론으로 남깁니다.

- **개선 적용**: 에이전트의 실제 행동을 바꿀 제약·워크플로·문서 구조 변경만 PR로 제안합니다.
- **통계 참고**: 근거는 있으나 아직 행동 변경으로 이어질 만큼 강하지 않은 경우입니다.
- **개선점 없음**: cosmetic 정리나 단발성 노이즈는 적용하지 않습니다.

비용 절제 장치가 두 가지 있습니다(반영 전 품질 관문은 위 독립 검토). **정독 게이트**는 가장 비싼 스텝(transcript 정독) 전에 압축 신호만으로 정독 가치를 판단해, 노이즈 batch는 정량 분석과 보고만으로 싸게 종료합니다. **결과 검증 루프**는 개선 PR마다 기대효과(`--expected`)를 기록해 두고, 다음 `/harvest`가 같은 패턴의 재발 여부로 그 개선을 채점합니다 — 재발이 확인되면 강화안 또는 revert를 제안해 효과 없는 규칙이 하네스에 쌓이는 것을 막습니다.

정상 완료한 batch만 `mark-reviewed`로 소비합니다. `--dry-run`이나 실패한 분석은 pending을 지우지 않습니다.

```bash
# 개선 PR을 만든 경우
scripts/harvest-queue.sh mark-reviewed --project <프로젝트> \
  --outcome improved --summary "<개선 요약>" --artifact "<PR URL>" \
  --expected "<다음 harvest가 효과를 판정할 기준>"

# 적용할 개선이 없는 경우
scripts/harvest-queue.sh mark-reviewed --project <프로젝트> \
  --outcome no-change --summary "<적용하지 않은 이유>"
```

<a id="auto-sync"></a>

### 자동 sync (opt-in)

플러그인은 마켓플레이스 auto-update로 최신이 되지만, 저장소에 깔린 생성물은 `/harness-init --sync`를 돌려야 따라옵니다. `~/.ai-harness/config`에 `HM_SYNC_AUTO=1`을 두면 정기 sweep이 기준 브랜치의 `harness_version`이 플러그인보다 낮은 하네스 저장소를 찾아 `/harness-init --sync --apply --auto`를 [자동 harvest](#auto-harvest)와 같은 무인 경로(작업 전용 worktree → headless `claude -p` → draft PR)로 실행합니다.

- **대상**: 수집된 세션 기록의 작업 경로(workspace 루트면 멤버까지)에서 찾은 하네스 저장소. 같은 저장소의 worktree는 원본 하나로 접고, 버전은 사용자 체크아웃이 아니라 하네스가 들어 있는 기준 브랜치에서 읽습니다
- **적용 범위**: `add`와 수정되지 않은(`unchanged`) 관리 생성물 `refresh`만. 승인 필요·보호 파일(AGENTS.md·docs·워크플로 본문)·삭제·계약 drift는 고치지 않고 PR 본문의 "사람 확인 필요" 표로 넘깁니다. workspace 루트(매니페스트·라우팅 AGENTS.md)는 대상이 아니며 알림만 합니다
- **비용**: 적용할 관리 생성물이 없으면 에이전트를 띄우지 않고 `no-change`로 끝냅니다(LLM 비용 0). 저장소·플러그인 버전 조합당 1회, 하루 `HM_SYNC_AUTO_DAILY_MAX`회(기본 6, 자동 harvest와 별도), 실행 lock·시간 제한·실행당 예산·실패 3회 포기·사용량 한도 휴지는 자동 harvest와 공유합니다. 동시에는 하나만 돌고 sweep에서는 harvest가 먼저입니다. 실행이 끝나면 같은 worker가 sweep과 같은 순서(harvest batch → sync)로 다음 실행을 이어서 띄워 상한까지 처리합니다 — 사용량 한도로 끝났거나 한도 휴지 중이거나 사용자가 다시 작업 중(`HM_IDLE_MINUTES`)이면 멈추고 다음 sweep이 이어받습니다. 무인 실행이 도는 동안의 정기 실행은 LLM 단계를 건너뜁니다
- **에이전트**: Claude Code만. Codex 샌드박스는 `.git`이 읽기 전용이라 브랜치·PR까지 갈 수 없어 `needs_claude`로 건너뜁니다
- **옛 PR 정리**: 새 sync PR이 열리면 같은 저장소의 이전 버전 sync PR(자동 sync 기록에 남은 PR과, 세션에서 직접 연 것을 포함해 브랜치 이름이 `harness-sync-<버전>`으로 끝나는 열린 PR) 중 아무도 손대지 않은(코멘트·리뷰·승인 0) 열린 PR을 "새 버전 PR로 대체" 코멘트와 함께 닫습니다(`runs.jsonl`에 `event:"superseded"`). 사람이 리뷰 중인 옛 sync PR이 있으면 새 sync를 띄우지 않고 `sync_pr_in_review`로 건너뜁니다 — 같은 파일을 고치는 두 PR은 함께 병합할 수 없습니다. PR 상태를 읽지 못하면 `sync_pr_status_unknown`으로 기다립니다(Bitbucket 자격증명은 셸 환경변수 → `~/.claude/settings.json`의 `env` 순으로 찾고, 끝내 없으면 `sync_pr_no_credentials`). 같은 저장소의 PR만 닫고, 새 PR이 열려 있음을 확인한 뒤에만 닫습니다. 한계: "손댐"은 코멘트·리뷰·승인으로만 봅니다(사람이 브랜치에 push만 한 PR은 닫힐 수 있고, Bitbucket은 봇 코멘트를 구분하지 못해 사람 활동으로 셉니다)
- **기록**: `~/.ai-harness/harvest-auto/runs.jsonl`에 `scope:"sync"`로 남고(`harvest-auto.sh runs`), 저장소별 마지막 시도는 `~/.ai-harness/sync-auto/<프로젝트>.json`(플러그인 버전·결과)입니다

<a id="auto-merge"></a>

### 자동 병합 (opt-in)

자동 sync·자동 harvest가 연 draft PR을 사람이 매번 검토·병합하지 않아도 되게, **기계적으로 검증되는 PR만** 병합합니다. 켜고 끄는 것은 사용자 설정만 정합니다 — 저장소 PR은 필요 없습니다.

```bash
# ~/.ai-harness/config
HM_SYNC_AUTO_MERGE=1       # 자동 sync PR
HM_HARVEST_AUTO_MERGE=1    # 자동 harvest PR
```

조정값도 같은 파일에 둡니다(선택). 저장소 기준 브랜치의 `.ai-harness/harness.json`에 `"auto_merge": {"method": "squash", "require_ci": true, …}`처럼 같은 키가 있으면 함께 읽고, 안전에 걸린 값(`sync_partial`·`require_ci`·`harvest_max_*`)은 **둘 중 안전한 쪽**을 씁니다. 저장소 값은 팀이 정하는 하한일 뿐 자동 병합을 켜는 스위치가 아니며, PR이 바꾼 manifest는 읽지 않습니다(PR이 스스로 기준을 느슨하게 하지 못합니다).

| 사용자 설정 (manifest 키) | 기본 | 뜻 | 둘 다 있으면 |
|---|---|---|---|
| `HM_AUTO_MERGE_METHOD` (`method`) | `default` | `squash`·`merge`·`default`(호스트 기본) | 사용자 값 |
| `HM_AUTO_MERGE_SYNC_PARTIAL` (`sync_partial`) | `0` | `1`이면 일부 적용 sync PR도 병합 | 한쪽이라도 끄면 끔 |
| `HM_AUTO_MERGE_REQUIRE_CI` (`require_ci`) | `1` | `0`이면 CI가 없는 저장소도 병합. 실패한 CI·브랜치 보호에 막힌 PR은 어느 설정에서도 병합하지 않음 | 한쪽이라도 요구하면 요구 |
| `HM_AUTO_MERGE_WAIT_HOURS` (`wait_hours`) | `72` (최대 336) | CI·상태 확인을 기다리는 시간, 넘으면 사람에게 | 사용자 값 |
| `HM_AUTO_MERGE_HARVEST_MAX_FILES`·`_MAX_LINES` (`harvest_max_files`·`harvest_max_lines`) | `3`·`40` (최대 5·100) | harvest PR 크기 상한 | 작은 값 |

예전 저장소 허용 스위치(`auto_merge.sync`·`auto_merge.harvest`, 또는 `"auto_merge": false`)는 더 이상 읽지 않습니다. `false`로 적혀 있어도 막지 않고, 남아 있는 저장소를 처음 만나면 세션 시작 때 한 번 알립니다. init·sync는 이 필드를 지우지 않고 그대로 둡니다. 아래 안전 최소 기준은 어느 설정으로도 바꿀 수 없습니다.

| 대상 | 병합 조건 (모두 만족) |
|---|---|
| sync PR | 결과 `improved`(일부 적용은 `sync_partial`이 켜졌을 때만) · 바뀐 파일이 카탈로그 `copy`·`render` 생성물과 `harness.json`뿐 · copy 생성물이 템플릿과 바이트 일치 · render 생성물(워크플로 진입점 커맨드·SKILL)이 `scripts/render-managed-file.sh` 결과와 바이트 일치 · manifest 해시가 파일과 일치 · `harness.json`은 관리 해시·버전 외 정책 필드가 그대로이고, 해시는 이번에 바꾼 파일 것만 바뀜(항목 삭제 거부). **render 생성물이 스크립트 결과와 다르거나(사람이 고친 진입점), 기준 브랜치 manifest에 결정적 render 표시(`renderer`)가 없는 기존 진입점을 처음 바꾸는 PR(예전 손 렌더의 저장소 맞춤이 지워질 수 있음, `render_first:`), 표시 뒤에 사람이 고친 진입점을 바꾸는 PR(`render_modified:`), head 기록에 표시가 없는 PR(`render_unmarked:`)은 사람이 봅니다** |
| harvest PR | 결과 `improved` · harvest가 기록한 1회차 독립 검토 전부 통과(`--first-pass pass`)·기대효과 — 에이전트 자기 신고라 거르는 데만 씀 · 바뀐 파일이 `AGENTS.md`·`.ai-harness/docs/**/*.md`·`.ai-harness/workflows/*.md`뿐 · 파일 3개·추가+삭제 40줄 이하(`harvest_max_*`로 조정, 최대 5개·100줄) · **worker가 따로 띄운 읽기 전용 검토 세션이 최종 diff를 통과**시킴(검증·승인 약화, 기존 규칙과 모순, 과잉 일반화, 무관한 지시가 있으면 탈락. 판정 줄에 그 실행만의 토큰을 요구해 diff 안에 미리 적힌 판정은 받지 않음) |
| 공통 (내용) | 추가·수정만(삭제·이름 바꾸기·모드 변경·링크·서브모듈 거부, 제어 문자가 든 경로 거부), 일반 파일 모드(copy는 템플릿과 같은 실행 비트) · PR URL이 이 저장소(origin)의 PR · 기준이 원격 브랜치(`origin/<branch>`) |
| 공통 (병합 직전, PR 호스트에서 직접 읽음) | 사용자 설정이 여전히 켜져 있음 · PR이 열려 있음 · 이 실행이 시작된 뒤 열린 PR · head가 판정한 커밋 그대로 · 대상 브랜치가 판정한 기준 브랜치 · 사람 활동(코멘트·리뷰·승인) 없음 — 사람이 보기 시작하면 사람에게 넘김 · 충돌 없음 · 원격 CI가 head에서 통과(GitHub 브랜치 보호가 막고 있으면 대기, `wait_hours` 안에 안 끝나면 사람에게, CI가 없으면 `require_ci`가 꺼졌을 때만 병합) |

- **흐름**: 무인 실행이 PR을 연 직후 내용 조건을 판정해 대기열(`~/.ai-harness/auto-merge/pending/`)에 넣고, 정기 실행이 매 회차(유휴·한도와 무관, LLM 없음) 호스트 조건을 확인해 draft를 풀고 head를 고정해 병합합니다. Bitbucket은 head를 고정할 수 없어 병합 직전에 다시 읽어 맞춰 봅니다
- **기록·알림**: `runs.jsonl`에 `auto_merge_queued`·`auto_merged`(병합 커밋)·`auto_merge_skipped`(사유)로 남고, 세션 시작 때 지난 알림 뒤의 병합·사람 확인 필요 건수를 알립니다
- **켜기 안내**: 꺼져 있어도 자동 sync PR은 LLM 없이 내용 조건만 판정해 `auto_merge_eligible`로 남깁니다. 최근 30일에 3건(`HM_AUTO_MERGE_HINT_MIN`) 이상이면 세션 시작 때 그 건수와 켜는 방법을 30일에 한 번 안내합니다(`HM_AUTO_MERGE_HINT=0`이면 끔). 기본값은 바꾸지 않고, harvest는 권하지 않습니다
- **되돌리기**: 자동으로 하지 않습니다. 자동 병합된 harvest 개선이 다음 harvest 검증에서 효과가 없으면 revert PR을 사람 검토용으로 엽니다(자동 병합 대상 아님)
- 한계: harvest의 독립 검토 세션도 LLM이라 diff에 섞인 지시문에 흔들릴 수 있습니다 — 경로·크기·모드 제한과 함께 쓰는 마지막 관문입니다(검토 1회 비용, 기본 상한 `HM_AUTO_MERGE_REVIEW_BUDGET_USD=1`). Bitbucket merge API는 head를 고정할 수 없어 draft 해제 전후와 병합 응답에서 head를 다시 맞춰 보지만, 마지막 확인과 병합 사이의 push는 막지 못합니다. 병합 직전에 달린 코멘트도 같은 틈이 있습니다. 병합 실패(호스트 merge check·권한)는 draft로 되돌리고 다시 시도하지 않으며 사람에게 넘깁니다

<a id="autofix"></a>

## 모니터링 기반 자동 수정 (opt-in)

모니터링 도구에 쌓인 운영 에러를 골라 고치고, **고친 뒤 그 에러가 더 나오지 않는 것까지** 확인합니다. 저장소마다 `/autofix setup`으로 `monitor` 설정을 두고(자격증명은 넣지 않습니다), `~/.ai-harness/config`에 `HM_AUTOFIX_AUTO=1`과 대상 저장소 목록 `HM_AUTOFIX_REPOS="<project_id>,…"`를 두면 정기 실행(`backfill-due.sh`, 사용자가 쉬는 동안)이 돕니다. setup이 이 무인 실행 설정(켜기·대상·주기·상한)까지 물어 `scripts/autofix-auto.sh configure`로 써 줍니다. 목록에 없는 저장소는 `monitor` 설정이 있어도 무인 실행하지 않습니다 — 클론만 한 저장소가 자기 설정으로 자격증명을 쓰거나 명령을 실행하게 두지 않기 위해서입니다.

`monitor` 설정은 기본으로 개인 로컬 파일 `~/.ai-harness/autofix/monitors/<project_id>.json`(내용이 곧 `monitor` 객체)에 둡니다. 켜기·상태가 로컬이므로 설정도 팀 저장소에 커밋할 필요가 없고, 공유 설정을 여러 사람이 각자 켜서 같은 에러로 PR이 중복되는 일도 없습니다. 팀이 공유해야 하면 `.ai-harness/harness.json`의 `monitor`(기준 브랜치에 커밋된 값)에 둘 수 있고, 둘 다 있으면 로컬 파일이 이깁니다. 로컬 파일이 잘못됐으면 manifest로 넘어가지 않고 거부하며, provider별 제한(아래)은 두 위치에 똑같이 적용됩니다.

**주기**: 기본은 정기 실행 주기(`HM_BACKFILL_INTERVAL_HOURS`, 기본 6시간)에 같이 돕니다. `HM_AUTOFIX_INTERVAL_MINUTES=<분>`을 두고 `scripts/schedule.sh install`을 돌리면 sweep만 그 분 주기로 부르는 LaunchAgent(`com.ai-harness.autofix`)를 따로 등록합니다(macOS가 아니면 cron 줄을 안내). 이 경로는 유휴 대기 없이 돌지만 사용량 한도 직후 휴지와 하루 상한은 지키고, 정기 실행 경로와 겹치면 늦게 온 sweep은 건너뜁니다. 값을 지우고 다시 install하면 전용 LaunchAgent를 내립니다.

```json
"monitor": { "provider": "sentry", "org": "acme", "project": "api", "environment": "production",
             "min_events": 10, "window_hours": 24, "deploy_branch": "main", "grace_hours": 24, "quiet_hours": 72 }
```

| provider | 설정 | 자격증명 |
|---|---|---|
| `sentry` | `org`, `project`, 선택 `environment` | `SENTRY_AUTH_TOKEN` (자체 호스팅은 config의 `HM_SENTRY_URL`) |
| `datadog` | `query`(예: `service:api env:prod status:error`), 선택 `site` | `DATADOG_API_KEY`·`DATADOG_APP_KEY` |
| `command` | `command`: 저장소 안 어댑터 스크립트(`list`·`detail`·`count` 하위 명령) | 어댑터가 처리 |

자격증명은 환경변수 → `~/.claude/settings.json`의 `env` → `~/.ai-harness/config`(`HM_SENTRY_TOKEN`·`HM_DATADOG_*`) 순으로 찾습니다. 저장소 설정이 자격증명을 보낼 곳을 바꾸지 못하도록 Sentry는 `*.sentry.io`, Datadog은 공개 사이트만 받습니다.

**setup에서 값 고르기**: service·env 같은 값을 문법·이름을 외워 입력하지 않아도 됩니다. setup은 저장소 흔적(`DD_SERVICE`·`dd.service`·`sentry.properties` 등)을 추천값으로 앞에 두고, `scripts/monitor-fetch.sh discover --provider datadog|sentry`로 최근 에러를 Datadog은 service·env별, Sentry는 project·environment별 건수로 보여 줘 고르게 합니다. 만든 `query`·필드를 보여 주고 확인받은 뒤에만 씁니다. 설정이 없는 저장소에서 `/autofix`를 부르면 후보 조회 대신 setup부터 시작합니다.

정기 실행 한 번은 이렇게 돕니다.

1. **검증(LLM 없음)**: 열린 PR의 상태를 보고(`open-pr.sh --status`) 병합되면 `verifying`, 사람이 닫으면 `declined`. 병합 커밋이 `deploy_branch`에 들어간 것을 처음 관찰한 때를 배포 시각으로 잡고(설정이 없으면 병합 시각), `grace_hours` 유예 뒤부터 관찰합니다. 관찰 창은 `quiet_hours`와 "수정 전 빈도라면 3건이 나왔을 시간" 중 긴 쪽(최대 14일)입니다. 창 안에 같은 시그니처가 다시 나오면 `regressed`, 끝까지 없으면 `resolved`입니다.
2. **수정(무인 에이전트 1건)**: 새 에러, 재발한 에러, 해결 뒤 다시 나타난 에러 중 가장 많이 난 것을 작업 전용 독립 저장소(원본의 로컬 clone)의 headless `claude -p "/ai-harness:autofix --auto …"`에 넘깁니다. 에이전트는 코드 버그인지 분류하고, 재현 테스트를 먼저 만들고, 프로젝트 `fix-bug` 절차로 고쳐 **draft PR**을 엽니다. 재현하지 못하거나 코드 버그가 아니면 PR 없이 `skipped`로 남기고 유예(7일) 뒤 다시 봅니다. 재발 재시도에는 지난 PR과 재발 근거를 같이 넘깁니다.

- **상한**: 하루 `HM_AUTOFIX_DAILY_MAX`(3)회, 시그니처당 PR `HM_AUTOFIX_MAX_ATTEMPTS`(2)개 — 상한까지 재발하면 `gave_up`으로 사람에게 넘깁니다. 실행당 `HM_AUTOFIX_BUDGET_USD`($10), `HM_AUTOFIX_TIMEOUT_MIN`(60분). 하루 상한 `1000` 이상(`configure --daily-max unlimited`, 보드의 '제한 없음')은 하루 실행 수를 세지 않고, 예산 `unlimited`(`configure --budget-usd unlimited`)는 수정 실행에 `--max-budget-usd`를 넘기지 않습니다 — 둘 다 비용 상한이 사라지므로 시간 제한만 남습니다. 하루 상한 `0`은 하루 0회입니다. 무인 실행 lock은 자동 harvest·sync와 공유합니다(동시에 하나)
- **안전장치**: 에러 본문은 외부 입력이라 비밀값을 가려 넘기고, 에이전트에 데이터로만 읽으라고 지시합니다. Bash는 빌드·테스트 명령(gradle·maven·npm/pnpm/yarn·go·pytest·make·cargo 등, `HM_AUTOFIX_BASH_ALLOW`로 추가)과 `fix/` 브랜치 push 같은 좁은 git 명령만 허용하고 나머지는 묻지 않고 거부합니다. 모니터링 자격증명은 에이전트 환경에서 빼고, 자격증명 파일 읽기도 막습니다. 테스트 러너는 저장소 코드를 실행하므로 이 경계가 완전하지는 않습니다 — 신뢰하는 저장소만 `HM_AUTOFIX_REPOS`에 넣으세요. 병합은 언제나 사람이 합니다
- **상태 보기**: `/autofix status`, `scripts/autofix-auto.sh status|runs`, 또는 [Harness Board](board.md#board)의 "자동 수정" 화면. 기록은 `~/.ai-harness/autofix/`(시그니처별 `state.json`, `runs.jsonl`, 실행 로그)
- **수동**: `/autofix`로 후보를 골라 이 세션에서 고칠 수 있고, 그렇게 연 PR도 `autofix-auto.sh track`으로 같은 검증에 올립니다. 수동 후보 조회(`autofix-auto.sh candidates --project <id> --root .`)는 `HM_AUTOFIX_REPOS`와 무관하게 그 저장소의 `monitor` 설정으로 계산하므로 무인 실행을 켜지 않아도 쓸 수 있습니다(검증 대상 등록 `track`은 목록에 있어야 합니다)
