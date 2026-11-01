# Design Handoff

How to turn a mockup — Figma file, image, HTML prototype, or screen recording — into an implementation that respects the project's design system, and how to report the differences. Project documentation overrides every number and default here.

## 1. Before writing code

Inventory the mockup: which screens, states (default, hover, focus, error, empty, loading), viewports, and themes it covers. Anything it does not cover is decided by the design system, not invented to look like the mockup.

Then compare every value in the mockup with the design system's tokens and components.

### Tolerance

Values within tolerance are the mockup approximating a token. Use the token silently and list the adjustment in the report.

| Property | Within tolerance when |
|---|---|
| Spacing, radius | ±2px, or less than half the gap to the neighboring step |
| Font size | ±1px |
| Color | ΔE2000 under 3 |
| Duration | ±20ms |

### Classifying a difference

| Kind | Example | Action |
|---|---|---|
| No token | A color or spacing value with no matching token | Ask (see question budget) |
| One-off implementation | A hand-built button that duplicates an existing component | Use the existing component |
| Concept mismatch | A structure that differs from how sibling screens do the same job | Build it as the mockup shows, and record it as pending a rule decision |
| Local defect | Misaligned element, inconsistent padding within one card, a typo | Fix silently and list it |

### Question budget

- New values not in the tokens, and patterns the existing components cannot express, are asked about once per screen, at most three to five questions, each with a recommended default.
- Everything else proceeds on the recommended default and is listed in the report.

### Accessibility violations

Insufficient contrast (WCAG 2.2 SC 1.4.3, 1.4.11), meaning carried by color alone (SC 1.4.1), and targets smaller than 24×24 CSS px (SC 2.5.8) get a strong warning with a concrete fix. In an unattended run, apply the fix and report the mockup's original value next to it.

### Structure and flow

Layout structure, content order, and user flow follow the mockup. Values reconcile to tokens; structure does not.

## 2. No design system

Extract the mockup's values — colors, type sizes, spacing, radii, shadows, durations — into a token draft. Leave out values that are defects (one-pixel inconsistencies, failing contrast pairs). Confirm the draft with the user once. Until confirmed, the draft lives in the report or pull request, not in design-system documentation.

## 3. Unattended runs

- Proceed on design-system defaults. Do not create new tokens on your own.
- Record every open decision in the pull request description, each with the default you applied.
- Never act as the human approver. A decision that needs approval stays open.

## 4. Review against the mockup

- Capture the mockup and the implementation side by side in the same state, viewport, and theme.
- Classify every difference:

| Class | Meaning |
|---|---|
| Match | Same within tolerance |
| Adjusted | Changed to a token or for accessibility, and listed |
| Missing | In the mockup, not implemented |
| Conflicting | Implemented differently from the mockup without a recorded reason |
| Added without approval | Implemented but not in the mockup or the request |

Missing and conflicting items are candidates for major findings.

## 5. Video mockups

Label every timing value extracted from a recording `measured` (read from frame positions) or `estimated` (judged by eye or inferred). When two estimates disagree, report a range rather than picking one.

## 6. Third-party designs

When the input is another company's site or design, confirm the user has the right to use it. Study it for structure and pacing; do not copy its brand marks, illustrations, photography, or copy.

## Report

- Adjusted to tokens (value → token).
- Local defects fixed.
- Accessibility fixes, with original values.
- Open questions and the defaults applied.
- Concept mismatches pending a rule decision.
- Token draft, if one was made.
- Side-by-side review classification.
