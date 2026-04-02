# Contributing to AI Harness

Thank you for your interest in contributing to AI Harness! This guide will help you get started.

## Getting Started

### Prerequisites

- **Node.js** >= 18
- **Git**
- **Claude Code** (for testing plugin features)

### Setup

```bash
git clone https://github.com/cano721/ai-harness.git
cd ai-harness
pnpm install
```

### Running Tests

```bash
pnpm test
```

This runs Hook unit tests defined in `*.test.yaml` files.

## How to Contribute

### Reporting Bugs

1. Check [existing issues](https://github.com/cano721/ai-harness/issues) first
2. Use the **Bug Report** issue template
3. Include: steps to reproduce, expected vs actual behavior, environment info

### Suggesting Features

1. Open a **Feature Request** issue
2. Describe the use case and expected behavior
3. Explain why this would benefit the project

### Submitting Code

1. Fork the repository
2. Create a feature branch from `main`
   ```bash
   git checkout -b feat/your-feature
   ```
3. Make your changes
4. Run tests: `pnpm test` and `pnpm test:packages`
5. Run lint: `pnpm lint`
6. Commit with a clear message
7. Open a Pull Request using the PR template

This repository uses `pnpm` workspaces. Do not commit `package-lock.json`.

## Code Guidelines

### Shell Scripts (hooks/)

- POSIX-compatible when possible
- Use `shellcheck` before committing
- Include corresponding `.test.yaml` for new hooks
- Always provide user-friendly error messages with alternatives

### Node.js Scripts (scripts/)

- ES Modules (`.mjs`)
- No external dependencies beyond what's in `package.json`
- Handle errors gracefully with clear messages

### Team Profiles (teams/)

Each team directory should contain:
- `CLAUDE.md` — Team-specific rules
- `hooks/` — Team-specific hook scripts with `.test.yaml`
- `skills/` — Team-specific skill definitions

## Pull Request Guidelines

- Keep PRs focused — one feature or fix per PR
- Update documentation if behavior changes
- Add tests for new hooks
- Fill out the PR template completely

## Code of Conduct

This project follows the [Contributor Covenant Code of Conduct](CODE_OF_CONDUCT.md). By participating, you are expected to uphold this code.

## Questions?

Open a [Discussion](https://github.com/cano721/ai-harness/discussions) or an issue with the `question` label.
