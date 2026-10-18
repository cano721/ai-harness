export const meta = {
  name: 'implement-feature',
  description: 'Deliver an already-approved feature through implementation, review, repair, and verification',
}

const input = args && typeof args === 'object' ? args : { brief: String(args ?? '') }
const brief = typeof input.brief === 'string' ? input.brief.trim() : ''
// The repair limit belongs to the project graph (limits.max_repair_attempts); the entrypoint passes it in.
const maxRepairs = Number.isInteger(input.max_repair_attempts) && input.max_repair_attempts > 0 ? input.max_repair_attempts : 10

if (input.approved !== true || !brief) {
  return {
    status: 'approval_required',
    message: 'Run this only after the project-local /implement-feature entrypoint has presented an Implementation Brief and it was approved (explicitly by the user, or by policy when .ai-harness/harness.json sets approval to auto). Pass { approved: true, brief: "...", max_repair_attempts: <graph limits.max_repair_attempts> }. No files were changed.',
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

const deliver = await agent(`
Implement the approved feature below in the current repository.

Approved Implementation Brief:
${brief}

Read AGENTS.md and project workflow/testing documents first. Follow the project's test policy: use Red → Green → Refactor only when TDD is required; otherwise follow its required, recommended, or available verification rules. Deliver all approved slices, run their required checks and the required broad verification. Do not commit, push, create a PR, or change scope; the entrypoint handles git as the project git_policy says. Return a concise summary of changed areas and commands/results.
`, { label: 'deliver-approved-feature' })

if (deliver === null) {
  return { status: 'interrupted', message: 'The delivery agent did not complete. No completion claim is made.' }
}

const reviewFeature = async (previousFindings = []) => agent(`
Review the current repository diff against this approved feature brief:
${brief}

Previous blocking findings, if any:
${JSON.stringify(previousFindings)}

Do not edit files. Check acceptance cases, regressions, security/data risk, required verification, scope violations, and unnecessary abstraction. A blocking finding is incorrect or missing behavior, a regression, security/data risk, a broken required check, or a material scope violation. Return findings using the requested schema.
`, { label: 'review-feature', schema: reviewSchema })

let review = await reviewFeature()
if (review === null) {
  return { status: 'review_incomplete', delivery: deliver, message: 'The reviewer did not complete; do not treat the feature as done.' }
}

for (let attempt = 1; review.blocking_findings.length > 0 && attempt <= maxRepairs; attempt += 1) {
  const repair = await agent(`
Repair only these blocking findings for the approved feature. Follow AGENTS.md and the project test policy. Route missing behavior through the appropriate delivery slice, then run affected targeted checks and required broad verification. Do not commit, push, create a PR, or change unrelated files.

Approved brief:
${brief}

Blocking findings:
${JSON.stringify(review.blocking_findings)}
`, { label: `repair-blocking-findings-${attempt}` })

  if (repair === null) {
    return { status: 'repair_incomplete', delivery: deliver, review, attempt }
  }

  review = await reviewFeature(review.blocking_findings)
  if (review === null) {
    return { status: 'review_incomplete', delivery: deliver, attempt }
  }
}

if (review.blocking_findings.length > 0) {
  return {
    status: 'user_decision_required',
    delivery: deliver,
    review,
    message: `Blocking findings remain after ${maxRepairs} repair attempts (the graph repair limit). Stop and ask the user for a product or technical decision.`,
  }
}

return {
  status: 'done',
  delivery: deliver,
  review,
  message: 'All approved acceptance cases were delivered, required checks were run by the delivery/repair agents, and no blocking review findings remain.',
}
