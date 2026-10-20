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

Start in planning mode and present the workflow-required implementation brief. Do not edit before explicit approval, or before the policy approval below when `approval` is `auto`. After approval, follow the graph transitions and use configured project agents only for bounded responsibilities.

## Project policy

Read `approval`, `git_policy`, and `issue_policy` from `.ai-harness/harness.json`. They decide where this workflow waits for a person and which git and issue-tracker actions it takes on its own.

- `approval`: `human` (default, also when the field is missing) — present the brief and do not edit before explicit approval. `auto` — present the brief, record it in the PR body (the runner also keeps it in its run directory), and continue without waiting, unless the brief has open questions or a product decision; then wait for the person.
- `git_policy`: `pr-only` — once the graph reaches publish, commit, push the work branch with a normal push, and open a PR with the PR tool the project workflow names (for example /bitbucket or gh); take reviewers and labels from the project's default rules instead of asking. `direct` — commit and push the current branch with a normal push; open a PR only when the project workflow requires one. Missing or any other value — do not commit, push, or create a PR unless separately authorized.
- `issue_policy`: `in-progress-on-start` — when the request names a tracker issue (a key such as `ABC-123` or an issue URL), move that issue to its in-progress state with the issue tool the project workflow names (for example /jira), before branch or worktree setup and before discovery. Pick the transition whose target status category is in progress instead of matching a status name. Leave an issue that is already in progress as it is; if it is done or closed, ask the person instead of reopening it. Do this before `driver.sh start` — the runner's first node is discovery. If the project workflow names no issue tool, ask the person which to use instead of guessing one. Missing or any other value — leave issue status alone.
- Under every policy: never merge, force-push, push to the base branch under `pr-only`, or change project policy without separate authorization. Escalations the graph routes to `user_decision`, such as the repair limit in `limits.max_repair_attempts` or a product decision, always go to the person.

## Graph runner

When `.ai-harness/workflows/implement-feature-driver.sh` exists, run the feature through it instead of following the graph yourself. The runner executes the graph outside the model: read-only nodes run in read-only sessions, the approval node waits for the person (or passes by policy under `approval: auto`), done requires the checks the runner executes itself, and the publish node commits, pushes, and opens the PR only as `git_policy` allows.

1. `bash .ai-harness/workflows/implement-feature-driver.sh start --request "<the user's request>"` runs discover and brief, then stops at approval (exit 10). Show the brief, the checks, and any open questions to the user as printed. Under `approval: auto` it does not stop unless the brief has open questions; go to step 4 when it exits.
2. If the user asks for changes, run `revise --feedback "<their words>"` and show the new brief.
3. When the user types `승인` or `approve`, run `resume`. The runner accepts only a message the user typed after the brief was shown, read from the session transcript. Never write, quote, or simulate an approval yourself. Delivery, checks, review, and repair can take many minutes; run it in the background when your tool allows it.
4. Report the outcome: exit 0 done (with the PR link when one was opened); 20 a person must decide (show the unresolved findings); 30 incomplete (show the cause, then `resume` after it is fixed); 40 invariant violation (stop and show it). `status` shows the current node and history.

Under `pr-only` or `direct` the runner leaves a local checkpoint commit after delivery and each repair, and its publish node commits, pushes, and opens the PR; under any other `git_policy` it never commits. Branch or worktree setup before it and docs and cleanup after it follow the project workflow. In Codex, the runner starts its own sandboxed `codex exec` sessions, so run it with permission to leave the current sandbox. If the runner is missing, follow the graph in this conversation as described above.
