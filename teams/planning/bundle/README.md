# Planning Bundle

`teams/planning` contains two different kinds of assets:

- `skills/` and `CLAUDE.md`: legacy planning drafts that are still under review
- `bundle/`: the installable planner bundle used by `harness-init` for planner mode

The bundle is split into:

- `common/`: canonical source assets copied from the reference Codex setup
- `runtimes/`: runtime-specific mapping rules for Codex and Claude Code
- `templates/`: planner-specific helper templates such as policy documents

Planner mode must install from `bundle/`, not from `teams/planning/skills`.
