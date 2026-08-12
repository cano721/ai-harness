export const meta = { name: 'review', description: 'Review a change and close blocking findings through verified re-review' }
const input = args && typeof args === 'object' ? args : { scope: String(args ?? '') }
const scope = typeof input.scope === 'string' ? input.scope.trim() : ''
if (!scope) return { status: 'scope_required', message: 'Pass { scope: "PR, diff, or completed change" }. No files were changed.' }
const schema = { type: 'object', required: ['summary', 'blocking_findings', 'non_blocking_findings'], properties: { summary: { type: 'string' }, blocking_findings: { type: 'array', items: { type: 'string' } }, non_blocking_findings: { type: 'array', items: { type: 'string' } } } }
const inspect = (prior = []) => agent(`Review the current repository diff for: ${scope}\nPrevious blocking findings: ${JSON.stringify(prior)}\nRead AGENTS.md and project review/testing docs. Do not edit files. Check behavior, required checks, security/data, compatibility, scope, and generated files. Return the requested schema.`, { label: 'review-change', schema })
let review = await inspect()
if (review === null) return { status: 'review_incomplete', message: 'Do not treat the change as done.' }
for (let attempt = 1; review.blocking_findings.length > 0 && attempt <= 2; attempt += 1) {
  const repair = await agent(`Repair only these authorized blocking findings: ${JSON.stringify(review.blocking_findings)}\nFollow AGENTS.md and required checks. Do not commit, push, create a PR, or change scope.`, { label: `repair-review-findings-${attempt}` })
  if (repair === null) return { status: 'repair_incomplete', review, attempt }
  review = await inspect(review.blocking_findings)
  if (review === null) return { status: 'review_incomplete', attempt }
}
if (review.blocking_findings.length) return { status: 'user_decision_required', review, message: 'Blocking findings remain after two focused repairs.' }
return { status: 'done', review, message: 'No blocking findings remain after review and required re-review.' }
