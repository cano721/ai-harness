export const meta = {
  name: 'fix-bug',
  description: 'Fix an already-approved, evidence-backed bug through regression verification, review, and repair',
}

const input = args && typeof args === 'object' ? args : { brief: String(args ?? '') }
const brief = typeof input.brief === 'string' ? input.brief.trim() : ''

if (input.approved !== true || !brief) {
  return {
    status: 'approval_required',
    message: 'Run this only after the project-local /fix-bug entrypoint has presented a Bug Fix Brief and the user explicitly approved it. Pass { approved: true, brief: "..." }. No files were changed.',
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

Read AGENTS.md and the project bug-fix, testing, and convention documents first. Preserve or establish the approved reproduction evidence, then follow the project's test policy for the regression case and run targeted plus required broad verification. Do not broaden scope, commit, push, create a PR, or change a product decision without explicit authorization. Return the observed reproduction, suspected or confirmed cause, changed areas, and command/results evidence.
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

let review = await reviewBugFix()
if (review === null) {
  return { status: 'review_incomplete', fix, message: 'The reviewer did not complete; do not treat the bug fix as done.' }
}

for (let attempt = 1; review.blocking_findings.length > 0 && attempt <= 2; attempt += 1) {
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

  review = await reviewBugFix(review.blocking_findings)
  if (review === null) {
    return { status: 'review_incomplete', fix, attempt }
  }
}

if (review.blocking_findings.length > 0) {
  return {
    status: 'user_decision_required',
    fix,
    review,
    message: 'Blocking findings remain after two focused repair attempts. Stop and ask the user for a product or environment decision.',
  }
}

return {
  status: 'done',
  fix,
  review,
  message: 'The approved bug fix has reproduction or equivalent verification evidence, required checks were run, and no blocking review findings remain.',
}
