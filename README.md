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

설치 즉시 세션 활동 수집이 시작된다 (Claude는 SessionEnd hook, Codex는 세션 로그를 질의 시점에 소화).

## 라이프사이클

```
/harness-init ──최초 1회──→ [하네스: AGENTS.md·docs·workflows]
                                 │                    ↑
                     에이전트가 하네스 따라 작업        │ 개선 PR 병합
                     (hook이 활동 자동 기록)           │
                                 ↓                    │
                            /metrics (관찰) ──→ /harvest (기록 근거로 개선안)
```

쓸수록 하네스가 좋아지는 루프: 셋업(1회) → 평소 작업이 자동 기록됨 → 기록을 관찰 → 기록을 근거로 하네스를 고침 → 좋아진 하네스로 다시 작업.

### /harness-init

프로젝트를 실측 분석(언어·빌드·테스트·git 컨벤션·모듈 구조)한 뒤 **수준 인터뷰**를 거쳐 하네스를 스캐폴딩한다:

- **규모**: `minimal`(AGENTS.md+docs) / `standard`(+워크플로·페르소나) / `full`(+편집 가드 hook)
- **테스트 정책**: TDD 강제 / 테스트 필수 / 권장 / 없음 — 실측과 모순되면 경고 (예: 테스트 0개인데 TDD 강제)
- **git 통제**: PR 필수(병합은 사람) / 직접 커밋 허용

선택은 `.ai-harness/harness.json`에 기록된다. docs 초안은 코드 실측으로만 채우고, Hard constraints는 빈 틀로 시작한다 — 검증된 지식은 `/harvest`가 시간을 들여 채운다.

**기존 하네스에서 재실행하면 수준 변경 모드**: 현재 수준을 보여주고 재인터뷰 후 diff만 적용한다. 업그레이드는 자동, 다운그레이드(삭제)는 대상 목록 확인 후에만.

### 자동 수집

세션 transcript를 압축 이벤트(JSONL)로 적재한다. LLM 비용 0 — `jq`만 사용.

수집 항목: 세션 메타(토큰·모델·턴), 워크플로/커맨드 사용, 페르소나 위임, 하네스 docs 읽힘, 편집 파일, bash 명령, MCP 툴, 이슈 키 언급, 에러/가드 차단/권한 거부/컨텍스트 압축 횟수, 사용자 교정 마크(위치만).

### /metrics [7d|30d|90d|all] [프로젝트]

사용량 요약 리포트: 프로젝트별 세션·토큰, 워크플로 순위, docs 읽힘 횟수(죽은 문서 탐지), 페르소나 위임, 에러/가드 신호, 이슈 언급. 조회 전용.

### /harvest <프로젝트> [--dry-run]

축적된 이벤트 + 사용자 교정 마크를 분석해 하네스 개선안을 도출하고 PR을 만든다.

가치 기준: **에이전트의 실제 행동이 바뀌는 개선만** PR화한다 — 반복 실수를 막는 constraint, 토큰/시간 낭비를 줄이는 구조 변경, 반복 삽질의 근본 해결. 문서 정리 같은 cosmetic 개선은 보고서 각주로만 남긴다. "이 변경이 없었으면 다음 달에 뭐가 잘못됐나?"에 답 못 하면 탈락.

## 데이터

- 저장 위치: 로컬 `~/.claude/harness-metrics/events/` 만. **transcript 원문은 어디에도 복사하지 않는다** — 이벤트는 카운트와 경로뿐이고, 원문이 필요한 분석은 로컬 원본을 참조한다.
- Codex 세션 로그(`~/.codex/sessions/`)도 동일하게 소화된다 — hook 불필요.
- 크래시로 hook이 못 돈 세션은 다음 `/metrics`·`/harvest` 실행 시 backfill이 소급 처리한다.

## 설정 (선택)

`~/.claude/harness-metrics/config`:

```bash
HM_ISSUE_RE="(NJ|JDA)-[0-9]+"        # 이슈 키 패턴 (기본: [A-Z]{2,}[0-9]*-[0-9]+)
HARNESS_METRICS_DIR="/custom/path"   # 데이터 디렉토리 변경
```

## 저장소 구조

```
.claude-plugin/   Claude Code 플러그인 매니페스트 + 마켓플레이스
.codex-plugin/    Codex CLI 플러그인 매니페스트
.agents/plugins/  Codex 마켓플레이스
commands/*.md     지시 원본 (단일 출처)
skills/*/SKILL.md Codex용 래퍼 — commands를 참조만 (수정은 commands 한 곳에서)
hooks/            SessionEnd hook 정의
scripts/          수집·집계 스크립트 (bash + jq, macOS/Linux)
```

## 요구사항 · 한계

- `jq`, bash (macOS/Linux 검증됨)
- 교정 마크 감지는 현재 한국어 패턴 위주
- Codex 이벤트 추출은 Claude보다 얕음 (명령·이슈 수준)
