---
name: langfuse
description: Langfuse(클라우드·self-hosted)의 trace·observation·비용·지연·프롬프트·점수·데이터셋·평가기·주석 큐·대시보드를 조회하고, 확인을 받아 관리한다. LLM 호출 실패 원인 분석, 기능·모델별 비용 집계, 프롬프트 버전·label 확인, 평가 결과 확인에 쓴다. 여러 Langfuse 프로젝트를 별칭으로 등록해 오간다. 공식 MCP 도구를 MCP 서버 등록 없이 스크립트로 호출한다.
---

# Langfuse

Langfuse 가 제공하는 공식 MCP 도구(`/api/public/mcp`, 약 95개)를 `scripts/lf.py` 로 HTTP 호출한다. MCP 서버를 등록하지 않으므로 도구 정의가 컨텍스트를 차지하지 않고, 도구 계약은 Langfuse 가 관리한다. MCP 에 없는 것만 공개 REST(`lf.py rest`)로 부른다.

## 사용자 규칙 (먼저 읽기)

`${HARNESS_METRICS_DIR:-$HOME/.ai-harness}/skills/langfuse.md`가 있으면 호출 전에 Read하고 따른다. `/ai-harness:setup`이 회사·팀 전용 값(프로젝트 별칭과 용도, 환경 이름, 프롬프트 label 관례, 개인정보 규칙)을 적어 두는 파일이다. 이 본문과 다르면 그 파일이 이긴다 — 단 자격 증명을 다루는 방식과 쓰기 전 확인 규칙은 이 본문을 따른다. 파일이 없으면 이 본문의 일반 규칙대로 하고, 매번 같은 값을 묻게 되면 `/ai-harness:setup`으로 저장하자고 한 번 제안한다.

## 인증 — 키는 프로젝트 단위

Langfuse API 키는 **개인 키가 아니라 프로젝트 키**다(조직 키는 관리용이라 trace 를 못 읽는다). 프로젝트마다 키 한 쌍을 별칭으로 등록한다.

| 환경변수 | 설명 |
|---|---|
| `LANGFUSE_PUBLIC_KEY[_<별칭>]` | `pk-lf-…` |
| `LANGFUSE_SECRET_KEY[_<별칭>]` | `sk-lf-…` |
| `LANGFUSE_HOST[_<별칭>]` | 기본 `https://cloud.langfuse.com`(EU). US `https://us.cloud.langfuse.com`, JP `https://jp.cloud.langfuse.com`, self-hosted 주소 |

- 별칭 → 접미사: 대문자 + `-`→`_` (`checkout-bot` → `_CHECKOUT_BOT`). 별칭 없음 = 접미사 없는 기본 키.
- `lf.py` 는 프로세스 환경 → `~/.claude/settings.json` 의 `env` → `${HARNESS_METRICS_DIR:-~/.ai-harness}/secrets.env` 순서로 읽는다. 방금 등록한 키도 세션 재시작 없이 쓴다.
- 별칭을 줬는데 키가 없으면 기본 키로 대신하지 않고 멈춘다 — 다른 프로젝트 데이터를 그 프로젝트 것으로 오인하지 않기 위해서다.
- 기본 키(접미사 없음)는 `/ai-harness:setup`(Codex는 ai-harness setup 스킬)이 발급 안내·저장·연결 확인까지 한다. 키가 없거나 401이면 그쪽으로 안내한다.
- **키를 대화에 붙여 넣게 하지 않는다.** 프로젝트를 더할 때(별칭)는 클립보드 단계로 등록한다(키 값은 대화·출력·명령 인자에 남지 않음):
  1. 사용자가 Langfuse → 프로젝트 → Settings → API Keys 에서 Public key 를 복사 → `python3 -I scripts/register.py <별칭> --stage pk`
  2. Secret key 복사 → `python3 -I scripts/register.py <별칭> --stage sk`
  3. `python3 -I scripts/register.py <별칭>` — 리전을 차례로 호출해 맞는 host 를 찾고, 키가 가리키는 프로젝트 이름을 보여 준 뒤 저장한다.
  - macOS 에서 단계 없이 `register.py <별칭>` 만 실행하면 가려진 입력 창 두 개로 받는다.
- 키 생성 버튼이 안 보이면 그 프로젝트에 키 생성 권한이 없는 것이다 — 프로젝트 owner/admin 에게 조회용 키를 따로 발급받게 안내한다(서비스가 쓰는 키와 분리하면 폐기가 쉽다).

