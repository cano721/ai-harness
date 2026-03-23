# AI Harness - OMC/OMX 연동

## 연동 개요

AI 하네스는 OMC/OMX를 **대체하지 않고 그 위에 회사 레이어를 얹는 방식**으로 동작한다.

```
사용자 요청
    ↓
┌─────────────────────────┐
│  Harness Context Layer  │  ← 팀/프로젝트 CLAUDE.md 자동 주입
└────────────┬────────────┘
             ↓
┌─────────────────────────┐
│  Harness Hook (Pre)     │  ← 회사 정책 검증 (보안, 권한, 규칙)
└────────────┬────────────┘
             ↓ pass
┌─────────────────────────┐
│  OMC Hook (Pre)         │  ← OMC 기능 (상태 관리, 에이전트 라우팅)
└────────────┬────────────┘
             ↓
┌─────────────────────────┐
│  도구 실행               │
└────────────┬────────────┘
             ↓
┌─────────────────────────┐
│  OMC Hook (Post)        │  ← OMC 후처리
└────────────┬────────────┘
             ↓
┌─────────────────────────┐
│  Harness Hook (Post)    │  ← 회사 검증 (lint, 보안 스캔, 감사 로깅)
└────────────┬────────────┘
             ↓
결과 반환
```

## Hook 체이닝

### 실행 순서

```
PreToolUse:
  1. harness/global/hooks/*     (회사 공통 - 항상 먼저)
  2. harness/teams/{team}/hooks/* (팀별 - 그다음)
  3. omc hooks                  (OMC 자체 Hook - 마지막)

PostToolUse:
  1. omc hooks                  (OMC 자체 Hook - 먼저)
  2. harness/teams/{team}/hooks/* (팀별)
  3. harness/global/hooks/*     (회사 공통 - 마지막)
```

Pre는 하네스가 먼저(차단 우선), Post는 OMC가 먼저(OMC 상태 정리 후 하네스 검증).

## OMC 모드별 하네스 설정

### autopilot 모드

```json
{
  "mode": "autopilot",
  "harness": {
    "require_approval_gate": ["db-migration", "deploy", "api-breaking-change"],
    "auto_verify": ["lint", "test", "security-scan"],
    "guardrails": {
      "max_cost_usd": 5.0,
      "max_files_changed": 20,
      "max_execution_minutes": 30
    }
  }
}
```

### ralph 모드

```json
{
  "mode": "ralph",
  "harness": {
    "max_loop_count": 10,
    "require_progress_per_loop": true,
    "verification_criteria": ["all_tests_pass", "no_lint_errors", "no_security_warnings"],
    "escalate_after_loops": 5
  }
}
```

### team 모드

```json
{
  "mode": "team",
  "harness": {
    "role_mapping": {
      "team-plan": "teams/planning/CLAUDE.md",
      "team-exec:frontend": "teams/frontend/CLAUDE.md",
      "team-exec:backend": "teams/backend/CLAUDE.md"
    },
    "agent_overrides": {
      "code-reviewer": "custom-agents/company-reviewer.md",
      "architect": "custom-agents/company-architect.md"
    }
  }
}
```

## 커스텀 에이전트 & 스킬

| 항목 | 설명 |
|------|------|
| **company-reviewer** | 기본 code-reviewer + 회사 네이밍 컨벤션, API 버저닝, 마이그레이션 스크립트 검증 |
| **company-architect** | 기본 architect + 회사 MSA 구조, 공통 모듈 우선, 인프라 제약 반영 |
| **/company-deploy** | 회사 배포 프로세스 (빌드→테스트→스테이징→프로덕션) |
| **/company-hotfix** | 핫픽스 프로세스 (브랜치→수정→긴급리뷰→배포) |
