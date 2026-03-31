# AI Harness - Task Workflow 시스템

## 개요

기존 팀 구성 기반 워크플로우를 **작업 유형 기반 task-workflow**로 전환합니다.

### 기존 방식 (v1 — deprecated)
- 팀 수에 따라 정적으로 워크플로우 결정 (Pipeline, Fan-out, Producer-Reviewer, Supervisor)
- 문제: init이 단일 팀 기준이라 Pipeline만 생성됨

### 새 방식 (v2)
- **작업 유형**에 따라 동적으로 워크플로우 결정
- 에이전트 분리를 구조적으로 강제 (self-review 방지)
- OMC와 연동하여 실행 수준 결정

## Task Workflow 구조

```yaml
name: 워크플로우 이름
trigger_keywords: [트리거 키워드들]
phases:
  - name: 단계명
    agent: 실행 에이전트
    enforce_separation: true/false
    steps: [구체적 작업 단계]
orchestration:
  default: "skill"      # OMC 없이도 동작
  enhanced: "omc-team"  # OMC 있으면 완전 분리
```

## 제공 워크플로우

| 워크플로우 | 트리거 | 단계 |
|-----------|--------|------|
| **implement-feature** | "만들어줘", "기능 구현" | architect 분석 → developer 구현 → reviewer 리뷰 → 수정 |
| **fix-bug** | "버그 수정", "에러 해결" | developer 진단 → developer 수정 → reviewer 리뷰 → 회귀 확인 |
| **refactor** | "리팩토링", "구조 개선" | architect 계획 → developer 구현 → reviewer 검증 |
| **code-review** | "리뷰해줘", "PR 리뷰" | reviewer 단독 리뷰 |
| **design** | "설계해줘", "아키텍처" | architect 분석 → architect 설계 → reviewer 검토 |

## Self-Review 방지

모든 워크플로우의 review phase에 `enforce_separation: true`가 적용됩니다.

| 실행 방식 | 분리 수준 |
|----------|----------|
| **Skill (기본)** | Agent 도구로 서브에이전트 호출 → 컨텍스트 분리 |
| **OMC team (강화)** | 별도 tmux pane/프로세스 → 완전 분리 |

구현 에이전트와 리뷰 에이전트가 같은 컨텍스트를 공유하지 않으므로, 자기 코드를 자기가 리뷰하는 문제를 구조적으로 방지합니다.

## 오케스트레이션

### OMC 없이 (Skill 기반)
```
사용자: "이 기능 만들어줘"
  → CLAUDE.md의 지시에 따라 task-workflow 매칭
  → Skill이 오케스트레이터 역할
  → 각 phase를 Agent 도구로 서브에이전트 호출
```

### OMC 있을 때 (team 모드)
```
사용자: "이 기능 만들어줘"
  → OMC team 모드가 task-workflow 로드
  → 각 phase를 별도 CLI 프로세스로 실행
  → 완전한 프로세스 분리 보장
```

### 향후 (v3+)
독립 오케스트레이터 서버 검토 (Paperclip 스타일)

## 기존 프리셋/워크플로우와의 관계

| 기존 | 새 체계 | 상태 |
|------|---------|------|
| `templates/presets/crud.yaml` | `task-workflows/implement-feature.yaml`에 흡수 | deprecated |
| `templates/presets/bugfix.yaml` | `task-workflows/fix-bug.yaml`에 흡수 | deprecated |
| `templates/presets/refactor.yaml` | `task-workflows/refactor.yaml`에 흡수 | deprecated |
| `templates/workflows/pipeline.md.tmpl` | task-workflow의 기본 실행 패턴 | deprecated |
| `templates/workflows/fan-out-fan-in.md.tmpl` | 향후 멀티팀 지원 시 재검토 | deprecated |
| `templates/workflows/producer-reviewer.md.tmpl` | task-workflow의 review phase로 대체 | deprecated |
| `templates/workflows/supervisor.md.tmpl` | 향후 멀티팀 지원 시 재검토 | deprecated |

기존 파일은 하위 호환을 위해 유지하되, 신규 init에서는 task-workflow를 사용합니다.

## OMC 모드와의 관계

OMC 모드는 task-workflow 위에 얹히는 **실행 오버레이**입니다.

```
Task Workflow: implement-feature (분석 → 구현 → 리뷰 → 수정)
     +
OMC Mode: ralph (반복 실행)
     =
Result: fix phase에서 ralph식 반복 (테스트 통과할 때까지)
```

| OMC 모드 | 워크플로우와의 관계 |
|----------|-------------------|
| **autopilot** | 워크플로우 전체를 자동 실행 |
| **ralph** | fix/regression phase에서 반복 루프 |
| **team** | 각 phase를 별도 프로세스로 분리 실행 |
| **ultrawork** | 독립적인 여러 워크플로우를 병렬 실행 |
