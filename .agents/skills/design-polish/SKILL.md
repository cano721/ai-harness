---
name: design-polish
description: Start a project-local quality pass on existing screens. Use when a screen that already works should look and read better as a whole — hierarchy, spacing, color, consistency with its sibling screens and the design rules ("이 화면 전반적으로 다듬어줘", "polish this page"); not for a new screen or mockup (design-screen), a missing feature or behavior (implement-feature), a broken behavior (fix-bug), or a critique (the design-reviewer agent).
---

# Design Polish

This is a project adapter, not the source of project policy. Read these files in order before polishing:

1. `AGENTS.md`
2. `.ai-harness/workflows/design-polish.md`
3. `.ai-harness/workflows/design-polish-graph.json`
4. `.ai-harness/docs/ui.md` and the design rule document it names

The project workflow and graph are authoritative. They define how to start the app, the supported viewports and themes, the design rule document and reference screen, the screens that share components, and the machine checks.

The pass is measured, not guessed: the screens are captured in a real browser before and after, scored with the project `design-audit` skill when the project has a design rule document and a reference screen, checked in the live page for layout breakage a score can miss (horizontal overflow, an empty band before the main content, clipped text, a background that stops short), and an independent reviewer compares the two. What gets fixed is a list the person chose. Test-first is not required for spacing, color, or hierarchy changes; add a check only for a violation a machine can catch (lint, contrast, token-copy checks).

Without a design rule document and a reference screen there is nothing to score against: the run stops after the critique and the fix list and changes nothing. Point the person to `/ai-harness:design-system-builder` to create the rules, or to `/harness-init --reconfigure` to enable the `design-system` stack when they already exist.

## Graph runner

When `.ai-harness/workflows/workflow-driver.sh` exists, run the pass through it instead of following the graph yourself. The runner executes `design-polish-graph.json` outside the model and decides pass or fail from the measurements, not from a session's claim.

To stop a running run, use only `bash .ai-harness/workflows/workflow-driver.sh stop [--run <id>] [--reason "<why>"]`: it ends just the processes that run recorded (the runner and its node session group, TERM then KILL after 5 seconds) and records `stopped` with the node, time, and reason. Never kill the runner or agent sessions by pattern (`pkill`, `killall`, `pgrep -f`); the same pattern matches other runs and sessions on the machine. `status` shows a stopped run and a run cut off outside the runner (`stale`); continue either with `resume`. `resume`, `approve`, and `revise` refuse a run whose runner is still alive (exit 2).

1. `bash .ai-harness/workflows/workflow-driver.sh start --workflow polish --request "<the screens to polish and what is wrong with them>"` measures the baseline (measure), critiques it independently (diagnose), and stops with the fix list. Exit 10: show the list and the checks as printed — major items are preselected — and ask which to fix. Exit 0 with `fix_list`: the project has no rules to score against; show the list and the next step above. Exit 0 with nothing to polish: say so. The runner picks the node runtime from `--runtime`, then `HM_RUNTIME_REPOS` (matching repository), then `HM_RUNTIME` in `~/.ai-harness/config`, then the calling CLI and integrations; pass `--runtime` only when the user asks for a specific CLI.
2. When the person wants other items, run `revise --workflow polish --select "P1,P3"` (no model call; it shows the list again). When the critique missed something or got it wrong, run `revise --workflow polish --feedback "<what to change>"`. Either way the runner waits for approval again.
3. When the person types `승인` or `approve`, run `resume --workflow polish`. The runner accepts only a message the person typed after the list was shown, read from the session transcript. Never write, quote, or simulate an approval yourself. Under `HM_APPROVAL=auto` the runner selects the major items itself and records why in the brief and the PR body.
4. The runner then fixes, runs the checks itself, measures again, and has an independent reviewer compare with the baseline. It passes only when no selected major item remains, the layout check finds no breakage on a target screen and none new on a sibling screen, the audit reaches the graph's `limits.audit_pass_score`, no audit axis fell below the baseline, no screen that shares the changed components regressed, and the checks pass; otherwise it fixes again, up to `limits.max_repair_attempts`. A file changed after a measurement or a review is refused and goes through the checks, a new measurement, and the review again. The check commands the measurement found do not run before approval. Then it publishes as `git_policy` allows and watches remote CI.
5. Report the outcome by exit code: 0 done (show the before and after scores and capture folders the runner prints); 20 a person must decide (show the reasons and evidence; when the runner stopped because the repository changed since it stopped (`baseline-changes.txt`), show that file; run `resume --workflow polish --accept-changes` only when the person explicitly says to take those changes into the run, never on your own); 30 incomplete (show the cause, then `resume`); 40 invariant violation (stop and show it). `status --workflow polish` shows the current node and history.

If the runner is missing, follow the graph in this conversation in the same order, keep captures and reports outside the working tree, and do not report the pass as done without the after measurement and an independent review.
