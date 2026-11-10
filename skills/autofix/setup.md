# /autofix setup — 저장소별 모니터링 설정과 무인 실행 설정

`/autofix setup`이거나, 수동 실행 0단계에서 monitor 설정이 없다고 나왔을 때(`monitor-fetch.sh check` exit 5) SKILL.md가 이 파일로 보낸다. 경로 표기 `$ROOT`는 SKILL.md와 같다(플러그인 루트).

**묻지 않고 정하지 않는다.** provider·service·env·project·environment 같은 값은 저장소 흔적과 실제 모니터링 데이터로 선택지를 보여 주고 사용자가 고르게 한다. 만든 설정은 쓰기 전에 전체를 보여 주고 확인받는다.

## 설정 형식

설정은 `monitor` 객체 하나다. 두 곳 중 한 곳에 두며, 둘 다 있으면 로컬 파일이 이긴다. **자격증명은 어느 쪽에도 넣지 않는다.**

| 위치 | 언제 | 비고 |
|---|---|---|
| 개인 로컬 `~/.ai-harness/autofix/monitors/<project_id>.json` (기본) | 나만 무인 실행을 켤 때 | 파일 내용이 곧 `monitor` 객체. 켜기(`HM_AUTOFIX_*`)·상태(`~/.ai-harness/autofix/`)와 같이 로컬에 있어 팀 저장소에 커밋할 일이 없다. 여러 사람이 같은 설정을 공유해 각자 켜면 같은 에러로 PR이 중복되므로 기본은 로컬이다 |
| 저장소 manifest `.ai-harness/harness.json`의 `monitor` (선택) | 팀이 같은 설정을 공유해야 할 때 | 기준 브랜치에 커밋된 값을 읽는다. 로컬 파일이 없을 때만 쓰인다 |

`<project_id>`는 manifest의 `project_id`(없으면 origin 저장소 이름 — `HM_AUTOFIX_REPOS`와 같은 키)다. 로컬 파일이 있는데 JSON 객체 하나가 아니거나 `provider`가 없으면 manifest로 넘어가지 않고 거부한다(설정 오류, 무인 실행 대상에서도 빠진다). provider별 규칙(아래 표, `base_url`·`site` 제한, `command` 경로 제한)은 두 위치에 똑같이 적용된다.

```json
{
  "provider": "sentry",
  "org": "acme", "project": "api-server", "environment": "production",
  "min_events": 10, "window_hours": 24,
  "deploy_branch": "main", "grace_hours": 24, "quiet_hours": 72
}
```

| provider | 필수 필드 | 자격증명(환경변수 · `~/.claude/settings.json` env · `~/.ai-harness/config`) |
|---|---|---|
| `sentry` | `org`, `project` (선택: `environment`, `base_url`은 `*.sentry.io`만) | `SENTRY_AUTH_TOKEN` 또는 `HM_SENTRY_TOKEN`. 자체 호스팅은 config의 `HM_SENTRY_URL` |
| `datadog` | `query` (예: `service:api env:prod status:error`), 선택 `site` | `DATADOG_API_KEY`·`DATADOG_APP_KEY` (또는 `DD_*`, `HM_DATADOG_*`) |
| `command` | `command` — 저장소 안 실행 파일의 상대 경로 | 어댑터가 알아서 |

공통 필드: `min_events`(기본 10, 창 안 발생 수가 이보다 적으면 후보 아님), `window_hours`(기본 24), `deploy_branch`(병합 커밋이 이 브랜치에 들어간 것을 관찰한 때를 배포 시각으로 본다. 없으면 병합 시각), `grace_hours`(배포 뒤 롤링·캐시를 기다리는 유예, 기본 24), `quiet_hours`(재발 없음을 지켜볼 최소 시간, 기본 72).

`command` 어댑터는 세 하위 명령을 지원해야 한다(저장소 루트에서 실행, 표준출력 JSON):
- `list <hours>` → 줄마다 `{"signature","title","count","first_seen","last_seen","link","meta":{}}`
- `detail <meta-json>` → `{"message","stack",...}`
- `count <meta-json> <since-iso>` → `{"seen":bool,"count":n,"last_seen"}`

## 절차

