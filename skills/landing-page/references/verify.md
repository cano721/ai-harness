# Verify

A page is done when it has been looked at, by someone other than its maker, and nothing major is left — not when it builds. The verdicts, the meaning of a major problem, and the false-pass list are the same as the harness `ui-review` contract, so a page reads the same way whichever path checked it.

## Which loop runs

- **The repository has an ai-harness UI contract** (`.claude/skills/ui-review/` or `.agents/skills/ui-review/`, or the task runs inside a workflow with a `ui_review` node): build and run the self-check below, then hand the page to that contract. Its `ui_review` node is the gate; do not run a second review loop here.
- **Otherwise** run the loop in this file.

```
build → self-check (measured) → independent review → fix majors → independent review   (at most 3 reviews)
```

## Tools and serving

- **Browser:** any of — the session's browser tool, Orca's embedded browser, Playwright or headless Chrome already installed on the machine. Installing one needs the user's approval like any package. Locate an existing Playwright before giving up (a global or `~/.npm/_npx/*/node_modules/playwright` install can be required by absolute path); pick a version whose browser revision is already downloaded.
- **States** with Playwright: `page.emulateMedia({ reducedMotion: "reduce" })`, `page.emulateMedia({ forcedColors: "active" })`, a context with `javaScriptEnabled: false`, `colorScheme` for themes.
- **Serve, do not open `file://`** — module scripts and some fonts fail under `file://`. Use a static server on a free port, then fetch the page once and confirm the response is this page (its `<title>`) before measuring; a stale server on the same port answers with someone else's page.
- **Static checks** need no browser and are never left unverified for lack of one: metadata, `lang`, landmarks, one `h1`, `alt` attributes, link targets, JSON-LD, external hosts referenced.

## Self-check (measured)

Viewports 1440, 768, 390, and 320 (reflow, WCAG 2.2 SC 1.4.10); every theme the site supports; after motion settles or with reduced motion on. Measure with `getBoundingClientRect()` and computed styles; do not judge by eye.

**Values the design system or the reconciled mockup set are not defects here.** The defaults in this skill are not standards to enforce against them. Only the accessibility floors apply to every value; when a design-system pair fails one, follow the substitution rule in `SKILL.md`. A default the page breaks without a system value behind it is a finding; a system value that differs from a default is at most a note.

| Check | Defect when |
|---|---|
| Destinations | The primary action, or any link, leads nowhere real (`#`, a self-anchor loop, an empty `href`) |
| Placeholders | A `[... 필요]`-style placeholder is visible to visitors |
| Claims | A claim of popularity, quantity, rank, or result ("많이", "인기", "N명이") without evidence on the page |
| First action | The primary action is not inside the first viewport |
| Contrast | Below WCAG AA (4.5:1 text, 3:1 large text, UI boundaries, focus). Over images or gradients, sample the rendered pixels behind the text, not computed colors |
| Overflow | Horizontal scroll or clipped text at any viewport |
| Headline lines | More than two at desktop, or an orphaned syllable group (no design-system rule set otherwise) |
| Assets | Broken images; a fallback face rendering where the intended font was approved and loaded |
| Size floor | Body under 15px or small text under 13px when the design system has no smaller step for that role (the 16–20px body in `layout-type.md` is a default, not the floor) |

## Independent review

Each review runs in a fresh reviewer that did not build the page: the `ai-harness:design-reviewer` agent, or a new session. Give it only:

- the served URL or file path, how to serve it, viewports and states to check;
- the audience and the one action the page exists for;
- where the design evidence is (design system, rule document, token mirror);
- the marketing checks below;
- the design evidence counts even when it is marked `draft`; the reviewer reads it;
- the `사용자 입력 필요` list so far, as facts only — what is missing, the evidence that the user has not supplied it (their words quoted, or "not in the request or sources"), and the `data-needs-input` element where it sits;
- from the second round, the previous round's findings and what changed since.

Not your direction notes, not your report, not "I fixed it". It does not edit files. The reviewer checks each `사용자 입력 필요` item: if it really needs the user it is reported under its own heading and **keeps the verdict at `issues`** — the list never turns a major into a pass; if the reviewer finds it fixable without the user, or the page does not match the list, it becomes an ordinary major. Without a way to start a fresh reviewer (for example a host without subagents), review yourself against the same list and mark the result `자기 검토`; a `자기 검토` result is at best `unverified`, never `verified`.

Marketing checks the reviewer adds to its own criteria:

- One-second view: what is this about, and what kind of product is it — could the imagery suggest a different kind of product than it is? Five-second view: what should I do?
- Squint: the claim and the action stay dominant.
- Cover the logo: could a competitor own this page? Generic is a finding when nothing on the page belongs only to this product.
- Does every visible action lead somewhere, and does every element that looks interactive respond?
- Is every claim either evidenced on the page or phrased as a description rather than a claim?
- Phone: composed, not shrunk.
- Tells: patterns from the tell lists in `direction.md`, `layout-type.md`, and `motion-web.md` that the direction did not choose.

## Verdicts

| Verdict | When |
|---|---|
| `verified` | Every viewport, theme, reduced-motion and no-JS state was rendered and operated (the state checks below), an independent review found no major problem, and the `사용자 입력 필요` list is empty |
| `issues` | One or more major problems remain, or the `사용자 입력 필요` list is not empty — `issues (공개 불가: 입력 대기)` when those are all that remain |
| `unverified` | The page could not be rendered or operated, or a required viewport, theme, or state was not actually checked |

A **major problem** (the same definition as the harness `ui-review` contract, repeated here so it applies without one):

