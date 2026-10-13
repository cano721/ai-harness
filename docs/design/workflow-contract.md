# 워크플로 계약 단일화와 경유 보장

- 상태: 제안 (2026-10-13)
- 범위: `templates/{implement-feature,fix-bug,review}`, `skills/harness-init`, `scripts/` 계측, `hooks/`
- 근거: 실사용 workspace 1곳(독립 저장소 24개, 하네스 standard 3곳)의 30일 기록과 Claude·Codex 독립 검토 2건
- 이슈: #102 (epic), #103~#110

## 1. 문제

사용자가 원하는 것은 두 가지다. **코드를 바꾸는 작업은 어디서 세션을 열든 워크플로를 탄다**, 그리고 **그 워크플로의 셋팅이 맞다**. 실측은 둘 다 아니라고 말한다.

### 1-1. 워크플로는 생각보다 많이 타지만 계측이 못 본다

| 관측 | 수치 | 출처 |
|---|---|---|
| `/metrics`가 집계한 `implement-feature` 진입 | 30일 3회 | `stats.sh` |
| 코드 변경 세션 중 디스패치(BRIEF) 자율 세션 | 131개 중 78개 | transcript 직접 집계 |
| 그중 워크플로 본문을 실제로 읽은 세션 | 78개 중 69개 (88%) | Bash `cat` 포함 |
| Bash로만 워크플로를 읽은 Claude 세션 | 154개 중 73개 | 〃 |

워크플로 본문을 `Read`가 아니라 `cat`으로 읽거나, 슬래시 커맨드가 아니라 BRIEF 지시로 진입하면 `/metrics`에 잡히지 않는다. 경유율 KPI가 20배 이상 과소 집계된다.

같은 추출기는 토큰을 **과대** 집계한다. Claude transcript는 응답 하나를 content block마다 별도 줄로 쓰고 같은 `message.id`·`usage`를 반복하는데, `extract-claude.jq`가 줄 단위로 합산한다. 한 세션 실측: 출력 114,065 → 중복 제거 55,438, cache read 18.8M → 9.7M.

### 1-2. 같은 워크플로를 세 문서가 다르게 정의한다

| 계약 항목 | 그래프 json (관리 생성물) | Claude 어댑터 js (관리 생성물) | 저장소 워크플로 본문 (보호 파일) |
|---|---|---|---|
| 수리 반복 한도 | 같은 원인 2회 → `user_decision` | 2회 | 최대 5회 |
| 종료 지점 | review → `done` | review 통과 → 종료 | docs 갱신·LLM 자산 리뷰·PR·worktree 정리까지 필수 |
| PR 생성 | 노드 없음 | 어댑터: 별도 승인 없이 금지 | 필수 단계 |
| 역할 도구 부재 시 | — | 단일 `agent()` | "중단, 단일 진행 금지" |
| 승인 | `user_explicitly_approved` | 승인된 Brief 전제 | 사용자 합의 (디스패치 운영은 "질문으로 멈추지 말 것") |

본문에는 현재 템플릿에 없는 문구도 남아 있다: 존재하지 않는 `/plan`·`/team`, 옛 도구 이름 `Task`, 위임 위반 시 "즉시 변경 폐기", cwd·권한 없는 `codex exec`. 페르소나 쪽에서는 fix-bug가 developer에게 회귀 테스트를 맡기는데 developer는 테스트 편집이 금지돼 있고, 멀티모듈 저장소의 쓰기 범위가 루트 `src/**`로 적혀 실제 경로(`<module>/src/**`)와 맞지 않는다.

**근본 원인은 템플릿 문구가 아니라 구조다.** `harness-init` SKILL.md:118은 이미 "같은 원인 2회 수리 후 사용자 판단", "역할 도구가 없다는 이유로 중단하지 않는다"를 규정한다. 그러나 워크플로 본문은 초기화 시점에 LLM이 그 규정을 풀어 쓴 **보호 파일**이고(SKILL.md:183, :194), 이후 `--sync`가 갱신하지 않는다. 그 결과:

