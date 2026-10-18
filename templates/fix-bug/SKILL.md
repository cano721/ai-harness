---
name: fix-bug
description: Start a project-local bug investigation and repair workflow. Use when behavior is incorrect, regressed, unreliable, or producing an error; not for a planned feature, refactor-only work, or speculative cleanup.
---

# Fix Bug

This is a project adapter, not the source of project policy. Read these files in order before investigating or editing:

1. `AGENTS.md`
2. `.ai-harness/workflows/fix-bug.md`
3. `.ai-harness/workflows/bug-fix-graph.json`
4. The personas and `.ai-harness/docs/` files selected by the workflow

The project workflow and graph are authoritative. They define evidence and reproduction requirements, the bug-fix brief and approval gate, regression policy, validation commands, review/repair loop, and escalation conditions.

Collect evidence without editing, then present the workflow-required bug-fix brief. Do not edit before explicit approval, or before the policy approval below when `approval` is `auto`. After approval, follow the graph transitions and use configured project agents only for bounded responsibilities.

## Project policy

Read `approval` and `git_policy` from `.ai-harness/harness.json`. They decide where this workflow waits for a person and which git actions it takes on its own.

- `approval`: `human` (default, also when the field is missing) — present the brief and do not edit before explicit approval. `auto` — present the brief, record it in the PR body (the runner also keeps it in its run directory), and continue without waiting, unless the brief has open questions or a product or environment decision; then wait for the person.
- `git_policy`: `pr-only` — once the graph reaches publish, commit, push the work branch with a normal push, and open a PR with the PR tool the project workflow names (for example /bitbucket or gh); take reviewers and labels from the project's default rules instead of asking. `direct` — commit and push the current branch with a normal push; open a PR only when the project workflow requires one. Missing or any other value — do not commit, push, or create a PR unless separately authorized.
- Under every policy: never merge, force-push, push to the base branch under `pr-only`, or change project policy without separate authorization. Escalations the graph routes to `user_decision`, such as the repair limit in `limits.max_repair_attempts` or a product or environment decision, always go to the person.
