---
name: harness-impact
description: Show what changed after this project adopted the AI harness — track whether each mistake a harvest improvement targeted came back afterwards, show what the edit guard actually blocked and how often the agent lacked project facts, and compare the latest window of real agent sessions with the same number of days just before the install date (repeated user corrections, turns per task, tool errors, optional rework rate) in an offline HTML report; on request, also run a controlled A/B experiment that gives the same task to a real agent in a repository with and without the harness files. Use when the user asks whether the harness helps or what improved since it was installed ("하네스 효과 보여줘", "하네스 도입 전후 비교", "하네스 쓰고 뭐가 나아졌어", "도입 효과 보고서", "harness impact", "before and after the harness", "하네스 없이 돌리면 얼마나 달라?"). Do not use for plain usage, token, or cost reports (that is metrics) or for improving the harness itself (that is harvest).
---

# /harness-impact — 하네스 도입 효과 리포트

설치일 직전 기간과 최근 기간의 실제 세션 기록을 같은 길이로 비교하고, /harvest 가 반영한 개선마다 그 실수가 반영 뒤 다시 나왔는지 따라가 HTML 한 파일로 보여준다. 리포트의 중심은 "하네스가 무엇을 없앴나"의 근거 — 개선별 재발, 막은 위험한 수정의 실제 내용, 프로젝트 사실을 몰라 생긴 문제(`missing_context`) — 이고, 턴·시간·토큰은 모델·작업 크기에 좌우돼 보조 지표로 내린다. 프로젝트 파일·PR에는 조회 전용이다.

경로 표기: 아래 `$ROOT` = 이 SKILL.md가 있는 디렉토리의 두 단계 상위(플러그인 루트).

인자: `$ARGUMENTS`
- `--at YYYY-MM-DD` — 설치일 직접 지정 (기본: `.ai-harness/harness.json`의 `initialized` → `AGENTS.md` 첫 커밋 날짜)
- `--window N` — 비교 구간 일수 (기본 30)
- `rework` — 재작업 PR 비율도 함께 (git 원격 기록을 읽으므로 느릴 수 있다)
- `--ab` — 통제 실험도 함께 (아래 "A/B 실험". 실제 에이전트를 여러 번 돌려 시간·비용이 든다)

## 절차

1. **대상 프로젝트**: 현재 작업 폴더의 저장소. 하네스 프로젝트가 아니거나(`.ai-harness/harness.json` 없음) 폴더가 프로젝트 밖이면 어느 프로젝트를 볼지 사용자에게 묻고 그 경로를 `--root`로 넘긴다.

2. **데이터 갱신 + 비교 JSON**:
```bash
$ROOT/scripts/backfill.sh >/dev/null
OUT="${HARNESS_METRICS_DIR:-$HOME/.ai-harness}/reports/.work"; mkdir -p "$OUT" && echo "$OUT"
$ROOT/scripts/impact.sh compare [--root <dir>] [--at <date>] [--window <N>] >"$OUT/data.json"
```
셸 변수는 다음 호출로 이어지지 않는다. 출력된 `$OUT`의 실제 경로를 기억해 이후 단계(파일 쓰기 도구 포함)에 그대로 쓴다.
`rework` 인자가 있으면 `--author "$(git config user.email)"`를 붙인다(이메일 대신 이름 패턴이 필요하면 사용자에게 묻는다). exit 3은 설치일을 못 찾은 것 — 사용자에게 설치일을 물어 `--at`으로 다시 실행한다.

3. **패턴 맞추기 → 하이라이트 JSON**: 집계 스크립트가 할 수 없는 의미 판단 두 가지를 여기서 한다.
   - **개선별 재발 매칭** (`data.json`의 `improvements[]`): 개선마다 `summary`·`expected`가 겨냥한 실수 유형을 읽고, `before.candidates.items`(근거 batch 세션의 finding)와 `after.candidates.items`(반영 뒤 세션의 finding)에서 **같은 유형**인 것의 `id`를 고른다. 표현이 달라도 같은 실수면 고르고, 비슷한 주제라도 다른 실수면 고르지 않는다. 개수를 세거나 판정하지 않는다 — 세션 단위 집계와 판정(사라짐·줄어듦·재발·판단 보류)은 render가 한다. `candidates.truncated`가 true면 그 쪽 목록이 잘린 것이니 리포트에 `≥`로 나온다.
   - **교정 묶기**: `corrections.before.items`·`corrections.after.items`(각 교정의 `date`·`summary`·`evidence`)를 읽고 같은 내용의 교정을 묶는다. 표현이 달라도 사용자가 고치게 한 내용이 같으면 한 묶음이다.

