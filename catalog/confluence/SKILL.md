---
name: confluence
description: Confluence 페이지를 조회·검색(CQL)하고, 생성·수정·코멘트·라벨을 curl로 한다. Confluence URL이나 페이지 제목이 나오거나, 문서를 찾거나 올려 달라는 요청에 쓴다.
---

# Confluence

Confluence Cloud REST API를 curl로 직접 호출한다. 조회는 바로 하고, 생성·수정·코멘트·첨부처럼 쓰는 요청은 사용자가 요청한 범위 안에서만 한다. 기존 페이지 수정은 바꿀 부분을 먼저 보여 준다.

## 사용자 규칙 (먼저 읽기)

`${HARNESS_METRICS_DIR:-$HOME/.ai-harness}/skills/confluence.md`가 있으면 호출 전에 Read하고 따른다. `/ai-harness:setup`이 회사·팀 전용 값(기본 프로젝트·필터, 필드 ID, 생성 규칙, 관례)을 적어 두는 파일이다. 이 본문과 다르면 그 파일이 이긴다 — 단 자격 증명을 다루는 방식과 쓰기 전 확인 규칙은 이 본문을 따른다. 파일이 없으면 이 본문의 일반 규칙대로 하고, 매번 같은 값을 묻게 되면 `/ai-harness:setup`으로 저장하자고 한 번 제안한다.

## 인증

| 환경변수 | 필수 | 설명 |
|---|---|---|
| `CONFLUENCE_BASE_URL` | 예 | 예: `https://acme.atlassian.net/wiki` (끝 `/` 없이) |
| `ATLASSIAN_USER` | 예 | Atlassian 계정 이메일 |
| `ATLASSIAN_API_TOKEN` | 예 | https://id.atlassian.com/manage-profile/security/api-tokens 에서 발급 |

Claude Code는 `~/.claude/settings.json`의 `env`, Codex는 셸 환경(`~/.ai-harness/secrets.env`를 source)에서 읽는다. 값이 없거나 401·403이면 값을 대화에 붙여 넣게 하지 말고 `/ai-harness:setup`(Codex는 ai-harness setup 스킬)으로 발급·저장·연결 확인을 안내한다. 값은 출력하거나 명령 인자에 펼치지 않는다.

## 호출 방법

Bash 호출마다 상태가 이어지지 않으므로 아래 함수를 매 호출에 함께 정의한다. 자격 증명은 `-K -`(stdin)로 넘긴다.

```bash
cf() { # cf <METHOD> <path?query> [curl 인자...]
  local method="$1" path="$2"; shift 2
  printf 'user = "%s:%s"\n' "${ATLASSIAN_USER:-}" "${ATLASSIAN_API_TOKEN:-}" \
    | curl -sS --fail-with-body -K - -X "$method" "${CONFLUENCE_BASE_URL%/}$path" -H 'Accept: application/json' "$@"
}
```

URL에서 페이지 ID는 `/pages/<id>/` 부분이다.

## 요청별 호출

1. **페이지 조회**
   ```bash
   cf GET "/api/v2/pages/<id>?body-format=storage" | jq '{id, title, spaceId, version:.version.number, body:.body.storage.value}'
   ```
   - 본문은 storage(XHTML) 형식이다. 요약할 때 태그를 걷어 내고 핵심만 보여 준다.

2. **검색 (CQL)**
   ```bash
   cf GET /rest/api/search -G --data-urlencode 'cql=type=page AND space="ENG" AND text~"배포 절차"' --data-urlencode 'limit=20' \
     | jq '[.results[]? | {id:.content.id, title:.content.title, space:.resultGlobalContainer.title, url:._links.webui}]'
   ```
   - 제목 정확 일치는 `title="..."`, 최근 수정은 `lastmodified > now("-7d")`.

3. **하위 페이지**
   ```bash
   cf GET "/api/v2/pages/<id>/children?limit=50" | jq '[.results[]? | {id, title}]'
   ```

4. **페이지 생성**
   ```bash
   cf GET "/api/v2/spaces?keys=ENG" | jq '.results[0].id'   # spaceId
   cf POST /api/v2/pages -H 'Content-Type: application/json' -d "$(jq -cn --arg s "<spaceId>" --arg p "<parentId>" --arg t "제목" --arg b "<p>본문</p>" \
     '{spaceId:$s, parentId:$p, status:"current", title:$t, body:{representation:"storage", value:$b}}')" | jq '{id, title, url:._links.webui}'
   ```

5. **페이지 수정** — 현재 버전 +1로 보낸다. 본문 전체를 교체하므로 먼저 조회한 본문을 고쳐서 보낸다.
   ```bash
   cf PUT "/api/v2/pages/<id>" -H 'Content-Type: application/json' -d "$(jq -cn --arg id "<id>" --arg t "제목" --arg b "<p>새 본문</p>" --argjson v <현재버전+1> \
     '{id:$id, status:"current", title:$t, body:{representation:"storage", value:$b}, version:{number:$v}}')" | jq '{id, version:.version.number}'
   ```
   - 409는 그사이 다른 사람이 고친 것이다. 다시 조회해 변경을 합친 뒤 보낸다.

6. **코멘트**
   ```bash
   cf POST /api/v2/footer-comments -H 'Content-Type: application/json' -d "$(jq -cn --arg p "<id>" --arg b "<p>코멘트</p>" '{pageId:$p, body:{representation:"storage", value:$b}}')"
   ```

7. **첨부 업로드**
   ```bash
   cf POST "/rest/api/content/<id>/child/attachment" -H 'X-Atlassian-Token: nocheck' -F 'file=@./diagram.png'
   ```

8. **라벨**
   ```bash
   cf POST "/rest/api/content/<id>/label" -H 'Content-Type: application/json' -d '[{"prefix":"global","name":"runbook"}]'
   ```

## 응답 정리

- `제목 · 스페이스 · 링크(CONFLUENCE_BASE_URL + _links.webui)`로 보여 준다.
- 쓰기 요청 뒤에는 결과를 다시 조회해 확인한다.
- 실패하면 HTTP 상태와 `message`·`errors`를 그대로 보여 준다. 401은 계정·토큰, 404는 base URL(`/wiki` 포함 여부)이나 권한을 먼저 의심한다.