- 본문은 생성 당시 버전(0.19.0·0.22.3)에 고정되고 플러그인은 0.35.x로 간다.
- 관리 생성물(그래프·어댑터) 해시는 모두 일치하는데 의미상 모순은 그대로다. 해시 동기화는 의미 정합성을 검사하지 않는다.
- 공통 절차와 저장소 고유 사실(검증 명령·기준 브랜치·쓰기 범위)이 한 파일에 섞여 있어, 공통 절차만 갱신할 방법이 없다. 두 저장소 본문의 일치율은 83%이고, 차이의 일부만 정당한 저장소 고유 차이다.

### 1-3. 경로에 따라 진입점·가드·페르소나가 빠진다

| 세션 위치 | 진입점 | 편집 가드 | 멤버 페르소나 |
|---|---|---|---|
| 멤버 저장소·worktree | 로드 | 로드 (차단 후 준수 30%) | 로드 |
| workspace 상위 폴더 | 미로드 | **미로드 (차단 0%)** | **같은 이름의 사용자 전역 페르소나로 대체** |

workspace 세션에서 `subagent_type: developer`는 멤버의 `.claude/agents/developer.md`가 아니라 `~/.claude/agents/developer.md`로 간다. 멤버 쓰기 범위가 적용되지 않은 채 위임이 일어난다. workspace AGENTS.md의 Preflight("멤버 워크플로를 직접 Read")는 문구일 뿐이라 코드 변경 workspace 세션 28개 중 11개만 따랐다.

### 1-4. 워크플로가 이득인지는 아직 모른다

워크플로 없이 같은 종류의 작업을 한 비교군이 사실상 없다. 단계 단위로는 근거가 있다.

| 단계 | 실행률 (디스패치 세션) | 산출 |
|---|---|---|
| 1차 리뷰 | 86% | 88회 중 57%가 Major 이상 발견 |
| 재리뷰 | — | 23회 중 43% |
| docs 리뷰 | 41% | 33회 중 52%가 사실 오류 발견 |
| 수리 반복 | 61% | — |
| docs 영향 분석 | 17% | — |
| Refactor | 9% | — |
| 인라인 코멘트 | 0% | — |

같은 날·같은 저장소의 유사 작업 7건 비교는 경유군이 토큰·시간을 더 썼지만 작업 성격이 달라 결론을 낼 수 없다. 재작업 사례(같은 테스트 중복 작성 → 2회 revert)의 원인은 워크플로가 아니라 병렬 작업 분담 충돌이었다.

## 2. 목표와 비목표

**목표**

1. 워크플로 계약의 단일 출처를 정하고, 나머지는 거기서 생성하거나 거기에 대해 검증한다.
2. 공통 절차와 저장소 사실을 분리해, 공통 절차 개선이 모든 저장소에 전파되게 한다.
3. 세션을 어디서 열든 코드 변경 전에 대상 저장소의 워크플로를 읽게 한다 — 권고가 아니라 차단으로.
4. 작업 크기에 맞는 경로를 둔다.
5. 경유와 효과를 잴 수 있게 계측을 고친다.

**비목표**

- 워크플로 절차를 플러그인 전역 Skill로만 두기. 플러그인을 설치하지 않은 팀원은 저장소 파일만 읽는다 — 저장소 사본은 유지한다.
- workspace 폴더를 워크플로의 소유자로 만들기. workspace는 git이 아니라 팀이 공유하지 못하고, 팀원은 저장소를 직접 연다.
- 임의 세션(플러그인·저장소 하네스 둘 다 없는 환경)에서의 경유 보장.

## 3. 설계

### D1. 계약의 단일 출처는 그래프

그래프 json(관리 생성물)이 승인·역할·수리 한도·종료 조건을 갖고, 본문·Claude js·Codex Skill은 이 값을 **복제하지 않고 참조**하거나 검증 대상이 된다.

그래프 스키마 확장(`version: 2`):

```json
{
  "lanes": { "small": {...}, "standard": {...} },
  "approval": { "sources": ["user_explicit", "approved_brief_file"] },
  "repair": { "max_same_root_cause": 2 },
  "optional_nodes": {
    "docs_sync": { "when": "docs_impact_identified" },
    "handoff_pr": { "when": "git_policy_allows_and_user_authorized" }
  }
}
```

