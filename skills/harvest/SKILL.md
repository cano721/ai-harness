---
name: harvest
description: 에이전트 활동 기록 기반 하네스 자동 개선. 축적된 이벤트와 사용자 교정 마크를 분석해 프로젝트 하네스(AGENTS.md, docs, workflows) 개선안을 도출하고 PR을 만든다. cosmetic 개선은 걸러내고 에이전트 행동이 실제로 바뀌는 것만 적용.
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

### 2. 정량 신호 해석

- **doc_read 관측 지원 세션에서 0회 또는 극소** 문서 → 병합/삭제 후보. 지원 세션 0개이거나 미지원 비중이 큰 범위에서는 후보로 올리지 않는다. 신설 문서는 기간 짧으니 제외
- **매 세션 읽히는 문서** → 자동 로드 문서(AGENTS.md 등)로 승격 검토
- **워크플로 사용 순위** → 안 쓰는 워크플로 정리, 자주 쓰는 것 스텝 다듬기
- **guard_block 빈도** → 잦으면 docs 접근성/워크플로 진입 문제
- **error 밀집 세션** → 반복 실패 패턴
- **permission_deny** → allowlist 후보 or deny 강화 후보
- **페르소나 위임 vs 직접 편집 비율** + 토큰 → 위임 가이드 조정 근거

stats의 `수집 범위`를 먼저 확인한다. Codex 등 해당 지표 미지원 세션은 **0회가 아니라 관측 불가**이며, 문서/워크플로/페르소나 삭제 근거의 분모에서 제외한다. 지원 세션 수와 전체 세션 수를 개선안 근거에 함께 쓴다.

### 3. 정성 분석 (correction_mark)

stats의 교정 마크에서 대상 프로젝트 항목을 고른 뒤, 해당 이벤트 파일의 `transcript` 경로로 원본을 열어 **그 교정 전후 맥락만** 정독한다 (전체 정독 금지 — 토큰 낭비). 이벤트 파일은 `~/.ai-harness/events/{claude,codex}-<sid>.jsonl`이며 stats에는 sid 앞 8자만 표시되므로 `events/*<sid8>*.jsonl` glob으로 찾는다.

`[reviewed]`로 표시된 교정 마크는 보관 정책으로 rollup된 과거 검토 완료 데이터다. transcript 경로와 원문이 의도적으로 제거됐으므로 다시 정독하거나 새 개선 근거로 사용하지 않고 baseline 횟수에만 포함한다.

- 반복되는 교정 (같은 실수 2회 이상) → constraint/컨벤션 후보
- 1회성 교정 → 무시

### 4. 개선안 확정

각 개선안: **근거**(수치 or 교정 사례, 세션 id 인용) / **대상 파일** / **변경 내용**.

근거 없는 "좋아 보이는" 개선 금지. 개선안 0건이면 0건이라고 보고하고 5단계는 건너뛴 뒤, dry-run이 아닐 때 6단계에서 분석 완료를 표시한다.

**가치 기준**: 문서 참조 정리·표현 보강 같은 cosmetic 개선은 PR 가치가 없다 — 보고서에 각주로만 남긴다. PR로 만들 개선안은 **에이전트의 실제 행동이 바뀌는 것**만: 반복 실수를 막는 새 constraint, 토큰/시간 낭비를 줄이는 구조 변경, 반복 삽질의 근본 해결. "이 변경이 없었으면 다음 달에 뭐가 잘못됐나?"에 답 못 하면 탈락.

`--dry-run`이면 여기서 보고 후 종료. dry-run은 analysis batch를 소비하지 않는다.

### 5. 적용 + PR

1. 대상 프로젝트의 AGENTS.md/CLAUDE.md Preflight 준수
2. 기본 브랜치 최신화 → 프로젝트 브랜치 규칙에 맞는 feature 브랜치 (이슈 필요 시 사용자에게 확인)
3. 개선안 적용 — 프로젝트에 docs 전담 페르소나가 있으면 그 규칙 준수
4. 커밋 → PR, 본문에 근거 수치 포함
5. 병합은 사용자 — PR 링크 보고로 종료

### 6. analysis batch 검토 완료 표시

시작할 때 `has_analysis_batch:true`였고 정상 완료했다면 실제 결론을 포함해 아래 둘 중 하나를 마지막에 실행한다.

```bash
# 행동을 바꾸는 개선 PR을 만들었을 때
$ROOT/scripts/harvest-queue.sh mark-reviewed --project <프로젝트> \
  --outcome improved --summary "<무엇을 왜 바꿨는지 1문장>" --artifact "<PR URL>"

# 개선점 0건이거나 통계 참고만 남겼을 때
$ROOT/scripts/harvest-queue.sh mark-reviewed --project <프로젝트> \
  --outcome no-change --summary "<적용하지 않은 핵심 이유 1문장>"
```

- 개선안 0건이어도 분석을 정상 완료했으면 `mark-reviewed`한다. 같은 데이터가 계속 재알림되는 것을 막기 위함이다.
- `--dry-run`, 분석 실패·중단, PR 생성 실패 때는 처리 완료로 표시하지 않는다.
- `mark-reviewed`는 analysis batch가 만들어질 때 포함된 세션만 옮긴다. 분석 도중 새로 들어온 세션은 다음 묶음에 남는다.
- 검토 완료 시 `review-history.jsonl`에 batch 근거와 실제 결론·요약·PR 참조가 누적되고, 보관 기간이 지난 상세 이벤트는 통계용 rollup으로 자동 전환된다.
