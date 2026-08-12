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

Perform the initial review read-only. Report the workflow-required findings with evidence; do not report completion while a blocking finding remains. Do not modify files, commit, push, create a PR, merge, or change project policy unless separately authorized.
