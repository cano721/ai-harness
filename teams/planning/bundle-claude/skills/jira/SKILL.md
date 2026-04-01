---
name: jira
description: Jira 이슈를 조회/생성/수정한다. CLI(curl) 기반으로 MCP 대체.
user-invocable: true
allowed-tools: Bash, Read, Grep, Glob
---

# Jira CLI Skill

Jira REST API를 curl로 직접 호출하여 이슈를 관리한다. MCP 도구 대신 사용하여 컨텍스트를 절약한다.

## 인증 정보

- **Base URL**: `https://midasitweb-jira.atlassian.net`
- **User**: `khb1122@midasin.com`
- **Token**: `~/.claude/credentials.md`의 **Atlassian** 섹션 참조
- **인증 방식**: Basic Auth (`-u user:token`)

## 인자 파싱

`$ARGUMENTS`를 분석하여 아래 액션을 결정한다:

### 액션 목록

1. **이슈 조회** — 이슈 키가 주어지면 (예: `NMRS-12345`)
   ```bash
   curl -s "https://midasitweb-jira.atlassian.net/rest/api/3/issue/{issueKey}" \
     -u "{user}:{token}" | jq '{key:.key, summary:.fields.summary, status:.fields.status.name, assignee:.fields.assignee.displayName, description:.fields.description}'
   ```

2. **이슈 검색** — JQL 또는 키워드가 주어지면
   ```bash
   curl -s -G "https://midasitweb-jira.atlassian.net/rest/api/3/search/jql" \
     --data-urlencode "jql={JQL}" --data-urlencode "fields=key,summary,status,assignee" \
     -u "{user}:{token}" | jq '.issues[] | {key:.key, summary:.fields.summary, status:.fields.status.name}'
   ```

3. **이슈 생성** — "생성", "만들어" 등의 키워드
   - 생성 전 필수 필드 확인: 프로젝트, 이슈타입, summary
   - 메모리 규칙에 따라 상위항목(Epic), Sprint, 수정버전(fixVersions) 필수
   - 활성 Sprint/버전을 먼저 조회하여 추천 후 사용자 확인
   ```bash
   curl -s "https://midasitweb-jira.atlassian.net/rest/agile/1.0/board/{boardId}/sprint?state=active" \
     -u "{user}:{token}" | jq '.values[] | {id:.id, name:.name}'

   curl -s "https://midasitweb-jira.atlassian.net/rest/api/3/project/{projectKey}/versions" \
     -u "{user}:{token}" | jq '[.[] | select(.released==false)] | .[] | {id:.id, name:.name}'

   curl -s -X POST "https://midasitweb-jira.atlassian.net/rest/api/3/issue" \
     -u "{user}:{token}" -H "Content-Type: application/json" \
     -d '{"fields":{"project":{"key":"{projectKey}"},"issuetype":{"name":"Task"},"summary":"{summary}","parent":{"key":"{epicKey}"},"customfield_10020":{sprintId},"fixVersions":[{"id":"{versionId}"}]}}'
   ```

4. **이슈 수정** — "수정", "업데이트", "변경" 등의 키워드 + 이슈 키
   ```bash
   curl -s -X PUT "https://midasitweb-jira.atlassian.net/rest/api/3/issue/{issueKey}" \
     -u "{user}:{token}" -H "Content-Type: application/json" \
     -d '{"fields":{변경할 필드}}'
   ```

5. **상태 전환** — "진행", "완료", "전환" 등
   ```bash
   curl -s "https://midasitweb-jira.atlassian.net/rest/api/3/issue/{issueKey}/transitions" \
     -u "{user}:{token}" | jq '.transitions[] | {id:.id, name:.name}'

   curl -s -X POST "https://midasitweb-jira.atlassian.net/rest/api/3/issue/{issueKey}/transitions" \
     -u "{user}:{token}" -H "Content-Type: application/json" \
     -d '{"transition":{"id":"{transitionId}"}}'
   ```

6. **코멘트 추가** — "코멘트", "댓글" 등
   ```bash
   curl -s -X POST "https://midasitweb-jira.atlassian.net/rest/api/3/issue/{issueKey}/comment" \
     -u "{user}:{token}" -H "Content-Type: application/json" \
     -d '{"body":"{코멘트 내용}"}'
   ```

7. **보드/스프린트 조회** — "보드", "스프린트" 등
   ```bash
   curl -s "https://midasitweb-jira.atlassian.net/rest/agile/1.0/board?projectKeyOrId={projectKey}" \
     -u "{user}:{token}" | jq '.values[] | {id:.id, name:.name}'

   curl -s "https://midasitweb-jira.atlassian.net/rest/agile/1.0/sprint/{sprintId}/issue" \
     -u "{user}:{token}" | jq '.issues[] | {key:.key, summary:.fields.summary, status:.fields.status.name}'
   ```

8. **체크리스트 등록** — "체크리스트" 키워드 → `/jira-checklist` skill로 위임

## 응답 포맷

- jq로 필요한 필드만 추출하여 출력
- 결과를 간결하게 요약하여 사용자에게 보여줌
- 에러 발생 시 HTTP 상태 코드와 메시지 출력

## 주의사항

- Bearer 토큰 사용 금지 (401 에러) → 반드시 Basic Auth
- `additional_fields` dict 파싱 실패 시 curl로 직접 호출
- Sprint 추가는 별도 Agile API 사용: `POST /rest/agile/1.0/sprint/{sprintId}/issue`

$ARGUMENTS
