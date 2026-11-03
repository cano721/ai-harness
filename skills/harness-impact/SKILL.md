---
name: harness-impact
description: Show what changed after this project adopted the AI harness — compare the latest window of real agent sessions with the same number of days just before the install date (repeated user corrections, risky edits the harness blocked, turns per task, tool errors, optional rework rate, the rules the harness learned) and open it as an offline HTML report. Use when the user asks whether the harness helps or what improved since it was installed ("하네스 효과 보여줘", "하네스 도입 전후 비교", "하네스 쓰고 뭐가 나아졌어", "도입 효과 보고서", "harness impact", "before and after the harness"). Do not use for plain usage, token, or cost reports (that is metrics) or for improving the harness itself (that is harvest).
---

# /harness-impact — 하네스 도입 효과 리포트

설치일 직전 기간과 최근 기간의 실제 세션 기록을 같은 길이로 비교해, 사용자가 체감하는 변화(같은 지적을 다시 하게 된 횟수, 하네스가 막은 위험, 작업당 턴, 오류)를 HTML 한 파일로 보여준다. 프로젝트 파일·PR에는 조회 전용이다.

경로 표기: 아래 `$ROOT` = 이 SKILL.md가 있는 디렉토리의 두 단계 상위(플러그인 루트).

인자: `$ARGUMENTS`
- `--at YYYY-MM-DD` — 설치일 직접 지정 (기본: `.ai-harness/harness.json`의 `initialized` → `AGENTS.md` 첫 커밋 날짜)
- `--window N` — 비교 구간 일수 (기본 30)
- `rework` — 재작업 PR 비율도 함께 (git 원격 기록을 읽으므로 느릴 수 있다)

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

3. **교정 묶기 → 하이라이트 JSON**: `data.json`의 `corrections.before.items`·`corrections.after.items`(각 교정의 `date`·`summary`·`evidence`)를 읽고 같은 내용의 교정을 묶는다. 표현이 달라도 사용자가 고치게 한 내용이 같으면 한 묶음이다. 이것은 집계 스크립트가 할 수 없는 판단이라 여기서 한다.

`<OUT>/highlights.json` (`<OUT>` = 2단계에서 출력된 경로):
```json
{
  "headline": "한 문장",
  "groups": [{"label": "묶음 이름", "before": 3, "after": 0}],
  "cases": [{"title": "사례 한 줄", "detail": "근거 한두 줄"}]
}
```
- `groups`: 설치 전에 2회 이상 나왔거나 전후 차이가 분명한 묶음만, 차이가 큰 순으로 최대 6개. `before`·`after`는 목록에서 실제로 센 교정 수다. 어림하지 않는다. `truncated`가 true인 쪽은 최근 200건만 본 것이니 그 쪽 수를 `"≥3"`처럼 문자열로 쓴다.
- `cases`: 최대 3개. `timeline`(harvest가 반영한 개선, 자동 적용 규칙)과 교정에서 "하네스가 바뀐 뒤 그 실수가 줄었다"를 보여주는 것을 고른다. 데이터에 없는 사실은 쓰지 않는다.
- `headline`: 데이터가 뒷받침하는 가장 큰 변화 한두 가지를 사용자의 말로. 예: "같은 지적 5건이 사라졌고, 위험한 수정 3건을 막았어요".
  - 토큰 총량이나 절약 시간은 헤드라인에 쓰지 않는다. 하네스는 문서를 읽게 해 토큰을 늘릴 수 있고, 절약 시간은 이 데이터로 잴 수 없다.
  - 나빠진 지표를 숨기지 않는다. 좋아진 것이 없으면 그대로 말한다.
  - `warnings`에 `before_missing`이 있으면 전후 비교 대신 최근 상태를 말한다(예: "최근 작업 16개 모두 하네스 문서를 읽고 시작했어요").
- 교정이 양쪽 다 없으면 `groups`는 빈 배열로 두고 다른 지표로 헤드라인을 쓴다.

4. **리포트 생성·열기**:
```bash
REPORT="$($ROOT/scripts/impact.sh render --data "<OUT>/data.json" --highlights "<OUT>/highlights.json")"
open "$REPORT" 2>/dev/null || xdg-open "$REPORT" 2>/dev/null || true
```
리포트는 `~/.ai-harness/reports/`에 남는다. 외부 리소스를 불러오지 않는 단일 파일이라 그대로 공유할 수 있다. 다만 교정 요약이 들어 있으니 공유 전에 내용을 확인하라고 알린다.

5. **터미널 요약**: 표를 붙이지 말고 3~5줄로.
   - 한 줄 개요: 프로젝트 · 설치일 · 비교 구간 · 세션 수
   - 헤드라인과 핵심 변화 2~3개 (이전 → 이후)
   - `warnings`가 있으면 한 줄로(아래 표)
   - 리포트 경로

| warning | 뜻 |
|---|---|
| `before_missing` | 설치 전 기록 없음 — transcript 보관 기간(Claude 기본 30일) 뒤 지워졌을 수 있다. 설치 후 추이만 의미 있다 |
| `low_sample` | 한쪽 구간의 작업 세션(턴 5 이상)이 10개 미만 |
| `few_digests` | LLM 세션 정리(`HM_DIGEST`)가 된 세션이 한쪽에 5개 미만 — 교정 비교의 신뢰도가 낮다 |
| `model_shift` | 두 구간의 주 모델이 다름 — 턴·토큰 차이에 모델 영향이 섞인다 |
| `gap` | 최근 구간이 설치일보다 뒤에서 시작 — 그 사이는 주간 추이로 본다 |
| `short_window` | 비교 구간이 7일 미만 (설치 직후이거나 `--window`가 짧음) |

## 원칙

- 이 리포트는 변화를 보여줄 뿐 원인을 증명하지 않는다. 결과를 전할 때 "하네스 덕분"이라고 단정하지 않는다.
- 같은 과제를 하네스 유무로 돌려 원인을 확인하는 A/B 실험은 아직 이 스킬에 없다. 사용자가 원인 검증을 원하면 그렇게 말한다.
- 사용량·토큰·비용만 묻는 요청은 `metrics`, 하네스를 고치는 요청은 `harvest`로 보낸다.
