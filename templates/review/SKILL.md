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

When the change alters what users see or operate and the graph has a `ui_review` node, list the affected screens as UI scenarios and, after the code review has no blocking findings, verify them with the project `ui-review` skill (`.agents/skills/ui-review/SKILL.md` or `.claude/skills/ui-review/SKILL.md`) and `.ai-harness/docs/ui.md`: render and operate each scenario in a real browser without changing the working tree. A blocking UI issue is a blocking finding. If the screens could not be rendered or operated, report the UI as unverified, not the change as done.

Perform the initial review read-only. Report the workflow-required findings with evidence; do not report completion while a blocking finding remains. Modify files only in an authorized repair the graph routes to.

Committing and pushing a repair follows `git_policy` in `.ai-harness/harness.json`: `pr-only` or `merge` — commit and push the reviewed change's work branch with a normal push (a review never merges, even under `merge`); `direct` — commit and push the current branch with a normal push; missing or any other value — do not commit or push unless separately authorized. Do not open a new PR from a review, and never merge, force-push, or change project policy without separate authorization. The repair limit is `limits.max_repair_attempts` in the graph.

## Graph runner

When `.ai-harness/workflows/workflow-driver.sh` exists, run the review through it instead of following the graph yourself. The runner executes `review-graph.json` outside the model: scope and inspect run without changing the working tree (ui_review runs the app before any agreement, so run untrusted branches in an isolated environment), classify routes the findings, a repair starts only after the person agrees to it (or by policy under `approval: auto`), verify is the checks the runner executes itself, and re_review and ui_review follow.

1. `bash .ai-harness/workflows/workflow-driver.sh start --workflow review --request "<the PR, branch, or diff to review>"` runs scope, inspect, and classify. Exit 0 means no blocking findings remain; report the review. Exit 10 means blocking findings could be repaired: show the findings and the checks as printed and ask whether to repair them. Exit 20 means a finding needs a product or scope decision; show it.
2. When the user types `승인` or `approve` to the repair, run `resume --workflow review`. The runner accepts only a message the user typed after the findings were shown, read from the session transcript. Never write, quote, or simulate an approval yourself. If the user does not want a repair, the printed findings are the review result. The agreement covers the findings shown; when a re-review or the UI check finds one outside them, the runner stops again with exit 10 and shows it, and the same rule applies.
3. Report the outcome by exit code as above; 30 incomplete (show the cause, then `resume` after it is fixed); 40 invariant violation (stop and show it). `status --workflow review` shows the current node and history.

The runner leaves repairs uncommitted. After it reports done, commit and push them as `git_policy` says above. If the runner is missing, follow the graph in this conversation as described above.