## 도구

스크립트 경로는 이 SKILL.md 옆 `scripts/`. 아래 `lf` 는 `python3 -I <skill-dir>/scripts/lf.py` 를 뜻한다.

```bash
lf aliases                              # 등록된 별칭
lf -p <별칭> whoami                     # host·프로젝트 확인 (401 이면 키/리전 불일치)
lf -p <별칭> tools [검색어]             # MCP 도구 목록 + 위험 등급(read / write / destructive)
lf -p <별칭> schema <도구>              # 입력 스키마 — 처음 쓰는 도구는 반드시 먼저 본다
lf -p <별칭> call <도구> '<JSON 인자>'  # 호출
lf -p <별칭> rest GET <경로> k=v …     # 공개 REST (MCP 에 없는 것만)
```

- 출력의 문자열 값은 기본 500자에서 잘린다(`--max-str N`, 0 = 끄기). 프롬프트 원문처럼 전체가 필요할 때만 늘린다.
- 도구 목록은 host 별로 하루 캐시된다. 도구를 못 찾으면 `tools --refresh`.

### 쓰기 안전장치 (스크립트가 강제)

위험 등급은 Langfuse 가 도구에 붙인 annotation 을 그대로 쓴다.

| 등급 | 동작 |
|---|---|
| `read` | 바로 실행 |
| `write` (생성·실행·비용 발생 포함) | `--yes` 없으면 차단. 무엇을 바꾸는지 한 줄로 보여 주고 사용자 확인 뒤에만 `--yes` |
| `destructive` (삭제·덮어쓰기, `createScore` 처럼 Langfuse 가 파괴적으로 분류한 것 포함) | `--allow-destructive` 없으면 차단. 사용자가 그 작업을 명시적으로 요청했을 때만 대상을 확인받고 붙인다 |

`rest` 는 GET 만 바로 되고, POST·PATCH·PUT 은 `--yes` 필요, DELETE 는 막혀 있다(삭제는 MCP 도구로).

## 공통 규칙

- **시간 범위는 거의 모든 조회에 필수**다(`fromStartTime`/`toStartTime` 또는 `fromTimestamp`/`toTimestamp`, ISO 8601 UTC). 기본 최근 1시간: `date -u -v-1H +%Y-%m-%dT%H:%M:%SZ`(macOS) / `date -u -d '-1 hour' +%Y-%m-%dT%H:%M:%SZ`(GNU).
- trace 는 별도 단위가 아니다 — **observation 이 기본 단위**. trace 목록 = `isRootObservation: true` 인 observation, trace 상세 = `traceId` 로 observation 전부. 응답의 `url` 이 Langfuse 화면 링크다.
- `listObservations` 의 `limit` 최대 100, `input`/`output` 을 고르면 50. `fields` 를 안 주면 간단한 기본 필드만 온다(`getObservationFieldSchema` 에 전체 목록).
- 목록은 커서식: `meta.cursor` 가 있으면 다음 장이 있다(한 장이 비어도). 인자 `cursor` 로 넘긴다.
- 필드 이름·필터 연산자를 추측하지 않는다 — `getObservationFieldSchema`, `getObservationFilterSchema`, `getObservationFilterValues`(이름·환경 등 실제 값 예시), `getMetricsSchema` 로 확인한다.
- 환경(dev·staging·production 등)은 `environment` 로 구분한다.
- input/output 에 개인정보가 있을 수 있다. 원문 필드(`input`·`output`)는 필요할 때만 요청하고, 원문을 이슈·문서·PR 에 옮기지 않는다.
- 응답에 `_deprecation` 경고가 보이면(REST) 사용자에게 알리고, 같은 정보를 주는 MCP 도구로 바꾼다.
- 원인 분석 보고는 조회한 observation·지표(실측)와 추정을 나눠 쓰고 링크를 붙인다.

## 요청별 레시피

`F`/`T` 는 시작·끝 시각, `A` 는 별칭.

1. **최근 호출(trace) 목록** — "trace", "호출 내역", "최근 요청"
   ```bash
   lf -p A call listObservations '{"limit":20,"fromStartTime":"'$F'","toStartTime":"'$T'","isRootObservation":true,"environment":"<env>"}'
   ```
   `userId`·`name`·`type`·`level`·`traceId` 인자로 좁힌다. 복잡한 조건은 `filter`(스키마 확인).

