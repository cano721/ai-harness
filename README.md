# ai-harness

에이전트 활동 기록 기반 하네스 자동 개선 — Claude Code · Codex CLI 듀얼 플러그인.

에이전트가 프로젝트에서 실제로 어떻게 일하는지(어떤 문서를 읽고, 어떤 워크플로를 쓰고, 어디서 반복 실수하는지)를 자동 수집하고, 그 데이터로 프로젝트 하네스(AGENTS.md, docs, workflows)를 근거 기반으로 개선한다.

## 설치

```bash
# Claude Code
claude plugin marketplace add cano721/ai-harness
claude plugin enable ai-harness@ai-harness

# Codex CLI
codex plugin marketplace add cano721/ai-harness
codex plugin add ai-harness@ai-harness
```

설치 즉시 세션 활동 수집이 시작된다. SessionEnd hook으로 전달된 Claude/Codex transcript를 즉시 소화하고, 누락되거나 진행 중인 Codex 세션 로그는 `/metrics`·`/harvest`·session 조회 시점의 backfill이 보완한다. 프로젝트별 누적량이 기준을 넘으면 다음 세션 시작 때 `/harvest`를 안내한다.

## 라이프사이클

```mermaid
flowchart TD
    I["/harness-init — 최초 1회"] --> H["하네스<br/>AGENTS.md · docs · workflows"]
    H -->|"에이전트가 하네스 따라 작업<br/>(hook이 활동 자동 기록)"| R["활동 기록"]
    R -->|"누적량 기준 충족"| Q["ready batch<br/>다음 세션에 알림"]
    Q --> V["/harvest<br/>기록 근거로 개선안"]
    V -->|"개선 PR 병합"| H
    R -.->|"아무 때나 관찰"| M["/metrics — 관찰창"]
```

쓸수록 하네스가 좋아지는 루프: 셋업(1회) → 평소 작업이 자동 기록됨 → 기록을 근거로 하네스를 고침 → 좋아진 하네스로 다시 작업.

`/metrics`는 루프 단계가 아니라 **관찰창** — 쌓인 기록을 사람이 보고 싶을 때 아무 때나 친다. `/harvest`는 필요한 통계를 스스로 갱신하므로 `/metrics` 선행이 필요 없다.

### /harness-init

프로젝트를 실측 분석(언어·빌드·테스트·git 컨벤션·모듈 구조)한 뒤 **수준 인터뷰**를 거쳐 하네스를 스캐폴딩한다:

- **규모**: `minimal`(AGENTS.md+docs) / `standard`(+워크플로·페르소나) / `full`(+편집 가드 hook)
- **테스트 정책**: TDD 강제 / 테스트 필수 / 권장 / 없음 — 실측과 모순되면 경고 (예: 테스트 0개인데 TDD 강제)
- **git 통제**: PR 필수(병합은 사람) / 직접 커밋 허용

선택은 `.ai-harness/harness.json`에 기록된다. docs 초안은 코드 실측으로만 채우고, Hard constraints는 빈 틀로 시작한다 — 검증된 지식은 `/harvest`가 시간을 들여 채운다.

**기존 하네스에서 재실행하면 수준 변경 모드**: 현재 수준을 보여주고 재인터뷰 후 diff만 적용한다. 업그레이드는 자동, 다운그레이드(삭제)는 대상 목록 확인 후에만.

### 자동 수집

세션 transcript를 압축 이벤트(JSONL)로 적재한다. LLM 비용 0 — `jq`만 사용.

수집 항목: 세션 메타(토큰·모델·턴), 워크플로/커맨드 사용, 페르소나 위임, 하네스 docs 읽힘, 편집 파일, bash 명령, MCP 툴, 이슈 키 언급, 에러/가드 차단/권한 거부/컨텍스트 압축 횟수, 사용자 교정 마크(해당 발화의 앞 60자 스니펫 — 개선 분석의 정독 후보 표시용).

각 session 이벤트는 `coverage`에 실제 관측 가능한 항목을 기록한다. 현재 Claude는 위 항목 전체, Codex는 bash 명령·이슈·교정 마크를 관측한다. 통계에서 **미지원은 0회와 구분**하며 `/harvest`의 삭제 근거로 쓰지 않는다.

#### 누적량 기반 harvest 트리거

SessionEnd hook은 LLM 분석을 실행하지 않고, 막 끝난 세션의 압축 이벤트를 프로젝트별 pending 큐에 멱등 적재한 뒤 누적량만 판정한다. 기본값은 **세션 10개 / 사용자 교정 2개 / 오류 5개 중 하나 충족**이다. 기준을 넘은 세션 집합은 하나의 ready batch로 고정되고, 다음 SessionStart hook이 한 번만 `/harvest <프로젝트>`를 안내한다.

