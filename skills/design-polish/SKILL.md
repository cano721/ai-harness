---
name: design-polish
description: Polish existing screens as a whole — hierarchy, spacing, color, consistency with sibling screens and the design rules — by measuring them in a real browser, listing what to fix with evidence, and (in a repository whose harness has the design-polish workflow) fixing the items the person picks and measuring again. Use when a working screen should look and read better ("이 화면 전반적으로 다듬어줘", "polish this page", "보드 화면 품질 좀 올려줘"). In a repository without that workflow it critiques and lists the fixes only. Do not use to draw a new screen or mockup (design-screen), to build a feature (implement-feature), to fix broken behavior (fix-bug), for a marketing page (landing-page), or to create design rules (design-system-builder).
---

# Design Polish

Make existing screens better against the project's own rules, with before-and-after evidence. A polish nobody measured is an opinion; this skill measures first and last.

## Route first

1. **The repository has the design-polish workflow** — `.ai-harness/workflows/design-polish-graph.json` exists. Follow the project entry instead of this file: `.claude/commands/design-polish.md` (Claude) or `.agents/skills/design-polish/SKILL.md` (Codex). It runs `bash .ai-harness/workflows/workflow-driver.sh start --workflow polish --request "<screens and what to improve>"`: baseline measure → independent diagnose → the person picks items → fix → checks → measure again → independent review, and publishes as the project's `git_policy` allows. Stop reading here.
2. **The repository has a harness but not this workflow** (`.ai-harness/harness.json` exists) — tell the person `/harness-init --sync --apply` adds it, then continue below for a critique now.
3. **No harness** — continue below. This path changes no file.

## Critique and fix list (no file changes)

1. **Find the screens and the rules.** Read the request, then find how to open the screens (README, package scripts, a static HTML file) and the design rules: a design rule document (`DESIGN.md`, `docs/design-system.md`, `docs/design/*.md`), tokens, shared components, and a reference screen (Storybook or an example page). Note what is missing; do not invent rules.
2. **Measure.** Open each target screen in a real browser (Playwright or the browser tool you have) at a mobile width (about 375px), a tablet width, and a desktop width, in every theme the screens support, in the default state before hovering. Save the captures outside the repository (for example `~/.ai-harness/polish/<repository>/<date>/`). Also capture one or two screens that share the target's components, so a later fix to a shared part is visible. Do not start servers with production credentials, and stop what you started.
3. **Critique independently.** Hand the captures and the rule sources to a reviewer that did not make the screens: the `ai-harness:design-reviewer` agent on Claude, or a fresh read-only session elsewhere. Give it the capture paths, the rule document path, and the request — not your conclusions. If no separate reviewer can run, critique yourself and say so in the report.
4. **Write the fix list,** most severe first, ids `P1`, `P2`, …. Each item: severity (major — a broken hierarchy or primary action, unreadable contrast or a missing focus state, a rule-document violation, a screen that disagrees with its siblings, a layout broken at a viewport or theme; minor — the rest worth fixing), what is wrong, evidence (the capture file and the rule-document section it breaks, when there is one), and the fix in tokens and shared components rather than raw values. Mark items a machine check could catch. Put anything that needs a product or content decision in a separate list.
5. **Report** the capture folder, the fix list, and the next step:
   - no design rule document or reference screen → `/ai-harness:design-system-builder` creates them; without them a polish cannot be scored, only critiqued;
   - rules exist but the repository has no harness → `/harness-init`, enabling the UI review and design scoring stacks (`ui`, `design-system`), adds this workflow with the measure–fix–review loop;
   - the person wants the fixes now anyway → the fixes are ordinary code changes; after them, capture the same screens at the same sizes again and compare before calling it done.

Do not edit the repository in this path, and do not report a screen as polished without an after measurement.
