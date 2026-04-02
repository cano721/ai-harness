# Backlog: Ddalkak Projects

**Format**: User Stories
**Total stories**: 15
**Phases**: 3 (프로젝트 등록 → 초기 셋업 → 일상 관리)

---

## Phase 1: 프로젝트 등록

### Story 1: 프로젝트 목록 조회

**As a** 개발자, **I want to** 등록된 프로젝트 목록을 카드 형태로 보고 싶다, **so that** 관리 중인 프로젝트를 한눈에 파악할 수 있다.

Acceptance Criteria:
- [ ] 프로젝트 카드에 이름, 경로, 기술 스택 뱃지, 에이전트 수가 표시된다
- [ ] 프로젝트가 0개일 때 "프로젝트를 추가해보세요" 안내와 추가 버튼이 표시된다
- [ ] 카드 클릭 시 ProjectDetail 페이지(/projects/:id)로 이동한다
- [ ] 목록은 생성일 역순으로 정렬된다

Priority: P0 | Effort: S | Dependencies: none

---

### Story 2: 프로젝트 경로 분석 미리보기

**As a** 개발자, **I want to** 프로젝트 경로를 입력하면 자동으로 분석 결과를 미리보기로 보고 싶다, **so that** 등록 전에 어떤 설정이 감지되었는지 확인할 수 있다.

Acceptance Criteria:
- [ ] 경로 입력 후 500ms debounce 뒤 POST /api/projects/analyze 호출
- [ ] 분석 중일 때 "분석 중..." 로딩 인디케이터가 표시된다
- [ ] 분석 결과로 기술 스택 뱃지, git 상태(repo/branch), CLAUDE.md 유무, 설치된 CLI(Claude/Codex/Cursor) 상태가 표시된다
- [ ] 존재하지 않는 경로 입력 시 "경로를 확인해주세요" 에러 메시지가 표시된다
- [ ] 프로젝트 이름이 경로의 마지막 디렉토리명으로 자동 채워진다 (수정 가능)

Priority: P0 | Effort: M | Dependencies: Story 3 (analyze API)

---

### Story 3: 프로젝트 등록

**As a** 개발자, **I want to** 경로를 지정하여 프로젝트를 등록하고 싶다, **so that** Ddalkak에서 해당 프로젝트를 관리할 수 있다.

Acceptance Criteria:
- [ ] "프로젝트 추가" 버튼 클릭 시 등록 모달이 열린다
- [ ] 경로(필수)와 이름(자동 채움, 수정 가능)을 입력할 수 있다
- [ ] 등록 시 POST /api/projects 호출, path가 있으면 서버가 gitUrl과 techStack을 자동 채운다
- [ ] 감지된 CLI(Claude, Codex, Cursor)가 에이전트로 자동 등록된다
- [ ] 등록 성공 시 모달이 닫히고 해당 프로젝트의 ProjectDetail 페이지로 이동한다
- [ ] 같은 경로의 프로젝트가 이미 존재하면 에러 메시지가 표시된다

Priority: P0 | Effort: M | Dependencies: none

---

### Story 4: 프로젝트 삭제

**As a** 개발자, **I want to** 더 이상 관리하지 않는 프로젝트를 삭제하고 싶다, **so that** 목록을 깔끔하게 유지할 수 있다.

Acceptance Criteria:
- [ ] 프로젝트 카드에 삭제 아이콘(또는 메뉴)이 있다
- [ ] 클릭 시 "프로젝트 '{이름}'을 삭제하시겠습니까? 에이전트, 태스크, 컨벤션도 함께 삭제됩니다." 확인 다이얼로그가 표시된다
- [ ] 확인 시 DELETE /api/projects/:id 호출 (cascade 삭제)
- [ ] 삭제 성공 시 목록에서 해당 카드가 사라진다
- [ ] 실제 프로젝트 파일(.ddalkak/, CLAUDE.md 등)은 삭제하지 않는다 (DB 레코드만 삭제)

Priority: P1 | Effort: S | Dependencies: none

---

### Story 5: 프로젝트 검색/필터

**As a** 개발자, **I want to** 프로젝트를 이름으로 검색하고 싶다, **so that** 프로젝트가 많을 때 원하는 프로젝트를 빠르게 찾을 수 있다.

