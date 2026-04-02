# AI Harness - 로드맵

## Phase 1: 기반 구축 (1~2주)

**목표**: 최소한의 하네스로 즉시 효과를 얻는다.

**전제조건**:
- @ai-harness/core CLI 엔진 및 Hook 런타임이 구현되어 있어야 함
- 또는 기존 Claude Code의 settings.json Hook 시스템을 직접 활용하여 시작 (CLI 없이 수동 설정)

| # | 항목 | 설명 | 산출물 |
|---|------|------|--------|
| 1-1 | Global CLAUDE.md 작성 | 회사 공통 코딩 원칙, 보안 정책 | `global/CLAUDE.md` |
| 1-2 | 위험 명령 차단 Hook | rm -rf, DROP, force push 등 차단 | `global/hooks/block-dangerous.sh` |
| 1-3 | 감사 로깅 Hook | 모든 AI 액션 기록 | `global/hooks/audit-logger.sh` |
| 1-4 | 민감 정보 스캐너 Hook | .env, 시크릿 유출 방지 | `global/hooks/secret-scanner.sh` |
| 1-5 | harness CLI 기본 | init, switch-team, validate | `cli/harness-*.sh` |

---

## Phase 2: 팀별 확장 (3~4주)

**목표**: 각 팀이 자신의 규칙과 도구를 독립적으로 운영한다.

| # | 항목 | 설명 | 산출물 |
|---|------|------|--------|
| 2-1 | 팀별 CLAUDE.md 작성 | 기획/디자인/FE/BE/QA/DevOps 각 팀 규칙 | `teams/*/CLAUDE.md` |
| 2-2 | 팀별 Hook 구현 | 각 팀 전용 검증 로직 | `teams/*/hooks/*` |
| 2-3 | 팀별 Skill 정의 | 팀 업무 특화 커맨드 | `teams/*/skills/*` |
| 2-4 | OMC Hook 체이닝 | 하네스 Hook ↔ OMC Hook 연동 | `omc-integration/harness-hook-bridge.js` |
| 2-5 | OMC 모드별 설정 | autopilot/ralph/team guardrail | `omc-integration/mode-configs/*` |

---

## Phase 3: 고도화 (5~8주)

**목표**: 자동화 범위 확대, 가시성 확보, 지속적 개선 체계 구축.

| # | 항목 | 설명 |
|---|------|------|
| 3-1 | 커스텀 에이전트 | 회사 전용 reviewer/architect |
| 3-2 | 워크플로우 엔진 | 업무 유형별 자동 파이프라인 |
| 3-3 | 대시보드 | AI 사용량, 비용, 품질 메트릭 시각화 |
| 3-4 | 비용 추적 | API 호출 비용 집계/알림 |
| 3-5 | 팀 간 워크플로우 | 기획→디자인→개발→QA 연결 파이프라인 |
| 3-6 | 온보딩 자동화 | 새 팀원/프로젝트 자동 셋업 |

---

## Phase 4: Control Plane 완성도 + Execution V2

**목표**: setup-first control plane 위에 queue/worker 기반 execution plane을 얹는다.

| # | 항목 | 설명 |
|---|------|------|
| 4-1 | setup control plane polish | Project Detail / Tasks / Run Inspector의 loading, recovery, activity UX 보강 |
| 4-2 | workflow task model 강화 | phase objective, checklist policy, reviewer separation을 task/run 정책으로 승격 |
| 4-3 | dispatch 경계 분리 | route에서 direct run 호출 제거, dispatcher/queue/service 경계 도입 |
| 4-4 | local worker queue mode | local runtime도 queue lease 기반으로 실행 |
| 4-5 | remote worker | worker registration, heartbeat, capacity 기반 분산 실행 |
| 4-6 | hard separation orchestration | review phase의 agent/worker/runtime 분리 강제 |

참고:
- 현재 완료/남은 일은 `29-next-steps.md`
- 실행 계층 확장 설계는 `30-execution-v2.md`

---

## 우선순위 원칙

1. **안전 > 효율 > 편의**: 사고 방지가 최우선
2. **작게 시작, 빠르게 검증**: Phase 1만으로도 즉시 가치 제공
3. **팀 자율성 존중**: global은 최소한, 팀별 커스텀에 자유도 부여
4. **기존 도구 활용**: OMC/OMX를 최대한 활용하여 중복 개발 방지
