# Backlog: Ddalkak Projects (v2)

**Format**: User Stories
**핵심 원칙**: 대시보드 = 프로젝트 파일들의 GUI 편집기. DB는 프로젝트 목록 + 실행 이력만.

---

## 설계 원칙

### 파일이 소스 오브 트루스
| 섹션 | 실제 파일 | DB |
|------|----------|-----|
| CLAUDE.md | `{project}/CLAUDE.md` | X |
| Hook | `{project}/.claude/settings.json` | X |
| 에이전트 | `{project}/.claude/agents/*.md` | X (목록 표시만) |
| 컨벤션 | `{project}/.ddalkak/skills/convention.md` | X |
| 스킬 | `{project}/.ddalkak/skills/*.md` | X (목록 표시만) |
| 프로젝트 목록 | - | O (경로 레지스트리) |
| 태스크/비용/로그 | - | O (실행 이력) |

### ai-harness 원칙 계승
- CLAUDE.md는 최소 규칙만, 상세는 스킬로 분리 (컨텍스트 절약)
- 프로젝트 셋업은 분석 → 자동 생성 → 멱등 (있으면 스킵/업데이트)
- 파일이 git에 커밋되면 팀 공유 완료 (별도 config.yaml 불필요)

---

## 페이지 구조

### Projects (목록 페이지)
프로젝트를 등록하고 목록을 관리하는 진입점.

### ProjectDetail (상세 페이지)
프로젝트의 모든 설정을 보고, 셋업하고, 관리하는 메인 페이지.

---

## Phase 1: 프로젝트 등록

### Story 1: 프로젝트 목록 조회

**As a** 개발자, **I want to** 등록된 프로젝트 목록을 카드 형태로 보고 싶다, **so that** 관리 중인 프로젝트를 한눈에 파악할 수 있다.

Acceptance Criteria:
- [ ] 프로젝트 카드에 이름, 경로, 기술 스택 뱃지, 에이전트 수가 표시된다
- [ ] 프로젝트 0개일 때 "프로젝트를 추가해보세요" 안내와 추가 버튼이 표시된다
- [ ] 카드 클릭 시 ProjectDetail(/projects/:id)로 이동한다
- [ ] 목록은 생성일 역순 정렬

Priority: P0 | Effort: S | Dependencies: none

---

### Story 2: 프로젝트 등록 (경로 분석 → 미리보기 → 등록)

**As a** 개발자, **I want to** 프로젝트 경로를 입력하면 자동 분석 후 등록하고 싶다, **so that** 프로젝트를 빠르게 Ddalkak에 추가할 수 있다.

Acceptance Criteria:
- [ ] "프로젝트 추가" 버튼 클릭 시 등록 모달이 열린다
- [ ] 경로 입력 후 500ms debounce 뒤 POST /api/projects/analyze 호출
- [ ] 분석 미리보기: 기술 스택 뱃지, git 상태(repo/branch), CLAUDE.md 유무, 설치된 CLI 상태
- [ ] 이름은 경로의 마지막 디렉토리명으로 자동 채움 (수정 가능)
- [ ] 존재하지 않는 경로 입력 시 "경로를 확인해주세요" 에러
- [ ] 등록 성공 시 ProjectDetail로 이동

Priority: P0 | Effort: M | Dependencies: none

---

### Story 3: 프로젝트 삭제

**As a** 개발자, **I want to** 프로젝트를 목록에서 제거하고 싶다, **so that** 더 이상 관리하지 않는 프로젝트를 정리할 수 있다.

Acceptance Criteria:
- [ ] 삭제 확인 다이얼로그: "프로젝트 '{이름}'을 목록에서 제거하시겠습니까?"
- [ ] DB 레코드만 삭제 (실제 프로젝트 파일은 건드리지 않음)
- [ ] 삭제 성공 시 목록에서 제거

Priority: P1 | Effort: S | Dependencies: none

---

## Phase 2: 프로젝트 셋업

### Story 4: 원클릭 프로젝트 셋업

**As a** 개발자, **I want to** "프로젝트 셋업" 버튼 하나로 CLAUDE.md, Hook, 컨벤션, 스킬을 한번에 생성하고 싶다, **so that** 프로젝트 초기 설정을 빠르게 끝낼 수 있다.