Acceptance Criteria:
- [ ] 목록 상단에 검색 입력 필드가 있다
- [ ] 입력 시 프로젝트 이름으로 클라이언트 사이드 필터링
- [ ] 검색 결과가 0개일 때 "검색 결과가 없습니다" 표시
- [ ] 검색어 초기화(X) 버튼이 있다

Priority: P2 | Effort: S | Dependencies: Story 1

---

## Phase 2: 초기 셋업 (ProjectDetail)

### Story 6: 프로젝트 개요 표시

**As a** 개발자, **I want to** 프로젝트 상세 페이지에서 기본 정보와 분석 결과를 보고 싶다, **so that** 프로젝트의 현재 상태를 파악할 수 있다.

Acceptance Criteria:
- [ ] 프로젝트 이름, 경로, git URL, description, 생성일이 표시된다
- [ ] path가 있으면 POST /api/projects/analyze 호출하여 techStack 뱃지, git 상태(branch명)가 표시된다
- [ ] 분석 로딩 중 스켈레톤 UI가 표시된다
- [ ] path가 없는 프로젝트는 기본 정보만 표시되고 깨지지 않는다
- [ ] "← Back" 버튼으로 Projects 목록으로 돌아갈 수 있다

Priority: P0 | Effort: S | Dependencies: Story 3

---

### Story 7: CLAUDE.md 생성

**As a** 개발자, **I want to** 프로젝트에 CLAUDE.md가 없을 때 버튼 하나로 기본 CLAUDE.md를 생성하고 싶다, **so that** AI 에이전트가 프로젝트 컨텍스트를 즉시 이해할 수 있다.

Acceptance Criteria:
- [ ] CLAUDE.md가 없으면 안내 문구 + "CLAUDE.md 생성" 버튼(accent 색상)이 표시된다
- [ ] 버튼 클릭 시 POST /api/projects/:id/setup/claudemd 호출
- [ ] 생성된 CLAUDE.md에는 프로젝트명, 감지된 기술 스택, 기본 코딩 컨벤션이 포함된다
- [ ] 생성 중 버튼이 "생성 중..." disabled 상태가 된다
- [ ] 생성 성공 시 해당 섹션이 즉시 갱신되어 CLAUDE.md 내용이 표시된다
- [ ] 이미 존재하면 409 에러 → "이미 CLAUDE.md가 존재합니다" 표시

Priority: P0 | Effort: M | Dependencies: Story 6

---

### Story 8: CLAUDE.md 보기/수정/삭제

**As a** 개발자, **I want to** CLAUDE.md 내용을 보고, 수정하고, 삭제할 수 있다, **so that** 프로젝트 컨텍스트를 지속적으로 관리할 수 있다.

Acceptance Criteria:
- [ ] CLAUDE.md가 있으면 내용이 코드 블록으로 표시된다 (최대 120px 높이, 접기/펼치기)
- [ ] "수정" 버튼 클릭 시 textarea 편집 모드로 전환된다
- [ ] textarea에 기존 content가 채워지고, monospace 폰트로 표시된다
- [ ] "저장" 버튼 클릭 시 PATCH /api/projects/:id/setup/claudemd 호출 → 성공 시 뷰 모드로 복귀
- [ ] "취소" 버튼 클릭 시 변경 사항 버리고 뷰 모드로 복귀
- [ ] "삭제" 버튼(빨간색) 클릭 시 confirm 다이얼로그 → DELETE /api/projects/:id/setup/claudemd
- [ ] 삭제 성공 시 "없음" 상태(생성 버튼)로 전환

Priority: P0 | Effort: M | Dependencies: Story 7

---

### Story 9: 보안 Hook 적용

**As a** 개발자, **I want to** 프로젝트에 보안 Hook이 없을 때 원클릭으로 적용하고 싶다, **so that** AI 에이전트의 위험 명령을 자동으로 차단할 수 있다.

Acceptance Criteria:
- [ ] Hook이 없으면 "보안 Hook을 적용하면 위험 명령을 자동 차단합니다" 안내 + "보안 Hook 적용" 버튼이 표시된다
- [ ] 버튼 클릭 시 POST /api/projects/:id/setup/hooks 호출
- [ ] .claude/settings.json에 PreToolUse Hook(block-dangerous, secret-scanner)이 등록된다
- [ ] 적용 중 버튼이 "적용 중..." disabled 상태
- [ ] 적용 성공 시 해당 섹션이 갱신되어 Hook 목록이 표시된다

