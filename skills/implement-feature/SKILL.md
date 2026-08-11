---
name: implement-feature
description: Implement a new product feature through scoped discovery, small evidence-backed Red-Green-Refactor slices, focused review, and proportionate verification. Use when adding a user-visible capability, API, domain behavior, integration, or configuration behavior; not for an isolated bug fix, test-only characterization, or refactor-only task.
---

# Implement Feature

Deliver the requested feature with a small, auditable change surface. The project’s `AGENTS.md`, harness docs, and existing conventions remain authoritative; this skill supplies the delivery loop when they do not already prescribe one.

## 1. Plan, then obtain explicit approval

Start every invocation in **planning mode**. Use the read-only project-contract discovery in section 2 as needed to prepare the brief. Before modifying test, production, configuration, documentation, or git state, present an `Implementation Brief` containing:

- intended behavior and explicit non-goals;
- acceptance cases, grouped into delivery slices of **one to three cases**;
- expected areas/files, public API, data migration, configuration, and documentation impact;
- test/build/lint verification commands and meaningful risks or open decisions.

Ask the user to confirm or adjust the brief. **Stop after presenting it**: a request to implement a feature authorizes discovery and planning, not edits. Begin the implementation phase only after the user explicitly approves (for example, “진행”, “proceed”, or an equivalent unambiguous instruction). If the user changes the brief materially, present the revised scope for approval again.

When the current conversation already contains an explicitly approved `Implementation Brief` whose scope still matches, state that it remains in force and continue; do not request the same approval again. When the user asks to plan only, finish after the brief. Do not treat an existing issue description, an implementation proposal, or a branch name as approval unless the user explicitly says the proposed implementation may proceed.

## 2. Establish the project contract

During planning, before any edit:

1. Read `AGENTS.md` and the closest applicable workflow, architecture, conventions, and testing documents. Follow project-specific branch, worktree, commit, CI, and approval rules; do not create a branch, worktree, commit, or PR merely because this skill was invoked.
2. Identify the project test policy from its workflow or testing docs: TDD required, tests required, tests recommended, or no automated-test requirement. The project policy overrides this Skill’s default delivery shape.
3. Inspect analogous production code and tests, the available verification commands, and the smallest likely change surface.
4. Use the approved `Implementation Brief` as the canonical acceptance-case, slice, and verification plan. Ask the user only when an unresolved product decision would materially change behavior.

New top-level types, modules, services, or abstractions need a concrete reason: an independent lifecycle, policy, technical boundary, or multiple callers. Otherwise extend the existing owner with the smallest clear design.

## 3. Choose execution mode deliberately

Use the project’s configured personas when available (`.codex/agents/`, `.claude/agents/`, or `.ai-harness/agents/`). Delegate only a bounded, independently reviewable responsibility:

| Need | Suitable role | Write boundary |
|---|---|---|
| Explore existing behavior or docs | explorer | read-only |
| Establish a Red test | test-engineer | test files only |
| Make a failing slice pass | developer | production/configuration files only |
| Inspect the completed diff | reviewer | read-only |

Never run concurrent writers against overlapping files. Do **not** block feature delivery solely because role agents or a subagent facility are absent: retain the same phase boundaries in one session and explicitly record the evidence. Use delegation only when its context cost is justified by the task’s scope or risk.

## 4. Deliver slices using the project test policy

For every slice, make only the change needed for the approved acceptance case, run the checks required by the project policy, and do not start the next slice while the current required checks fail.

### TDD required — Red → Green → Refactor

### Red — demonstrate the missing behavior

- Add only the test(s) needed for this slice, following the project’s testing convention.
- Run the narrowest relevant test command and confirm it fails for the expected behavioral reason. A compile failure caused solely by a missing production API is not evidence of Red; first add the smallest behavior-free signature/stub if the project permits it, then establish an intentional failing assertion.
- Do not change production logic in this phase. If the observed failure exposes a different requirement, return to the acceptance cases before continuing.

### Green — implement no more than the slice needs

- Change production code and required configuration only enough to make the new test pass.
- Run the targeted test and any fast regression command required by the project.
- Avoid speculative options, extension points, or abstractions that lack a current acceptance case.

### Refactor — improve only while green

- With tests passing, improve naming, duplication, boundaries, and readability where it reduces real complexity.
- Keep test intent unchanged during this phase; if a test must change, treat it as a new Red/Green slice.
- Re-run the targeted test after refactoring. If no worthwhile cleanup exists, explicitly record a no-op refactor.

### Tests required, but not TDD

Follow the project’s specified order. Add or update relevant tests and run them with the affected regression checks before declaring the slice complete. Do not invent a mandatory failing-test phase when the project does not require it.

### Tests recommended or no automated-test requirement

Propose the smallest useful automated test when feasible, but do not claim coverage that was not added. Run available build, lint, type, static-analysis, or manual verification appropriate to the project; record skipped checks and the reason in the handoff.

## 5. Close the review → repair → re-review loop

After all slices, compare the final diff with the approved acceptance cases and original scope. Review for missing boundary behavior, accidental public/API changes, unwanted generated files, and unnecessary abstraction. Run the project-required broad verification (for example, the mandated test suite, build, lint, type check, or migration validation).

Classify findings as:

- **Blocking**: incorrect or missing behavior, a regression, security/data risk, a broken required check, or a material scope violation.
- **Non-blocking**: optional cleanup or follow-up that does not invalidate the approved feature.

For every blocking finding, run this closed loop:

1. Route it to its owning phase: missing behavior → a new slice following the project test policy; production defect → implementation; test defect → test update; documentation mismatch → documentation update.
2. Re-run the affected targeted checks, then the project-required broad verification.
3. Re-review the changed diff and record whether each blocking finding is resolved, still present, or replaced by a new finding.

Finish only when all approved acceptance cases are covered, required checks pass, and no blocking findings remain. Report non-blocking findings as follow-ups. If the same root cause remains after **two focused repair attempts**, or resolution requires a product decision, stop and ask the user rather than masking the uncertainty.

Update documentation only when externally visible behavior, configuration, architecture, operational behavior, or established conventions changed. Keep code as the source of truth.

## 6. Hand off with evidence

Report:

- delivered behavior and intentionally deferred scope;
- files/areas changed and any new public contract;
- slice-by-slice implementation and verification evidence appropriate to the project test policy, including the commands run;
- final verification results and anything not run, with the reason;
- documentation changes and follow-up risks.

Commit, push, create a PR, merge, or delete a worktree only when the user request or the repository’s explicit policy authorizes that action.
