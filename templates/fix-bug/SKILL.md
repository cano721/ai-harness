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

Collect evidence without editing, then present the workflow-required bug-fix brief. Do not edit before explicit approval. After approval, follow the graph transitions and use configured project agents only for bounded responsibilities. Do not commit, push, create a PR, merge, or change project policy unless separately authorized.
