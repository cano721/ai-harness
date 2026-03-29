# AI Harness — Team-based AI Agent Setup System

> [한국어 README](README.md)

Install the plugin and run `/harness-init` — it analyzes your project and automatically configures security hooks, code conventions, and skills tailored to your team. Once setup is complete, the harness steps back and lets Claude Code operate on its own.

## Design Philosophy

| Philosophy | Description |
|-----------|-------------|
| **Recommend + Choose** | Harness recommends best practices, your team decides |
| **Setup & Step Back** | Configures during init, then Claude Code takes over |
| **Guide, Not Block** | Violations show concrete alternative code, not just errors |
| **Team Autonomy** | Each team freely configures their own domain, conventions, and skills |
| **Minimal Enforcement** | Only 4 security hooks are mandatory. Everything else is opt-in |

## Quick Start

### Install

```bash
# Register from marketplace
claude plugin marketplace add https://github.com/cano721/ai-harness.git

# Install plugin
claude plugin install ai-harness
```

### Initialize

```
"Initialize harness"
or
"/harness-init"
```

Claude sets up in 4 steps (user confirmation at each step):

1. **Team Selection** — Detects tech stack → recommends team → you choose
2. **Global Setup** — Applies 4 security hooks to all projects (after confirmation)
3. **Project Check** — Analyzes current project → confirms setup target
4. **Project Setup** — Shows configured/unconfigured items → you select what to apply

### Check Status

```
"/harness-status"
```

Shows applied teams, hooks, and today's event summary.

## Skills

7 skills to fully control the harness. All can be invoked with natural language.

| Skill | Example | Function |
|-------|---------|----------|
| **harness-init** | "Initialize harness" | Analyze project → recommend team → generate conventions → register hooks |
| **harness-status** | "Show harness status" | Settings status + block history + diagnostics |
| **harness-rules** | "Show applied rules" | Current security rules, last block reason |
| **harness-team** | "Add QA team" | Add/remove teams, modify conventions |
| **harness-exclude** | "Exclude this project" | Manage global harness exclusions |
| **harness-metrics** | "Analyze metrics" | Agent work efficiency metrics + improvement suggestions |
| **harness-scaffold** | "Create CRUD" | Convention-based code boilerplate generation |

## Hook System

### Global Hooks (Applied to All Teams)

4 mandatory hooks are automatically registered:

| Hook | Function |
|------|----------|
| **block-dangerous.sh** | Blocks `rm -rf`, `DROP TABLE`, `force push`, `chmod 777`, `sudo` |
| **secret-scanner.sh** | Detects API keys, passwords, PII. Auto-masks before commit |
| **check-architecture.sh** | Validates dependency direction (Entity → Repository → Service → Controller) |
| **audit-logger.sh** | Logs all actions in JSONL format with sensitive data masking |

### Team Hooks

Each team brings its own hooks. For example, Backend team adds:
- `sql-review.sh` — SQL query review
- `api-compat.sh` — API compatibility check
- `entity-review.sh` — JPA entity validation

## Team Profiles

Currently **Backend team** is fully provided. Other teams are in preparation.

### Available

| Team | Role | Conventions | Hooks | Skills |
|------|------|-------------|-------|--------|
| **BE** | API/DB development | Package structure, DTO naming, REST rules | sql-review, api-compat | entity, migration, api-design, convention |

### Coming Soon

| Team | Role | Status |
|------|------|--------|
| FE | React/Vue development | In progress |
| QA | Testing/Verification | In progress |
| DevOps | Infra/Deployment | In progress |
| Planning | PRD/User stories | In progress |
| Design | Design system | In progress |

## Requirements

- **Node.js**: >= 18
- **Git**: Repository required
- **Claude Code**: Registered as plugin
- **OS**: macOS, Linux (Windows requires WSL)

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## Security

See [SECURITY.md](SECURITY.md) for reporting vulnerabilities.

## License

[MIT](LICENSE)

## Author

cano721
