---
name: harvest
description: 에이전트 활동 기록 기반 하네스 자동 개선. 축적된 이벤트와 사용자 교정 마크를 분석해 프로젝트 하네스(AGENTS.md, docs, workflows) 개선안을 도출하고 PR을 만든다. cosmetic 개선은 걸러내고 에이전트 행동이 실제로 바뀌는 것만 적용. 지난 개선의 기대효과는 다음 실행이 재발 여부로 검증한다.
---

# /harvest — 에이전트 활동 기록 기반 하네스 자동 개선

에이전트 활동 메트릭을 분석해 프로젝트 하네스(.ai-harness, AGENTS.md, settings 등) 개선안을 도출하고 PR까지 만든다.

경로 표기: 아래 `$ROOT` = 이 SKILL.md가 있는 디렉토리의 두 단계 상위(플러그인 루트).

인자: `$ARGUMENTS` — 대상 프로젝트명. `--dry-run` 포함 시 개선안 보고만 하고 파일 수정/PR 안 함.

## 절차

### 1. 데이터 갱신 + 통계

```bash
$ROOT/scripts/backfill.sh
$ROOT/scripts/harvest-queue.sh import --project <프로젝트>
$ROOT/scripts/harvest-queue.sh status --project <프로젝트>
$ROOT/scripts/harvest-queue.sh history --project <프로젝트> | tail -n 20
$ROOT/scripts/stats.sh --days 30 --project <프로젝트>
$ROOT/scripts/stats.sh --days 90 --project <프로젝트>   # 추세 비교용
```

`status`가 `has_analysis_batch:true`일 때만 아래를 실행한다.

```bash
$ROOT/scripts/stats.sh --project <프로젝트> --analysis-batch
$ROOT/scripts/harvest-queue.sh events --project <프로젝트>
```

analysis batch는 개선 판정이 아니라 검토할 입력 묶음이다. batch 통계를 이번 입력의 정량 근거로, 30/90일 통계를 반복성·baseline 판단에 구분해 쓴다. 재개된 동일 세션의 queue 신호 수는 이전 검토 이후 차분이고, event 통계·transcript는 현재 누적 세션이라는 점을 구분한다. 최근 history의 `improved`·`no-change` 결론과 summary를 먼저 확인해 같은 근거·같은 개선을 반복 제안하지 않는다. 아직 기준 미달이어도 사용자가 `/harvest`를 명시 실행했다면 분석은 계속하되 기준 미달임을 결과에 표시한다.

### 2. 이전 개선 결과 검증

history의 `improved` 레코드 중 `review.expected`가 있는 것을 이번 batch 신호·30일 통계와 대조한다. expected는 지난 harvest가 "이 개선이 효과 있다면 다음에 이렇게 보일 것"이라고 남긴 검증 기준이다.

- **충족** (겨냥한 교정/오류 패턴 재발 없음) → 검증 통과. 보고서에 1줄
- **재발** (같은 패턴의 correction_mark/error가 batch에 다시 등장) → 개선 실패. 6단계에서 강화안 또는 revert를 개선안 후보로 승격한다. `review.artifact`의 PR revert가 가장 싼 선택지 — 효과 없는 규칙을 하네스에 남겨 비대화시키지 않는다
- **판정 불가** (해당 신호 미관측이거나 경과 세션이 적음) → 보류, 다음 harvest로 이월

`expected`가 없는 improved 레코드(구버전 기록)는 검증 대상이 아니다. 검증 결과는 통과/재발/보류 모두 최종 보고서에 포함한다.

### 3. 정량 신호 해석

- **doc_read 관측 지원 세션에서 0회 또는 극소** 문서 → 병합/삭제 후보. 지원 세션 0개이거나 미지원 비중이 큰 범위에서는 후보로 올리지 않는다. 신설 문서는 기간 짧으니 제외
- **매 세션 읽히는 문서** → 자동 로드 문서(AGENTS.md 등)로 승격 검토
- **워크플로 사용 순위** → 안 쓰는 워크플로 정리, 자주 쓰는 것 스텝 다듬기
- **guard_block 빈도** → 잦으면 docs 접근성/워크플로 진입 문제
- **error 밀집 세션** → 반복 실패 패턴
- **permission_deny** → allowlist 후보 or deny 강화 후보
- **페르소나 위임 vs 직접 편집 비율** + 토큰 → 위임 가이드 조정 근거

stats의 `수집 범위`를 먼저 확인한다. Codex 등 해당 지표 미지원 세션은 **0회가 아니라 관측 불가**이며, 문서/워크플로/페르소나 삭제 근거의 분모에서 제외한다. 지원 세션 수와 전체 세션 수를 개선안 근거에 함께 쓴다.

### 4. 정독 게이트

transcript 정독(5단계)은 가장 비싼 스텝이다. 진입 전에 batch trigger_counts와 stats의 교정 마크 스니펫(앞 60자)만으로 **정독 가치 / 근거 / focus**를 판단한다. focus는 정독 시작점(어느 세션의 어떤 신호부터 볼지) 한 줄.

- **노이즈 판정** (교정이 전부 1회성 오타 지시, 오류가 일시 환경 문제 등) → 5·6단계를 건너뛰고 판정 근거를 보고한 뒤, dry-run이 아니면 8단계에서 `no-change`로 종료한다. 단 2단계에서 재발이 확인됐으면 게이트와 무관하게 6단계를 진행한다
- **신호 판정** → focus를 들고 5단계 진행

