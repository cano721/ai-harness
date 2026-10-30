---
name: jira
description: Jira 이슈를 조회·검색(JQL)하고, 생성·수정·상태 전환·코멘트를 curl로 한다. 이슈 키(예 ABC-123)나 Jira URL이 나오거나, 이슈를 진행 중으로 옮기거나 만들어 달라는 요청에 쓴다.
---

# Jira

Jira Cloud REST API v3를 curl로 직접 호출한다. 조회는 바로 하고, 생성·수정·전환·코멘트처럼 쓰는 요청은 사용자가 요청한 범위 안에서만 한다. 요청에 없던 필드를 채워야 하면 추천값과 함께 먼저 묻는다.

## 인증

| 환경변수 | 필수 | 설명 |
|---|---|---|
| `JIRA_BASE_URL` | 예 | 예: `https://acme.atlassian.net` (끝 `/` 없이) |
| `ATLASSIAN_USER` | 예 | Atlassian 계정 이메일 |
| `ATLASSIAN_API_TOKEN` | 예 | https://id.atlassian.com/manage-profile/security/api-tokens 에서 발급 |

Claude Code는 `~/.claude/settings.json`의 `env`, Codex는 셸 환경에서 읽는다. 값이 없으면 대화에 붙여 넣게 하지 말고, 사용자가 직접 위 위치에 넣도록 안내한다. 토큰은 출력하거나 명령 인자에 펼치지 않는다. 인증은 Basic만 된다 — Bearer는 401이다.

## 호출 방법

Bash 호출마다 상태가 이어지지 않으므로 아래 함수를 매 호출에 함께 정의한다. 자격 증명은 `-K -`(stdin)로 넘긴다.

```bash
jr() { # jr <METHOD> <path?query> [curl 인자...]
  local method="$1" path="$2"; shift 2
  printf 'user = "%s:%s"\n' "${ATLASSIAN_USER:-}" "${ATLASSIAN_API_TOKEN:-}" \
    | curl -sS --fail-with-body -K - -X "$method" "${JIRA_BASE_URL%/}$path" \
        -H 'Accept: application/json' -H 'Content-Type: application/json' "$@"
}
```

v3의 `description`과 코멘트 `body`는 문자열이 아니라 ADF(Atlassian Document Format)다. 일반 텍스트는 아래처럼 감싼다.

```bash
adf() { jq -cn --arg t "$1" '{type:"doc",version:1,content:[$t | split("\n\n")[] | {type:"paragraph",content:[{type:"text",text:.}]}]}'; }
```

## 요청별 호출

1. **이슈 조회** — 이슈 키나 URL이 주어지면
   ```bash
   jr GET "/rest/api/3/issue/ABC-123?fields=summary,status,assignee,issuetype,priority,parent,description" \
     | jq '{key, summary:.fields.summary, status:.fields.status.name, type:.fields.issuetype.name, assignee:.fields.assignee.displayName, parent:.fields.parent.key, description:.fields.description}'
   ```
   - `description`은 ADF라 `content[].content[].text`를 이어 읽는다.

2. **검색 (JQL)**
   ```bash
   jr GET "/rest/api/3/search/jql" -G --data-urlencode 'jql=project = ABC AND assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC' \
     --data-urlencode 'fields=summary,status,assignee' --data-urlencode 'maxResults=20' \
     | jq '[.issues[]? | {key, summary:.fields.summary, status:.fields.status.name}]'
   ```
   - 다음 페이지는 응답의 `nextPageToken`을 `nextPageToken=`으로 넘긴다.

3. **상태 전환** — "진행 중으로", "완료 처리"
   ```bash
   jr GET /rest/api/3/issue/ABC-123/transitions | jq '[.transitions[] | {id, name, to:.to.name, category:.to.statusCategory.key}]'
   jr POST /rest/api/3/issue/ABC-123/transitions -d '{"transition":{"id":"31"}}'
   ```
   - 상태 이름을 하드코딩하지 말고 목표의 `statusCategory.key`로 고른다: 진행 중 `indeterminate`, 완료 `done`, 할 일 `new`.
   - 이미 그 범주면 전환하지 않는다. 완료된 이슈를 다시 여는 건 사용자에게 먼저 묻는다.

4. **코멘트**
   ```bash
   jr POST /rest/api/3/issue/ABC-123/comment -d "$(jq -cn --argjson b "$(adf '코멘트 내용')" '{body:$b}')"
   ```

5. **이슈 생성**
   - 프로젝트·이슈 타입·요약은 필수다. 프로젝트가 요구하는 필드는 먼저 확인한다:
   ```bash
   jr GET "/rest/api/3/issue/createmeta/ABC/issuetypes" | jq '[.issueTypes[]? | {id, name}]'
   jr GET "/rest/api/3/issue/createmeta/ABC/issuetypes/<typeId>" | jq '[.fields[]? | select(.required) | {fieldId, name}]'
   ```
   ```bash
   jr POST /rest/api/3/issue -d "$(jq -cn --argjson d "$(adf '설명')" \
     '{fields:{project:{key:"ABC"}, issuetype:{name:"Task"}, summary:"요약", description:$d}}')" | jq '{key, self}'
   ```
   - 상위 항목은 `parent:{key:"ABC-1"}`. 스프린트·커스텀 필드 ID는 저장소마다 다르니 `jr GET /rest/api/3/field | jq '[.[] | select(.name|test("Sprint";"i")) | {id,name}]'`로 찾는다.
   - 프로젝트·팀 규칙(필수 에픽·버전 등)이 저장소 문서나 사용자 지침에 있으면 그것을 따른다.

6. **필드 수정**
   ```bash
   jr PUT /rest/api/3/issue/ABC-123 -d '{"fields":{"summary":"새 요약"}}'
   ```
   - 담당자는 `accountId`가 필요하다: `jr GET "/rest/api/3/user/search?query=<이메일>" | jq '.[0].accountId'`.

7. **보드·스프린트**
   ```bash
   jr GET "/rest/agile/1.0/board?projectKeyOrId=ABC" | jq '[.values[]? | {id, name, type}]'
   jr GET "/rest/agile/1.0/board/<boardId>/sprint?state=active" | jq '[.values[]? | {id, name}]'
   jr POST "/rest/agile/1.0/sprint/<sprintId>/issue" -d '{"issues":["ABC-123"]}'
   ```

## 응답 정리

- `키 · 요약 · 상태 · 담당자`로 짧게 보여 주고, 링크는 `$JIRA_BASE_URL/browse/<키>`.
- 쓰기 요청 뒤에는 바뀐 결과를 한 번 다시 조회해 확인한다.
- 실패하면 HTTP 상태와 `errorMessages`·`errors`를 그대로 보여 준다. 400의 필드 오류는 어떤 필드가 빠졌는지 짚어 다시 묻는다.
