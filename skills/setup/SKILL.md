---
name: setup
description: ai-harness 설치 후 사용자 전역 셋업. 기본 스킬 카탈로그(datadog·sentry·jira·confluence·langfuse)에서 고른 것만 ~/.claude/skills·~/.agents/skills에 설치·갱신·제거하고, 외부 디자인 스킬(impeccable 등)을 원본 저장소의 고정 커밋으로 설치하며(대화형 셋업에서 함께 묻는다), 토큰 발급을 안내해 대화에 남기지 않고 저장한 뒤 연결을 확인하며, 회사·팀 전용 값(기본 프로젝트·필드 ID·생성 규칙·이슈 타입 계층)을 팀 규칙 원본에서 차이를 확인해 가져오거나 물어서 사용자 규칙 파일로 남기고, 선택형 자동화 옵션을 켠다. 플러그인을 처음 설치했을 때, 세션 시작 안내가 셋업을 권할 때, 또는 기본 스킬을 추가·제거하고 싶을 때 쓴다.
---

# /setup — ai-harness 전역 셋업

플러그인 설치만으로는 아무 스킬도 사용자 전역 폴더에 깔지 않는다. 이 Skill이 사용자가 고른 것만 설치한다. 인자: `$ARGUMENTS` (없으면 대화형 셋업, `update`면 4단계만, `status`면 1단계와 6단계(연결 확인), 디자인 스킬 상태 요약만, `design`이면 [디자인 스킬](#디자인-스킬-design)만, `team`이면 [팀 규칙 가져오기](#7-0-팀-규칙-가져오기)만, `<스킬 이름>`이면 그 스킬의 5~7단계만).

경로 표기: 아래 `$ROOT` = 이 SKILL.md가 있는 디렉터리의 두 단계 상위(플러그인 루트).

## 1. 현재 상태

```bash
$ROOT/scripts/setup.sh list
```

스킬마다 한 줄 JSON이 나온다: `name`, `summary`, `status.claude`·`status.codex`, `env[]`(`keys`, `required`, `found`, `source`).

| status | 뜻 |
|---|---|
| `absent` | 설치 안 됨 |
| `current` | ai-harness가 설치한 사본, 최신 |
| `outdated` | ai-harness가 설치한 사본, 플러그인에 새 버전 있음 (손대지 않았으므로 갱신 안전) |
| `modified` | ai-harness가 설치한 사본을 사용자가 고침 — 자동 갱신하지 않음 |
| `foreign` | 같은 이름의 스킬이 원래 있었음 — ai-harness가 관리하지 않음 |

표로 보여 준다: 스킬 · 하는 일 · Claude/Codex 상태 · 접속 정보(필수 키 중 빠진 것) · 사용자 규칙 파일 유무(`profile.exists`).

디자인 스킬 상태도 함께 본다(대화형 셋업과 `status`):

```bash
$ROOT/scripts/setup.sh design list
```

한 줄로 요약한다: 묶음별로 설치됨(`current`)·직접 둔 사본(`foreign`)·안 됨(`absent`)·갱신 필요(`outdated`)·고친 사본(`modified`), 내장(`builtin`)·수동(`manual`) 항목 이름, `superseded`·`conflict`가 있으면 그 안내. 도구마다 상태가 다르면 도구별로 나눠 쓴다. 상태값 뜻은 [디자인 스킬](#디자인-스킬-design) 1번.

## 2. 고르기

다음을 묻는다. 질문 도구가 있으면 그것으로, 없으면 번호 목록으로 묻는다.

1. **설치할 스킬** (여러 개 선택). 이미 `current`인 것은 기본 선택, `foreign`은 "이미 직접 만든 스킬 있음 — 유지 권장"으로 표시한다.
2. **도구**: 지금 세션의 도구를 기본값으로 — Claude Code면 `claude`, Codex면 `codex`. 둘 다 쓰면 `both`.
3. 선택에서 빠진 `current`/`outdated` 스킬이 있으면 제거할지 따로 확인한다. 묻지 않고 지우지 않는다.
4. **디자인 스킬** (질문 하나). 1단계 `design list` 결과로 묻는다.
   - `core` (권장) — `impeccable` + Claude 내장 `dataviz`. 화면·대시보드·리포트 작업의 주도 스킬이다.
   - extra 개별 — `bundle:"extra"`이면서 `builtin`이 `null`이고 `source`가 있는 설치 가능 항목(현재 `design-taste-frontend`·`ui-ux-pro-max`)을 여러 개 고른다. 항목마다 `review.runs`·`review.network`를 한 줄로 함께 보여 줘 외부 스크립트·네트워크 사용을 알고 고르게 한다. core도 함께 원하면 같이 고를 수 있다.
   - 건너뛰기.

   상태는 고른 도구 기준으로 본다. `both`인데 도구마다 상태가 다르면 도구별로 판단해 알린다 — 예: Claude는 직접 둔 사본이 있고 Codex는 없으면 "Codex에만 core 설치를 권함"으로 묻고, 같은 `design install --tool both`가 Claude 쪽은 `skipped foreign`으로 그대로 둔다. core의 설치 대상(`impeccable`)이 이미 `current`거나 `foreign`(사용자가 직접 둔 같은 이름 스킬)이면 질문을 줄인다 — "core 있음"을 알리고 기본 선택을 건너뛰기로 둔 채 extra만 물을지 확인한다. `foreign`은 "직접 둔 사본이 있어 그대로 쓴다 — 고정 커밋 사본으로 바꾸려면 교체를 명시"라고 표시하고 권장하지 않는다(골라도 `skipped foreign`이 된다). 교체를 명시하면 3단계 `--replace` 규칙을 따른다. `current`인 extra는 기본 선택, `foreign`인 extra는 같은 표시로 고를 대상에서 뺀다. 내장(`builtin`)·수동(`manual`) 항목은 고를 대상에서 빼고 상태만 표시한다. `superseded`·`conflict` 안내는 [디자인 스킬](#디자인-스킬-design) 3번 규칙 그대로다. 도구는 위 2번 답을 재사용한다. 고르지 않은 디자인 스킬은 지우지 않는다.

## 3. 설치·제거

```bash
$ROOT/scripts/setup.sh install --tool <claude|codex|both> <name>...
$ROOT/scripts/setup.sh remove --tool <claude|codex|both> <name>...
```

결과는 항목별 `action`이다: `installed`·`updated`·`unchanged`·`removed`·`skipped`(`detail`이 `foreign`/`modified`).

- `skipped foreign`: 사용자가 원래 갖고 있던 스킬이라 그대로 뒀다고 알린다. 사용자가 **교체를 명시**했을 때만 `install --replace`로 다시 실행한다 — 기존 폴더는 지우지 않고 `~/.ai-harness/setup/backups/`로 옮겨지며, 결과 `detail`에 그 경로가 나온다.
- `skipped modified`: 사용자가 고친 사본이다. 덮어쓰기는 같은 방식(`--replace`, 백업 후 교체)으로 사용자가 원할 때만 한다.
- 새로 깐 스킬은 다음 세션부터 로드된다고 알린다.

2단계에서 디자인 스킬을 골랐으면 같은 도구로 기존 경로를 쓴다(결과 처리는 [디자인 스킬](#디자인-스킬-design) 4번):

```bash
$ROOT/scripts/setup.sh design install --tool <claude|codex|both> <core|이름>...
```

## 4. 갱신 (`update`)

손대지 않은(`outdated`) 관리 사본은 SessionStart가 자동으로 최신화하고 알린다. 지금 바로 하려면:

```bash
$ROOT/scripts/setup.sh update
```

`modified` 사본은 갱신하지 않는다. 사용자가 원하면 카탈로그 원본(`$ROOT/catalog/<name>/SKILL.md`)과 diff를 보여 주고, 합칠지 `--replace`로 교체할지 묻는다.

## 5. 접속 정보 — 발급·저장·연결 확인

설치한 스킬마다 `list`의 `env[]`를 본다. `found:null`이고 `required:true`인 키를 하나씩 처리한다. 이미 있는 키도 6단계 연결 확인에서 실패하면 같은 절차로 다시 넣는다.

1. **발급 안내** — `issue.url`(있으면 링크), `issue.steps`, `issue.scopes`를 그대로 보여 준다. scope가 있으면 "읽기 전용 scope만 고르세요"를 덧붙인다. 같은 키를 쓰는 스킬이 여럿이면(jira·confluence의 `ATLASSIAN_*`) 한 번만 묻는다. Langfuse는 아래 [Langfuse 키](#langfuse-키)를 따른다.
2. **저장 대상** — 2단계에서 고른 도구: Claude Code는 `~/.claude/settings.json`의 `env`, Codex는 `~/.ai-harness/secrets.env`(권한 600).
3. **비밀 아닌 값**(`secret:false` — base URL·이메일·조직 slug·사이트): 대화로 받아 바로 저장한다.
   ```bash
   $ROOT/scripts/setup.sh set --tool <claude|codex|both> JIRA_BASE_URL https://acme.atlassian.net
   ```
   base URL은 사용자가 붙인 브라우저 주소에서 뽑아도 된다(Jira `https://<사이트>.atlassian.net`, Confluence `.../wiki`까지, Datadog 사이트는 `app.` 뒤 도메인).
4. **비밀 값**(`secret:true` — 토큰·키): **대화로 받지 않는다.** 사용자에게 별도 터미널에서 아래를 실행하라고 안내하고(입력이 화면에 보이지 않는 프롬프트), 끝났다고 답하면 다음으로 간다. 이 세션의 Bash로 대신 실행하지 않는다 — 숨김 입력을 받을 터미널이 없다.
   ```bash
   <$ROOT의 실제 절대 경로>/scripts/setup.sh set --tool <claude|codex|both> ATLASSIAN_API_TOKEN
   ```
   클립보드에 복사해 뒀다면 `pbpaste | <경로>/scripts/setup.sh set --tool claude ATLASSIAN_API_TOKEN`도 된다. `setup.sh`는 secret 키를 명령 인자로 주면 거부한다.
5. Codex에 저장했으면 결과의 `shell_profile_line`을 셸 프로파일(`~/.zshrc` 등)에 한 번 넣으라고 안내한다.

값을 출력하거나 `echo $KEY`로 확인하지 않는다.

### Langfuse 키

키는 개인이 아니라 프로젝트 단위다. 여기서는 기본 프로젝트 한 쌍만 넣고, 다른 프로젝트는 같은 스크립트에 별칭을 주어 더한다고 안내한다. `setup.sh set` 대신 설치된 스킬의 `register.py`를 쓴다 — 리전(host)을 자동으로 찾아 저장하므로 EU 밖 계정이 `LANGFUSE_HOST`를 따로 넣지 않아도 된다. 아래 `<lf>`는 설치된 사본의 `scripts/` 절대 경로(Claude `~/.claude/skills/langfuse/scripts`, Codex `~/.agents/skills/langfuse/scripts`).

먼저 묻는다: **키를 각자 발급하는가, 팀 비밀 저장소(AWS SSM·Vault·1Password 등)에 있는가?** 사용자 규칙 파일에 `key_source`가 이미 있으면 묻지 않고 따른다.

- **직접 발급** — 발급 안내(`issue`)를 보여 주고, 키 값은 대화로 받지 않고 클립보드 단계로 넣는다. 이 세션의 Bash로 실행해도 된다(값이 출력되지 않음).
  1. Public Key를 복사하게 한 뒤 `python3 -I <lf>/register.py default --stage pk`
  2. Secret Key를 복사하게 한 뒤 `python3 -I <lf>/register.py default --stage sk`
  3. `python3 -I <lf>/register.py default` — 리전 탐색·프로젝트 이름 확인 후 저장
- **비밀 저장소** — 발급 안내를 건너뛴다. 키를 한 줄로 출력하는 명령 두 개를 사용자와 정한다(경로는 사용자가 알려 준 규칙대로 — 추측하지 않는다). 명령은 비밀이 아니므로 대화로 받아도 된다.
  ```bash
  python3 -I <lf>/register.py default --pk-cmd '<명령>' --sk-cmd '<명령>'
  ```
  명령이 실패하면 그 오류(로그인 만료·권한 없음 등)를 보여 주고 사용자가 고친 뒤 다시 한다. 예: AWS SSM은 `aws ssm get-parameter --name <경로> --with-decryption --query Parameter.Value --output text`(필요하면 `--profile`), 권한 `ssm:GetParameter`·`kms:Decrypt`.

`register.py`는 Claude `settings.json`에 저장하고 `secrets.env`가 있으면 그곳에도 저장한다. `~/.claude`가 없으면(Codex만 사용) `secrets.env`를 만들어 저장한다. 스킬 스크립트는 두 파일을 모두 직접 읽는다. 저장소 종류·경로 규칙은 7단계 사용자 규칙(`key_source`)에 남긴다.

## 6. 연결 확인

```bash
$ROOT/scripts/setup.sh check <name>
```

읽기 전용 호출 하나로 자격 증명을 확인한다(Datadog `/api/v1/validate`+현재 사용자, Jira `/myself`, Confluence 현재 사용자, Sentry 조직 조회, Langfuse 키가 가리키는 프로젝트 조회 — 401이면 키나 리전(`LANGFUSE_HOST`) 불일치). 방금 저장한 값은 이 세션 환경에 아직 없으므로 스크립트가 settings.json·secrets.env에서 직접 읽는다.

- `ok:true` — `as`(누구로 접속했는지)를 보여 준다. 다른 계정이면 사용자에게 확인한다.
- `ok:false` — `error`와 `hint`를 보여 주고 5단계로 돌아가 해당 키를 다시 넣는다. 두 번 실패하면 멈추고 사용자에게 넘긴다.
- `missing` — 5단계를 건너뛴 키다.

## 7. 사용자 규칙 (회사·팀 전용 값)

카탈로그 스킬 본문은 범용이다. 회사·팀마다 다른 값은 스킬 파일이 아니라 `list`의 `profile.path`(`~/.ai-harness/skills/<name>.md`)에 적는다 — 스킬 본문을 고치면 그 사본은 `modified`가 되어 자동 갱신이 멈춘다. 카탈로그 스킬은 호출 전에 이 파일을 먼저 읽는다.

### 7-0. 팀 규칙 가져오기

조직이 규칙을 한 곳(팀 규칙 원본 — git 저장소나 공유 폴더의 `skills/<name>.md`)에 두었으면 질문 전에 그것부터 가져온다. 원본은 아래 순서로 찾고, 둘 다 없으면 이 절을 건너뛰고 1번 질문으로 간다.

1. 개인 설정: `~/.ai-harness/config`의 `HM_TEAM_RULES=<git URL 또는 로컬 경로>`(선택 `HM_TEAM_RULES_REF=<브랜치·태그·커밋>`)
2. 저장소 표식: 현재 위치에서 위로 가장 가까운 `.ai-harness/harness.json`(workspace면 `workspace.json`)의 `"team_rules": {"source": "<git URL 또는 경로>", "ref": "<선택>"}`. 상대 경로는 그 저장소 루트 기준이다. `/harness-init`이 넣는다.

```bash
$ROOT/scripts/setup.sh team list
```

`source`(찾은 원본, 없으면 `null`)·`from`(`config` 또는 표식 파일 경로)과 원본에 있는 카탈로그 스킬마다 `name`·`sha256`·`state`가 나온다. git 원본은 `skills/`만 받는다(프롬프트·hook 없이). 원본 내용은 에이전트 지시가 되므로 이 두 곳 말고 다른 데서 찾지 않는다.

| state | 뜻 |
|---|---|
| `new` | 사용자 규칙 파일 없음 |
| `untracked` | 파일은 있는데 팀 블록 없음 — 적용하면 기존 내용은 개인 블록으로 남는다 |
| `current` | 팀 블록이 원본과 같음 — 건너뛴다 |
| `changed` | 원본이 바뀜 |
| `broken` | 마커가 깨짐 — 적용하지 않고 사용자에게 마커를 손으로 고치게 한다 |

`new`·`untracked`·`changed`인 스킬마다:

1. 차이를 보여 준다 — 바로 덮어쓰지 않는다:
   ```bash
   $ROOT/scripts/setup.sh team diff <name>
   ```
   unified diff를 그대로 보여 주고, 원본 출처(`source`)와 함께 "이 내용이 에이전트 규칙이 된다"고 알린 뒤 적용할지 묻는다.
2. 확인받은 것만 그 diff의 sha로 쓴다:
   ```bash
   $ROOT/scripts/setup.sh team apply <name> --sha <diff에 나온 sha256>
   ```
   `stale`이면 원본이 그사이 바뀐 것이다 — diff부터 다시 보여 준다.

파일은 팀 블록(`<!-- ai-harness:team-rules:begin source=… ref=… sha256=… -->` ~ `<!-- ai-harness:team-rules:end -->`)과 그 밖의 개인 블록으로 나뉜다. 다시 적용하면 팀 블록만 바뀌고 개인 블록은 그대로다. 개인 값(기본 프로젝트 등)은 아래 질문으로 개인 블록에 적는다 — 팀 블록이 이미 답한 질문은 건너뛴다. 원본에도 이 파일에도 자격 증명을 두지 않는다.

갱신 알림: 세션 시작 안내가 적용한 팀 블록의 sha와 원본을 비교해 바뀌었으면 "팀 규칙 원본이 갱신됐습니다 — `/ai-harness:setup team`으로 반영"을 한 번 알린다(자동으로 덮어쓰지 않음). git 원본은 세션 시작을 막지 않게 하루 한 번(`HM_TEAM_RULES_REFRESH_HOURS`, 기본 24) 백그라운드로 받아 두고 다음 세션에 비교한다. 저장소 표식이 가리키는 원본을 아직 가져오지 않았으면 그것도 원본마다 한 번 알린다. 끄려면 `HM_TEAM_RULES_HINT=0`.

### 7-1. 질문

1. 연결 확인이 된 스킬은 선택지를 계정에서 읽어 온다:
   ```bash
   $ROOT/scripts/setup.sh detect <name>
   ```
   Jira는 스프린트·에픽 링크 필드 ID(이름이 아니라 타입으로 찾으므로 언어 설정과 무관)와 최근 프로젝트, 기본 프로젝트의 생성 가능한 이슈 타입과 계층(`issue_types`), 그 프로젝트 최근 이슈의 전환 목록(`transitions`)을 준다. 기본 프로젝트를 이미 정했으면 `detect jira --project <KEY>`로 그 프로젝트를 본다. Confluence는 스페이스, Datadog은 최근 24시간 에러가 많은 서비스, Sentry는 프로젝트 목록을 준다.
2. `profile.questions`를 순서대로 묻는다. `detect` 결과가 있는 질문은 선택지로 보여 준다(Jira 이슈 타입은 `issue_types`, 쓰지 않는 상태는 `transitions.list`에서 여러 개 고르게 한다). 필드 ID처럼 자동으로 확정되는 값은 묻지 않고 적는다. 모르는 항목은 비워 둔다.
3. 같은 이름의 개인 스킬이 `foreign`으로 남아 있으면, 그 SKILL.md를 Read해 회사 전용 값(사이트 주소·필수 필드·커스텀 필드 ID·팀 관례)을 뽑아 초안으로 제안한다. 뽑은 필드 ID가 `detect` 결과와 다르면 `detect` 값을 쓰고 차이를 알린다.
4. 사용자가 확인한 내용만 Write로 저장한다. 이미 파일이 있으면 Read해 바뀐 줄만 고친다 — 팀 블록(마커 사이)은 고치지 않는다(팀 규칙과 다르게 하고 싶은 값은 개인 블록에 적는다). 형식:
   ```markdown
   # jira 사용자 규칙
   <!-- /ai-harness:setup이 만든 파일. 직접 고쳐도 되고, 다시 setup하면 이 내용을 바탕으로 묻는다. -->

   - 기본 프로젝트: NJ
   - 필드: 스프린트 `customfield_10113`, 에픽 링크 `customfield_10006`
   - 이슈 생성: 상위 에픽·활성 스프린트·수정 버전을 반드시 채운다. 모르면 후보를 조회해 추천하고 확인받는다.
   - 이슈 타입: 에픽 > Task > SubTask. Story는 기획자만 만든다 — 에이전트는 만들지 않는다.
   - 쓰지 않는 상태: Drop — 전환할 때 고르지 않는다.
   - 후속·반영 이슈: 새 Task가 아니라 원 이슈의 SubTask로 만든다.
   - 관례: 요약은 "[모듈] 동사로 끝나는 한 줄"
   ```
   자격 증명 값은 이 파일에 적지 않는다.

## 8. 자동화 옵션 (선택)

`~/.ai-harness/config`를 Read해 현재 값을 보여 주고, 켤 것을 고르게 한다. 고른 것만 `KEY=VALUE` 줄로 추가하거나 기존 줄을 고친다. 아무것도 고르지 않으면 파일을 건드리지 않는다.

| 키 | 기본 | 켜면 |
|---|---|---|
| `HM_DIGEST` | `0` | 하루 한 번 최근 세션을 저비용 모델로 정리해 사용자 교정·마찰을 harvest 근거로 남긴다 (LLM 비용 발생) |
| `HM_HARVEST_AUTO` | `0` | analysis batch가 생기면 `/harvest --auto`를 백그라운드로 돌려 draft PR까지 만든다 |
| `HM_SYNC_AUTO` | `0` | 하네스가 플러그인보다 뒤처진 저장소에 `/harness-init --sync`를 백그라운드로 돌려 draft PR을 만든다 |
| `HM_SYNC_AUTO_MERGE` | `0` | 자동 sync PR 중 기계적으로 검증되는 것(템플릿 그대로 복사한 생성물·`harness.json`만 바뀜, CI 통과, 사람 활동 없음)을 병합한다. `HM_SYNC_AUTO=1`과 함께 쓴다 |
| `HM_HARVEST_AUTO_MERGE` | `0` | 자동 harvest PR 중 작은 문서 변경이고 worker가 띄운 독립 검토를 통과한 것을 병합한다(검토 1회 LLM 비용). `HM_HARVEST_AUTO=1`과 함께 쓴다 |
| `HM_DB_SCAN_GUARD` | `0` | 스키마 조건 없는 information_schema 조회를 Bash 실행 전에 막는다 |

자세한 동작은 README의 해당 절을 가리킨다. 백그라운드 실행 옵션은 draft PR까지만 하고, 병합은 자동 병합 옵션을 켠 경우에만 한다는 점을 함께 알린다.

자동 병합 옵션을 고르면 세 가지를 더 알린다.
- 이 설정만으로 동작한다. 저장소 `harness.json`에 허용 스위치를 넣는 팀 PR은 필요 없다(예전 `auto_merge.sync`·`harvest`는 읽지 않는다). 내용 조건과 병합 직전 호스트 조건(사람 활동 없음·CI 통과·head 고정)은 그대로 확인한다.
- 조정값은 같은 파일의 `HM_AUTO_MERGE_METHOD`(`squash`·`merge`·`default`)·`HM_AUTO_MERGE_SYNC_PARTIAL`·`HM_AUTO_MERGE_REQUIRE_CI`·`HM_AUTO_MERGE_WAIT_HOURS`·`HM_AUTO_MERGE_HARVEST_MAX_FILES`·`HM_AUTO_MERGE_HARVEST_MAX_LINES`로 바꿀 수 있다. 묻지 않고 기본값을 두며, 사용자가 원할 때만 적는다. 저장소 기준 브랜치에 같은 키(`auto_merge.<key>`)가 있으면 안전한 쪽을 쓴다(README 자동 병합 절).
- 처음에는 sync만 켜고 지켜본 뒤 넓히기를 권한다. harvest 자동 병합은 팀 에이전트 지침을 사람 검토 없이 바꾸므로 sync가 안정적으로 돈 뒤에 고려한다.

### 8-0. 워크플로 승인 모드 (선택)

승인 게이트를 사용자 개인 설정으로 고른다. `~/.ai-harness/config`를 읽어 현재 값을 보여 주고 선택한 키만 기록한다. 기본은 `human`이며, 저장소 manifest의 기존 `approval`은 더 이상 적용되지 않는다.

1. 전체 설정 `HM_APPROVAL=human|auto`를 고른다. `auto`는 Brief에 추천 결정과 근거를 남기고, 사람이 정할 사항이 없을 때 승인 게이트를 통과한다.
2. 저장소별 예외가 있으면 `HM_APPROVAL_REPOS="<project_id>=<human|auto>,…"`로 지정한다. 일치하는 저장소별 항목이 전체 설정보다 우선한다. 키는 manifest `project_id` 또는 origin 저장소 이름이다.
3. 설정 파일의 다른 줄·주석·권한을 보존한다. 기존 manifest에 `approval`이 있으면 자동 삭제하지 말고 사용자에게 개인 설정으로 옮기도록 안내한다.

### 8-1. 워크플로 자동화 단계 (선택)

워크플로 러너(기능 개발·버그 수정)가 PR 뒤 어디까지 스스로 갈지를 **사용자마다** 고른다. 저장소 설정이 아니라 `~/.ai-harness/config`에 남으므로 팀 PR 없이 바로 바뀌고, 같은 저장소의 다른 사람에게 영향이 없다. 같은 파일을 Read해 현재 값을 보여 주고 묻는다. 고르지 않으면 건드리지 않는다 — 값이 없으면 러너는 PR까지만 한다. 병합 여부를 정하는 곳은 이 설정뿐이다(저장소의 예전 `git_policy:"merge"`·`merge_policy` 병합 조건은 더 이상 쓰지 않는다).

1. 기본 단계 `HM_DELIVERY_LEVEL`:
   - `pr` — PR까지. 병합·배포는 사람이 한다 (직접 리뷰하고 싶은 사람)
   - `merge` — 병합 조건이 맞으면 러너가 병합하고 병합 커밋의 원격 CI까지 본다
   - `deploy` — `merge`에 더해 저장소에 있는 배포 확인·스모크 명령까지. 저장소에 그 명령이 없으면 `merge`까지 하고 결과에 밝힌다
2. 저장소마다 다르게 하고 싶으면 `HM_DELIVERY_LEVEL_REPOS="<project_id>=<단계>,…"`로 덮어쓴다. `project_id`는 저장소 `.ai-harness/harness.json`의 `project_id`(없으면 origin 저장소 이름)이며, 현재 저장소에서 고르는 중이면 그 값을 읽어 제안한다.
3. `merge`·`deploy`를 골랐으면 병합 조건 최소치를 묻는다. 정하지 않으면 네 조건 모두·승인 1·squash를 쓴다. 현재 저장소 manifest `merge_policy`에 예전 `require`·`min_approvals`·`method`가 남아 있으면 그 값을 보여 주고 옮길지 묻는다 — 러너는 그 값을 읽지 않는다.
   - `HM_MERGE_REQUIRE` — `human_approval`·`remote_ci`·`no_conflict`·`not_draft` 중 쉼표 구분
   - `HM_MERGE_MIN_APPROVALS` — 1 이상
   - `HM_MERGE_METHOD` — `squash`·`merge`·`rebase`(Bitbucket은 rebase 불가)

`merge`·`deploy`를 고르면 다음을 함께 알린다.
- 팀 통제는 PR 호스트의 브랜치 보호다. 러너는 병합 직전에 기준 브랜치의 보호 규칙을 읽고, **필수 승인이 걸려 있지 않거나 읽을 수 없으면 병합하지 않고 사람에게 넘긴다**. GitHub 예전 브랜치 보호와 Bitbucket branch restrictions는 저장소 관리자 권한이 있어야 읽히므로, 권한이 없으면 GitHub 규칙 세트로 보호하거나 직접 병합한다.
- 호스트의 필수 승인 수·필수 체크는 내 조건보다 우선하는 하한으로 더해진다.
- 무인 실행(자동 harvest·sync 등)은 이 설정으로 병합하지 않는다.
- 기준 브랜치·배포·스모크 명령은 저장소 사실이라 `/harness-init`에서 PR로 바꾼다.

### 8-2. 보드에서 권한 요청 답하기 (선택)

`/ai-harness:board`(Harness Board)에서 다른 세션의 권한 요청을 허용/거부하려면 Claude Code PermissionRequest 훅이 필요하다. **묻지 않고 연결하지 않는다.** 현재 상태를 먼저 본다:

```bash
$ROOT/scripts/board/board.sh hook status
```

`installed`면 연결돼 있다고 알리고 끌지 묻는다. `others`에 다른 경로의 `permission-hook.py`가 있으면(예전에 손으로 둔 보드 훅) 그 줄을 보여 주고, 두 훅이 같은 요청을 함께 받는다는 것을 알린다 — 지울지는 사용자가 정하고, 지운다면 사용자가 직접 `~/.claude/settings.json`에서 뺀다.

물을 때 함께 알린다.
- 보드가 떠 있고 최근 30분 안에 누군가 보드를 본 경우에만 요청을 보드로 넘긴다. 보드가 꺼져 있으면 훅은 아무것도 출력하지 않아 평소처럼 터미널에서 묻는다.
- 보드는 사람이 누른 허용/거부만 돌려준다. 질문(AskUserQuestion)은 넘기지 않는다.
- Claude Code 전용이다(Codex에는 같은 훅이 없다).

고르면:

```bash
$ROOT/scripts/board/board.sh hook on    # 끄기: hook off
```

훅 파일을 `~/.ai-harness/board/bin/permission-hook.py`에 복사하고 `~/.claude/settings.json`에 PermissionRequest 항목(timeout 3600)을 더한다. 바꾸기 전 백업(`settings.json.bak-board-<시각>`)을 남기고 그 경로를 결과 `backup`으로 준다. `off`는 이 항목만 빼고 다른 훅·설정은 그대로 둔다. 새 세션부터 적용된다고 알린다.

## 디자인 스킬 (`design`)

ai-harness는 디자인 데이터셋을 담지 않고 절차만 둔다. 빈자리를 채우는 외부 디자인 스킬은 `catalog/design-skills.json`이 원본 저장소·고정 커밋·라이선스·실행 스크립트 검토 결과를 적고, 어느 작업에서 어느 스킬이 주도하는지는 디자인 스킬 지도(`$ROOT/templates/ui-review/references/design-skills.md`)가 정한다. 위 기본 카탈로그와 달리 사본을 들고 있지 않고 **원본 저장소의 고정 커밋에서 받는다**. 예외로 작고 안정적인 3종(`web-design-guidelines`·`emil-design-eng`·`design-system-patterns`)은 ai-harness에 고정 사본으로 내장돼 있어(`builtin: "ai-harness"`) 설치하지 않는다.

1. 현재 상태:
   ```bash
   $ROOT/scripts/setup.sh design list
   ```
   스킬마다 `bundle`(`core` 필수 / `extra` 선택), `summary`, `license`, `source`(저장소·커밋), `review`(실행하는 것·네트워크), `overlaps`(하네스 스킬이 대체하는 부분), `status.claude`·`status.codex`가 나온다. 상태는 위 표에 셋이 더 있다: `builtin`(그 도구에 내장 — 설치 불필요), `unavailable`(이 도구엔 대응 없음), `manual`(고정할 원본을 확인하지 못해 setup이 설치하지 않음 — `note`의 공식 경로로 직접 설치), `superseded`(setup이 예전에 받은 사본인데 이제 ai-harness에 내장됨 — `absorbed`가 내장 위치). `builtin`이 `ai-harness`인 항목에 같은 이름 폴더가 있으면 setup이 기록한 사본만 `superseded`이고, 고친 사본은 `modified`, 사용자가 직접 둔 폴더는 `foreign`이고 `conflict`에 도구별 안내가 붙는다. `outdated`는 카탈로그의 고정 커밋이 바뀌었다는 뜻이다.
2. 표로 보여 준다: 스킬 · 묶음 · 하는 일 · 라이선스 · 실행하는 것/네트워크 · Claude/Codex 상태. `review.network`에 외부 호출이 있으면 그 줄을 그대로 보여 준다.
3. 고르게 한다. 기본 선택은 `core`. 내장 항목은 고를 대상에서 빼고 "내장"으로만 표시한다. `superseded`가 있으면 "이제 내장이라 지워도 된다"고 알리고 `design remove`를 권한다 — `web-design-guidelines`의 예전 사본은 실행할 때마다 원격 규칙을 받으므로 특히 권한다. 사용자가 고르지 않으면 지우지 않는다. `conflict`가 있으면 그 문구를 그대로 보여 준다 — 직접 둔 폴더라 setup이 지우지 않으며, 옛 `web-design-guidelines`는 실행할 때마다 원격 규칙을 받으니 필요하면 사용자가 직접 정리한다. 하네스 스킬이 이미 대체하는 것(`overlaps`)은 "대부분 대체됨"으로 표시한다. 도구는 2단계와 같은 규칙.
4. 설치·제거:
   ```bash
   $ROOT/scripts/setup.sh design install --tool <claude|codex|both> <core|extra|all|이름>...
   $ROOT/scripts/setup.sh design remove --tool <claude|codex|both> <이름>...
   ```
   결과 `action`은 위와 같고 `builtin`(내장 — `--replace`여도 받지 않음)·`failed`(`detail`에 git 오류나 SKILL.md 확인 실패)가 더 있다. `superseded` 사본은 `remove`가 지우고, 고친 사본(`modified`)은 `--force`일 때만 백업 후 지운다. `foreign`·`modified` 처리와 `--replace`·`--force` 규칙은 3단계와 같다 — 사용자가 직접 깐 같은 이름 스킬은 명시 없이 바꾸지 않는다.
5. 외부 디자인 스킬은 SessionStart가 자동 갱신하지 않는다(설치할 때만 네트워크를 쓴다). 카탈로그의 고정 커밋이 바뀌어 `outdated`가 되면 `design install`을 다시 실행해 갱신한다.

## 9. 마무리

```bash
$ROOT/scripts/setup.sh done
```

셋업을 마쳤다고 기록한다. 이후 SessionStart는 카탈로그에 새 스킬이 추가됐을 때만 다시 안내한다. 사용자가 아무것도 설치하지 않았어도 실행한다.

끝으로 설치·제거·건너뛴 스킬, 연결 확인 결과, 저장한 사용자 규칙 파일, 켠 옵션을 짧게 요약한다. 새로 저장한 접속 정보는 새 세션(Codex는 새 셸)부터 스킬에서 쓰인다고 알린다.
