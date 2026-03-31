---
name: jira-checklist
description: Jira 이슈 내용과 코드 변경사항을 분석하여 검증 체크리스트를 자동 생성하고 등록한다.
user-invocable: true
---

# Jira Checklist

Jira 이슈의 요구사항과 실제 코드 변경사항을 분석하여 QA 검증용 체크리스트를 자동 생성하고, Jira Issue Checklist 플러그인의 Checklist Text 필드(`customfield_10384`)에 등록한다.

## 인증 정보

- **Base URL**: `https://midasitweb-jira.atlassian.net`
- **User/Token**: `~/.claude/credentials.md`의 **Atlassian** 섹션 참조
- **인증 방식**: Basic Auth (`-u user:token`)

## 절차

1. 인자로 Jira 이슈 키(예: `NMRS-15863`)를 받는다
2. **Jira 이슈 분석**: curl로 이슈를 조회한다
   ```bash
   curl -s "https://midasitweb-jira.atlassian.net/rest/api/3/issue/{issueKey}" \
     -u "{user}:{token}" | jq '{summary:.fields.summary, description:.fields.description, status:.fields.status.name}'
   ```
3. **Figma 디자인 확인** (선택):
   - description에 Figma 링크가 있으면 curl로 Figma API를 호출하여 디자인 스펙을 가져온다
   - URL에서 fileKey, nodeId 추출 후: `curl -s "https://api.figma.com/v1/files/{fileKey}/nodes?ids={nodeId}" -H "X-Figma-Token: {token}"`
   - 기획 내용(UI 구성, 정책, 플로우)을 체크리스트에 반영한다
4. **코드 변경사항 분석** (선택):
   - 이슈 키로 관련 브랜치를 찾아 git diff를 분석한다
   - `feature/{이슈키}` 브랜치가 있으면 base 브랜치 대비 diff 확인
   - 현재 브랜치에 변경사항이 있으면 `git diff main...HEAD` 활용
   - 변경된 파일 목록과 핵심 로직 변경 내용을 파악한다
5. **검증 항목 도출**:

   ### A. 요구사항/기획 기반 (Jira 이슈 + Figma)
   - 이슈에 명시된 추가/수정/제거 기능별 검증 항목
   - Figma 디자인에서 도출한 UI/UX 검증 항목
   - 기획서에서 미정의/모호한 부분 식별

   ### B. 개발항목 기반 (코드 변경)
   - 실제 코드에서 변경된 쿼리/로직의 정합성 검증
   - 새로 추가된 메서드/API의 동작 검증
   - 엣지 케이스: null 처리, 데이터 없는 경우, 경계값 등
   - 기존 기능 영향도: 변경으로 인해 기존 코드가 깨지지 않는지 확인
   - 성능: 대량 데이터 처리, N+1 쿼리 여부 등

6. 체크리스트를 Checklist Text 형식으로 작성한다:
   ```
   --- 카테고리명
   * [ ] 검증 항목 1
   * [ ] 검증 항목 2
   --- 다른 카테고리
   * [ ] 검증 항목 3
   ```
7. curl로 `customfield_10384` 필드에 체크리스트를 등록한다:
   ```bash
   curl -s -X PUT "https://midasitweb-jira.atlassian.net/rest/api/3/issue/{issueKey}" \
     -u "{user}:{token}" \
     -H "Content-Type: application/json" \
     -d '{"fields":{"customfield_10384":"--- 카테고리\n* [ ] 항목1\n* [ ] 항목2"}}'
   ```
8. 등록된 체크리스트 항목을 카테고리별로 요약하여 출력한다

## 체크리스트 포맷 규칙

- **헤더(카테고리)**: `--- 카테고리명`
- **미체크 항목**: `* [ ] 검증 항목`
- **체크 항목**: `* [x] 검증 항목`
- 항목 간 구분: `\n`
- 삭제: `"customfield_10384": null`

## 체크리스트 작성 규칙

- 각 항목은 **검증 가능한 구체적인 문장**으로 작성
- 카테고리별로 `---` 헤더로 그룹핑
- 한국어로 작성
- 기존 체크리스트가 있으면 덮어쓸지 사용자에게 확인
- 요구사항 항목과 코드 변경 항목이 중복되면 하나로 합친다

$ARGUMENTS
