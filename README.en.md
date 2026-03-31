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

## User Flow

### Initialization (`/harness-init`)

```
[1] Team Selection ── "Which team setup do you want?"
                       Tech stack detection → recommendation → user chooses
    ↓
[2] Global Setup ──── "Applying security hooks to all projects"
                       → User confirms → registers in ~/.claude/settings.json
    ↓
[3] Project Check ─── "Current project: my-service (Java/Spring)"
                       → "Set up this project?" confirmation
    ↓
[4] Project Setup ─── Shows configured / unconfigured items
                       → User selects items → applies
    ↓
[Done] Summary
```

### Daily Usage

```
Use Claude Code as usual.
The harness only sets things up and steps back. Claude Code does the work.

Developer: "Create an applicant list API"
    ↓
Claude: Refers to convention-backend.md
    → /api/v1/applicants (versioning applied)
    → CommonResponse<T> (common response format)
    ↓
[Claude Code Hook] Auto-validates on code write
    → SELECT * used? → Block + "Specify columns" guidance
    → Hardcoded secret? → Block + "Use environment variables" guidance
    ↓
[Audit Log] All actions auto-recorded in .ai-harness/logs/
```

### Management (When Needed)

```
"Add QA team"            → /harness-team
"Why was it blocked?"    → /harness-rules
"Show harness status"    → /harness-status
```

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

### Troubleshooting

When you want to know why something was blocked:

```
"Why was it blocked?"
```

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

**block-dangerous.sh** — Dangerous pattern blocking

- `rm -rf` (rm with -r, -f flag combinations)
- `DROP TABLE/DATABASE/INDEX`
- `TRUNCATE TABLE`
- `git push --force` (`--force-with-lease` is allowed)
- `chmod 777`
- `sudo` commands

On block: "BLOCKED: [reason]. Alternative: [recommended approach]"

**secret-scanner.sh** — Sensitive information leak prevention

- Detects API keys, passwords, PII
- Auto-masks before commit
- Guides to store secrets in `.env` etc.

**check-architecture.sh** — Architecture boundary validation

- Detects dependency direction violations (Types/Entity → Config → Repository → Service → Controller)
- Blocks upper layer imports from lower layers + provides alternatives

**audit-logger.sh** — Action audit logging

- Records who, when, what in JSONL format
- `.ai-harness/logs/{YYYY-MM-DD}.jsonl`
- Auto-masks sensitive info (API keys, passwords)

### Team Hooks

Each team brings its own hooks. For example, Backend team adds:
- `sql-review.sh` — SQL query review
- `api-compat.sh` — API compatibility check
- `entity-review.sh` — JPA entity validation

## Hook Example Scenarios

### Scenario 1: rm -rf attempt

```
Claude: "Deleting all log files"
bash: rm -rf logs/

Hook response:
BLOCKED: rm -rf is blocked by harness security policy.
Alternative: Delete individual files or use rimraf
```

### Scenario 2: Sensitive info detected

```
Claude: "Saving DB connection info to .env"
PLAINTEXT: DATABASE_URL="postgres://user:password@host"

Hook response:
BLOCKED: Plaintext password detected.
Alternative: Load via environment variables or use secrets.json
Masked: DATABASE_URL="postgres://user:***@host"
```

### Scenario 3: Team hook

```
Claude: "Writing a React component"
Bundle size: 450KB → 480KB (+30KB)

Hook response:
Warning: Bundle size increased by 30KB (limit: 100KB).
Analysis: New library @emotion/core (25KB)
Recommendation: Consider dynamic import
```

## Team Profiles

Currently **Backend team** is fully provided. Other teams are in preparation.

### Available

| Team | Role | Conventions | Hooks | Skills |
|------|------|-------------|-------|--------|
| **BE** | API/DB development | Package structure, DTO naming, REST rules | sql-review, api-compat, entity-review | entity, migration, api-design, convention |

### Coming Soon

| Team | Role | Status |
|------|------|--------|
| FE | React/Vue development | In progress |
| QA | Testing/Verification | In progress |
| DevOps | Infra/Deployment | In progress |
| Planning | PRD/User stories | In progress |
| Design | Design system | In progress |

Each team receives these files after initialization:

- `.ai-harness/teams/{team}/skills/convention-{team}.md` — Team code style
- `.ai-harness/teams/{team}/CLAUDE.md` — Team minimal rules + skill references

## Project Structure

```
ai-harness/
├── skills/                     # 7 skill directories
│   ├── harness-init/
│   ├── harness-status/
│   ├── harness-rules/
│   ├── harness-team/
│   ├── harness-exclude/
│   ├── harness-metrics/
│   └── harness-scaffold/
│
├── scripts/                    # Helper scripts (called internally by skills)
│   ├── check-environment.mjs   # Node.js, Git, Claude Code version check
│   ├── register-hooks.mjs      # Hook register/unregister
│   ├── copy-team-resources.mjs # Copy team hooks/skills
│   ├── inject-claudemd.mjs     # Inject harness rules into CLAUDE.md
│   ├── test-hooks.mjs          # Hook unit tests
│   └── validate-yaml.mjs       # YAML file validation
│
├── hooks/                      # Global hook scripts
│   ├── block-dangerous.sh      # Dangerous command blocking
│   ├── audit-logger.sh         # Audit logging
│   ├── secret-scanner.sh       # Sensitive info leak prevention
│   ├── check-architecture.sh   # Architecture boundary check
│   └── *.test.yaml             # Hook unit tests
│
├── teams/                      # 6 teams (Planning/Design/FE/BE/QA/DevOps)
│   ├── backend/
│   │   ├── skills/             # Team skills
│   │   └── hooks/              # Team hooks
│   ├── frontend/
│   ├── qa/
│   ├── devops/
│   ├── planning/
│   └── design/
│
├── templates/                  # Config/policy templates
│   ├── config.yaml
│   ├── context-map.md
│   ├── lock-policy.yaml
│   └── presets/                # Work presets (CRUD, bugfix, refactor)
│
├── custom-agents/              # Custom agents
│   ├── company-reviewer.md
│   └── company-architect.md
│
├── docs/                       # Design docs (28 planning + 8 SDD)
│
├── CLAUDE.md                   # Plugin context (auto-injected)
└── package.json
```

## Helper Scripts

Node.js utilities called internally by skills. Users rarely need to call these directly.

| Script | Role |
|--------|------|
| `check-environment.mjs` | Check Node.js, Git, Claude Code versions |
| `register-hooks.mjs` | Register/unregister hooks in `.claude/settings.json` |
| `copy-team-resources.mjs` | Copy team hooks, default skills, convention templates |
| `inject-claudemd.mjs` | Inject `# harness:start ~ harness:end` section into CLAUDE.md |
| `test-hooks.mjs` | Test hooks with `.test.yaml` defined cases |
| `validate-yaml.mjs` | Validate all YAML files in the project |

## Implementation Status

| Phase | Content | Status |
|-------|---------|--------|
| Design | 28 planning docs + 8 SDD, 3 review rounds | ✅ |
| Phase 1 | 6 engines + 3 hooks + 3 templates (CLI removed for plugin) | ✅ |
| Phase 2 | 6 team CLAUDE.md, 6 hooks, 18 skills, OMC integration | ✅ |
| Phase 3 | 3 adapters, metrics, workflow, onboarding | ✅ |
| Additional | Error handling, troubleshooting | ✅ |
| Plugin Migration | CLI → Claude Code plugin (5 skills + 5 scripts) | ✅ |

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
