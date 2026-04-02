# AI Harness - Execution V2

이 문서는 현재의 direct local run 구조를 `queue + worker + orchestration` 구조로 확장하기 위한 설계 초안이다.

## 1. 왜 필요한가

현재 구조는 다음과 같다.

- `POST /tasks/:id/run`
- route가 즉시 `runTask(...)`를 호출
- `task-runner.service.ts`가 adapter를 직접 실행
- run 상태와 activity를 같은 프로세스에서 처리

이 구조는 local MVP에는 적합하지만 아래 한계가 있다.

- task dispatch와 execution이 강하게 결합됨
- remote worker를 붙이기 어려움
- review separation을 "다른 agent 추천" 수준 이상으로 강제하기 어려움
- queueing, retry, cancel, capacity 관리가 없음

Execution V2의 목표는 이 결합을 풀고, control plane 위에 execution plane을 올리는 것이다.

## 2. 목표

### 기능 목표
- task run을 queue에 넣을 수 있어야 한다.
- worker가 queue에서 run을 lease 받아 실행할 수 있어야 한다.
- review phase는 다른 worker / agent / runtime으로 강제할 수 있어야 한다.
- run retry, cancel, timeout, stale lease 회수를 지원해야 한다.

### 제품 목표
- setup-first product 정체성은 유지한다.
- `Project Detail`과 `Tasks`는 orchestration 상태를 읽는 control plane이 된다.
- execution layer는 local adapter와 remote worker를 모두 지원한다.

## 3. 제안 아키텍처

```text
UI / Control Plane
  ├─ Project Detail
  ├─ Tasks
  └─ Run Inspector
        │
        ▼
API Layer
  ├─ tasks route
  ├─ workers route
  └─ runs route
        │
        ▼
Orchestration Layer
  ├─ task-dispatcher.service
  ├─ run-queue.service
  ├─ worker-registry.service
  └─ phase-policy.service
        │
        ▼
Execution Layer
  ├─ local worker
  ├─ remote worker
  └─ adapter runtime (claude/codex/cursor)
```

## 4. 핵심 컴포넌트

### 4-1. Task Dispatcher
역할:
- `run now` 요청을 queue request로 변환
- task/workflow/phase policy 확인
- 어떤 worker capability가 필요한지 계산
- queue item 생성

핵심 입력:
- task id
- requested agent id
- workflow phase
- separation policy

핵심 출력:
- queued run request
- dispatch decision metadata

### 4-2. Run Queue
역할:
- 실행 대기 중인 run 요청 저장
- worker가 lease 할 수 있는 next job 제공
- timeout/stale lease 회수
- retry scheduling

최소 상태:
- `queued`
- `leased`
- `running`
- `completed`
- `failed`
- `cancelled`

### 4-3. Worker Registry
역할:
- worker 등록
- heartbeat 관리
- capability/adapter/runtime 보고
- idle/busy capacity 추적

worker 메타 예시:
- worker id
- runtime kind (`local`, `remote`)
- adapter types (`claude_local`, `codex_local`, ...)
- supported capabilities (`implementation`, `review`, `validation`)
- concurrency
- last heartbeat

### 4-4. Phase Policy Service
역할:
- 현재 phase가 어떤 worker/agent/runtime을 요구하는지 계산
- separation rule 위반 여부 판단
- checklist gating과 phase handoff policy를 실행 계층으로 올림

예시:
- review phase + `enforceSeparation=true`
  - lastCompletedAgentId 와 다른 agent 필요
  - 같은 worker reuse 금지 가능
  - capability `review pass` 필요

## 5. 데이터 모델 초안

### Run Request
- id
- taskId
- projectId
- requestedAgentId?
- requestedBy
- queueState
- leaseOwnerWorkerId?
- leaseExpiresAt?
- attempts
- priority
- phaseId
- separationRequirement
- capabilityRequirement[]

### Worker
- id
- name
- runtimeKind
- adapterTypes[]
- capabilityLabels[]
- status
- concurrency
- activeRunCount
- lastHeartbeat

### Run Attempt
- id
- runRequestId
- workerId
- agentId
- startedAt
- completedAt
- exitCode
- timedOut
- outcome

## 6. API 방향

### 기존 API 유지
- `POST /tasks/:id/run`

하지만 내부 동작은 바뀐다.
- v1: direct run
- v2: dispatch enqueue

응답 예시:
- `accepted`
- `queuedRunId`
- `queueState`

### 추가 API 후보
- `POST /workers/register`
- `POST /workers/:id/heartbeat`
- `POST /workers/:id/lease`
- `POST /workers/:id/runs/:runRequestId/complete`
- `POST /workers/:id/runs/:runRequestId/fail`

## 7. 점진적 마이그레이션

### Phase A. Internal Boundary First
- `tasks route`에서 direct `runTask` 호출 제거
- `task-dispatcher` 경유로만 실행
- 실제 executor는 여전히 local process

### Phase B. Local Worker Mode
- 앱 프로세스 내부 local worker 추가
- queue lease -> local worker execute
- 현재 adapter 실행은 local worker 안에서 유지

### Phase C. Remote Worker Mode
- 별도 프로세스/머신 worker 등록
- remote worker가 lease 받아 실행
- SSE/log/activity는 같은 run stream contract 유지

### Phase D. Hard Separation
- review/verify phase는 previous worker/agent와 다른 lease를 강제
- 필요 시 다른 runtime class까지 강제

## 8. UI 영향

`Project Detail` / `Tasks` / `Run Inspector`는 아래 상태를 읽게 된다.

- queued
- leased
- running
- retry scheduled
- waiting for reviewer capacity
- worker stale

추가로 보여줄 메타:
- assigned worker
- worker capability match
- separation satisfied / violated
- queue wait reason

## 9. MVP 범위

Execution V2의 첫 구현에서는 여기까지만 한다.

- in-memory queue
- local worker registration
- task dispatcher
- lease/heartbeat 개념
- run inspector에 queue state 표시
- review separation을 worker level로 한 단계 강화

이번 단계에서 제외:
- 완전한 distributed scheduler
- multi-region worker
- advanced autoscaling
- durable retry backoff tuning

## 10. 첫 구현 체크리스트

- `task-dispatcher.service.ts` 추가
- `run-queue.service.ts` 추가
- `worker-registry.service.ts` 추가
- `POST /tasks/:id/run` -> enqueue 기반으로 변경
- local worker bootstrap 추가
- run inspector에 `queued / leased / worker` 메타 표시
- queue/worker 테스트 추가

## 11. 결정 원칙

Execution V2에서도 아래 원칙을 유지한다.

1. setup-first product identity를 해치지 않는다.
2. 기존 local direct run은 한동안 fallback으로 유지한다.
3. UI에서 보이는 정책은 orchestration 계층에서도 집행한다.
4. separation rule은 review phase부터 강하게 적용한다.
5. remote worker 전에 local worker queue mode로 구조를 먼저 검증한다.
