---
name: metrics
description: 에이전트 사용량 리포트. 전체 집계(기간·프로젝트별 세션·토큰, 워크플로 순위, docs 읽힘, 페르소나 위임, 에러/가드 신호) 또는 세션 1개 정밀 리포트(session 모드). 조회 전용.
---

# /metrics — 에이전트 사용량 리포트

`~/.ai-harness/` 데이터를 집계해 리포트를 출력한다. 프로젝트 파일·PR에는 조회 전용이며, 로컬 event cache와 harvest 대기 상태는 최신 transcript/extractor 기준으로 갱신한다 (개선 작업은 `/harvest`).

경로 표기: 아래 `$ROOT` = 이 SKILL.md가 있는 디렉토리의 두 단계 상위(플러그인 루트).

인자: `$ARGUMENTS`
- 기간: `7d` / `30d` / `90d` / `all` (기본 `30d`)
- 프로젝트명 (예: `my-service`) — 지정 시 해당 프로젝트만
- **`session [sid앞부분]`** — 세션 1개 정밀 모드 (아래 "session 모드"). sid 생략 시 현재 세션
- 예: `/metrics 7d my-service`, `/metrics all`, `/metrics session`, `/metrics session a7e2fc6f`

## session 모드 (첫 인자가 `session`일 때)

1. `$ROOT/scripts/session.sh [sid|latest]` 실행 — sid 미지정이면 `latest`. 스크립트가 Codex `CODEX_THREAD_ID` 또는 Claude session ID를 우선하고, 없을 때만 현재 프로젝트의 최신 transcript를 선택한다
2. 표를 그대로 붙이지 말고 요약: 한 줄 개요(턴·토큰·서브에이전트 토큰·주 활동) → 눈에 띄는 포인트 2~3개 (토큰 비대 원인, 컨텍스트 최대치와 그것을 채운 툴 결과·docs 상위, docs/워크플로 경유 vs 직접 편집, error·guard_block 지점). 컨텍스트 수치는 transcript의 호출별 usage와 결과 크기(UTF-8 바이트/4)로 낸 추정이며, 시스템 프롬프트·툴 정의 같은 항목별 내역은 transcript에 없어 `/context`로만 볼 수 있음을 필요하면 밝힌다
3. 진행 중 세션이면 "현재까지" 기준임을 명시

## 절차 (전체 집계 모드)

1. 데이터 갱신 + 집계:
```bash
$ROOT/scripts/backfill.sh
$ROOT/scripts/health.sh status
$ROOT/scripts/stats.sh --days <N> [--project <P>]
```
`all`이면 `--days` 생략. 추세 언급을 위해 직전 동일 기간과 비교하고 싶으면 `--days 2N` 결과와 차분.

프로젝트가 지정됐으면 과거 event cache도 누적량 판정에 포함하고 준비 상태를 확인한다.

```bash
$ROOT/scripts/harvest-queue.sh import --project <P>
$ROOT/scripts/harvest-queue.sh status --project <P>
$ROOT/scripts/harvest-queue.sh history --project <P>
```

`has_analysis_batch:true`이면 리포트 마지막에 묶음 생성 사유와 세션·교정·오류·차단·권한 거부 수를 요약하고 `/harvest <P>`를 안내한다. metrics에서는 `mark-reviewed`하지 않는다.

history가 있으면 `review.outcome`별 `improved`/`no-change` 횟수와 최근 summary·artifact를 짧게 보여준다. 이는 분석 묶음 수가 아니라 실제 개선 산출률이며, outcome이 없는 legacy `reviewed` 항목은 별도로 표시한다.

`health.sh status`에서 최근 `last_result`가 failure인 구성요소가 있으면 해당 시각·오류와 함께 수집 건강 경고를 표시한다. 이벤트 상세가 보관 정책으로 정리된 기간은 `rollups/` 통계가 자동 포함되며, 교정 원문은 이미 검토 완료되어 `[reviewed]`로 비식별화됐음을 명시한다.

프로젝트가 지정됐고 그 프로젝트 경로를 알면(cwd 등) **0회 문서 산출**: 해당 프로젝트 `.ai-harness/docs/**/*.md` 파일 목록과 stats의 doc_read 목록을 차집합. 단, stats의 `수집 범위`에서 `doc_read` 지원 세션만 분모로 사용하고, 지원 세션이 0개면 0회/죽은 문서 판정을 하지 않는다. 경로를 모르면 "최저 읽힘"까지만 언급.

**재작업 비율** (사용자가 재작업·후속 PR 비율을 물었거나 인자에 `rework`가 있을 때만): 이벤트 데이터가 아니라 git 머지 기록으로 잰다. 대상 저장소 경로를 모르면 사용자에게 묻는다.

```bash
$ROOT/scripts/rework.sh --repo <저장소> [--repo <저장소>]... --author <이메일 또는 이름 패턴> \
  --since <YYYY-MM-DD> --until <YYYY-MM-DD> [--window 7] [--exclude-key <설정용 키>]
```

정의: 기간 안에 머지된 PR(작성자 커밋 포함) 중, 머지 뒤 window일 안에 **같은 이슈 키로 새 PR 작업이 시작된** 비율. 시작 시각은 후속 PR이 들여온 가장 이른 커밋이라 원본 머지 전에 시작한 분할 PR은 세지 않는다. window가 아직 끝나지 않은 PR은 `pending_prs`로 분모에서 빠진다 — 이번 주 값이 비어 보이면 기간을 window만큼 앞당겨 다시 잰다. 원격 브랜치(`git fetch`)만 보므로 먼저 fetch하고, 머지되지 않은 후속 PR은 세지 못한다(과소 추정)는 점을 함께 쓴다.

2. 원본 표를 그대로 붙이지 말고 **요약**해서 출력:

```
## 사용량 리포트 (<기간>, <범위>)

**한 줄 요약**: 세션 N개 · 턴 N · in/out 토큰 N/N (cache hit ~N%) · 서브에이전트 in/out N/N · source별 관측 범위

**어디에 썼나**: 프로젝트 상위 2~3개 + 세션/토큰 비중
**비율**: 워크플로 경유 세션 %(하네스 프로젝트 활성 세션 기준) — stats `## 비율` 값을 분자/분모와 함께 그대로 옮긴다. 낮은 프로젝트 1~2개만 짚는다. 재작업 비율을 쟀으면 `rework_prs/settled_prs`(pending 수)와 저장소별 상위만 덧붙인다
**뭘로 썼나**: 워크플로/커맨드 상위 3~5 + 페르소나 위임 상위 3
**docs 활용**: 최다 읽힘 2~3개 / 관측 지원 세션 기준 0회 문서 명단. 미지원은 0회로 쓰지 않음
**컨텍스트**: 프로젝트별 첫 호출(≈고정 오버헤드)·최대 중앙값 — 높은 프로젝트만 짚는다. docs 컨텍스트 비용 상위(1회당 크기가 큰 문서는 분할 후보), 툴 결과 크기 상위 2~3
**신호**: error·guard_block·permission_deny·compact 합계 — 눈에 띄는 것만 코멘트
**Jira**: 언급 상위 3 이슈
```

3. 마지막에 눈에 띄는 포인트 1~3개만 짚는다 (예: "docs X 30일째 0회", "error 급증"). 근거 수치 없이 해석하지 않는다. 개선까지 원하면 `/harvest` 안내.