Priority: P0 | Effort: S | Dependencies: Story 6

---

### Story 10: Hook 목록 보기/개별 삭제/전체 초기화

**As a** 개발자, **I want to** 적용된 Hook을 개별적으로 확인하고 삭제할 수 있다, **so that** 필요한 Hook만 선택적으로 유지할 수 있다.

Acceptance Criteria:
- [ ] Hook이 있으면 이벤트별로 카드 형태로 표시된다 (이벤트명 뱃지 + 명령어 목록)
- [ ] 각 Hook 항목(명령어) 옆에 삭제 버튼(X)이 있다
- [ ] 개별 삭제 클릭 시 해당 Hook만 .claude/settings.json에서 제거된다 (PUT /api/projects/:id/setup/hooks로 갱신된 hooks 전체 전송)
- [ ] 삭제 성공 시 목록에서 해당 항목이 사라진다
- [ ] 마지막 Hook을 삭제하면 "없음" 상태(적용 버튼)로 전환
- [ ] "Hook 전체 초기화" 버튼(빨간색) 클릭 시 confirm 다이얼로그 → 전체 제거
- [ ] 전체 초기화 시 DELETE /api/projects/:id/setup/hooks 호출

Priority: P1 | Effort: M | Dependencies: Story 9

---

### Story 11: 컨벤션 자동 생성

**As a** 개발자, **I want to** 프로젝트에 컨벤션이 없을 때 기술 스택 기반으로 자동 생성하고 싶다, **so that** 기본적인 코딩 규칙을 빠르게 셋업할 수 있다.

Acceptance Criteria:
- [ ] 컨벤션이 없으면 안내 문구 + "컨벤션 자동 생성" 버튼이 표시된다
- [ ] 버튼 클릭 시 POST /api/projects/:id/setup/conventions 호출
- [ ] 기술 스택에 맞는 기본 컨벤션이 생성된다 (예: Node.js → camelCase, async/await)
- [ ] 생성된 컨벤션이 .ddalkak/conventions.yaml + DB에 저장된다
- [ ] 성공 시 해당 섹션이 갱신되어 컨벤션 목록이 표시된다

Priority: P0 | Effort: S | Dependencies: Story 6

---

### Story 12: 컨벤션 수동 추가

**As a** 개발자, **I want to** 프로젝트에 컨벤션을 직접 추가하고 싶다, **so that** 팀 고유의 코딩 규칙을 정의할 수 있다.

Acceptance Criteria:
- [ ] 컨벤션 목록 하단에 "컨벤션 추가" 버튼이 있다
- [ ] 클릭 시 인라인 폼이 열린다 (카테고리 입력 + 규칙 입력)
- [ ] "추가" 버튼 클릭 시 POST /api/conventions/:projectId 호출
- [ ] 카테고리 또는 규칙이 비어있으면 버튼 비활성화
- [ ] 추가 성공 시 목록에 즉시 반영되고 입력 필드가 초기화된다

Priority: P1 | Effort: S | Dependencies: Story 11

---

### Story 13: 컨벤션 삭제

**As a** 개발자, **I want to** 불필요한 컨벤션을 개별적으로 삭제하고 싶다, **so that** 컨벤션 목록을 깔끔하게 유지할 수 있다.

Acceptance Criteria:
- [ ] 각 컨벤션 항목 오른쪽에 삭제 버튼(X 또는 휴지통 아이콘)이 있다
- [ ] 클릭 시 confirm 없이 즉시 DELETE /api/conventions/:projectId/:id 호출
- [ ] 삭제 성공 시 목록에서 해당 항목이 사라진다
- [ ] .ddalkak/conventions.yaml에도 동기화 반영된다

Priority: P1 | Effort: S | Dependencies: Story 12

---

## Phase 3: 일상 관리

### Story 14: 에이전트 현황 표시

**As a** 개발자, **I want to** 프로젝트에 연결된 에이전트와 CLI 설치 상태를 보고 싶다, **so that** 어떤 AI 도구를 사용할 수 있는지 파악할 수 있다.

