---
name: review
description: Start a project-local change review workflow. Use for a PR, local diff, completed feature, bug fix, migration, or release candidate; not for exploratory code reading without a change to assess.
---

# Review Change

This is a project adapter, not the source of project policy. Read these files in order before reviewing:

1. `AGENTS.md`
2. `.ai-harness/workflows/review.md`
3. `.ai-harness/workflows/review-graph.json`
4. The reviewer persona and `.ai-harness/docs/` files selected by the workflow

The project workflow and graph are authoritative. They define review scope, risk checks, finding severity, repair ownership, required verification, re-review, and escalation conditions.

Perform the initial review read-only. Report the workflow-required findings with evidence; do not report completion while a blocking finding remains. Modify files only in an authorized repair the graph routes to.

Committing and pushing a repair follows `git_policy` in `.ai-harness/harness.json`: `pr-only` — commit and push the reviewed change's work branch with a normal push; `direct` — commit and push the current branch with a normal push; missing or any other value — do not commit or push unless separately authorized. Do not open a new PR from a review, and never merge, force-push, or change project policy without separate authorization. The repair limit is `limits.max_repair_attempts` in the graph.
