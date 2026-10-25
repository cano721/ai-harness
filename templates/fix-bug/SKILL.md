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

Read `approval`, `git_policy`, and `issue_policy` from `.ai-harness/harness.json`. They decide where this workflow waits for a person and which git and issue-tracker actions it takes on its own.

- `approval`: `human` (default, also when the field is missing) — present the brief and do not edit before explicit approval. `auto` — present the brief, record it in the PR body (the runner also keeps it in its run directory), and continue without waiting, unless the brief has open questions or a product or environment decision; then wait for the person.
- `git_policy`: `pr-only` — once the graph reaches publish, commit, push the work branch with a normal push, and open a PR with the PR tool the project workflow names (for example /bitbucket or gh); take reviewers and labels from the project's default rules instead of asking. `direct` — commit and push the current branch with a normal push; open a PR only when the project workflow requires one. Missing or any other value — do not commit, push, or create a PR unless separately authorized.
- Remote CI (the graph's `remote_ci` node): work that was pushed is not done until remote CI for the pushed commit has finished. Watch it with the PR or CI tool the project workflow names (for example `gh pr checks --watch`, or the Bitbucket pipelines API through /bitbucket) until every check reaches a final state. If it fails, repair it through the same loop and limit (`limits.max_repair_attempts`), push with a normal push, and check again. If the repository has no remote CI, say so. If you cannot see the result, report "remote CI unverified" with the PR link instead of done. A local run of the CI-equivalent commands does not stand in for remote CI.
- UI verification (the graph's `ui_review` node): when the change alters what users see or operate — markup, styles, server-rendered templates, user-facing text, or how buttons, links, disclosures, forms, and dialogs behave — the brief lists `ui_scenarios` (user role, entry → key action → success check → return, the states, viewports, and themes to see). After a review with no blocking findings, verify them with the project `ui-review` skill (`.agents/skills/ui-review/SKILL.md` or `.claude/skills/ui-review/SKILL.md`) and `.ai-harness/docs/ui.md`: render and operate each scenario in a real browser without changing the working tree, keeping captures outside the repository. A blocking UI issue goes through repair, re-review, and `ui_review` again. If the screens could not be rendered or operated, report "implementation done, UI unverified" with what blocked it, never done. A test that clicked an element by its text, a class or token in the markup, or a screenshot file is not evidence.
- `issue_policy`: `in-progress-on-start` — when the request names a tracker issue (a key such as `ABC-123` or an issue URL), move that issue to its in-progress state with the issue tool the project workflow names (for example /jira), before branch or worktree setup and before collecting evidence. Pick the transition whose target status category is in progress instead of matching a status name. Leave an issue that is already in progress as it is; if it is done or closed, ask the person instead of reopening it. If the project workflow names no issue tool, ask the person which to use instead of guessing one. Missing or any other value — leave issue status alone.
- Under every policy: never merge, force-push, push to the base branch under `pr-only`, or change project policy without separate authorization. Escalations the graph routes to `user_decision`, such as the repair limit in `limits.max_repair_attempts` or a product or environment decision, always go to the person.
