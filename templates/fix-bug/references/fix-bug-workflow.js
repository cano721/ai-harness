export const meta = {
  name: 'fix-bug',
  description: 'Fix an already-approved, evidence-backed bug through regression verification, review, and repair',
}

const input = args && typeof args === 'object' ? args : { brief: String(args ?? '') }
const brief = typeof input.brief === 'string' ? input.brief.trim() : ''
// The repair limit belongs to the project graph (limits.max_repair_attempts); the entrypoint passes it in.
const maxRepairs = Number.isInteger(input.max_repair_attempts) && input.max_repair_attempts > 0 ? input.max_repair_attempts : 10
// The approved brief's ui_scenarios; empty when users cannot see the change.
const uiScenarios = Array.isArray(input.ui_scenarios) ? input.ui_scenarios.filter((s) => typeof s === 'string' && s.trim()) : []

if (input.approved !== true || !brief) {
  return {
    status: 'approval_required',
    message: 'Run this only after the project-local /fix-bug entrypoint has presented a Bug Fix Brief and it was approved (explicitly by the user, or by policy when .ai-harness/harness.json sets approval to auto). Pass { approved: true, brief: "...", max_repair_attempts: <graph limits.max_repair_attempts>, ui_scenarios: [<the brief's UI scenarios, if any>] }. No files were changed.',
  }
}

const reviewSchema = {
  type: 'object',
  required: ['summary', 'blocking_findings', 'non_blocking_findings'],
  properties: {
    summary: { type: 'string' },
    blocking_findings: { type: 'array', items: { type: 'string' } },
    non_blocking_findings: { type: 'array', items: { type: 'string' } },
  },
}

const fix = await agent(`
Fix the approved bug below in the current repository.

Approved Bug Fix Brief:
${brief}

Read AGENTS.md and the project bug-fix, testing, and convention documents first. Preserve or establish the approved reproduction evidence, then follow the project's test policy for the regression case and run targeted plus required broad verification. Do not broaden scope, commit, push, create a PR, or change a product decision; the entrypoint handles git as the project git_policy says. Return the observed reproduction, suspected or confirmed cause, changed areas, and command/results evidence.
`, { label: 'fix-approved-bug' })

if (fix === null) {
  return { status: 'interrupted', message: 'The bug-fix agent did not complete. No completion claim is made.' }
}

const reviewBugFix = async (previousFindings = []) => agent(`
Review the current repository diff against this approved Bug Fix Brief:
${brief}

Previous blocking findings, if any:
${JSON.stringify(previousFindings)}

Do not edit files. Check reproduction or equivalent verification evidence, expected behavior, regressions, compatibility/data risk, required verification, and scope violations. A blocking finding is missing or incorrect behavior, unverified reproduction/verification evidence, a regression, security/data risk, a broken required check, or a material scope violation. Return findings using the requested schema.
`, { label: 'review-bug-fix', schema: reviewSchema })

// Screens the change alters are verified by rendering and operating them, not by reading code (the graph's ui_review node).
const uiSchema = {
  type: 'object',
  required: ['status', 'summary', 'blocking_findings', 'unverified'],
  properties: {
    status: { type: 'string', enum: ['verified', 'issues', 'unverified'] },
    summary: { type: 'string' },
    blocking_findings: { type: 'array', items: { type: 'string' } },
    unverified: { type: 'array', items: { type: 'string' } },
  },
}

const uiReview = async (previousFindings = []) => agent(`
Verify the screens this change alters. Do not edit, create, or delete any file in the repository; keep captures and notes outside it.

UI scenarios:
${uiScenarios.map((s) => `- ${s}`).join('\n')}

Previous blocking UI findings, if any:
${JSON.stringify(previousFindings)}

Follow the project ui-review skill (.agents/skills/ui-review/SKILL.md or .claude/skills/ui-review/SKILL.md, with references/checklist.md) and .ai-harness/docs/ui.md when they exist; project design documents, semantic tokens, shared components, and reference screens come first. Start the app, open every scenario in a real browser, and operate it as a first-time user with mouse, keyboard, and a mobile-width viewport, in each supported theme. Look at the default and collapsed states before hovering or focusing anything. If a design-system example was added or changed, open and operate it too.
A test that clicked an element by its text, a class or token in the markup, an attribute being set, a screenshot file existing, or a claim that something was fixed is not evidence.
status: verified when every scenario was rendered and operated with no blocking UI issue and nothing left in unverified; issues when there is at least one; unverified when the app or a browser could not be used or a required scenario, viewport, or theme was not checked.
`, { label: 'ui-review', schema: uiSchema })

const reviewAndVerifyUi = async (previousFindings = []) => {
  const review = await reviewBugFix(previousFindings)
  if (review === null || review.blocking_findings.length > 0 || uiScenarios.length === 0) return review
  const ui = await uiReview(previousFindings)
  if (ui === null) return null
  return { ...review, ui, blocking_findings: ui.status === 'issues' ? [...ui.blocking_findings, ...ui.unverified.map((u) => `not yet verified: ${u}`)] : [] }
}

let review = await reviewAndVerifyUi()
if (review === null) {
  return { status: 'review_incomplete', fix, message: 'The reviewer did not complete; do not treat the bug fix as done.' }
}

for (let attempt = 1; review.blocking_findings.length > 0 && attempt <= maxRepairs; attempt += 1) {
  const repair = await agent(`
Repair only these blocking findings for the approved bug fix. Follow AGENTS.md, preserve or improve regression evidence, and run affected targeted checks plus required broad verification. Do not commit, push, create a PR, or make unrelated changes.

Approved brief:
${brief}

Blocking findings:
${JSON.stringify(review.blocking_findings)}
`, { label: `repair-bug-fix-${attempt}` })

  if (repair === null) {
    return { status: 'repair_incomplete', fix, review, attempt }
  }

  review = await reviewAndVerifyUi(review.blocking_findings)
  if (review === null) {
    return { status: 'review_incomplete', fix, attempt }
  }
}

if (review.blocking_findings.length > 0) {
  return {
    status: 'user_decision_required',
    fix,
    review,
    message: `Blocking findings remain after ${maxRepairs} repair attempts (the graph repair limit). Stop and ask the user for a product or environment decision.`,
  }
}

if (review.ui && (review.ui.status !== 'verified' || review.ui.unverified.length > 0)) {
  return {
    status: 'ui_unverified',
    fix,
    review,
    message: `Implementation done, UI unverified: ${review.ui.summary}. Report what blocked verification; do not call this done.`,
  }
}

return {
  status: 'done',
  fix,
  review,
  message: 'The approved bug fix has reproduction or equivalent verification evidence, required checks were run, and no blocking review findings remain.',
}
