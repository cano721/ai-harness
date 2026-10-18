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

## Graph runner

When `.ai-harness/workflows/implement-feature-driver.sh` exists, run the feature through it instead of following the graph yourself. The runner executes the graph outside the model: read-only nodes run in read-only sessions, the approval node waits for the person, and done requires the checks the runner executes itself.

1. `bash .ai-harness/workflows/implement-feature-driver.sh start --request "<the user's request>"` runs discover and brief, then stops at approval (exit 10). Show the brief, the checks, and any open questions to the user as printed.
2. If the user asks for changes, run `revise --feedback "<their words>"` and show the new brief.
3. When the user types `승인` or `approve`, run `resume`. The runner accepts only a message the user typed after the brief was shown, read from the session transcript. Never write, quote, or simulate an approval yourself. Delivery, checks, review, and repair can take many minutes; run it in the background when your tool allows it.
4. Report the outcome: exit 0 done; 20 a person must decide (show the unresolved findings); 30 incomplete (show the cause, then `resume` after it is fixed); 40 invariant violation (stop and show it). `status` shows the current node and history.

The runner never commits. Branch or worktree setup before it and docs, PR, and cleanup after it follow the project workflow. In Codex, the runner starts its own sandboxed `codex exec` sessions, so run it with permission to leave the current sandbox. If the runner is missing, follow the graph in this conversation as described above.
