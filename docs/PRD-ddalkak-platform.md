# PRD: Ddalkak(딸깍) 플랫폼

## 1. Summary

Ddalkak은 AI 코딩 에이전트(Claude Code, Codex, Cursor)를 안전하게 관리하고 모니터링하는 **로컬 웹 대시보드**다. 개발자가 프로젝트를 등록하면 에이전트 설정, 보안 Hook, 코딩 컨벤션, 실행 비용을 한곳에서 관리할 수 있다. 기존 ai-harness 플러그인의 Hook/컨벤션 엔진을 웹 UI로 확장한 것이다.

---

## 2. Contacts

| 이름 | 역할 | 비고 |
|------|------|------|
| khb1122 | Owner / Developer | 전체 설계 및 구현 |

---

## 3. Background

### Context
AI 코딩 에이전트(Claude Code, Codex, Cursor)가 실무에서 점점 많이 쓰이고 있다. 하지만 에이전트가 어떤 명령을 실행했는지, 얼마나 비용이 들었는지, 위험한 행동을 했는지 한눈에 파악하기 어렵다.

### Why Now
- ai-harness가 Hook + 컨벤션 엔진으로 CLI 기반 거버넌스를 제공 중
- CLI만으로는 모니터링과 관리에 한계 → 웹 대시보드 필요
- Paperclip 스타일의 독립 오케스트레이터 서버가 로드맵에 있었음 (docs/11-cross-team-workflow.md)

### What Changed
- PGlite(인메모리 PostgreSQL)로 별도 DB 서버 없이 로컬 실행 가능해짐
- Express 5 + React 19 기술 스택 안정화

---

## 4. Objective

### 목표
AI 코딩 에이전트를 사용하는 개발자가 **프로젝트별로 에이전트를 안전하게 관리하고, 활동을 모니터링하며, 비용을 추적**할 수 있게 한다.

### 핵심 가치 3축
| 축 | 의미 | 핵심 질문 |
|----|------|----------|
| **Guard** | 안전 | 에이전트가 위험한 행동을 했는가? |
| **Guide** | 품질 | 에이전트가 우리 팀의 컨벤션을 따르는가? |
| **Gear** | 효율 | 에이전트가 얼마나 효율적으로 일했는가? |

### Key Results (SMART)
- KR1: 프로젝트 등록 후 5분 이내에 보안 Hook + 컨벤션 + CLAUDE.md 셋업 완료
- KR2: 에이전트 실행 비용을 일별/프로젝트별/에이전트별로 추적 가능
- KR3: 보안 차단 이벤트를 실시간으로 대시보드에서 확인 가능

---

## 5. Market Segment

### 대상 사용자
**AI 코딩 에이전트를 업무에 활용하는 개발자/팀 리드**

| 페르소나 | 특징 | 핵심 니즈 |
|----------|------|----------|
| 개인 개발자 | Claude Code를 일상적으로 사용 | 비용 추적, 보안 안심 |
| 팀 리드 | 팀원들이 AI 에이전트 사용 | 컨벤션 통일, 활동 모니터링 |
| DevOps/보안 담당 | AI 에이전트의 인프라 접근 우려 | 위험 명령 차단, 감사 로그 |

### 제약 조건
- 로컬 실행 전용 (localhost:7777, 외부 노출 없음)
- 별도 DB 서버 없음 (PGlite 인메모리/파일)
- CLI 에이전트(Claude Code, Codex, Cursor)만 지원

---

## 6. Value Proposition

### 해결하는 문제

| 문제 | 현재 상태 | Ddalkak으로 해결 |
|------|----------|----------------|
| "에이전트가 뭘 했는지 모르겠다" | 터미널 로그 뒤지기 | 활동 로그 + 보안 이벤트 대시보드 |
| "비용이 얼마나 드는지 모르겠다" | 각 서비스 콘솔에서 따로 확인 | 통합 비용 추적 (일별/에이전트별) |
| "에이전트가 위험한 명령을 실행할까 걱정" | 수동 확인 또는 방치 | 보안 Hook 자동 차단 + 실시간 알림 |
| "팀원마다 AI 사용 방식이 다르다" | 구두 합의 | 프로젝트별 컨벤션/스킬 관리 |
| "에이전트 설정이 분산되어 있다" | ~/.claude, ~/.codex 등 각각 | 통합 설정 뷰어 + 편집 |

---

## 7. Solution

### 7.1 페이지별 기능 정의

---

#### 📊 1. Dashboard

