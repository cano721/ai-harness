---
description: Start a project-local root-cause investigation that changes no code. Use when a bug, QA report, incident, or unexpected behavior needs its cause found and explained with evidence before anyone decides on a fix; not for fixing it (use fix-bug), reviewing a change, or building a feature.
argument-hint: "<증상 설명 또는 이슈 번호>"
---

# Investigate

This is a project adapter, not the source of project policy. Read these files in order before investigating:

1. @AGENTS.md
2. @.ai-harness/workflows/investigate.md
3. @.ai-harness/workflows/investigate-graph.json
4. The personas and `.ai-harness/docs/` files selected by the workflow

The project workflow and graph are authoritative. They define where the domain documents are, how to reproduce safely, which logs and data may be read, where the report goes, and when to hand a fix to `fix-bug`.

Do not edit, create, or delete any file in the repository (build output that `.gitignore` already covers, such as a test run leaves, is not a change), and do not change the index, commit, switch branches, or move the checkout. Keep scratch scripts, logs, the report, and drafts outside the working tree, under `~/.ai-harness/investigations/<repository name>/` unless the project workflow names another place outside the repository. Delegate only read-only exploration to the project's explorer persona.

## Steps

Follow the graph nodes in order. Each step builds on the previous one; do not skip one because the cause looks obvious.

1. **triage** — State the observed behavior, the expected behavior, the impact, when it happens (environment, data, account, version), and the relevant modules and files. This is the same node as `fix-bug` triage.
2. **baseline** — Read code as it is on the remote base branch, not as the local checkout happens to be. Run `git fetch origin` and compare the checkout with `origin/<base>` (the base branch the project workflow names). When the checkout is behind, read files with `git show origin/<base>:<path>` and search with `git grep <pattern> origin/<base>` instead of the working tree. When the report concerns a deployed version, read that tag or commit the same way. Record the commit you read; if fetch fails, say the baseline is unverified in the report.
3. **domain_docs** — Read the domain documents the workflow lists for the modules involved (`.ai-harness/docs/domain.md` and the files it points to) before deciding what the correct behavior is. A behavior the documents describe as intended is not a bug; report it as such.
4. **reproduce** — Reproduce with the smallest safe steps: a test or command run, or a request against a local server with the local or test configuration the project documents. Run it against the baseline commit: when the checkout is behind, export that commit outside the repository (`git archive origin/<base> | tar -x -C <scratch dir>`) and run there. Record the commit you ran; a reproduction on other code is not evidence about the baseline. Never use production data or credentials, and point anything the app writes outside the repository. When it cannot be run, collect equivalent evidence: log lines, data queries the workflow allows as read-only, a stack trace, or code paths with a falsifiable hypothesis. This is the same node as `fix-bug` reproduce. If there is neither a reproduction nor such evidence, stop at `user_decision` and list what a person must provide (an environment, logs, data, or the expected behavior).
5. **report** — Write the investigation report as a Markdown file and show its path and summary. It contains: symptom and reproduction conditions; the commit read (and whether it is `origin/<base>`); the documents read; each hypothesis with how it was checked and whether it was confirmed or refuted; the evidence (commands and their decisive output, log lines, code locations as `path:line` at the commit read); the cause, or the remaining candidates when it is not settled; a suggested fix direction (files, approach, regression test); and open questions. End with whether a code fix is needed.
6. **handoff** — When a code fix is needed, hand it to `fix-bug` with the report: `/fix-bug <report path>`, or with the runner `bash .ai-harness/workflows/workflow-driver.sh start --workflow bug-fix --request "<one-line summary>" --investigation <report>`. `fix-bug` then starts from its brief instead of repeating triage and reproduce. Do not start the fix yourself.

## External systems

Writes to external systems — issue or PR comments, tracker status changes, chat messages — are drafts. Save each draft next to the report (for example `<report>.comment.md`) and show where it is; a person posts it. Reading the tracker, logs, or dashboards the workflow names is allowed. Leave tracker issue status as it is; the issue moves when the fix starts.

## Graph runner

The graph runner (`.ai-harness/workflows/workflow-driver.sh`) does not run this workflow yet; follow `investigate-graph.json` in this conversation as described above. Its `--investigation` option on a `bug-fix` start is how the report reaches the fix.

## Request

$ARGUMENTS