1. 저장소에 `.ai-harness/harness.json`이 없으면 `/harness-init`을 먼저 안내하고 멈춘다. `project_id`를 확인한다(manifest의 `project_id`, 없으면 origin 저장소 이름).
2. 쓰는 모니터링 도구를 확인한다 — 저장소에서 SDK 흔적(`sentry` 의존성·DSN 설정, `dd-trace`·`datadog` 설정)을 먼저 찾고, 없거나 둘 이상이면 사용자에게 묻는다. 그 밖의 도구면 `command` 어댑터 골격을 만들어 준다(어댑터 스크립트는 저장소 안에 있어야 한다).
3. 이미 설정이 있으면(로컬 파일 또는 manifest) 현재 값과 출처를 보여 주고 바꿀지 묻는다. 바꾸지 않으면 6단계로 간다.
4. provider 필수 값을 고르게 한다(Datadog `query`, Sentry `org`·`project`·`environment`).
   1. **저장소 흔적 → 추천값**: 찾은 값은 추천으로만 쓰고 출처(파일:줄)를 함께 보인다.
      - Datadog: `DD_SERVICE`·`DD_ENV`·`DD_SITE`·`DD_TAGS`(env 파일·Dockerfile·배포 매니페스트), `dd.service`·`dd.env`(JVM 옵션·`application.yml`), `datadog.yaml`의 `service`·`env`
      - Sentry: `sentry.properties`·`.sentryclirc`의 `defaults.org`·`defaults.project`, `SENTRY_ORG`·`SENTRY_PROJECT`·`SENTRY_ENVIRONMENT`, SDK 초기화의 `environment`. DSN에는 org 슬러그가 없으니 org는 흔적이나 아래 org 목록으로 정한다
   2. **실제 데이터로 선택지**: 최근 에러가 어디서 나는지 보여 준다. 자격증명은 `monitor` 설정과 같은 곳에서 찾고, 전송처도 같은 규칙으로 제한된다(Datadog `--site`는 공개 사이트만, Sentry `--base-url`은 `*.sentry.io`만 — 자체 호스팅은 `~/.ai-harness/config`의 `HM_SENTRY_URL`).
      - Datadog: `$ROOT/scripts/monitor-fetch.sh discover --provider datadog [--site <site>] [--hours 24]` → 줄마다 `{"service","env","count","query"}`(최근 error 로그를 service·env로 묶은 건수, 많은 순)
      - Sentry: org를 모르면 `$ROOT/scripts/monitor-fetch.sh discover --provider sentry`로 org 목록(`{"org","name"}`)을 먼저 보여 주고 고르게 한다. 이어 `discover --provider sentry --org <org> [--hours 24]` → 줄마다 `{"project","environment","events","issues"}`
      - 결과를 표로 보여 준다(번호·service/project·env/environment·건수, 흔적과 맞는 행에 추천 표시). 사용자가 하나 이상 고른다. Datadog은 여러 service를 고르면 `(service:a OR service:b) env:prod status:error`처럼 묶는다. Sentry `monitor`는 project 하나와 environment 하나(비우면 전체)라, 여러 개를 고르면 그 한계를 알리고 하나로 좁히게 한다.
      - discover가 실패하면(자격증명 없음 exit 4 등) 메시지대로 자격증명 위치를 안내하고, 사용자가 원하면 값을 직접 받는다. 결과가 비면 `--hours 168`로 한 번 넓혀 보고, 그래도 없으면 직접 받는다. 어느 경우든 값을 지어내지 않는다.
   3. 공통 필드(`min_events`·`window_hours`·`deploy_branch`·`grace_hours`·`quiet_hours`)는 기본값을 보여 주고 바꿀지 묻는다.
   4. **확인 후 쓰기**: 만든 `monitor` 객체 전체(예: `{"provider":"datadog","query":"service:api env:prod status:error","site":"datadoghq.com"}`)를 보여 주고 확인받은 뒤에만 5단계로 간다.
5. 쓸 위치를 고르게 한다 — 추천은 **개인 로컬 파일**이고, 팀 공유가 필요하다고 할 때만 manifest에 쓴다.
   - 로컬: `~/.ai-harness/autofix/monitors/<project_id>.json`에 `monitor` 객체만 쓴다(폴더가 없으면 만든다). 저장소 파일은 건드리지 않는다.
   - manifest: `.ai-harness/harness.json`의 `monitor`만 쓴다(다른 필드는 건드리지 않는다). 커밋해야 정기 실행이 읽는다.