- `approved_brief_file`: 사람이 승인한 Brief 파일(디스패치의 BRIEF)을 승인 근거로 인정한다. 지금은 디스패치 운영이 승인 게이트를 설계상 깨고 있다 — 규칙이 안 지켜지는 게 아니라 규칙을 고쳐야 하는 경우다.
- docs 갱신과 PR은 필수 단계가 아니라 조건부 노드다. 실행률 17%·0%인 단계를 필수로 두지 않는다.
- 불변식은 유지한다: 승인 전 쓰기 노드 도달 불가, blocking finding에서 `done` 직행 불가, 수리 뒤 검증·재리뷰.

`scripts/validate-workflow-contract.sh <project>`를 추가한다. 그래프를 기준으로 본문·js·페르소나를 검사한다.

| 검사 | 예 |
|---|---|
| 수리 한도 일치 | 본문에 그래프와 다른 반복 횟수가 있으면 실패 |
| 도구 이름 허용 목록 | `/plan`, `/team`, `Task 도구` 등 존재하지 않는 도구 참조 |
| 역할↔쓰기 범위 | 워크플로가 역할에 맡긴 산출물이 그 페르소나 쓰기 범위 밖이면 실패 (fix-bug 회귀 테스트 ↔ developer) |
| 쓰기 범위↔실제 경로 | 페르소나 범위의 경로 패턴이 저장소에 하나도 매칭되지 않으면 경고 |
| 종료 계약 | 본문이 그래프에 없는 필수 노드를 요구하면 실패 |

`--sync`가 이 검사를 실행해 결과를 "보호 파일 후속 조치" 표에 싣는다. 해시 동기화가 못 잡던 의미 drift가 여기서 드러난다.

### D2. 공통 절차는 관리 생성물, 저장소 사실은 정책 파일

| 파일 | 소유 | 내용 |
|---|---|---|
| `.ai-harness/workflows/<name>.md` | **관리 생성물** (현재: 보호 파일) | 공통 절차. 템플릿에서 렌더. 저장소 사실은 정책 키로 참조 |
| `.ai-harness/policy.md` | 보호 파일 (사람·harvest 소유) | 검증 명령(targeted/full/push 전 게이트), 기준 브랜치 규칙, 역할별 쓰기 범위, worktree 규칙, 워크플로별 추가 규칙 |
| `.ai-harness/workflows/<name>.local.md` | 보호 파일, 선택 | 저장소 전용 추가 단계가 필요할 때만 |

- harvest는 저장소 사실·추가 규칙을 `policy.md`로, 공통 절차 결함은 ai-harness 템플릿 이슈로 보낸다.
- 플러그인 미설치 팀원은 저장소의 렌더된 사본을 읽는다. 사본은 해시로 관리돼 손으로 고치지 않는다.
- 저장소 밖(디스패치 폴더 등)에만 있는 영속 사실 — 실제 CI 게이트 명령, 공유 락, 환경 권한 — 을 `policy.md`로 옮기는 것이 이 구조의 전제다. git 밖 파일은 팀원도 harvest도 보지 못한다.

**마이그레이션**: 기존 보호 본문이 있는 저장소에서 `--sync`가 (1) 본문과 새 공통 절차의 차이를 계산하고, (2) 공통 절차에 없는 저장소 고유 문장을 `policy.md` 후보로 추출해 diff로 보이고, (3) 승인 후 본문을 관리 생성물로 교체한다. 생성물 구조가 바뀌므로 **MAJOR** 변경이다(`CONTRIBUTING.md` 버전 기준).

### D3. 작업 크기별 경로 (lane)

| lane | 진입 조건 (Brief에서 판정, 리뷰어가 상향 가능) | 경로 |
|---|---|---|
| small | production 파일 ≤ 2, 공개 계약·스키마·마이그레이션·보안 경계 변경 없음 | Brief(인라인 승인) → 테스트 우선 수정 → 검증 → 리뷰 → (blocking 시) 수리 |
| standard | 그 외 | 현재 전체 경로. docs·PR은 조건부 노드 |

역할 분리(위임)는 standard에서만 필수다. 실측에서 production 파일 2개 변경에 위임 8회가 일어났다.

### D4. 도구 매핑과 역할 규칙

템플릿과 harness-init 규정에서 다음을 고정한다.

