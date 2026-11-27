# 설정

[← README](../README.md)

<a id="configuration"></a>

## 설정 (선택)

`~/.ai-harness/config`에 아래 값을 둘 수 있습니다.

```bash
HM_ISSUE_RE="(NJ|JDA)-[0-9]+"   # 기본: [A-Z]{2,}[0-9]*-[0-9]+
HM_HARVEST_SESSION_THRESHOLD=10  # 0이면 세션 수 기준 비활성화
HM_HARVEST_CORRECTION_THRESHOLD=2
HM_HARVEST_CORRECTION_SESSION_THRESHOLD=2
HM_HARVEST_ERROR_THRESHOLD=5
HM_HARVEST_ERROR_SESSION_THRESHOLD=2
HM_HARVEST_GUARD_THRESHOLD=3
HM_HARVEST_GUARD_SESSION_THRESHOLD=2
HM_HARVEST_PERMISSION_THRESHOLD=3
HM_HARVEST_PERMISSION_SESSION_THRESHOLD=2
HM_HARVEST_MAX_BATCH_SESSIONS=50
HM_HARVEST_REMIND_HOURS=24       # 0이면 batch당 한 번만 알림
HM_HARVEST_AUTO=0                # 1이면 batch 생성 시 /harvest를 백그라운드 실행
HM_MEMBER_GUARD=1                # 저장소 밖 세션의 다른 하네스 저장소 코드 편집: 1=사용자 확인, block=차단, 0=끔
HM_DIGEST=0                      # 1이면 일일 backfill 뒤 최근 세션을 LLM으로 정리
HM_DIGEST_DAILY_MAX=20
HM_HARVEST_INSIGHT_THRESHOLD=3
HM_HARVEST_INSIGHT_SESSION_THRESHOLD=2
HM_HARVEST_AUTO_DAILY_MAX=2      # 하루 자동 실행 상한
HM_HARVEST_AUTO_SESSIONS_ONLY=0  # 1이면 세션 수만 넘은 batch도 자동 실행
HM_HARVEST_AUTO_AGENT=auto       # auto(claude 우선)|claude|codex
HM_HARVEST_AUTO_WORKSPACE=1      # 0이면 workspace AGENTS.md 자동 적용 끔
HM_SYNC_AUTO=0                   # 1이면 하네스가 플러그인보다 뒤처진 저장소에 /harness-init --sync를 백그라운드 실행(draft PR)
HM_SYNC_AUTO_DAILY_MAX=6         # 하루 자동 sync 상한
HM_SYNC_AUTO_MERGE=0             # 1이면 검증되는 자동 sync PR을 병합(저장소 설정 불필요)
HM_HARVEST_AUTO_MERGE=0          # 1이면 검증되는 자동 harvest PR을 병합(저장소 설정 불필요)
HM_AUTO_MERGE_HINT=1             # 0이면 자동 sync 병합 켜기 안내(조건을 만족한 sync PR이 30일 3건 이상일 때)를 끔
HM_AUTO_MERGE_METHOD=            # squash|merge|default. 비면 저장소 auto_merge.method, 그것도 없으면 호스트 기본
HM_AUTO_MERGE_SYNC_PARTIAL=      # 1이면 일부 적용 sync PR도 병합(저장소 sync_partial:false면 끔)
HM_AUTO_MERGE_REQUIRE_CI=        # 0이면 CI 없는 저장소도 병합(저장소 require_ci:true면 요구). 실패한 CI는 항상 막음
HM_AUTO_MERGE_WAIT_HOURS=        # CI·상태 확인 대기(기본 72, 최대 336)
HM_AUTO_MERGE_HARVEST_MAX_FILES= # harvest PR 파일 상한(기본 3, 최대 5, 저장소 값이 있으면 작은 쪽)
HM_AUTO_MERGE_HARVEST_MAX_LINES= # harvest PR 줄 상한(기본 40, 최대 100, 저장소 값이 있으면 작은 쪽)
HM_HARVEST_GLOBAL_DAYS=7         # 전역 지침 분석 주기(일). 0이면 끔
HM_HARVEST_AUTO_BUDGET_USD=5     # 자동 실행 1회 비용 상한 (Claude)
HM_APPROVAL=human               # 승인 게이트: human|auto (기본 human). auto는 모든 저장소에 적용 — 신뢰하는 저장소만 아래 줄로 켜기를 권장
HM_APPROVAL_REPOS=               # 저장소별 승인 모드(<project_id>=human|auto, 쉼표 구분). 전체 설정보다 우선
HM_RUNTIME=                      # 러너 노드 세션의 기본 CLI: claude|codex. 비면 자동 선택(부른 CLI > integrations > 설치된 유일한 CLI). 고른 CLI가 없으면 러너가 멈춤
HM_RUNTIME_REPOS=                # 저장소별 런타임(<project_id>=claude|codex, 쉼표 구분, 예: "acme-api=codex"). 전체 설정보다 우선, --runtime이 가장 우선
HM_DELIVERY_LEVEL=               # 워크플로 자동화 단계 pr|merge|deploy. 비어 있으면 PR까지
HM_DELIVERY_LEVEL_REPOS=         # 저장소별 단계(<project_id>=<단계>, 쉼표 구분)
HM_TARGET_CI=wait                # 병합 뒤 병합 커밋 CI: wait(끝까지 기다림, 기본)|notify(한 번만 읽고 진행 중이면 분리 감시가 실패를 알림)
HM_TARGET_CI_REPOS=              # 저장소별 값(<project_id>=wait|notify, 쉼표 구분). 전체 설정보다 우선
HM_DESKTOP_NOTIFY=1              # 0이면 병합 커밋 CI 감시의 데스크톱 알림을 보내지 않음(progress.log ALERT·상태 alerts는 남김)
HM_AUTOFIX_AUTO=0                # 1이면 monitor 설정이 있는 저장소의 운영 에러를 자동 수정(draft PR)·해결 검증
HM_AUTOFIX_REPOS=                # 자동 수정을 허용할 project_id 목록(쉼표 구분). 비어 있으면 아무 저장소도 돌지 않음
HM_AUTOFIX_INTERVAL_MINUTES=     # 자동 수정 sweep 전용 주기(분). 비면 정기 backfill 주기에 같이 돎. 바꾸면 schedule.sh install
HM_AUTOFIX_BASH_ALLOW=           # 무인 에이전트에 더 허용할 검증 명령 패턴(세미콜론 구분, 예: "./scripts/ci.sh*")
HM_AUTOFIX_DEPLOY_WAIT_DAYS=14   # 병합 커밋이 deploy_branch에 보이기를 기다리는 상한. 넘으면 gave_up
HM_AUTOFIX_DAILY_MAX=3           # 하루 자동 수정 실행 상한. 0 = 하루 0회, 1000 이상 = 제한 없음
HM_AUTOFIX_MAX_ATTEMPTS=2        # 시그니처당 PR 상한. 넘어서 재발하면 gave_up
HM_AUTOFIX_SKIP_COOLDOWN_DAYS=7  # 코드 버그 아님·재현 불가로 넘긴 에러를 다시 볼 때까지
HM_AUTOFIX_BUDGET_USD=10         # 자동 수정 1회 비용 상한. unlimited = 상한 없음(--max-budget-usd 생략)
HM_AUTOFIX_TIMEOUT_MIN=60
HM_SENTRY_URL=                   # 자체 호스팅 Sentry 주소(저장소 설정의 base_url은 *.sentry.io만)
HM_EVENT_RETENTION_DAYS=180      # 0이면 일반 이벤트 자동 정리 비활성화
HM_SIGNAL_EVENT_RETENTION_DAYS=365
HM_BACKFILL_INTERVAL_HOURS=6     # 정기 backfill 주기. 0이면 비활성화
HM_IDLE_MINUTES=20               # 이 시간 동안 기록에 시각 찍힌 줄이 없어야 LLM 단계 실행. 0이면 기다리지 않음
HM_IDLE_WAIT_HOURS=4             # 쉬는 시간을 기다리는 최대 시간
HM_LLM_BACKOFF_HOURS=5           # 사용량 한도 실패 뒤 LLM 단계 휴지
HM_UPDATE_CHECK_HOURS=24         # 0이면 매 SessionStart마다 확인
HM_UPDATE_RETRY_MINUTES=15       # 조회 실패 후 첫 재시도 간격. 0이면 백오프 없음
HM_UPDATE_RETRY_MAX_MINUTES=360  # 연속 실패 시 백오프 상한
HM_UPDATE_CONNECT_TIMEOUT=2      # 릴리스 조회 연결 타임아웃(초)
HM_UPDATE_MAX_TIME=5             # 릴리스 조회 전체 타임아웃(초)
HM_DB_SCAN_GUARD=0               # 1이면 DB 스캔 가드 활성화(기본 꺼짐)
HM_STALE_RESET_GUARD=1           # 0이면 stale reset 가드 끔(기본 켬)
HM_BACKGROUND_WATCHDOG=1         # 0이면 백그라운드 Bash 명령에 세션 종료 감시자를 붙이지 않음(Claude Code)
HM_HEAVY_SLOTS=                  # 무거운 명령(빌드·dev 서버·전체 테스트·e2e)의 동시 실행 상한. 비우면 끔(Claude Code)
                                 # 남은 메모리 30% 미만이면 절반, 15% 미만이면 1개. 자리가 없으면 hook이 기다렸다 실행한다
HM_HEAVY_WAIT=540                # 자리를 기다리는 최대 초(최대 580). 넘기면 실행 중인 명령 목록과 함께 거절한다
HM_HEAVY_BG_WAIT=60              # 백그라운드로 띄우는 명령이 자리를 기다리는 최대 초(감시자가 그룹을 찾는 120초 안)
HM_HEAVY_PATTERNS=               # 무거운 명령 판정 정규식(ERE). &&·;·| 등으로 나눈 각 명령의 머리(앞의 VAR=값·env·nohup·sudo·timeout 제외)에 맞춘다.
                                 # 지정하면 기본 패턴을 대신한다. 잘못된 정규식이면 아무것도 맞지 않는다
HM_HEAVY_SLOT_TTL=10800          # 끝났다는 신호가 없는 포그라운드 명령의 자리를 회수하는 초
HM_SETUP_HINT=1                  # 0이면 /setup 안내(첫 세션·카탈로그 추가)를 띄우지 않음. 관리 스킬 갱신은 계속
HM_TEAM_RULES=                   # 팀 규칙 원본(git URL 또는 로컬 경로, skills/<name>.md). 비우면 저장소 표식(team_rules)을 본다
HM_TEAM_RULES_REF=               # git 원본의 브랜치·태그·커밋(비우면 기본 브랜치)
HM_TEAM_RULES_REFRESH_HOURS=24   # git 원본을 백그라운드로 다시 받는 주기. 0이면 받지 않음(/setup team은 항상 받음)
HM_TEAM_RULES_HINT=1             # 0이면 팀 규칙 갱신·미적용 원본 안내를 띄우지 않음
HM_IMPACT_HINT=1                 # 0이면 설치 N일 뒤 /harness-impact 안내(프로젝트당 한 번)를 띄우지 않음
HM_IMPACT_HINT_DAYS=30
```

저장 위치를 바꾸려면 셸 프로파일에 설정합니다.

```bash
export HARNESS_METRICS_DIR="/custom/path"  # 기본: ~/.ai-harness
```
