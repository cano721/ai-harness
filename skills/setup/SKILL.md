---
name: setup
description: ai-harness 설치 후 사용자 전역 셋업. 기본 스킬 카탈로그(datadog·sentry·jira·confluence)에서 고른 것만 ~/.claude/skills·~/.agents/skills에 설치·갱신·제거하고, 필요한 접속 정보가 있는지 점검하며, 선택형 자동화 옵션을 켠다. 플러그인을 처음 설치했을 때, 세션 시작 안내가 셋업을 권할 때, 또는 기본 스킬을 추가·제거하고 싶을 때 쓴다.
---

# /setup — ai-harness 전역 셋업

플러그인 설치만으로는 아무 스킬도 사용자 전역 폴더에 깔지 않는다. 이 Skill이 사용자가 고른 것만 설치한다. 인자: `$ARGUMENTS` (없으면 대화형 셋업, `update`면 4단계만, `status`면 1단계만).

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

표로 보여 준다: 스킬 · 하는 일 · Claude/Codex 상태 · 접속 정보(필수 키 중 빠진 것).

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

## 5. 접속 정보

설치한 스킬마다 `env[]`에서 `required:true`인데 `found:null`인 항목을 모아 보여 준다. 키 **이름**과 넣을 위치만 안내하고, 값은 받지 않는다 — 값을 대화에 붙여 넣으면 대화 기록에 남는다.

- Claude Code: `~/.claude/settings.json`의 `env` 객체에 `"KEY": "값"`을 추가하고 새 세션을 연다.
- Codex: 셸 프로파일(`~/.zshrc` 등)에 `export KEY="값"`을 추가하고 새 셸에서 Codex를 연다.
- 키를 발급받는 곳은 각 스킬 SKILL.md의 "인증" 절에 있다.

값을 출력하거나 `echo $KEY`로 확인하지 않는다. 확인은 다시 `setup.sh list`의 `found`·`source`로만 한다.

## 6. 자동화 옵션 (선택)

`~/.ai-harness/config`를 Read해 현재 값을 보여 주고, 켤 것을 고르게 한다. 고른 것만 `KEY=VALUE` 줄로 추가하거나 기존 줄을 고친다. 아무것도 고르지 않으면 파일을 건드리지 않는다.

| 키 | 기본 | 켜면 |
|---|---|---|
| `HM_DIGEST` | `0` | 하루 한 번 최근 세션을 저비용 모델로 정리해 사용자 교정·마찰을 harvest 근거로 남긴다 (LLM 비용 발생) |
| `HM_HARVEST_AUTO` | `0` | analysis batch가 생기면 `/harvest --auto`를 백그라운드로 돌려 draft PR까지 만든다 |
| `HM_SYNC_AUTO` | `0` | 하네스가 플러그인보다 뒤처진 저장소에 `/harness-init --sync`를 백그라운드로 돌려 draft PR을 만든다 |
| `HM_DB_SCAN_GUARD` | `0` | 스키마 조건 없는 information_schema 조회를 Bash 실행 전에 막는다 |

자세한 동작은 README의 해당 절을 가리킨다. 백그라운드 실행 옵션은 병합을 하지 않고 draft PR까지만 한다는 점을 함께 알린다.

## 7. 마무리

```bash
$ROOT/scripts/setup.sh done
```

셋업을 마쳤다고 기록한다. 이후 SessionStart는 카탈로그에 새 스킬이 추가됐을 때만 다시 안내한다. 사용자가 아무것도 설치하지 않았어도 실행한다.

끝으로 설치·제거·건너뛴 스킬, 빠진 접속 정보, 켠 옵션을 짧게 요약한다.