Acceptance Criteria:
- [ ] .claude/agents/*.md에서 감지된 에이전트가 뱃지로 표시된다
- [ ] 설치된 CLI 상태가 표시된다 (Claude ✓, Codex ✓, Cursor ✗)
- [ ] DB에 등록된 에이전트가 카드로 표시된다 (이름, 어댑터 아이콘, 상태 뱃지)
- [ ] 에이전트 카드 클릭 시 AgentDetail 페이지로 이동한다

Priority: P1 | Effort: S | Dependencies: Story 6

---

### Story 15: 비용/태스크 요약 표시

**As a** 개발자, **I want to** 프로젝트의 비용 요약과 최근 태스크를 보고 싶다, **so that** 에이전트 사용 현황을 파악할 수 있다.

Acceptance Criteria:
- [ ] 비용 섹션에 Total Spend(USD), Input/Output Tokens가 표시된다
- [ ] 비용 데이터 없으면 "No cost data yet" 표시
- [ ] 최근 태스크 10개가 상태 뱃지(todo/in_progress/done/blocked)와 함께 표시된다
- [ ] 태스크 없으면 "No tasks" 표시
- [ ] 관련 프로젝트(depends_on)가 있으면 하단에 표시, 클릭 시 해당 프로젝트로 이동

Priority: P2 | Effort: S | Dependencies: Story 6

---

## Story Map

```
Must-have (P0)           Should-have (P1)         Nice-to-have (P2)
──────────────────       ─────────────────        ──────────────────
#1 프로젝트 목록          #4 프로젝트 삭제          #5 검색/필터
#2 경로 분석 미리보기     #10 Hook 보기/초기화      #15 비용/태스크 요약
#3 프로젝트 등록          #12 컨벤션 수동 추가
#6 프로젝트 개요          #13 컨벤션 삭제
#7 CLAUDE.md 생성         #14 에이전트 현황
#8 CLAUDE.md 보기/수정/삭제
#9 보안 Hook 적용
#11 컨벤션 자동 생성
```

## Technical Notes

### API 엔드포인트 (기존 + 신규)
- `GET /api/projects` — 프로젝트 목록
- `POST /api/projects` — 프로젝트 등록 (path 있으면 자동 분석 + 에이전트 등록)
- `POST /api/projects/analyze` — 경로 분석 (등록 전 미리보기)
- `DELETE /api/projects/:id` — 프로젝트 삭제 (cascade)
- `POST /api/projects/:id/setup/claudemd` — CLAUDE.md 생성
- `PATCH /api/projects/:id/setup/claudemd` — CLAUDE.md 수정
- `DELETE /api/projects/:id/setup/claudemd` — CLAUDE.md 삭제
- `POST /api/projects/:id/setup/hooks` — Hook 적용
- `DELETE /api/projects/:id/setup/hooks` — Hook 초기화
- `POST /api/projects/:id/setup/conventions` — 컨벤션 자동 생성
- `GET /api/conventions/:projectId` — 컨벤션 목록
- `POST /api/conventions/:projectId` — 컨벤션 추가
- `DELETE /api/conventions/:projectId/:id` — 컨벤션 삭제

### 파일시스템 접근
- CLAUDE.md: 프로젝트 root에 생성/수정/삭제
- .claude/settings.json: Hook 등록/제거
- .ddalkak/conventions.yaml: 컨벤션 동기화
- 분석 시 읽기: .claude/agents/*.md, .ddalkak/skills/*.md

### 상태 관리
- React Query: 서버 데이터 (staleTime: 10s)
- useMutation: 생성/수정/삭제 후 invalidateQueries
- useState: 편집 모드, 모달 상태

## Open Questions

1. **프로젝트 수정**: 등록 후 이름/경로를 변경할 수 있어야 하는가? (현재 API에 PATCH 존재하지만 UI 미구현)
2. **스킬 관리**: 스킬은 현재 파일 기반으로 보기만 가능. UI에서 스킬을 추가/수정할 수 있어야 하는가?
3. **Hook 개별 관리**: 현재는 전체 적용/전체 초기화만 가능. 개별 Hook 추가/삭제가 필요한가?
4. **컨벤션 수정**: 기존 컨벤션의 카테고리/규칙을 수정하는 기능이 필요한가? (현재 삭제 후 재추가만 가능)
5. **분석 자동 갱신**: ProjectDetail에서 분석 결과를 주기적으로 갱신할지, 수동 새로고침만 할지?