**목적**: 전체 프로젝트/에이전트 현황을 한눈에 파악한다.

**사용자 스토리**: 개발자로서, 대시보드를 열면 현재 에이전트 상태와 오늘의 주요 이벤트를 즉시 확인하고 싶다.

**핵심 기능**:
| # | 기능 | 설명 |
|---|------|------|
| D-1 | 메트릭 카드 4개 | 활성 에이전트 수, 실행 중 에이전트, 이번 달 비용, 오늘 보안 이벤트 |
| D-2 | 최근 활동 피드 | 최근 10개 활동 로그 (태스크 완료, 차단, 에러) |
| D-3 | 프로젝트별 빠른 링크 | 등록된 프로젝트 카드 → 클릭 시 ProjectDetail |
| D-4 | 에이전트 상태 요약 | running/idle/error 에이전트 목록 |

**데이터 소스**: `GET /api/dashboard`, `GET /api/activity?limit=10`

**액션**: 카드/링크 클릭으로 상세 페이지 이동

**수락 기준**:
- [ ] 서버 시작 후 대시보드 로드 시 3초 이내 모든 카드 렌더링
- [ ] 실시간 데이터 반영 (10초 stale time)
- [ ] 에이전트 0개일 때 빈 상태 안내 표시

---

#### 📂 2. Projects

**목적**: 프로젝트를 등록하고 목록을 관리한다.

**사용자 스토리**: 개발자로서, 내 프로젝트를 등록하고 어떤 에이전트/설정이 적용되어 있는지 한눈에 보고 싶다.

**핵심 기능**:
| # | 기능 | 설명 |
|---|------|------|
| P-1 | 프로젝트 목록 | 카드 형태로 전체 프로젝트 표시 (이름, 경로, 스택 뱃지, 에이전트 수) |
| P-2 | 프로젝트 추가 모달 | 경로 입력 → 자동 분석 미리보기 (스택, git, CLI 감지) → 등록 |
| P-3 | 프로젝트 삭제 | 확인 후 삭제 (cascade: 에이전트, 태스크, 컨벤션 등 전부 삭제) |
| P-4 | 검색/필터 | 프로젝트명으로 필터링 |

**데이터 소스**: `GET /api/projects`, `POST /api/projects/analyze`, `POST /api/projects`

**액션**:
- 프로젝트 카드 클릭 → ProjectDetail 이동
- "프로젝트 추가" 버튼 → 등록 모달
- 삭제 아이콘 → 확인 다이얼로그 → 삭제

**수락 기준**:
- [ ] 경로 입력 후 500ms debounce로 분석 미리보기 표시
- [ ] 이름은 경로 마지막 디렉토리에서 자동 추출 (수정 가능)
- [ ] 등록 성공 시 목록 갱신 + 해당 프로젝트 상세 페이지로 이동
- [ ] 잘못된 경로 입력 시 에러 안내

---

#### 📋 3. ProjectDetail

**목적**: 개별 프로젝트의 현황을 보고, 초기 셋업하고, 설정을 관리한다.

**사용자 스토리**: 개발자로서, 프로젝트를 등록한 후 한 페이지에서 CLAUDE.md, Hook, 컨벤션 등을 셋업하고 관리하고 싶다.

