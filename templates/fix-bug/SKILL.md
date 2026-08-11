---
name: fix-bug
description: Investigate, reproduce, fix, and verify a defect through an approved, evidence-backed workflow. Use when behavior is incorrect, regressed, unreliable, or producing an error; not for a planned feature, refactor-only work, or speculative cleanup.
---

# Fix Bug

Follow the project’s `AGENTS.md`, `.ai-harness` docs, and local `fix-bug` workflow first. Read the project-local bug-fix graph before changing files. Keep the change surface as small as the confirmed defect allows.

## 1. Triage and reproduce without editing

Before changing test, production, configuration, documentation, or git state:

1. Read the applicable project contract, error reports, related code, and analogous tests.
2. State the observed behavior, expected behavior, impact, affected versions or environments, and available evidence. Separate facts from hypotheses.
3. Reproduce with the narrowest safe command, test, request, log query, or deterministic observation available. Record the exact result and environmental assumptions.
4. Trace the smallest plausible execution path and identify the suspected failing boundary. Do not call a root cause confirmed unless the evidence distinguishes it from alternatives.

If the issue cannot be reproduced and no safe observation plan can distinguish the hypotheses, stop and ask for the missing environment, logs, sample data, or product expectation. Do not make a speculative fix.

## 2. Obtain approval for the fix brief

Present a `Bug Fix Brief` before any edit. Include:

- observed versus expected behavior, impact, and reproduction evidence or explicit reproduction gap;
- suspected cause and competing hypotheses, each tied to evidence;
- regression case or other verification evidence to add after approval;
- smallest expected files/areas, compatibility or data risk, and verification commands;
- explicit non-goals, rollback considerations, and open product decisions.

Stop after presenting the brief. Begin edits only when the user explicitly approves it. Reuse an approved brief only when its scope and evidence still match; materially changed diagnosis or scope requires a revised brief and new approval.

## 3. Fix with regression evidence

After approval, follow the project test policy:

- **TDD required or tests required**: add or update the smallest regression test, demonstrate its intended failure when the project permits it, then make it pass.
- **Tests recommended**: add a focused regression test when feasible; otherwise record the strongest available reproduction and verification evidence.
- **No automated-test requirement**: use the narrowest deterministic command, request, log assertion, or manual check available and state its limitations.

Make no unrelated cleanup or abstraction change. If the confirmed cause disproves the approved brief, stop, revise the brief, and seek approval again.

## 4. Verify and close the review loop

Run the targeted regression evidence, then the project-required broad verification. Review the final diff for the reported behavior, regressions, compatibility/data risk, missing edge cases, and scope drift.

Classify findings as blocking or non-blocking. For every blocking finding, repair the owning cause, rerun targeted and required broad checks, then re-review. Finish only when the approved expected behavior is verified, required checks pass, and no blocking finding remains.

After two focused attempts at the same root cause, or when evidence requires a product or environment decision, stop and ask the user. Do not mask uncertainty with a speculative workaround.

## 5. Hand off with evidence

Report the defect and impact, reproduction evidence, confirmed cause or remaining uncertainty, files changed, regression and broad verification commands/results, skipped checks with reasons, rollback or follow-up risk, and any non-blocking findings.

Commit, push, create a PR, merge, or delete a worktree only when the user request or explicit project policy authorizes it.
