# AGENTS.md

## Global note

- This workspace may also be used for planning, specification, and product thinking support, not only implementation.

## Subagent activation policy

- Do not spawn subagents by default.
- Spawn subagents only when the user explicitly requests delegation or subagent use.
- If the user does not explicitly request delegation, keep the task in the main agent.
- The routing rules below apply only after subagent activation is explicitly allowed.

## Subagent routing rules

### Core principle

- When delegation is allowed, always solve with the smallest competent subagent set.
- Prefer explicit delegation over broad, generic implementation.
- Keep PM/planning, design, implementation, architecture review, code review, and QA logically separated.
- Do not use a specialist when the main implementation agent can safely complete the work without loss of quality.

### Planning line

- Use `product-manager` for problem framing, scope, prioritization, and PRD-adjacent product decisions.
- Use `business-analyst` for policy, workflow, requirement structure, edge cases, and business rule clarification.
- Use `project-manager` for execution planning, sequencing, dependency tracking, and delivery coordination.
- Use `knowledge-synthesizer` to merge outputs from multiple agents into one coherent conclusion or final handoff.
- When a planning agent can use an installed PM skill, it should consult the relevant PM skill first and follow its structure before falling back to generic reasoning.

### Design line

- Use `ui-designer` before implementation when the task needs concrete UI structure, interaction behavior, screen hierarchy, or implementation-ready UX guidance.
- Use `api-designer` before implementation when the task needs API contract design, request/response modeling, versioning, validation semantics, or backward-compatibility review.
- Use `architect-reviewer` when the task involves coupling, boundaries, system design, migration risk, long-term maintainability, or rollout concerns.

### Implementation line

- Use `frontend-developer` for scoped frontend implementation, UI bug fixes, state-flow fixes, accessibility-sensitive interaction work, and production UI changes.
- Use `backend-developer` for scoped backend implementation, server-side bug fixes, auth-sensitive behavior, persistence changes, or service-layer logic updates.
- Use `fullstack-developer` only when one bounded feature or bug clearly spans frontend and backend and one worker can safely own the whole path without causing broad churn.
- Do not use `fullstack-developer` for large, ambiguous, or architecture-heavy changes. Split those into `frontend-developer` and `backend-developer`.

### Specialist line

- Use `react-specialist` only when the main task has React-specific complexity such as hooks, rendering behavior, effect safety, component ownership, or performance-sensitive UI behavior.
- Use `typescript-pro` only when the task is materially about type boundaries, generics, interface design, compiler-driven fixes, or contract safety in TypeScript.
- Use `python-pro` only when the task is materially about Python runtime behavior, packaging, typing, testing, scripts, or Python framework implementation.
- Use `sql-pro` only when the task is materially about SQL correctness, joins, aggregation, migration analysis, execution-plan risk, or schema-aware query debugging.
- Specialists should deepen a narrow part of the task. They should not replace the main owner unless the task is primarily within that specialty.

### Review and QA line

- Use `code-reviewer` after implementation when you need maintainability, correctness, readability, regression-risk, or risky implementation-choice review.
- Use `qa-expert` after implementation or before release when you need acceptance coverage, boundary scenarios, release gating, or risk-based QA guidance.
- For high-risk work, prefer this sequence:
  1. `architect-reviewer`
  2. `code-reviewer`
  3. `qa-expert`

### Delegation patterns

- UI-heavy feature:
  - `ui-designer` -> `frontend-developer` -> `react-specialist` or `typescript-pro` if needed -> `code-reviewer` -> `qa-expert`
- API or backend-heavy feature:
  - `api-designer` -> `backend-developer` -> `sql-pro` or `python-pro` if needed -> `code-reviewer` -> `qa-expert`
- Bounded end-to-end feature:
  - `ui-designer` and/or `api-designer` -> `fullstack-developer` -> specialist if needed -> `code-reviewer` -> `qa-expert`
- Architecture-sensitive change:
  - `architect-reviewer` first, then implementation agent, then `code-reviewer`, then `qa-expert`
- Multi-agent synthesis needed:
  - Always finish with `knowledge-synthesizer`

### Safety and scope control

- Each implementation agent must prefer the smallest coherent change.
- Avoid broad refactors unless explicitly requested.
- Avoid mixing design recommendations, implementation, and review findings in one agent unless the task is intentionally bounded and small.
- If a task is unclear, first map the boundary and choose the narrowest qualified subagent.
- If design is unresolved, do not jump straight into implementation. Delegate design first.