`<OUT>/highlights.json` (`<OUT>` = 2단계에서 출력된 경로):
```json
{
  "headline": "한 문장",
  "groups": [{"label": "묶음 이름", "before": 3, "after": 0}],
  "cases": [{"title": "사례 한 줄", "detail": "근거 한두 줄"}],
  "improvements": [{"id": "h1", "label": "짧은 패턴 이름", "before": ["<후보 id>"], "after": ["<후보 id>"], "note": "선택: 판정에 덧붙일 한 줄"}]
}
```
- `improvements`: `data.json`의 `improvements[]` 하나당 하나. `id`는 그 항목의 `id`, `before`·`after`는 후보 목록에 있는 `id`만 쓴다(목록에 없는 id는 render가 버린다). 같은 유형이 없으면 빈 배열이다. 빠뜨린 개선은 "판정 안 함"으로 나온다.
- `groups`: 설치 전에 2회 이상 나왔거나 전후 차이가 분명한 묶음만, 차이가 큰 순으로 최대 6개. `before`·`after`는 목록에서 실제로 센 교정 수다. 어림하지 않는다. `truncated`가 true인 쪽은 최근 200건만 본 것이니 그 쪽 수를 `"≥3"`처럼 문자열로 쓴다.
- `cases`: 최대 3개. 개선별 성과 카드·막은 위험과 겹치지 않는 것 — 교정·`missing_context` 목록에서 눈에 띄는 묶음(예: "몰라서 생긴 문제가 dv 검증 환경에 몰려 있음"), 모델 교체처럼 숫자를 읽을 때 알아야 할 맥락 — 을 고른다. 데이터에 없는 사실은 쓰지 않는다.
- `headline`: 데이터가 뒷받침하는 가장 큰 변화 한두 가지를 사용자의 말로. 개선별 판정(사라짐·재발)과 막은 위험이 전후 비교보다 우선한다 — 같은 시기 비교라 모델 영향이 작다. 예: "커버리지 게이트 실수가 반영 뒤 사라졌고, 위험한 수정 3건을 막았어요".
  - `model_shift`가 있으면 턴·시간 차이를 헤드라인에 쓰지 않는다. 모델 교체로 바로 반박된다.
  - 판단 보류·기준 없음인 개선을 성공처럼 쓰지 않는다. 재발은 숨기지 않는다.
  - 토큰 총량이나 절약 시간은 헤드라인에 쓰지 않는다. 하네스는 문서를 읽게 해 토큰을 늘릴 수 있고, 절약 시간은 이 데이터로 잴 수 없다.
  - 나빠진 지표를 숨기지 않는다. 좋아진 것이 없으면 그대로 말한다.
  - `warnings`에 `before_missing`이 있으면 전후 비교 대신 최근 상태를 말한다(예: "최근 작업 16개 모두 하네스 문서를 읽고 시작했어요").
- 교정이 양쪽 다 없으면 `groups`는 빈 배열로 두고 다른 지표로 헤드라인을 쓴다.

리포트 구성(템플릿 고정, 생성 때 외부 스킬을 부르지 않는다): 판정 한 줄 → 핵심 카드 3개(같은 지적·프로젝트 사실을 몰라 생긴 문제·막은 위험) → 개선별 성과 → 막은 위험(가드 종류·도구·대상) → 주간 추이 → 상세(보조 지표 표·교정 목록·자동 규칙·도입 현황) → 신뢰도. 신뢰도 경고는 해당 숫자 옆에도 칩으로 붙는다.
- 개선별 판정: 근거 세션에 그 유형이 없으면 **기준 없음**, 반영 뒤 정리된 세션이 5개 미만이고 재발이 없으면 **판단 보류**(성공으로 세지 않는다), 반영 뒤 0이면 **사라짐**, 발생 비율이 줄면 **줄어듦**, 아니면 **재발**. 반영 시점은 harvest 기록 시각이라 실제 머지보다 이를 수 있다.
- 막은 위험의 사례는 가드 사례를 기록하는 추출기로 뽑은 세션에서만 나온다. 그 전 세션의 차단은 수만 있고, transcript가 남아 있으면 다음 기록 갱신 때 채워진다. 경로는 작업 폴더 기준 상대 경로·`~/`로 줄이고 비밀값은 `scripts/redact.jq`로 가린다.
- `rework`는 머지 뒤 같은 이슈 키로 다시 연 PR이라, 이슈를 단계별 PR로 나누거나 자리표시 키를 쓰는 팀에서는 높게 나온다. 리포트가 경고를 붙인다.