- **Claude**: 위임은 Agent 도구의 `subagent_type`. 계획은 대화 안의 Brief(별도 스킬 없음). Dynamic Workflow js는 2.1.154 이상에서만 선택적으로.
- **Codex**: `.codex/agents/*.toml` 네이티브 서브에이전트를 우선한다. `codex exec` 폴백은 `-C <저장소>`, 쓰기 단계는 `-s workspace-write`, 결과는 `-o`로 수집한다고 명시한다(기본 sandbox는 읽기 전용이라 그대로는 쓰기 단계를 수행할 수 없다). 둘 다 없으면 단일 세션에서 페르소나를 전환해 진행한다 — "중단"하지 않는다.
- **위임 위반 처리**: "즉시 폐기" 금지. 중단 → diff 보존 → 범위 확인 → 올바른 역할에 재위임.
- **fix-bug**: 회귀 테스트는 test-engineer, production 수정은 developer.
- **페르소나 쓰기 범위**는 `policy.md`의 역할별 경로에서 렌더한다(멀티모듈 경로 포함).

### D5. 어디서 열든 워크플로를 타게 하는 메커니즘

강제력 순으로 둘을 조합한다.

**R1. 디스패치 공식화 (입증된 경로)**
workspace 세션이 대상 저장소에 세션을 띄우는 방식은 실측에서 경유율 88%, 리뷰 실행률 86%였고 멤버의 가드·페르소나도 로드된다. 지금은 임시 운영이다. 이를 workspace 모드 산출물로 만든다.

- 대상 판정: 경로 첫 세그먼트가 아니라 git root(`git rev-parse --show-toplevel`, worktree는 `--git-common-dir`)와 그 안의 `.ai-harness/harness.json`.
- BRIEF 형식 고정: 승인된 Brief, 대상 워크플로, `policy.md` 경로, lane. D1의 `approved_brief_file` 승인 근거가 된다.
- 실행: 대상 cwd에서 Claude 또는 `codex -C <저장소>`.

**R2. 플러그인 레벨 편집 가드 (안전망)**
플러그인 hook은 cwd와 무관하게 로드된다. `hooks/hooks.json`에 PreToolUse를 추가한다.

- 대상: Edit·Write·MultiEdit·NotebookEdit와 편집 MCP 도구로 `src/main|src/test`(또는 `policy.md`가 정한 production·test 경로)를 바꿀 때.
- 멤버 판정: 편집 파일에서 위로 올라가 `.ai-harness/harness.json`이 있는 git root.
- 발동: 세션 프로젝트 디렉토리가 그 멤버 root가 아닐 때만(멤버 안에서는 저장소 가드가 담당). 
- 검사: 이 세션(서브에이전트면 그 transcript)이 그 멤버의 워크플로 본문 또는 승인 BRIEF를 Read 또는 Bash로 읽었는지. 아니면 exit 2로 차단하고 멤버 워크플로 목록을 안내한다.
- transcript를 읽을 수 없으면 통과(fail-open), timeout 3초.

**R3. 페르소나 가림 경고**
workspace 모드 초기화·동기화가 멤버 페르소나와 같은 이름의 사용자 전역 페르소나(`~/.claude/agents/<name>.md`)를 감지하면 경고하고, workspace AGENTS.md는 위임을 디스패치(R1)로 돌리도록 안내한다.

**R4. Codex**
Codex는 상위 폴더의 `.agents/skills`를 독립 저장소 안에서 발견하지 않는다. 구현은 `codex -C <저장소>`로 시작하는 것을 기본으로 하고(R1), Codex hook 기반 강제는 별도 검증 뒤에 다룬다.

**R5. Claude 디렉토리 기능 (공식 문서 확인)**

| 기능 | 멤버 커맨드·스킬·페르소나 | 멤버 settings의 hook·권한 | CLAUDE.md / AGENTS.md | `CLAUDE_PROJECT_DIR` |
|---|---|---|---|---|
| `/add-dir <member>` (cwd 하위, 2.1.257+) | 로드 | **미로드** | CLAUDE.md는 하위 파일 접근 시 온디맨드, AGENTS.md 미로드 | 시작 디렉토리 |
| `/cd <member>` (2.1.246+) | 로드 | 로드 | CLAUDE.md 로드 | **시작 디렉토리 유지** |

