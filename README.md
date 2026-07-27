# ai-harness

에이전트 활동 기록 기반 하네스 자동 개선 — Claude Code 플러그인.

```bash
claude plugin marketplace add cano721/ai-harness
claude plugin enable ai-harness@ai-harness
```

## 기능 — 하네스 라이프사이클

```
/harness-init (셋업) → 자동 수집 (hook) → /metrics (관찰) → /harvest (개선 PR) ─┐
        ↑                                                                        │
        └───────────────────── 개선이 다시 하네스로 ←────────────────────────────┘
```

- **`/harness-init [--minimal] [--guard]`** — 프로젝트 분석 후 `.ai-harness` 스캐폴딩: AGENTS.md, docs(실측 기반 초안), 워크플로, 페르소나, 편집 가드
- **자동 수집**: `SessionEnd` hook이 세션 transcript를 압축 이벤트(JSONL)로 적재. LLM 비용 0 (jq만 사용)
- **`/metrics [7d|30d|90d|all] [프로젝트]`** — 사용량 요약 리포트: 프로젝트별 세션·토큰, 워크플로/커맨드 순위, 하네스 docs 읽힘 횟수, 페르소나 위임, 에러/가드 신호, 이슈 언급
- **`/harvest <프로젝트> [--dry-run]`** — 축적된 이벤트 + 사용자 교정 마크를 분석해 하네스(AGENTS.md, docs, workflows) 개선안 도출 → PR 생성. cosmetic 개선은 걸러냄 — 에이전트 행동이 실제로 바뀌는 것만

데이터는 로컬(`~/.claude/harness-metrics/events/`)에만 저장. transcript 원문은 어디에도 복사하지 않음.

설정(`~/.claude/harness-metrics/config`, 선택):

```bash
HM_ISSUE_RE="(NJ|JDA)-[0-9]+"   # 이슈 키 패턴 (기본: [A-Z]{2,}[0-9]*-[0-9]+)
```

요구사항: `jq`, bash (macOS/Linux). 한계: 교정 마크 감지는 현재 한국어 패턴 위주.