**핵심 기능**:
| # | 기능 | 설명 |
|---|------|------|
| PD-1 | 프로젝트 개요 | 이름, 경로, git 정보, 기술 스택 뱃지 |
| PD-2 | CLAUDE.md 관리 | **보기**: 내용 미리보기 + 전체 보기 토글 |
| | | **생성**: 스택 기반 기본 CLAUDE.md 자동 생성 |
| | | **수정**: 인라인 텍스트 에디터로 편집 → 저장 |
| | | **삭제**: 확인 후 파일 삭제 |
| PD-3 | 에이전트 현황 | 감지된 .claude/agents/*.md 목록 + DB 등록 에이전트 + CLI 설치 상태 |
| PD-4 | Hook 관리 | **보기**: 적용 중인 Hook 목록 (이벤트 + 명령어) |
| | | **적용**: 보안 Hook(block-dangerous, secret-scanner) 원클릭 적용 |
| | | **초기화**: Hook 전체 제거 |
| PD-5 | 스킬 목록 | .ddalkak/skills/ 파일 목록 표시 |
| PD-6 | 컨벤션 관리 | **보기**: 적용 중인 컨벤션 목록 (카테고리 + 규칙) |
| | | **자동 생성**: 스택 기반 기본 컨벤션 생성 |
| | | **수동 추가**: 카테고리 + 규칙 입력 폼 |
| | | **삭제**: 개별 컨벤션 삭제 |
| PD-7 | 비용 요약 | 이 프로젝트의 누적 비용/토큰 표시 |
| PD-8 | 최근 태스크 | 이 프로젝트의 최근 태스크 10개 (상태 뱃지) |
| PD-9 | 관련 프로젝트 | depends_on 관계 표시, 클릭 시 해당 프로젝트로 이동 |

**데이터 소스**: 
- `GET /api/projects/:id` — 프로젝트 기본 정보
- `POST /api/projects/analyze` — 실시간 분석 (CLAUDE.md, agents, hooks, skills, conventions, CLI)
- `GET /api/agents` → projectId 필터
- `GET /api/tasks` → projectId 필터
- `GET /api/costs/by-project`
- `GET /api/conventions/:projectId`
- `GET /api/relations/:projectId`

**셋업 액션 (빈 항목에 표시)**:
- "CLAUDE.md 생성" → `POST /api/projects/:id/setup/claudemd`
- "보안 Hook 적용" → `POST /api/projects/:id/setup/hooks`
- "컨벤션 자동 생성" → `POST /api/projects/:id/setup/conventions`

**관리 액션 (있는 항목에 표시)**:
- CLAUDE.md 수정 → `PATCH /api/projects/:id/setup/claudemd`
- CLAUDE.md 삭제 → `DELETE /api/projects/:id/setup/claudemd`
- Hook 초기화 → `DELETE /api/projects/:id/setup/hooks`
- 컨벤션 추가 → `POST /api/conventions/:projectId`
- 컨벤션 삭제 → `DELETE /api/conventions/:projectId/:id`

**수락 기준**:
- [ ] path가 있는 프로젝트 진입 시 분석 결과가 각 섹션에 표시 (로딩 스켈레톤)
- [ ] path가 없는 프로젝트는 기본 정보만 표시
- [ ] 셋업 버튼 클릭 후 성공 시 해당 섹션 즉시 갱신
- [ ] CLAUDE.md 수정 시 인라인 에디터 → 저장/취소 → 성공 시 뷰 모드로 복귀
- [ ] 삭제 시 confirm 다이얼로그 → 성공 시 "없음" 상태로 전환

---

#### 🤖 4. Agents

**목적**: 전체 에이전트 목록을 보고, 등록/삭제한다.

**사용자 스토리**: 개발자로서, 어떤 에이전트가 어떤 프로젝트에 연결되어 있고 현재 상태가 무엇인지 한눈에 보고 싶다.

**핵심 기능**:
| # | 기능 | 설명 |
|---|------|------|
| A-1 | 에이전트 목록 | 카드 형태 (이름, 어댑터 아이콘, 상태 뱃지, 소속 프로젝트) |
| A-2 | 에이전트 추가 | 프로젝트 선택 + 이름 + 어댑터 타입(Claude/Codex/Cursor) |
| A-3 | 에이전트 삭제 | 확인 후 삭제 |
| A-4 | 상태 필터 | 전체/running/idle/error 필터 |

**데이터 소스**: `GET /api/agents`, `POST /api/agents`, `DELETE /api/agents/:id`

**액션**:
- 에이전트 카드 클릭 → AgentDetail 이동
- "에이전트 추가" → 등록 모달
- 삭제 아이콘 → 확인 후 삭제

**수락 기준**:
- [ ] 에이전트 상태 뱃지가 색상으로 구분 (running=녹, idle=회, error=적)
- [ ] 어댑터 타입별 아이콘 구분 (C=Claude, X=Codex, Cu=Cursor)
- [ ] 클릭 시 AgentDetail로 이동

---

#### 🔍 5. AgentDetail

**목적**: 개별 에이전트의 상세 정보와 실행 이력을 본다.

**사용자 스토리**: 개발자로서, 특정 에이전트가 얼마나 일했고, 비용이 얼마이고, 정상 동작 중인지 확인하고 싶다.

**핵심 기능**:
| # | 기능 | 설명 |
|---|------|------|
| AD-1 | 에이전트 정보 | 이름, 어댑터, 상태, config JSON |
| AD-2 | Heartbeat 상태 | 마지막 heartbeat 시각, healthy/stale 표시 |
| AD-3 | 실행 이력 | taskRuns 기반 (시작/종료 시각, exit code, 비용) |
| AD-4 | 누적 비용 | 이 에이전트의 총 비용/토큰 |
| AD-5 | 최근 활동 | 이 에이전트의 최근 activity_log |

**데이터 소스**: 
- `GET /api/agents/:id`
- `GET /api/tasks` → agentId 필터
- `GET /api/costs/by-agent`
- `GET /api/activity?agentId=X&limit=20`

**액션**: 뒤로 가기 (Agents 목록)

**수락 기준**:
- [ ] Heartbeat 30초 초과 시 "stale" 경고 표시
- [ ] 실행 이력이 시간순 정렬
- [ ] 비용이 $0.0000 형식으로 표시

---

#### ✅ 6. Tasks

**목적**: 태스크를 생성하고, 에이전트에 할당하고, 실행 상태를 추적한다.

**사용자 스토리**: 개발자로서, 에이전트에게 할 일을 지시하고 진행 상황을 실시간으로 보고 싶다.

**핵심 기능**:
| # | 기능 | 설명 |
|---|------|------|
| T-1 | 태스크 목록 | 전체 태스크 (상태 뱃지: todo/in_progress/done/blocked) |
| T-2 | 태스크 생성 | 프로젝트 선택 + 제목 + 설명 + 에이전트 할당(선택) |
| T-3 | 태스크 실행 | "실행" 버튼 → 에이전트에게 태스크 전달 → 실시간 로그(SSE) |
| T-4 | 상태 변경 | 수동으로 상태 변경 (todo↔blocked 등) |
| T-5 | 실행 로그 | SSE 스트리밍으로 실시간 로그 표시 |
| T-6 | 프로젝트 필터 | 특정 프로젝트의 태스크만 보기 |

**데이터 소스**: 
- `GET /api/tasks`
- `POST /api/tasks`
- `PATCH /api/tasks/:id`
- `POST /api/tasks/:id/run`
- `GET /api/tasks/runs/:runId/stream` (SSE)

**액션**:
- "태스크 추가" → 생성 모달
- "실행" 버튼 → 에이전트 실행 + 로그 패널 오픈
- 상태 뱃지 클릭 → 상태 변경

**수락 기준**:
- [ ] 태스크 생성 시 프로젝트 필수, 에이전트 선택적 (미지정 시 자동 라우팅)
- [ ] "실행" 클릭 후 SSE로 실시간 로그 스트리밍
- [ ] 완료/실패 시 상태 뱃지 자동 갱신
- [ ] 에이전트 미할당 상태에서 실행 시 idle 에이전트 자동 선택

---

#### 🏢 7. OrgChart

**목적**: 프로젝트와 에이전트의 관계를 시각적으로 파악한다.

**사용자 스토리**: 팀 리드로서, 어떤 프로젝트에 어떤 에이전트가 연결되어 있고 현재 상태인지 조직도처럼 보고 싶다.

**핵심 기능**:
| # | 기능 | 설명 |
|---|------|------|
| O-1 | 트리 시각화 | 프로젝트 → 에이전트 계층 구조 |
| O-2 | 상태 색상 | 에이전트 상태별 색상 (running=녹, idle=회, error=적) |
| O-3 | 프로젝트 관계 | depends_on 연결선 |
| O-4 | 노드 클릭 | 프로젝트/에이전트 상세 페이지로 이동 |

**데이터 소스**: `GET /api/projects`, `GET /api/agents`, `GET /api/relations`

**액션**: 노드 클릭 → 상세 페이지 이동

**수락 기준**:
- [ ] CSS/SVG 기반 시각화 (외부 라이브러리 없이)
- [ ] 프로젝트 0개일 때 빈 상태 안내
- [ ] 노드 클릭 시 해당 상세 페이지로 네비게이션

---

#### 💰 8. Costs

**목적**: 에이전트 실행 비용을 다양한 축으로 추적한다.

**사용자 스토리**: 개발자로서, AI 에이전트 사용 비용이 얼마인지, 어떤 에이전트/프로젝트가 비용이 높은지 파악하고 싶다.

**핵심 기능**:
| # | 기능 | 설명 |
|---|------|------|
| C-1 | 월간 총 비용 | 이번 달 총 USD + 토큰 수 |
| C-2 | 일별 차트 | 최근 14일 비용 추이 (막대 차트) |
| C-3 | 에이전트별 분류 | 에이전트별 비용 테이블 (정렬 가능) |
| C-4 | 프로젝트별 분류 | 프로젝트별 비용 테이블 |
| C-5 | 기간 필터 | 7일/14일/30일 선택 |

**데이터 소스**: 
- `GET /api/costs/summary`
- `GET /api/costs/daily?days=14`
- `GET /api/costs/by-agent`
- `GET /api/costs/by-project`

**액션**: 기간 필터 변경, 에이전트/프로젝트 클릭 → 상세 이동

**수락 기준**:
- [ ] 비용 데이터 없을 때 "$0.0000" 표시 (에러 아님)
- [ ] 일별 차트가 CSS 기반 막대 그래프로 렌더링
- [ ] 토큰 수는 K/M 단위로 축약 표시

---

#### 📈 9. Metrics

**목적**: 에이전트/프로젝트의 성능 메트릭을 분석한다.

**사용자 스토리**: 팀 리드로서, 에이전트의 성공률과 평균 실행 시간을 보고 효율을 판단하고 싶다.

**핵심 기능**:
| # | 기능 | 설명 |
|---|------|------|
| M-1 | 시스템 메트릭 | 전체 에이전트 수, 활용률, 평균 성공률, 총 비용 |
| M-2 | 에이전트별 메트릭 | 실행 횟수, 성공률, 평균 시간, 비용/태스크 |
| M-3 | 프로젝트별 메트릭 | 태스크 수, 완료율, 총 비용 |
| M-4 | 탭 전환 | System / Agents / Projects 탭 |

**데이터 소스**: 
- `GET /api/metrics/system`
- `GET /api/metrics/agents`
- `GET /api/metrics/projects`

**액션**: 탭 전환

**수락 기준**:
- [ ] 데이터 없을 때 "아직 실행 이력이 없습니다" 안내
- [ ] 성공률은 퍼센트로 표시 (예: 85.7%)
- [ ] 평균 시간은 분/초 단위로 표시

---

#### ⚙️ 10. Settings

**목적**: Claude Code, Codex, Cursor의 전역 설정을 확인하고 수정한다.

**사용자 스토리**: 개발자로서, 설치된 AI 에이전트들의 설정을 한곳에서 보고 수정하고 싶다.

**핵심 기능**:
| # | 기능 | 설명 |
|---|------|------|
| S-1 | 에이전트 카드 | Claude/Codex/Cursor 3종 카드 (설치 여부, 버전) |
| S-2 | Claude 설정 | CLAUDE.md 편집, MCP 서버 관리, Hook 목록, 플러그인 관리 |
| S-3 | Codex 설정 | API 키 설정, 모델 선택, provider 설정 |
| S-4 | Cursor 설정 | 설정 파일 경로, Rules 파일 관리 |
| S-5 | MCP 서버 테스트 | 개별/전체 MCP 서버 연결 테스트 |

**데이터 소스**: 
- `GET /api/settings`
- `GET /api/settings/:type`
- `POST /api/settings/:type/mcp`
- `DELETE /api/settings/:type/mcp/:name`
- `PATCH /api/settings/:type/config`

**액션**: 에이전트 카드 클릭 → 해당 설정 확장, MCP 추가/삭제/테스트, 설정 값 변경

**수락 기준**:
- [ ] 미설치 에이전트는 "설치되지 않음" + 설치 안내 표시
- [ ] MCP 서버 테스트 결과 reachable/unreachable 표시
- [ ] 설정 변경 시 즉시 파일에 반영

---

#### 📏 11. Conventions

**목적**: 프로젝트별 코딩 컨벤션을 관리한다.

**사용자 스토리**: 팀 리드로서, 프로젝트의 코딩 규칙을 정의하고 에이전트가 따르게 하고 싶다.

**핵심 기능**:
| # | 기능 | 설명 |
|---|------|------|
| CV-1 | 프로젝트 선택 | 드롭다운으로 프로젝트 선택 |
| CV-2 | 컨벤션 목록 | 카테고리별 그룹화 (naming, style, structure 등) |
| CV-3 | 컨벤션 추가 | 카테고리 + 규칙 입력 폼 |
| CV-4 | 컨벤션 수정 | 인라인 편집 |
| CV-5 | 컨벤션 삭제 | 개별 삭제 |
| CV-6 | 활성/비활성 토글 | 개별 컨벤션 on/off |
| CV-7 | 파일 동기화 | DB 변경 → .ddalkak/conventions.yaml 자동 반영 |

**데이터 소스**: 
- `GET /api/conventions/:projectId`
- `POST /api/conventions/:projectId`
- `PATCH /api/conventions/:projectId/:id`
- `DELETE /api/conventions/:projectId/:id`

**액션**: CRUD + 토글

**수락 기준**:
- [ ] 컨벤션 변경 시 .ddalkak/conventions.yaml에 자동 동기화
- [ ] 카테고리별 그룹화 표시
- [ ] enabled 토글 시 즉시 반영

---

#### 🛡️ 12. Security

**목적**: 보안 차단 이벤트를 실시간으로 모니터링한다.

**사용자 스토리**: DevOps 담당으로서, AI 에이전트가 차단당한 위험 명령을 확인하고 패턴을 파악하고 싶다.

**핵심 기능**:
| # | 기능 | 설명 |
|---|------|------|
| SC-1 | 이벤트 피드 | security.* 이벤트 시간순 목록 |
| SC-2 | 이벤트 상세 | 차단 사유, 명령어, 도구명, 시각 |
| SC-3 | 이벤트 타입 필터 | DANGEROUS_COMMAND, SECRET_DETECTED, INFRA_CHANGE 등 |
| SC-4 | 오늘 카운트 | 오늘 발생한 보안 이벤트 수 |

**데이터 소스**: 
- `GET /api/activity/security`
- `GET /api/activity/counts`

**액션**: 필터 변경, 이벤트 상세 펼치기

**수락 기준**:
- [ ] 새 이벤트 발생 시 목록 상단에 표시 (새로고침 시)
- [ ] 이벤트 없을 때 "차단된 이벤트가 없습니다" 안내
- [ ] detail JSON의 주요 필드를 읽기 쉽게 포맷

---

#### 📝 13. Activity

**목적**: 전체 시스템의 감사 로그를 조회한다.

**사용자 스토리**: 팀 리드로서, 에이전트가 수행한 모든 활동의 이력을 시간순으로 확인하고 싶다.

**핵심 기능**:
| # | 기능 | 설명 |
|---|------|------|
| AC-1 | 활동 로그 목록 | 전체 activity_log 시간순 (페이지네이션) |
| AC-2 | 이벤트 타입 필터 | task.started, task.completed, task.failed, security.*, agent.timeout 등 |
| AC-3 | 프로젝트 필터 | 특정 프로젝트의 활동만 |
| AC-4 | 상세 보기 | detail JSON 펼치기 |

**데이터 소스**: 
- `GET /api/activity?limit=50&offset=0`
- `GET /api/activity?eventType=task.completed`
- `GET /api/activity?projectId=X`

**액션**: 필터 변경, 페이지네이션, 상세 펼치기

**수락 기준**:
- [ ] 50개 단위 페이지네이션
- [ ] 이벤트 타입별 아이콘/색상 구분
- [ ] 에이전트/프로젝트 이름이 ID가 아닌 이름으로 표시

---

### 7.2 사이드바 네비게이션 구조

```
📊 Dashboard
─────────────
📂 Projects
🤖 Agents
✅ Tasks
🏢 OrgChart
─────────────
💰 Costs
📈 Metrics
─────────────
⚙️ Settings
📏 Conventions
🛡️ Security
📝 Activity
```

### 7.3 Technology

| 계층 | 기술 |
|------|------|
| Frontend | React 19 + Vite 6 + TailwindCSS 4 + React Query 5 |
| Backend | Express 5 + TypeScript |
| Database | PGlite (embedded PostgreSQL) + Drizzle ORM |
| CLI | Node.js (bin: ddalkak) |
| 실행 | 로컬 전용 (127.0.0.1:7777) |

### 7.4 Assumptions

- 사용자는 Claude Code, Codex, Cursor 중 최소 1개를 사용한다
- 프로젝트 경로는 로컬 파일시스템에 존재한다
- 동시 사용자는 1명이다 (로컬 앱)
- PGlite 데이터는 ~/.ddalkak/data/에 영속화된다

---

## 8. Release

### v1.0 (현재 구현 완료)
- 전체 13개 페이지 기본 구현
- 프로젝트 등록 + 자동 분석
- 초기 셋업 (CLAUDE.md, Hook, 컨벤션) 원클릭 생성
- CRUD (생성, 수정, 삭제) 지원
- 비용 추적, 보안 모니터링, 메트릭

### v1.1 (후속)
- 프로젝트 등록 시 자동 컨벤션 분석 (코드 기반 AI 분석)
- 실시간 SSE 로그 스트리밍 UI
- 태스크 실행 + 결과 확인 전체 플로우 완성
- 다크/라이트 테마 전환

### v2.0 (중기)
- 멀티 프로젝트 워크플로우 (프로젝트 간 태스크 체인)
- npm 패키지 배포 (`npx ddalkak start`)
- Claude 플러그인 마켓플레이스 등록
