---
name: setup
description: ai-harness 설치 후 사용자 전역 셋업. 기본 스킬 카탈로그(datadog·sentry·jira·confluence)에서 고른 것만 ~/.claude/skills·~/.agents/skills에 설치·갱신·제거하고, 토큰 발급을 안내해 대화에 남기지 않고 저장한 뒤 연결을 확인하며, 회사·팀 전용 값(기본 프로젝트·필드 ID·생성 규칙)을 사용자 규칙 파일로 남기고, 선택형 자동화 옵션을 켠다. 플러그인을 처음 설치했을 때, 세션 시작 안내가 셋업을 권할 때, 또는 기본 스킬을 추가·제거하고 싶을 때 쓴다.
---

# /setup — ai-harness 전역 셋업

플러그인 설치만으로는 아무 스킬도 사용자 전역 폴더에 깔지 않는다. 이 Skill이 사용자가 고른 것만 설치한다. 인자: `$ARGUMENTS` (없으면 대화형 셋업, `update`면 4단계만, `status`면 1단계와 6단계(연결 확인)만, `<스킬 이름>`이면 그 스킬의 5~7단계만).

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

## 2. 고르기

다음을 묻는다. 질문 도구가 있으면 그것으로, 없으면 번호 목록으로 묻는다.

1. **설치할 스킬** (여러 개 선택). 이미 `current`인 것은 기본 선택, `foreign`은 "이미 직접 만든 스킬 있음 — 유지 권장"으로 표시한다.
2. **도구**: 지금 세션의 도구를 기본값으로 — Claude Code면 `claude`, Codex면 `codex`. 둘 다 쓰면 `both`.
3. 선택에서 빠진 `current`/`outdated` 스킬이 있으면 제거할지 따로 확인한다. 묻지 않고 지우지 않는다.

## 3. 설치·제거

```bash
$ROOT/scripts/setup.sh install --tool <claude|codex|both> <name>...
$ROOT/scripts/setup.sh remove --tool <claude|codex|both> <name>...
```

결과는 항목별 `action`이다: `installed`·`updated`·`unchanged`·`removed`·`skipped`(`detail`이 `foreign`/`modified`).

- `skipped foreign`: 사용자가 원래 갖고 있던 스킬이라 그대로 뒀다고 알린다. 사용자가 **교체를 명시**했을 때만 `install --replace`로 다시 실행한다 — 기존 폴더는 지우지 않고 `~/.ai-harness/setup/backups/`로 옮겨지며, 결과 `detail`에 그 경로가 나온다.
- `skipped modified`: 사용자가 고친 사본이다. 덮어쓰기는 같은 방식(`--replace`, 백업 후 교체)으로 사용자가 원할 때만 한다.
- 새로 깐 스킬은 다음 세션부터 로드된다고 알린다.

## 4. 갱신 (`update`)

손대지 않은(`outdated`) 관리 사본은 SessionStart가 자동으로 최신화하고 알린다. 지금 바로 하려면:

```bash
$ROOT/scripts/setup.sh update
```

`modified` 사본은 갱신하지 않는다. 사용자가 원하면 카탈로그 원본(`$ROOT/catalog/<name>/SKILL.md`)과 diff를 보여 주고, 합칠지 `--replace`로 교체할지 묻는다.

## 5. 접속 정보 — 발급·저장·연결 확인

설치한 스킬마다 `list`의 `env[]`를 본다. `found:null`이고 `required:true`인 키를 하나씩 처리한다. 이미 있는 키도 6단계 연결 확인에서 실패하면 같은 절차로 다시 넣는다.

1. **발급 안내** — `issue.url`(있으면 링크), `issue.steps`, `issue.scopes`를 그대로 보여 준다. scope가 있으면 "읽기 전용 scope만 고르세요"를 덧붙인다. 같은 키를 쓰는 스킬이 여럿이면(jira·confluence의 `ATLASSIAN_*`) 한 번만 묻는다.
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

## 6. 연결 확인