- the visitor cannot find or misreads the main action, or an action's name differs from its result;
- a required input or an error cannot be recovered from;
- a flow cannot be completed by keyboard, or at a supported viewport or theme;
- a one-off build where a shared component of the same role exists;
- a hard-to-undo action without confirmation;
- for a public page, also: an action with no real destination, a placeholder visible to visitors, a claim without evidence, a page that misstates what the product is.

Spacing and alignment that do not change any of that are minor.

`unverified` is not done. A major problem left in the page is not done.

## Fix loop and stopping

- Run the built-in `web-design-guidelines` check after the first review's fixes, so the last reviews see its result. Its rules assume English UI copy (title case, straight quotes); where they conflict with the project's own copy rules or the page's language, the project wins — note which rules you skipped.

- Fix majors first, highest impact first; then minors that are cheap. Re-capture the same states after fixing; "fixed" is not evidence.
- **Needs the user** — a real URL, a media asset, legal text, a business fact, a product decision, the conditions behind an offer the sources mention without terms — is not a fix the loop can make. Classify it as `사용자 입력 필요` and keep it in the list: no review banner on the page. In the page, the item takes its least misleading form, marked with `data-needs-input`:
  - an unknown destination: a `<button type="button" aria-disabled="true">` with the visible label and a short visible reason, so it stays focusable and announced; the first-action check counts it as `사용자 입력 필요`, not as a pass;
  - missing legal or business text: a labeled placeholder where it belongs;
  - an offer with unconfirmed terms: left out.

  A placeholder that carries `data-needs-input` and is on the list is not a second finding; it is why the page stays at `issues (공개 불가: 입력 대기)`.
- **When the only majors left are `사용자 입력 필요` items, stop.** The page ends as `issues (공개 불가: 입력 대기)` with the list; do not spend the remaining reviews on them.
- Never clear a finding by deleting the section that makes the page's argument, by weakening a claim the brief asked for into nothing, or by changing design-system values. A claim without evidence is rewritten as a description of what the product does, or gets a placeholder and goes to `사용자 입력 필요`.
- **At most three reviews.** After the third, report what remains with its evidence. A review that could not finish counts and is reported as such.
- **In a harness repository** the `ui_review` gate has no `사용자 입력 필요` class; list those items as product decisions in the brief or pull request, which the workflow routes to `user_decision` instead of repair.

## State checks

- Hover, and `:focus-visible` on every interactive element.
- Form errors, empty or missing data, overlong text (long names, long Korean words without spaces).
- Keyboard only: skip link first, logical tab order, visible focus, no trap; a horizontally scrolling region is reachable.
- JavaScript disabled (or the motion script blocked): all content visible, links and forms usable.
- `prefers-reduced-motion: reduce`: no movement beyond opacity and color; nothing missing.
- `forced-colors: active`: borders, focus rings, and icons remain visible; no meaning carried only by background images or color.

## False passes

None of these is evidence on its own:

| Looks like evidence | What it misses | Check instead |
|---|---|---|
| A browser test found the element by text and clicked it | Whether a person recognizes it as clickable | Point at each control on the default-state capture |
| The right class or token is in the markup | Whether other CSS overrode it | The rendered look against the design system |
| A capture file exists | Which state, viewport, and theme it shows | One capture per state checked |
| An attribute (`aria-expanded`, a theme flag) is set | Whether the rendering changes with it | Render each state separately |
| "Fixed" in a report | Whether the page changed | A new capture of the same state after the fix |
| The self-check passed | Everything a maker does not see in their own page | An independent review |

## Accessibility details

- Skip link to `main`; landmarks `header`, `nav` (when there is navigation), `main`, `footer`; one `h1`.
- Meaningful `alt` on content images, empty `alt` on decorative ones.
- Video with speech has captions (SC 1.2.2); autoplay video is muted and has a pause control.
- Auto-moving content longer than five seconds can be paused (SC 2.2.2).
- Target size at least 24×24 CSS px, or enough spacing around a smaller target (SC 2.5.8); visible focus (SC 2.4.7).
- A horizontally scrolling region is reachable by keyboard (`tabindex="0"` with a label) or is not used for content.
- Elements styled as cards or buttons either respond to input or do not look interactive.

## SEO and sharing

- Unique `<title>` and meta description; `lang` on `<html>`; canonical URL.
- Open Graph `og:title`, `og:description`, `og:image` (1200×630), `og:url`; `twitter:card`. A missing share image is a placeholder in the report.
- Favicon set.
- JSON-LD (`Organization`, `Product`, or `SoftwareApplication`) only for facts visible on the page — no invented ratings or prices.
- For a multi-page site: `robots.txt` and `sitemap.xml`.

## Performance

Field targets at the 75th percentile, mobile (Core Web Vitals "good": LCP ≤ 2.5s, CLS ≤ 0.1, INP ≤ 200ms) cannot be measured on a page with no traffic. Report a lab run (Lighthouse or the browser's performance panel) with the tool and settings, using TBT as the stand-in for INP; without one, performance is `unverified`.

- The LCP element is text or a hero image with `fetchpriority="high"`, never something revealed by animation.
- Images in AVIF/WebP with `srcset`; dimensions set.
- Fonts: WOFF2, subset, at most two families; preload only the first-viewport file.
- Motion and WebGL code loads after first paint and only where used.

## Legal and analytics

Analytics, cookie or tracking consent, privacy notice, and required business information: check the applicable country's law and the product's policy; do not invent the text. Missing legal text is `사용자 입력 필요`.

## Report

Per viewport, theme, and state: what was checked, evidence (capture paths, measurements), and the verdict. Then each review round in one line (`1차 issues 4 → 2차 issues 1 (입력 대기) …`), whether the reviews were independent, the `사용자 입력 필요` list, and what stayed unverified.
