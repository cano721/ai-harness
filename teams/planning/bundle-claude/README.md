# planner bundle for Claude Code

Claude Code에 설치되는 실제 planner bundle 배포물이다.

- `CLAUDE.md`
- `agents/*.md`
- `skills/*`

`scripts/install-planner-bundle.mjs --runtime claude`는 이 디렉토리를 기준으로:

- `CLAUDE.md` → `~/.claude/CLAUDE.md`
- `agents/*.md` → `~/.claude/agents/*.md`
- `skills/*` → `~/.claude/plugins/marketplaces/ai-harness/skills/*`

설치 후 Claude Code에서 planner subagent 자산을 한 번 더 정리해야 하면 `refresh-planning-subagents` skill을 실행한다.
