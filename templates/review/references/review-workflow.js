export const meta = { name: 'review', description: 'Review a change and close blocking findings through verified re-review' }
const input = args && typeof args === 'object' ? args : { scope: String(args ?? '') }
const scope = typeof input.scope === 'string' ? input.scope.trim() : ''
const maxRepairs = Number.isInteger(input.max_repair_attempts) && input.max_repair_attempts > 0 ? input.max_repair_attempts : 10 // graph limits.max_repair_attempts
const uiScenarios = Array.isArray(input.ui_scenarios) ? input.ui_scenarios.filter((s) => typeof s === 'string' && s.trim()) : [] // screens the change alters; empty when users cannot see it
if (!scope) return { status: 'scope_required', message: 'Pass { scope: "PR, diff, or completed change", max_repair_attempts: <graph limits.max_repair_attempts>, ui_scenarios: [<scenarios for screens the change alters, if any>] }. No files were changed.' }
const schema = { type: 'object', required: ['summary', 'blocking_findings', 'non_blocking_findings'], properties: { summary: { type: 'string' }, blocking_findings: { type: 'array', items: { type: 'string' } }, non_blocking_findings: { type: 'array', items: { type: 'string' } } } }
const inspect = (prior = []) => agent(`Review the current repository diff for: ${scope}\nPrevious blocking findings: ${JSON.stringify(prior)}\nRead AGENTS.md and project review/testing docs. Do not edit files. Check behavior, required checks, security/data, compatibility, scope, and generated files. Return the requested schema.`, { label: 'review-change', schema })
const uiSchema = { type: 'object', required: ['status', 'summary', 'scenarios', 'blocking_findings', 'unverified'], properties: { scenarios: { type: 'array', items: { type: 'object', required: ['scenario', 'captures'], properties: { scenario: { type: 'string' }, captures: { type: 'array', items: { type: 'string' } } } } }, status: { type: 'string', enum: ['verified', 'issues', 'unverified'] }, summary: { type: 'string' }, blocking_findings: { type: 'array', items: { type: 'string' } }, unverified: { type: 'array', items: { type: 'string' } } } }
const uiReview = (prior = []) => agent(`Verify the screens this change alters (the graph's ui_review node). Do not edit, create, or delete any file in the repository; keep captures outside it.\nUI scenarios:\n${uiScenarios.map((s) => `- ${s}`).join('\n')}\nPrevious blocking UI findings: ${JSON.stringify(prior)}\nFollow the project ui-review skill (.agents/skills/ui-review or .claude/skills/ui-review, with references/checklist.md) and .ai-harness/docs/ui.md when they exist; project design rules come first. Start the app and operate every scenario in a real browser as a first-time user with mouse, keyboard, and a mobile-width viewport, in each supported theme, looking at default and collapsed states first. A test that clicked an element by text, a class or token in the markup, an attribute being set, or a screenshot file existing is not evidence. Return one scenarios entry per scenario, viewport, and theme you operated, with its captures. status: verified (nothing left in unverified), issues, or unverified (the app or a browser could not be used, or a required scenario, viewport, or theme was not checked).`, { label: 'ui-review', schema: uiSchema })
const check = async (prior = []) => {
  const r = await inspect(prior)
  if (r === null || r.blocking_findings.length || !uiScenarios.length) return r
  const ui = await uiReview(prior)
  return ui === null ? null : { ...r, ui, blocking_findings: ui.status === 'issues' && ui.blocking_findings.length > 0 ? [...ui.blocking_findings, ...ui.unverified.map((u) => `not yet verified: ${u}`)] : [] }
}
let review = await check()
if (review === null) return { status: 'review_incomplete', message: 'Do not treat the change as done.' }
for (let attempt = 1; review.blocking_findings.length > 0 && attempt <= maxRepairs; attempt += 1) {
  const repair = await agent(`Repair only these authorized blocking findings: ${JSON.stringify(review.blocking_findings)}\nFollow AGENTS.md and required checks. Do not commit, push, create a PR, or change scope.`, { label: `repair-review-findings-${attempt}` })
  if (repair === null) return { status: 'repair_incomplete', review, attempt }
  review = await check(review.blocking_findings)
  if (review === null) return { status: 'review_incomplete', attempt }
}
if (review.blocking_findings.length) return { status: 'user_decision_required', review, message: `Blocking findings remain after ${maxRepairs} repairs (the graph repair limit).` }
if (review.ui && (review.ui.status !== 'verified' || review.ui.unverified.length > 0 || review.ui.scenarios.length < uiScenarios.length)) return { status: 'ui_unverified', review, message: `Code review clean, UI unverified: ${review.ui.summary}. Do not treat the change as done.` }
return { status: 'done', review, message: 'No blocking findings remain after review and required re-review.' }