게이트는 transcript 정독 여부만 정한다. 정량 해석·이전 개선 검증·보고는 게이트 결과와 무관하게 항상 수행한다.

### 5. 정성 분석 (correction_mark)

stats의 교정 마크에서 대상 프로젝트 항목을 고른 뒤, 해당 이벤트 파일의 `transcript` 경로로 원본을 열어 **그 교정 전후 맥락만** 정독한다 (전체 정독 금지 — 토큰 낭비). 이벤트 파일은 `~/.ai-harness/events/{claude,codex}-<sid>.jsonl`이며 stats에는 sid 앞 8자만 표시되므로 `events/*<sid8>*.jsonl` glob으로 찾는다.

`[reviewed]`로 표시된 교정 마크는 보관 정책으로 rollup된 과거 검토 완료 데이터다. transcript 경로와 원문이 의도적으로 제거됐으므로 다시 정독하거나 새 개선 근거로 사용하지 않고 baseline 횟수에만 포함한다.

- 반복되는 교정 (같은 실수 2회 이상) → constraint/컨벤션 후보
- 1회성 교정 → 무시

### 6. 개선안 확정

각 개선안: **근거**(수치 or 교정 사례, 세션 id 인용) / **대상 파일** / **변경 내용** / **기대효과**(다음 harvest가 무엇으로 효과를 판정할지 — 이벤트 신호로 확인 가능한 1문장. 예: "X 유형 correction_mark 재발 0").

2단계에서 재발이 확인된 항목은 강화안 또는 revert PR로 여기 포함한다.

근거 없는 "좋아 보이는" 개선 금지. 개선안 0건이면 0건이라고 보고하고 7단계는 건너뛴 뒤, dry-run이 아닐 때 8단계에서 분석 완료를 표시한다.

**가치 기준**: 문서 참조 정리·표현 보강 같은 cosmetic 개선은 PR 가치가 없다 — 보고서에 각주로만 남긴다. PR로 만들 개선안은 **에이전트의 실제 행동이 바뀌는 것**만: 반복 실수를 막는 새 constraint, 토큰/시간 낭비를 줄이는 구조 변경, 반복 삽질의 근본 해결. "이 변경이 없었으면 다음 달에 뭐가 잘못됐나?"에 답 못 하면 탈락.

**라우팅**: 개선안은 가장 작은 아티팩트 단위로 보낸다. 한 신호가 둘 이상에 걸리면 작은 쪽 — AGENTS.md 비대화 방지.

| 신호 패턴 | 대상 |
|---|---|
| 반복 위임 역할 (같은 성격의 하위 작업 위임 반복) | 페르소나 (`.claude/agents/` 등) |
| 반복 절차 (매번 같은 순서의 다단계 작업) | `.ai-harness/workflows/` |
| 불변 사실·환경 지식 (구조, 함정, 접속 방법) | `.ai-harness/docs/` |
| 좁은 행동 정책 (금지/필수 규칙 1~2줄) | AGENTS.md constraint |

`--dry-run`이면 여기서 보고 후 종료. dry-run은 analysis batch를 소비하지 않는다.

### 7. 적용 + PR

1. 대상 프로젝트의 AGENTS.md/CLAUDE.md Preflight 준수
2. 기본 브랜치 최신화 → 프로젝트 브랜치 규칙에 맞는 feature 브랜치 (이슈 필요 시 사용자에게 확인)
3. 개선안 적용 — 프로젝트에 docs 전담 페르소나가 있으면 그 규칙 준수
4. 커밋 → PR, 본문에 근거 수치와 기대효과 포함
5. 병합은 사용자 — PR 링크 보고로 종료

### 8. analysis batch 검토 완료 표시

시작할 때 `has_analysis_batch:true`였고 정상 완료했다면 실제 결론을 포함해 아래 둘 중 하나를 마지막에 실행한다.

```bash
# 행동을 바꾸는 개선 PR을 만들었을 때
$ROOT/scripts/harvest-queue.sh mark-reviewed --project <프로젝트> \
  --outcome improved --summary "<무엇을 왜 바꿨는지 1문장>" --artifact "<PR URL>" \
  --expected "<다음 harvest가 효과를 판정할 기준 1문장>"

# 개선점 0건이거나 통계 참고만 남겼을 때
$ROOT/scripts/harvest-queue.sh mark-reviewed --project <프로젝트> \
  --outcome no-change --summary "<적용하지 않은 핵심 이유 1문장>"
```

`--expected`는 6단계 개선안의 기대효과를 그대로 옮긴다(개선안 여러 건이면 핵심 1건 기준). 이 값이 2단계 검증의 입력이 된다 — 생략하면 이번 개선은 다음 harvest가 검증하지 못한다.

- 개선안 0건이어도 분석을 정상 완료했으면 `mark-reviewed`한다. 같은 데이터가 계속 재알림되는 것을 막기 위함이다.
- `--dry-run`, 분석 실패·중단, PR 생성 실패 때는 처리 완료로 표시하지 않는다.
- `mark-reviewed`는 analysis batch가 만들어질 때 포함된 세션만 옮긴다. 분석 도중 새로 들어온 세션은 다음 묶음에 남는다.
- 검토 완료 시 `review-history.jsonl`에 batch 근거와 실제 결론·요약·PR 참조가 누적되고, 보관 기간이 지난 상세 이벤트는 통계용 rollup으로 자동 전환된다.
