---
name: datadog
description: Datadog 로그·메트릭·모니터·인시던트·이벤트·호스트·서비스를 curl로 조회한다. 에러 원인 조사, 배포 뒤 재발 확인, 알림 상태 확인에 쓴다. 읽기 전용이며 Datadog 설정을 바꾸지 않는다.
---

# Datadog

Datadog API를 curl로 직접 호출한다. 읽기 전용이다 — 모니터·대시보드·인시던트를 만들거나 바꾸는 요청은 사용자가 명시했을 때만, 바꿀 내용을 먼저 보여 주고 확인받은 뒤 한다.

## 사용자 규칙 (먼저 읽기)

`${HARNESS_METRICS_DIR:-$HOME/.ai-harness}/skills/datadog.md`가 있으면 호출 전에 Read하고 따른다. `/ai-harness:setup`이 회사·팀 전용 값(기본 프로젝트·필터, 필드 ID, 생성 규칙, 관례)을 적어 두는 파일이다. 이 본문과 다르면 그 파일이 이긴다 — 단 자격 증명을 다루는 방식과 쓰기 전 확인 규칙은 이 본문을 따른다. 파일이 없으면 이 본문의 일반 규칙대로 하고, 매번 같은 값을 묻게 되면 `/ai-harness:setup`으로 저장하자고 한 번 제안한다.

## 인증

| 환경변수 | 필수 | 설명 |
|---|---|---|
| `DATADOG_API_KEY` (또는 `DD_API_KEY`) | 예 | API key |
| `DATADOG_APP_KEY` (또는 `DD_APP_KEY`) | 예 | Application key (조회 권한) |
| `DATADOG_SITE` (또는 `DD_SITE`) | 아니오 | `datadoghq.com`(기본), `us3.datadoghq.com`, `us5.datadoghq.com`, `datadoghq.eu`, `ap1.datadoghq.com` 등 |

Claude Code는 `~/.claude/settings.json`의 `env`, Codex는 셸 환경(`~/.ai-harness/secrets.env`를 source)에서 읽는다. 값이 없거나 401·403이면 값을 대화에 붙여 넣게 하지 말고 `/ai-harness:setup`(Codex는 ai-harness setup 스킬)으로 발급·저장·연결 확인을 안내한다. 값은 출력하거나 명령 인자에 펼치지 않는다.

## 호출 방법

Bash 호출마다 상태가 이어지지 않으므로 아래 함수를 매 호출에 함께 정의한다. 키는 프로세스 목록에 남지 않도록 `-K -`(stdin)로 넘긴다.

```bash
dd() { # dd <METHOD> <path?query> [curl 인자...]
  local site="${DATADOG_SITE:-${DD_SITE:-datadoghq.com}}" method="$1" path="$2"; shift 2
  printf 'header = "DD-API-KEY: %s"\nheader = "DD-APPLICATION-KEY: %s"\n' \
    "${DATADOG_API_KEY:-${DD_API_KEY:-}}" "${DATADOG_APP_KEY:-${DD_APP_KEY:-}}" \
    | curl -sS --fail-with-body -K - -X "$method" "https://api.$site$path" -H 'Content-Type: application/json' "$@"
}
```

## 요청별 호출

시간 범위가 없으면 최근 1시간(`now-1h` ~ `now`)을 쓴다. 상대 시간을 받지 않는 v1 API는 `date +%s`로 epoch 초를 계산한다.

1. **로그 검색** — "로그", "에러 로그", "log"
   ```bash
   dd POST /api/v2/logs/events/search -d '{"filter":{"query":"service:api status:error","from":"now-1h","to":"now"},"sort":"-timestamp","page":{"limit":50}}' \
     | jq '[.data[]? | {t:.attributes.timestamp, service:.attributes.service, status:.attributes.status, msg:(.attributes.message // "" | .[0:300])}]'
   ```
   - 다음 페이지는 응답의 `meta.page.after`를 `page.cursor`로 넘긴다. 한 요청 최대 1000건.
   - 같은 에러끼리 묶어 세려면 `/api/v2/logs/analytics/aggregate`를 쓴다:
   ```bash
   dd POST /api/v2/logs/analytics/aggregate -d '{"filter":{"query":"status:error","from":"now-24h","to":"now"},"compute":[{"aggregation":"count"}],"group_by":[{"facet":"service","limit":10},{"facet":"@error.kind","limit":10}]}' \
     | jq '.data.buckets'
   ```

2. **메트릭 조회** — "메트릭", "metric", "CPU", "지연"
   ```bash
   to=$(date +%s); from=$((to - 3600))
   dd GET "/api/v1/query?from=$from&to=$to" -G --data-urlencode 'query=avg:system.cpu.user{service:api} by {host}' \
     | jq '[.series[]? | {scope, last:(.pointlist[-1][1]), points:(.pointlist|length)}]'
   ```

3. **모니터** — "모니터", "알림", "monitor"
   ```bash
   dd GET /api/v1/monitor/search -G --data-urlencode 'query=status:alert' \
     | jq '[.monitors[]? | {id, name, status, tags}]'
   ```
   - 단건: `dd GET /api/v1/monitor/<id> | jq '{id, name, overall_state, query, message}'`

4. **인시던트** — "인시던트", "장애", "incident"
   ```bash
   dd GET /api/v2/incidents | jq '[.data[]? | {id, title:.attributes.title, state:.attributes.fields.state.value, severity:.attributes.fields.severity.value, created:.attributes.created}]'
   ```

5. **이벤트** — "이벤트", "배포 이벤트", "event"
   ```bash
   dd POST /api/v2/events/search -d '{"filter":{"query":"source:alert","from":"now-3h","to":"now"},"page":{"limit":50}}' \
     | jq -r '.data[]? | "\(.attributes.timestamp) \(.attributes.attributes.title // .attributes.message)"'
   ```

6. **호스트** — "호스트", "서버", "host"
   ```bash
   dd GET /api/v1/hosts -G --data-urlencode 'filter=web' | jq '[.host_list[]? | {name, up:.is_up, apps}]'
   ```

7. **대시보드** — "대시보드", "dashboard"
   ```bash
   dd GET /api/v1/dashboard | jq --arg q "keyword" '[.dashboards[]? | select(.title | test($q; "i")) | {id, title, url}]'
   ```

8. **서비스 정의 (APM)** — "서비스", "APM", "담당 팀"
   ```bash
   dd GET /api/v2/services/definitions | jq '[.data[]? | {name:.attributes.schema."dd-service", team:.attributes.schema.team}]'
   ```

## 응답 정리

- jq로 필요한 필드만 뽑는다. 결과가 많으면 상위 20건과 전체 건수를 보여 준다.
- 타임스탬프는 사람이 읽는 형식으로 바꾼다.
- 실패하면 HTTP 상태와 응답의 `errors`를 그대로 보여 준다. 401·403은 키 또는 권한(App key scope), 404는 사이트 설정(`DATADOG_SITE`)을 먼저 의심한다.
- 로그 본문에 토큰·개인정보가 보이면 요약에 옮기지 않는다.
- Rate limit(429)이면 `X-RateLimit-Reset` 초만큼 기다렸다가 한 번만 다시 시도한다.