Acceptance Criteria:
- [ ] ProjectDetail 상단에 "프로젝트 셋업" 버튼이 있다
- [ ] 클릭 시 서버가 프로젝트를 분석하고 다음을 순차 실행:
  - CLAUDE.md — 없으면 스택 기반 생성, 있으면 스킵
  - .claude/settings.json Hook — 없으면 보안 Hook 적용, 있으면 스킵
  - .ddalkak/skills/convention.md — 없으면 스택 기반 컨벤션 생성, 있으면 변경점 업데이트
  - .ddalkak/skills/develop.md — 없으면 개발 가이드 스킬 생성, 있으면 스킵
  - .ddalkak/skills/review.md — 없으면 리뷰 가이드 스킬 생성, 있으면 스킵
- [ ] 실행 중 각 항목별 진행 상태 표시 (스피너 → ✓ 완료 / — 스킵)
- [ ] 완료 후 결과 리포트:
  ```
  CLAUDE.md         생성됨 ✓
  보안 Hook          이미 적용됨 — 스킵
  convention.md     생성됨 ✓
  develop 스킬       생성됨 ✓
  review 스킬        생성됨 ✓
  ```
- [ ] 결과 리포트 확인 후 페이지가 갱신되어 셋업된 내용이 각 섹션에 표시
- [ ] 이미 전부 셋업된 상태에서 다시 누르면 "모든 항목이 이미 셋업되어 있습니다"

Priority: P0 | Effort: L | Dependencies: Story 2

---

## Phase 3: 개별 섹션 관리

### Story 5: 프로젝트 개요 표시

**As a** 개발자, **I want to** 프로젝트의 기본 정보와 기술 스택을 보고 싶다, **so that** 프로젝트 현황을 파악할 수 있다.

Acceptance Criteria:
- [ ] 이름, 경로, git URL, git branch, 생성일이 표시된다
- [ ] 기술 스택이 뱃지로 표시된다
- [ ] 분석 로딩 중 스켈레톤 UI
- [ ] "← Back" 버튼으로 목록 복귀

Priority: P0 | Effort: S | Dependencies: none

---

### Story 6: CLAUDE.md 보기/수정/삭제

**As a** 개발자, **I want to** 프로젝트의 CLAUDE.md를 대시보드에서 보고 수정하고 삭제하고 싶다, **so that** AI 에이전트의 프로젝트 컨텍스트를 관리할 수 있다.

Acceptance Criteria:
- [ ] **있을 때**: 내용을 코드 블록으로 표시 (접기/펼치기)
- [ ] "수정" 클릭 → textarea 편집 모드 (monospace) → "저장"/"취소"
- [ ] 저장 시 프로젝트의 CLAUDE.md 파일 덮어쓰기
- [ ] "삭제" 클릭 → confirm → 프로젝트의 CLAUDE.md 파일 삭제
- [ ] **없을 때**: "프로젝트 셋업을 실행하면 자동으로 생성됩니다" 안내

Priority: P0 | Effort: M | Dependencies: Story 5

---

### Story 7: Hook 보기/개별 삭제/초기화

**As a** 개발자, **I want to** 프로젝트의 보안 Hook을 보고 관리하고 싶다, **so that** 필요한 Hook만 선택적으로 유지할 수 있다.

Acceptance Criteria:
- [ ] **있을 때**: 이벤트별 카드 (이벤트명 뱃지 + 명령어 목록)
- [ ] 각 Hook 명령어 옆에 삭제 버튼(X)
- [ ] 개별 삭제 시 .claude/settings.json에서 해당 Hook만 제거
- [ ] 마지막 Hook 삭제 시 "없음" 상태로 전환
- [ ] "Hook 전체 초기화" 버튼 → confirm → 전체 제거
- [ ] **없을 때**: "프로젝트 셋업을 실행하면 자동으로 적용됩니다" 안내

Priority: P1 | Effort: M | Dependencies: Story 5

---

### Story 8: 컨벤션 보기/추가/삭제

**As a** 개발자, **I want to** 프로젝트의 컨벤션을 보고 추가/삭제하고 싶다, **so that** 팀의 코딩 규칙을 관리할 수 있다.

Acceptance Criteria:
- [ ] **있을 때**: convention.md의 내용을 파싱하여 규칙별로 표시
- [ ] "컨벤션 추가" → 인라인 폼 (카테고리 + 규칙) → convention.md에 추가
- [ ] 개별 삭제 → convention.md에서 해당 규칙 제거
- [ ] 변경 시 .ddalkak/skills/convention.md 파일 자동 갱신
- [ ] **없을 때**: "프로젝트 셋업을 실행하면 자동으로 생성됩니다" 안내

Priority: P1 | Effort: M | Dependencies: Story 5

---

### Story 9: 스킬 목록 보기