6. `$ROOT/scripts/monitor-fetch.sh check --root .` 로 접근을 확인하고, 실패하면 메시지대로 자격증명 위치를 안내한다. 이어 `$ROOT/scripts/monitor-fetch.sh list --root .` 상위 5건을 보여 준다.
   - 로컬 파일은 바로 읽힌다. manifest에 썼다면 `check`·`list`는 기준 브랜치의 manifest를 읽으므로, 아직 커밋 전이면 커밋 뒤 다시 확인하라고 알린다.
   - 수동 실행 0단계에서 넘어왔다면 확인 뒤 SKILL.md **수동 수정** 1단계로 돌아간다.
7. 무인 실행 설정을 묻고 쓴다. 먼저 `$ROOT/scripts/autofix-auto.sh configure`로 현재 값을 보여 준다(값은 개인 `~/.ai-harness/config`의 전역 설정이라 모든 저장소에 적용된다). 아래를 하나씩 추천값과 함께 묻고, 사용자가 그대로 두겠다고 하면(엔터) 추천값을 쓴다. 이미 값이 있으면 현재 값을 추천값 대신 보여 주고 바꿀지 묻는다.

   | 질문 | 플래그 | 추천값 |
   |---|---|---|
   | 무인 실행을 켤까요? | `--auto 1` / `--auto 0` | 켜기 |
   | 이 저장소를 무인 실행 대상에 넣을까요? (기존 목록은 유지, 중복 없이 추가) | `--add-repo <project_id>` | 넣기 |
   | sweep 주기(분, 1~999999 정수 — 5·90·180 등 아무 값. macOS가 아니면 60·24를 나누지 않는 주기는 cron 한 줄로 못 써 systemd 타이머를 안내한다)? 비워 두면 정기 실행 주기(`HM_BACKFILL_INTERVAL_HOURS`, 기본 6시간)에 같이 돈다 | `--interval-minutes N` / `off` | 비움(정기 실행 주기) |
   | 하루 실행 상한? (0이면 하루 0회, `unlimited`면 제한 없음) | `--daily-max N` / `unlimited` | 3 |
   | 시그니처당 PR 상한? | `--max-attempts N` | 2 |
   | 실행당 예산(USD)? (`unlimited`면 수정 실행에 비용 상한을 넘기지 않음) | `--budget-usd X` / `unlimited` | 10 |

   사용자가 하루 상한이나 실행당 예산에 `unlimited`를 고르면 비용이 커질 수 있다고 한 줄로 알리고, 둘 다 `unlimited`면 "비용 상한이 없어진다"고 분명히 말한 뒤 그대로 쓸지 한 번 더 확인한다. `--daily-max unlimited`는 보드의 자동 harvest·sync '제한 없음'과 같은 관례로 `1000`을 쓴다(1000 이상 = 제한 없음 — 1000 이상의 수를 직접 넣어도 제한 없음으로 동작한다).

   고른 값을 한 번에 쓴다: `$ROOT/scripts/autofix-auto.sh configure --auto 1 --add-repo <project_id> --daily-max 3 --max-attempts 2 --budget-usd 10 [--interval-minutes N]`. 이 명령은 해당 키만 바꾸고 다른 줄·주석·권한은 그대로 두며, 값이 하나라도 틀리면(정수·소수 아님 등) 아무것도 쓰지 않고 exit 2로 끝난다 — 메시지를 보여 주고 다시 묻는다. 출력 JSON(현재 값)을 사용자에게 보여 준다.
   - 주기를 정했거나(`--interval-minutes N`) 끄면(`off`) 이어서 `$ROOT/scripts/schedule.sh install`을 돌려 sweep 전용 LaunchAgent를 등록(또는 내림)하고, `$ROOT/scripts/schedule.sh status`의 `autofix`(설치 여부·`interval_minutes`)로 확인해 보여 준다. macOS가 아니면 install이 cron 줄을 안내하므로 그대로 전한다.
   - 검증 명령이 기본 빌드 도구 목록(gradle·maven·npm/pnpm/yarn·go·pytest·make·cargo)에 없으면 `HM_AUTOFIX_BASH_ALLOW="./scripts/ci.sh*"`처럼 패턴을 더하게 한다(이 값은 `configure`가 쓰지 않는다 — config에 직접 쓴다).
   - 주기마다 검증 → 새 에러 1건 수정을 돈다. 전용 주기(`HM_AUTOFIX_INTERVAL_MINUTES`)는 유휴 대기 없이 돌지만 사용량 한도 직후 휴지(`HM_LLM_BACKOFF_HOURS`)와 하루 상한은 지킨다. 정기 실행 경로와 겹치면 늦게 온 sweep은 건너뛴다.
