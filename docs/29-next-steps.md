# AI Harness - Next Steps

현재 브랜치(`feature/ddalkak-platform`) 기준으로, setup-first control plane과 workflow-driven task review control plane의 핵심 흐름은 구현된 상태다. 이 문서는 "무엇이 끝났고, 다음에 무엇을 해야 하는지"를 잊지 않기 위한 작업 기준 문서다.

## 1. 현재 완료된 큰 축

### 1-1. Project Setup Control Plane
- `Project Detail`이 프로젝트 단위 control plane 역할을 한다.
- `Guard / Guide / Gear`를 axis 단위가 아니라 operation 단위로 plan/apply/reset 할 수 있다.
- setup drift, preview, compare preview, diff summary, reset flow가 붙어 있다.
- missing asset은 `Create via Setup`, managed asset은 `Reset via Setup`으로 연결된다.

### 1-2. Workflow-Driven Task Model
- `Gear` workflow가 task template로 연결된다.
- task는 workflow metadata, phase, separation policy, checklist를 가진다.
- recent tasks, task cards, run inspector가 workflow phase를 읽고 보여준다.

### 1-3. Review Separation Control Plane
- enforced workflow는 review phase를 implement phase와 분리한다.
- reviewer assignment, reviewer-missing fallback, reviewer setup recovery CTA가 있다.
- blocked review는 setup recovery와 retry review flow로 이어진다.

### 1-4. Run Timeline / Inspector
- task timeline, previous runs, retry chain, replacement jump가 있다.
- run logs fetch, live tail, completion state, run inspector drawer가 붙어 있다.
- inspector는 workflow phase, setup origin, policy, capabilities, checklist, recovery 상태를 보여준다.

### 1-5. Checklist-Aware Handoff Recovery
- checklist는 `required / evidence / advisory` semantics를 가진다.
- server는 `required` checklist가 남으면 handoff를 409로 차단한다.
- UI는 차단 이유를 drawer와 task card에 연결한다.
- blocker를 해결하면 `Retry Send to Review / Retry Advance Phase`로 즉시 이어진다.
- recovery retry는 `retrying -> handoff started / blocked again` 상태 피드백을 가진다.

## 2. 지금 남은 가장 큰 일

현재 남은 일은 크게 두 층이다.

### 2-1. Execution V2
현 구조는 "local adapter + direct run" 중심이다. 다음 단계는 `paperclip`에 가까운 execution plane 분리다.

해야 할 일:
- queue 도입
- worker registration / heartbeat
- task dispatch lease
- remote worker run
- phase별 runtime separation 강제
- run scheduling / retry / cancel 정책 정리

### 2-2. UX / Product Polish
현재 control plane은 동작하지만, 운영 완성도는 더 높일 수 있다.

해야 할 일:
- drawer / timeline / recovery UI polish
- loading / empty / error 상태 공통화
- project-wide activity와 task inspector 연결 강화
- setup 상태를 dashboard / project list 요약으로 반영
- e2e 수준의 통합 테스트 추가

## 3. 다음 권장 구현 순서

### Step 1. Execution V2 문서 기준 확정
- `30-execution-v2.md`를 기준으로 queue/worker 설계 확정
- 기존 direct run 경로를 완전히 버리지 말고 fallback path로 유지

### Step 2. Server 내부 dispatch 경계 분리
- `tasks route`가 바로 `runTask`를 호출하지 않도록 분리
- `task-dispatcher`, `run-queue`, `worker-registry` 서비스 경계 만들기

### Step 3. In-memory Queue MVP
- 우선 DB queue 전에 in-memory dispatch로 구조를 검증
- worker lease, assignment, state transition 이벤트를 먼저 붙이기

### Step 4. Persistent Queue / Remote Worker
- DB-backed queue 또는 durable job table 도입
- remote worker process registration / heartbeat / capacity 반영

### Step 5. Phase Policy Escalation
- UI에서 안내하던 separation / checklist / capability rule을 orchestration 계층으로 올리기
- review phase는 다른 worker / 다른 runtime / 다른 agent lease를 강제

## 4. 지금 당장 건드릴 파일 후보

Execution V2를 시작할 때 먼저 볼 파일:
- `packages/server/src/routes/tasks.ts`
- `packages/server/src/services/task-runner.service.ts`
- `packages/server/src/services/task-runner.test.ts`
- `packages/shared/src/types.ts`
- `packages/db/src/schema/tasks.ts`

추가 예정 서비스 후보:
- `packages/server/src/services/task-dispatcher.service.ts`
- `packages/server/src/services/run-queue.service.ts`
- `packages/server/src/services/worker-registry.service.ts`

## 5. 비목표

다음 단계에서 당장 하지 않을 것:
- setup control plane을 다시 대규모 재설계
- adapter 패키지 구조 재분해
- global runtime settings를 project setup에서 직접 수정
- worker/queue 이전에 full distributed system 최적화

## 6. 현재 기준 완료율 감각

- setup/control plane: 약 90%
- workflow/review control plane: 약 85~90%
- execution v2: 아직 시작 전
- remote worker / queue / distributed orchestration: 0~10%

즉, 제품의 "보여주고 조작하는 운영면"은 많이 올라왔고, 다음 큰 점프는 "실제 실행 계층 분리"다.