출처: Claude Code 문서 permissions("Additional directories grant file access, not configuration", "Move the session to another directory"), sub-agents(우선순위 표), hooks(`CLAUDE_PROJECT_DIR` 정의).

- workspace AGENTS.md와 harness-init 7-4의 "Claude는 cwd의 `.claude/`만 로드하므로 해결 불가"는 현재 버전에서 틀렸다. workspace에서 `/add-dir <member>`면 멤버 슬래시 커맨드를 쓸 수 있고, `/cd <member>`면 가드까지 적용된다. Preflight를 이 기준으로 고친다.
- **`/cd` 후 멤버 가드가 깨진다.** 멤버 settings의 hook 명령이 `${CLAUDE_PROJECT_DIR}/.ai-harness/hooks/...`인데, `/cd` 뒤에도 이 변수는 workspace 루트를 가리킨다. 생성하는 hook 명령을 `"$(git rev-parse --show-toplevel)"` 또는 hook 입력의 `cwd` 기준으로 바꾼다(단계 2).
- `/add-dir` 페르소나와 사용자 전역 페르소나가 같은 이름일 때의 우선순위는 문서에 없다. R3의 경고는 유지한다.
- 편집 가드(R2)는 편집 파일 경로로 멤버를 판정하므로 어느 방식으로 진입하든 동작한다. hook 문서상 PreToolUse는 exit 2로 차단할 수 있고 입력에 `cwd`·`transcript_path`·`agent_id`가 온다.

### D6. 계측

| 항목 | 변경 |
|---|---|
| 워크플로 읽기 | Bash `cat/sed/head/tail/nl/awk`로 `.ai-harness/workflows/*.md`를 읽은 것도 `doc_read`로 기록 |
| 디스패치 진입 | BRIEF → 워크플로 체인을 `workflow` 이벤트로 기록 |
| 토큰 | `message.id` 기준 중복 제거 후 합산 |
| 단계 실행 | 서브에이전트 meta(agentType·description)로 세션별 실행 단계 집계 |
| 효과 (후속) | PR 단위: 첫 push CI 통과, 병합 후 14일 내 같은 이슈키의 fix·revert, 사람 리뷰 코멘트 수 |

효과 검증은 실험으로 한다: 비슷한 크기의 이슈를 small lane과 standard lane에 나눠 배정하고 위 PR 단위 지표를 비교한다. 슬래시 호출률이 아니라 **"올바른 대상 계약 선택 → 실제 검증 → 리뷰 finding 종료" 성공률**을 본다.

## 4. 단계

| 단계 | 내용 | 버전 영향 |
|---|---|---|
| 1 | 계측 버그: 토큰 중복 합산, Bash 워크플로 읽기 미집계 | PATCH |
| 2 | 템플릿·harness-init 규정 정정(D4, R5 Preflight·hook 경로) + 계약 검증 스크립트(D1 검사) + `--sync` 연동 | MINOR |
| 3 | 플러그인 편집 가드(R2), 페르소나 가림 경고(R3) | MINOR |
| 4 | 그래프 v2(lane·승인 근거·조건부 노드), 디스패치 공식화(R1) | MINOR |
| 5 | 공통 절차 관리 생성물화 + `policy.md` 분리 + 마이그레이션(D2) | MAJOR |
| 6 | 단계 실행·PR 단위 효과 지표, lane 실험 | MINOR |

1~3은 구조를 바꾸지 않고 바로 효과가 난다. 5는 기존 저장소에 마이그레이션을 요구하므로 2·4의 검증 결과를 본 뒤 진행한다.

## 5. 위험

- **관리 생성물화(D2)는 사람이 본문에 넣은 규칙을 잃을 수 있다.** 마이그레이션은 자동 교체가 아니라 추출 diff → 승인 → 교체 순서로만 한다.
- **편집 가드의 오탐**: 문서·설정 편집은 대상에서 제외하고, 차단 메시지에 읽어야 할 파일을 정확히 적는다. 실패 시 통과.
- **플러그인 업데이트가 모든 저장소의 절차를 바꾼다**: 저장소 사본은 `template_version`으로 고정되고 `--sync` 승인으로만 갱신된다.
- **lane 오분류**: small 판정은 Brief에 근거를 적고, 리뷰어가 standard로 올릴 수 있다.