4. **리포트 생성·열기** (A/B 실험을 하기로 했으면 이 단계 전에 아래 "A/B 실험"을 끝내고 `--ab <결과 JSON>`을 붙인다. 설치일을 못 찾아 2단계를 건너뛰었으면 `--data` 없이 `--ab`만으로 만든다):
```bash
REPORT="$($ROOT/scripts/impact.sh render --data "<OUT>/data.json" --highlights "<OUT>/highlights.json" [--ab <ab.json>])"
open "$REPORT" 2>/dev/null || xdg-open "$REPORT" 2>/dev/null || true
```
리포트는 `~/.ai-harness/reports/`에 남는다. 외부 리소스를 불러오지 않는 단일 파일이라 그대로 공유할 수 있다. 다만 교정 요약이 들어 있으니 공유 전에 내용을 확인하라고 알린다.

5. **터미널 요약**: 표를 붙이지 말고 3~5줄로.
   - 한 줄 개요: 프로젝트 · 설치일 · 비교 구간 · 세션 수
   - 헤드라인과 핵심 변화 2~3개 (개선별 판정 먼저, 이전 → 이후)
   - `warnings`가 있으면 한 줄로(아래 표)
   - 리포트 경로

| warning | 뜻 |
|---|---|
| `before_missing` | 설치 전 기록 없음 — transcript 보관 기간(Claude 기본 30일) 뒤 지워졌을 수 있다. 설치 후 추이만 의미 있다 |
| `low_sample` | 한쪽 구간의 작업 세션(턴 5 이상)이 10개 미만 |
| `few_digests` | LLM 세션 정리(`HM_DIGEST`)가 된 세션이 한쪽에 5개 미만 — 교정 비교의 신뢰도가 낮다 |
| `model_shift` | 두 구간의 주 모델이 다름 — 턴·토큰 차이에 모델 영향이 섞인다. 개선별 판정은 같은 시기 비교라 영향이 작다 |
| `gap` | 최근 구간이 설치일보다 뒤에서 시작 — 그 사이는 주간 추이로 본다 |
| `short_window` | 비교 구간이 7일 미만 (설치 직후이거나 `--window`가 짧음) |

## A/B 실험 (`--ab` 또는 "하네스 없이 돌리면 얼마나 달라?" 같은 원인 확인 요청)

같은 과제를 같은 코드 저장소에서 하네스 파일(AGENTS.md·CLAUDE.md·`.ai-harness/docs`)이 있을 때와 없을 때 실제 에이전트로 돌리고, 숨긴 검사로 채점한다. 실제 사용 기록 비교와 달리 작업 종류·모델이 같으므로 차이를 하네스 문서 덕분이라고 말할 수 있다. 과제와 검사는 플러그인에 든 합성 저장소(`$ROOT/evals/ab/`)라 사용자 프로젝트 코드는 쓰지 않는다.

1. Claude Code에서만 돈다(`claude -p`, `python3`, `git` 필요). Codex에서 요청받으면 Claude Code에서 실행하라고 안내하고 멈춘다. 설치일이 없는 프로젝트나 프로젝트 밖에서도 A/B만 따로 할 수 있다.
2. 규모를 먼저 보여주고 **실행 전에 확인을 받는다**. 실제 에이전트 실행이라 구독 사용량·비용을 쓴다.
```bash
$ROOT/scripts/ab.sh estimate [--runs 2]
```
`agent_runs`(케이스 × 2조건 × 회차)와 함께 "회당 수 분, 상한 `--max-cost`(기본 $10)"를 알린다. 모델을 정하지 않았으면 `--model sonnet`을 추천한다.
3. 승인되면 실행한다. 오래 걸리므로 백그라운드로 돌리고 끝나면 결과를 읽는다.
```bash
$ROOT/scripts/ab.sh run --runs 2 --model sonnet --max-cost 10   # 마지막 줄이 결과 JSON 경로
```
4. 결과를 `render --ab`로 리포트에 싣고, 터미널에는 케이스별 **종류별** 통과율(`score_by_kind`: 기본 동작 vs 프로젝트 규칙, 있음 vs 없음)과 하네스 없을 때 놓친 검사 이름을 요약한다. 프로젝트 규칙 점수는 문서로만 알 수 있는 규칙이라 없음 쪽이 낮은 게 당연하다 — 기본 동작 점수가 비슷한지도 함께 말한다. `partial: true`면 비용 상한으로 일부 회차만 돈 것이고, `errors`는 오류로 점수에서 뺀 실행 수다.

한계를 함께 말한다: 검사에는 하네스 문서에만 적힌 프로젝트 규칙이 들어 있어, 이 실험은 "규칙을 문서로 알려주면 지키는가"를 본다. 회차가 적으면 우연이 섞인다. 두 조건 모두 사용자의 전역 설정(CLAUDE.md·플러그인)은 같게 로드된다.

## 원칙

- 이 리포트는 변화를 보여줄 뿐 원인을 증명하지 않는다. 결과를 전할 때 "하네스 덕분"이라고 단정하지 않는다.
- 사용량·토큰·비용만 묻는 요청은 `metrics`, 하네스를 고치는 요청은 `harvest`로 보낸다.