**As a** 개발자, **I want to** 프로젝트에 설치된 스킬 목록과 내용을 보고 싶다, **so that** 에이전트가 어떤 가이드를 따르는지 파악할 수 있다.

Acceptance Criteria:
- [ ] .ddalkak/skills/*.md 파일 목록이 뱃지로 표시된다
- [ ] 스킬 클릭 시 내용을 펼쳐 볼 수 있다 (아코디언 or 모달)
- [ ] 스킬이 없으면 "프로젝트 셋업을 실행하면 자동으로 생성됩니다" 안내

Priority: P1 | Effort: S | Dependencies: Story 5

---

### Story 10: 에이전트 현황 표시

**As a** 개발자, **I want to** 프로젝트의 에이전트와 CLI 설치 상태를 보고 싶다, **so that** 사용 가능한 AI 도구를 파악할 수 있다.

Acceptance Criteria:
- [ ] .claude/agents/*.md 감지된 에이전트가 뱃지로 표시
- [ ] 설치된 CLI 상태 (Claude ✓, Codex ✓, Cursor ✗)
- [ ] 에이전트 클릭 시 AgentDetail로 이동

Priority: P1 | Effort: S | Dependencies: Story 5

---

### Story 11: 비용/태스크 요약

**As a** 개발자, **I want to** 프로젝트의 비용과 최근 태스크를 보고 싶다, **so that** 에이전트 사용 현황을 파악할 수 있다.

Acceptance Criteria:
- [ ] 비용: Total Spend(USD), Input/Output Tokens
- [ ] 비용 없으면 "No cost data yet"
- [ ] 최근 태스크 10개 (상태 뱃지)
- [ ] 태스크 없으면 "No tasks"

Priority: P2 | Effort: S | Dependencies: Story 5

---

## Story Map

```
P0 (Must-have)            P1 (Should-have)         P2 (Nice-to-have)
──────────────────        ─────────────────        ──────────────────
#1 프로젝트 목록           #3 프로젝트 삭제          #11 비용/태스크 요약
#2 프로젝트 등록           #7 Hook 관리
#4 원클릭 프로젝트 셋업    #8 컨벤션 관리
#5 프로젝트 개요           #9 스킬 목록 보기
#6 CLAUDE.md 관리          #10 에이전트 현황
```

## Technical Notes

### API 엔드포인트

**분석/등록:**
- `POST /api/projects/analyze` — 경로 분석 (미리보기용)
- `POST /api/projects` — 프로젝트 등록 (DB에 경로 저장)
- `DELETE /api/projects/:id` — 프로젝트 제거 (DB만)

**원클릭 셋업:**
- `POST /api/projects/:id/setup` — 통합 셋업 (분석 → 생성/스킵 → 결과 리포트)

**개별 파일 관리 (모두 프로젝트 경로 기반 파일 I/O):**
- `GET /api/projects/:id/file/claudemd` — CLAUDE.md 읽기
- `PUT /api/projects/:id/file/claudemd` — CLAUDE.md 쓰기
- `DELETE /api/projects/:id/file/claudemd` — CLAUDE.md 삭제
- `GET /api/projects/:id/file/hooks` — .claude/settings.json의 hooks 읽기
- `PUT /api/projects/:id/file/hooks` — hooks 쓰기
- `DELETE /api/projects/:id/file/hooks` — hooks 제거
- `GET /api/projects/:id/file/conventions` — convention.md 읽기
- `PUT /api/projects/:id/file/conventions` — convention.md 쓰기
- `GET /api/projects/:id/file/skills` — skills 목록
- `GET /api/projects/:id/file/skills/:name` — 특정 스킬 내용

### DB 테이블 (최소)
- `projects` — id, name, path, createdAt (경로 레지스트리)
- `tasks` — 태스크 실행 이력
- `task_runs` — 실행 결과 (비용, 토큰)
- `activity_log` — 이벤트 로그
- `cost_daily` — 비용 집계

### 불필요해진 DB 테이블
- ~~conventions~~ — 파일이 소스 오브 트루스
- ~~guardrails~~ — config.yaml 자체가 불필요
- ~~agents~~ (부분적) — 파일 감지로 대체, 실행 상태 추적용으로만 유지

## Open Questions

1. **프로젝트 수정**: 등록 후 이름/경로 변경 UI 필요한가?
2. **셋업 재실행**: "변경점 업데이트"의 범위 — convention.md에 사용자가 직접 추가한 규칙이 있을 때 덮어쓰지 않아야 하는가?
3. **스킬 수동 편집**: 대시보드에서 스킬 내용을 수정할 수 있어야 하는가, 아니면 보기만?
