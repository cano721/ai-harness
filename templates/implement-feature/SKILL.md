---
name: implement-feature
description: Start a project-local feature delivery workflow. Use when adding a user-visible capability, API, domain behavior, integration, or configuration behavior; not for an isolated bug fix, test-only characterization, or refactor-only task.
---

# Implement Feature

This is a project adapter, not the source of project policy. Read these files in order before planning or editing:

1. `AGENTS.md`
2. `.ai-harness/workflows/implement-feature.md`
3. `.ai-harness/workflows/feature-delivery-graph.json`
4. The personas and `.ai-harness/docs/` files selected by the workflow

The project workflow and graph are authoritative. They define the approval gate, test policy, role boundaries, validation commands, review/repair loop, and escalation conditions.

Start in planning mode and present the workflow-required implementation brief. Do not edit before explicit approval. After approval, follow the graph transitions and use configured project agents only for bounded responsibilities. Do not commit, push, create a PR, merge, or change project policy unless separately authorized.
