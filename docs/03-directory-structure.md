# AI Harness - 디렉토리 구조

## 전체 구조

```
company-harness/
│
├── global/                          # ━━ 회사 공통 (모든 팀 적용) ━━
│   ├── CLAUDE.md                    # 공통 코딩 원칙, 보안 정책
│   ├── hooks/
│   │   ├── block-dangerous.sh       # rm -rf, DROP, force push 차단
│   │   ├── audit-logger.sh          # 모든 액션 로깅
│   │   └── secret-scanner.sh        # 민감 정보 유출 방지
│   ├── guardrails/
│   │   ├── security.md              # 보안 필수 규칙
│   │   └── forbidden-patterns.md    # 금지 패턴 목록
│   ├── skills/
│   │   └── handoff.md               # 크로스팀 핸드오프 (Global 스킬)
│   └── mcp/
│       ├── jira-server/             # 공통 Jira 연동
│       ├── confluence-server/       # 공통 Confluence 연동
│       └── git-server/              # Git 정책 강제
│
├── teams/                           # ━━ 팀별 커스텀 ━━
│   ├── planning/                    # 기획팀
│   │   ├── CLAUDE.md / hooks/ / skills/ / workflows/
│   ├── design/                      # 디자인팀
│   │   ├── CLAUDE.md / hooks/ / skills/ / mcp/
│   ├── frontend/                    # 프론트엔드팀
│   │   ├── CLAUDE.md / hooks/ / skills/ / workflows/
│   ├── backend/                     # 백엔드팀
│   │   ├── CLAUDE.md / hooks/ / skills/ / workflows/
│   ├── qa/                          # QA팀
│   │   ├── CLAUDE.md / hooks/ / skills/ / workflows/
│   └── devops/                      # DevOps팀
│       ├── CLAUDE.md / hooks/ / skills/ / workflows/
│
├── omc-integration/                 # ━━ OMC/OMX 연동 ━━
│   ├── harness-hook-bridge.js       # 하네스 Hook ↔ OMC Hook 브릿지
│   ├── custom-agents/               # 하네스 전용 에이전트 정의
│   ├── custom-skills/               # 하네스 전용 스킬
│   └── mode-configs/                # OMC 모드별 하네스 설정
│
└── cli/                             # ━━ 하네스 CLI 도구 ━━
    ├── bin/ai-harness.js              # CLI 진입점
    └── src/cli/
        ├── init.ts                    # ai-harness init
        ├── update.ts                  # ai-harness update
        ├── config.ts                  # ai-harness config (show/set/reset/diff)
        ├── team.ts                    # ai-harness team (list/add/remove/switch)
        ├── hook.ts                    # ai-harness hook (list/enable/disable/test)
        ├── status.ts                  # ai-harness status
        ├── doctor.ts                  # ai-harness doctor
        ├── uninstall.ts               # ai-harness uninstall
        └── version.ts                 # ai-harness version
```

## 각 디렉토리 역할

### global/

모든 팀에 **무조건 적용**되는 회사 공통 설정. 팀별 설정으로 오버라이드할 수 없는 보안 정책 포함.

### teams/{team-name}/

팀별로 독립 관리하는 커스텀 설정. 각 팀이 자율적으로 수정 가능하되, global 보안 정책은 우회 불가.

### omc-integration/

기존 OMC/OMX와의 연동 레이어. 하네스의 규칙을 OMC의 Hook/Agent/Skill/Mode에 주입하는 브릿지.

### cli/

하네스를 프로젝트에 적용하고 관리하는 CLI 도구 모음.