```bash
$ROOT/scripts/setup.sh check <name>
```

읽기 전용 호출 하나로 자격 증명을 확인한다(Datadog `/api/v1/validate`+현재 사용자, Jira `/myself`, Confluence 현재 사용자, Sentry 조직 조회). 방금 저장한 값은 이 세션 환경에 아직 없으므로 스크립트가 settings.json·secrets.env에서 직접 읽는다.

- `ok:true` — `as`(누구로 접속했는지)를 보여 준다. 다른 계정이면 사용자에게 확인한다.
- `ok:false` — `error`와 `hint`를 보여 주고 5단계로 돌아가 해당 키를 다시 넣는다. 두 번 실패하면 멈추고 사용자에게 넘긴다.
- `missing` — 5단계를 건너뛴 키다.

## 7. 사용자 규칙 (회사·팀 전용 값)

카탈로그 스킬 본문은 범용이다. 회사·팀마다 다른 값은 스킬 파일이 아니라 `list`의 `profile.path`(`~/.ai-harness/skills/<name>.md`)에 적는다 — 스킬 본문을 고치면 그 사본은 `modified`가 되어 자동 갱신이 멈춘다. 카탈로그 스킬은 호출 전에 이 파일을 먼저 읽는다.

1. 연결 확인이 된 스킬은 선택지를 계정에서 읽어 온다:
   ```bash
   $ROOT/scripts/setup.sh detect <name>
   ```
   Jira는 스프린트·에픽 링크 필드 ID(이름이 아니라 타입으로 찾으므로 언어 설정과 무관)와 최근 프로젝트, Confluence는 스페이스, Datadog은 최근 24시간 에러가 많은 서비스, Sentry는 프로젝트 목록을 준다.
2. `profile.questions`를 순서대로 묻는다. `detect` 결과가 있는 질문은 선택지로 보여 준다. 필드 ID처럼 자동으로 확정되는 값은 묻지 않고 적는다. 모르는 항목은 비워 둔다.
3. 같은 이름의 개인 스킬이 `foreign`으로 남아 있으면, 그 SKILL.md를 Read해 회사 전용 값(사이트 주소·필수 필드·커스텀 필드 ID·팀 관례)을 뽑아 초안으로 제안한다. 뽑은 필드 ID가 `detect` 결과와 다르면 `detect` 값을 쓰고 차이를 알린다.
4. 사용자가 확인한 내용만 Write로 저장한다. 이미 파일이 있으면 Read해 바뀐 줄만 고친다. 형식:
   ```markdown
   # jira 사용자 규칙
   <!-- /ai-harness:setup이 만든 파일. 직접 고쳐도 되고, 다시 setup하면 이 내용을 바탕으로 묻는다. -->

   - 기본 프로젝트: NJ
   - 필드: 스프린트 `customfield_10113`, 에픽 링크 `customfield_10006`
   - 이슈 생성: 상위 에픽·활성 스프린트·수정 버전을 반드시 채운다. 모르면 후보를 조회해 추천하고 확인받는다.
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
| `HM_DB_SCAN_GUARD` | `0` | 스키마 조건 없는 information_schema 조회를 Bash 실행 전에 막는다 |

자세한 동작은 README의 해당 절을 가리킨다. 백그라운드 실행 옵션은 병합을 하지 않고 draft PR까지만 한다는 점을 함께 알린다.

## 9. 마무리

```bash
$ROOT/scripts/setup.sh done
```

셋업을 마쳤다고 기록한다. 이후 SessionStart는 카탈로그에 새 스킬이 추가됐을 때만 다시 안내한다. 사용자가 아무것도 설치하지 않았어도 실행한다.

끝으로 설치·제거·건너뛴 스킬, 연결 확인 결과, 저장한 사용자 규칙 파일, 켠 옵션을 짧게 요약한다. 새로 저장한 접속 정보는 새 세션(Codex는 새 셸)부터 스킬에서 쓰인다고 알린다.