실제 분석·파일 수정·PR 생성은 `/harvest`에서 수행한다. 종료 훅을 짧고 실패 안전하게 유지하고, 사용자의 작업 도중 임의 변경이나 LLM 호출을 만들지 않기 위함이다. 분석 도중 새로 끝난 세션은 현재 batch에 섞지 않고 다음 batch로 보존한다. 정상 분석 완료 시에만 batch를 처리 완료로 옮기며, `--dry-run`이나 실패한 분석은 소비하지 않는다.

### /metrics [7d|30d|90d|all] [프로젝트] · /metrics session [sid]

사용량 리포트 (프로젝트에는 조회 전용, 로컬 event cache는 갱신):
- **전체 집계**: 프로젝트별 세션·토큰, source별 수집 범위, 워크플로 순위, docs 읽힘 횟수(관측 지원 세션만 대상으로 0회 판단), 페르소나 위임, 에러/가드 신호, 이슈 언급
- **`session` 모드**: Claude/Codex 세션 1개 정밀 리포트 — 이 세션이 토큰을 어디에 쓰고, 어떤 문서를 읽고, 어디서 막혔는지. sid 생략 시 환경의 실제 session/thread ID를 우선

### /harvest <프로젝트> [--dry-run]

축적된 이벤트 + 사용자 교정 마크를 분석해 하네스 개선안을 도출하고 PR을 만든다.

가치 기준: **에이전트의 실제 행동이 바뀌는 개선만** PR화한다 — 반복 실수를 막는 constraint, 토큰/시간 낭비를 줄이는 구조 변경, 반복 삽질의 근본 해결. 문서 정리 같은 cosmetic 개선은 보고서 각주로만 남긴다. "이 변경이 없었으면 다음 달에 뭐가 잘못됐나?"에 답 못 하면 탈락.

## 데이터

- 이벤트 저장 위치: 로컬 `~/.ai-harness/events/`. 이벤트는 카운트·경로·메타데이터이며, 예외로 교정 마크만 발화 앞 60자 스니펫을 담는다. **transcript 전문은 어디에도 복사하지 않는다** — 원문이 필요한 분석은 로컬 원본을 참조한다.
- harvest 대기 상태: 로컬 `~/.ai-harness/harvest-queue/`. pending·ready·처리 완료 세션의 작은 참조/카운트만 두며 transcript를 복사하지 않는다.
- Codex 세션 로그(`$CODEX_HOME/sessions/`, `~/.codex/sessions/`)도 동일하게 소화된다. 공용 hook은 `rollout-*.jsonl`을 Codex extractor로 분류해 Claude 이벤트와 섞지 않는다.
- 진행 중 JSONL도 손상되지 않은 줄까지 안전하게 소화하며, 다음 질의에서 갱신분을 재추출한다.
- 크래시로 hook이 못 돈 세션과 extractor/event version이 바뀐 과거 세션은 다음 `/metrics`·`/harvest` 실행 시 backfill이 소급 처리한다.
- 프로젝트 ID는 `.ai-harness/harness.json`의 `project_id`를 우선하며, 없으면 git origin/common-dir로 정규화해 worktree를 같은 프로젝트로 묶는다.

## 설정 (선택)

`~/.ai-harness/config`:

```bash
HM_ISSUE_RE="(NJ|JDA)-[0-9]+"   # 이슈 키 패턴 (기본: [A-Z]{2,}[0-9]*-[0-9]+)
HM_HARVEST_SESSION_THRESHOLD=10  # 0이면 이 기준 비활성화
HM_HARVEST_CORRECTION_THRESHOLD=2
HM_HARVEST_ERROR_THRESHOLD=5
```

데이터 디렉토리 자체를 옮기려면 셸 프로파일(예: `~/.zshrc`)에 환경변수로:

```bash
export HARNESS_METRICS_DIR="/custom/path"   # 기본: ~/.ai-harness
```

## 저장소 구조

```
.claude-plugin/   Claude Code 플러그인 매니페스트 + 마켓플레이스
.codex-plugin/    Codex CLI 플러그인 매니페스트
.agents/plugins/  Codex 마켓플레이스
skills/*/SKILL.md 지시 단일 출처 (Agent Skills 규격 — Claude·Codex 공용 로드)
hooks/            SessionEnd 수집·SessionStart ready 알림 hook 정의
scripts/          수집·집계 스크립트 (bash + jq, macOS/Linux)
```

## 요구사항 · 한계

- `jq`, bash (macOS/Linux 검증됨)
- 교정 마크 감지는 현재 한국어 패턴 위주
- Codex 이벤트 추출은 Claude보다 얕음 (명령·이슈·교정 마크). 미지원 항목은 통계에 관측 불가로 표시
- 회귀 테스트: `bash tests/run.sh` (`shellcheck`이 있으면 `shellcheck scripts/*.sh tests/*.sh`도 권장)