2. **trace 상세** — trace id
   ```bash
   lf -p A call listObservations '{"limit":100,"fromStartTime":"<trace 이전>","toStartTime":"'$T'","traceId":"<id>",
     "fields":["traceName","parentObservationId","type","name","level","statusMessage","providedModelName","latency","usageDetails","totalCost","startTime"]}'
   lf -p A call getObservation '{"observationId":"<id>","fromStartTime":"…","toStartTime":"…","fields":["input","output"]}'   # 원문은 필요한 한 건만
   ```
   `parentObservationId` 로 트리를 재구성하고, 단계별 지연·모델·토큰·비용·`statusMessage` 를 보고한다. trace 비용 = `totalCost` 합(루트 것만 보면 하위 generation 이 빠진다).

3. **실패·경고** — "에러", "실패"
   ```bash
   lf -p A call listObservations '{"limit":100,"fromStartTime":"'$F'","toStartTime":"'$T'","level":"ERROR"}'
   ```
   같은 `statusMessage` 로 묶어 건수 순 → 대표 1~2건만 2번으로 상세. 건수 추이는 4번에 `level` 차원.

4. **비용·토큰·지연·건수 집계** — "비용", "토큰", "p95", "일별", "모델별", "기능별"
   ```bash
   lf -p A schema queryMetrics   # 처음 한 번: 차원·측정값 확인
   lf -p A call queryMetrics '{"view":"observations","dimensions":[{"field":"providedModelName"}],
     "metrics":[{"measure":"totalCost","aggregation":"sum"},{"measure":"count","aggregation":"count"},{"measure":"latency","aggregation":"p95"}],
     "filters":[{"column":"type","operator":"=","value":"GENERATION","type":"string"}],
     "timeDimension":{"granularity":"day"},"fromTimestamp":"'$F'","toTimestamp":"'$T'"}'
   ```
   `timeDimension` 을 쓰면 빈 시간 칸이 `null` 행으로 섞인다 — 합계·순위는 `select(.<차원> != null)` 로 거른다. 차원: `traceName`(기능별)·`environment`·`level`·`promptName`·`name`. `latency` 집계 단위는 **밀리초**(observation 필드 `latency` 는 초). `traceId`·`userId` 같은 고카디널리티 필드는 차원 불가 — 필터로만. 점수 평균은 `view: "scores-numeric"`.

5. **세션** — `listObservations` 에 `"isRootObservation":true,"filter":[{"column":"sessionId","operator":"=","value":"<id>"}]`.

6. **프롬프트** — "프롬프트", "label", "버전"
   ```bash
   lf -p A call listPrompts '{"limit":50}'
   lf -p A --max-str 0 call getPrompt '{"name":"<name>","label":"<label>"}'   # 또는 "version": n
   ```
   버전 비교는 두 버전을 받아 diff. 변경(`createTextPrompt`·`createChatPrompt`·`updatePromptLabels`)은 write — label 이 운영 배포 스위치인 팀이 많으니 영향 환경을 먼저 말하고 확인받는다.

7. **점수·평가** — "점수", "score", "평가기", "eval"
   - 조회: `listScores`·`getScore`·`listScoreConfigs`, 평가기 `listEvaluators`·`getEvaluator`·`listEvaluationRules`, 실험 `listExperiments`·`listExperimentItems`.
   - `testEvaluator`·`runBatchEvaluation` 은 LLM 비용이 드는 write 다 — 대상 범위와 예상 건수를 말하고 확인받는다.

8. **데이터셋·실험 결과** — `listDatasets`·`getDataset`·`listDatasetItems`·`listDatasetRuns`·`getDatasetRun`·`listDatasetRunItems`.

9. **사람 검토·코멘트** — 주석 큐 `listAnnotationQueues`·`listAnnotationQueueItems`, 코멘트 `listComments`·`createComment`(write).

10. **대시보드·알림·모델 가격** — `listDashboards`·`getDashboard`·`listDashboardWidgets`, `listAlerts`·`getAlert`, `listModels`(가격표; 비용이 0 으로 나오면 모델 가격 미등록 의심).

11. **그 밖** — `lf -p A tools <검색어>` 로 찾고 `schema` 를 본 뒤 호출한다. 여러 프로젝트 비교는 별칭마다 같은 호출을 돌려 나란히 보고한다.
