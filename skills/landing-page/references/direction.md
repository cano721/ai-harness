# Direction

Decide what the page argues and how it should feel before choosing any value. A direction written down once keeps later layout and motion choices consistent.

## 1. Brief

Collect, from the request, the repository, and existing pages:

| Item | Question | If unknown |
|---|---|---|
| Audience | Who arrives, from where, knowing what? | Infer from the product and state the assumption |
| Action | The one thing a visitor should do | Ask — a page without a primary action has no measure of success |
| Proof | What real evidence exists: product UI, numbers, customers, demos | List what is missing; never fill it in |
| Constraints | Stack, deadline, languages, legal or brand rules | Read from the repository |
| Identity | Existing logo, colors, type, voice, earlier pages | Decides visual authority below |

Ambiguity:

- **Interactive session** — ask the open questions together, at most two or three, about intent and audience. Never ask for CSS values; propose them. Mockup questions (`design-handoff.md`) share one budget with these: at most five for the whole page.
- **Unattended run** — state your interpretation in one line at the top of the report and proceed.
- An explicit brief beats every default in this skill.

## 2. Visual authority

Decide whose visual language the page speaks before designing anything.

| Situation | Signal | Rule |
|---|---|---|
| Redesign | The user asks for a new look | New identity allowed; keep logo and name unless told otherwise |
| Established brand | A brand or product design system, or a consistent set of live pages, exists | Inherit the brand layer — no new fonts, colors, or component styles. Layout, composition, and pacing are still this page's to direct (see `SKILL.md` precedence) |
| Established marketing site | Live marketing pages with their own look exist | Inherit them whole, layout included |
| Incomplete | Some brand assets exist (logo, one color) but no system | Keep what exists, fill the gaps, and list every value you added |
| None | Nothing exists | A new identity is yours to propose; confirm the direction once |

Adding a section or page to an established site never justifies a new identity.

## 3. Direction candidates

Skip this step only when a mockup of this page or an established marketing site already decides the look. An established brand fixes the colors, typefaces, and voice of every candidate; the candidates differ in composition, pacing, imagery, and signature moment.

1. **Theme inventory** — list 8–12 concrete things the product is about: materials, verbs, places, rituals, artifacts its users handle. Avoid category clichés (circuits for software, leaves for sustainability).
2. **Idea sentence** — one sentence that states the page's point of view. Test it by substituting a competitor's name; if the sentence still holds, it says nothing.
3. **Candidates** — propose two or three directions, built from the references the user kept (section 7), each naming the references it draws on, with: the idea sentence, type character, color strategy, one signature moment, and what it rules out. Always include one restrained standard option as an exit.
4. **Pick one.** In an unattended run, pick and give the reason in one line.

Record the chosen direction in the report (idea, audience, action, color strategy, type pair, signature moment). Keep it out of the code.

## 4. Sections

- Each section makes one **claim** and shows **evidence** for it. Order sections by the argument, not by a stock template (hero → features → testimonials → pricing → CTA is a fallback, not a plan).
- The first viewport states the thesis and shows proof of it: the product itself, a result, or a concrete scene. A headline alone is not a thesis.
- For software, show real interface fragments at legible size instead of icon grids or abstract illustrations.
- Remove any section whose claim repeats another.

### Per width

Plan the phone composition with the sections, not after the desktop page is built. One responsive page serves every width; separate desktop and mobile pages only when the user or the site's infrastructure requires them.

- For each section, write what changes at phone width: order, what collapses or drops, how a row of items regroups (a four-across row becomes two-by-two, a horizontal swipe row, or one featured item).
- The phone's first screen holds the thesis and the primary action; name what moves below it.
- Images that need a different crop at phone width get one through `<picture>` sources (art direction), not just scaling.
- A mockup for both widths is followed for each. A desktop-only mockup leaves the phone to this plan; say "no phone mockup" in the report.

## 5. Evidence

- Never fabricate testimonials, logos, metrics, user counts, ratings, press, or awards. Where real evidence is missing, insert a visibly labeled placeholder (for example `[고객 후기 필요]`) and list each one in the report. Mark each with `data-needs-input`; a page with one still visible is `issues (공개 불가: 입력 대기)`, not ready to publish.
- An offer the sources mention without its terms (a free trial, a credit, a discount) is a claim too: until its terms are confirmed, leave it out and list it as `사용자 입력 필요`.
- Implied claims need evidence too. A heading like "most popular questions" claims popularity; without data, describe instead ("questions people practice for each role").
- Example data inside a product mockup (a sample report, a score) is labeled as an example on the page and never used as a claim.
- Say what the product is in the first viewport in plain words. When imagery could suggest a different kind of product (photos of people for an automated service), the headline or lead says what it is.
- Images: record the source and license of every image or video; generated images are labeled as such in the report.
- A form with no backend: use `mailto:` or a disabled state and say in the report that it is not connected.
- An action whose destination is unknown is a `사용자 입력 필요` item in the report. Do not point it at the page itself to make it look like it works.
- A secondary action whose content does not exist yet (a sample clip, a demo) is left out until it does, rather than opening an empty placeholder.
- Facts come from the sources the user named. A source that turns out to hold another company's material is a reference for structure only; none of its facts are the product's.

## 6. Copy

- Buttons: one to three words, a verb about the visitor's outcome. One primary action per view; secondary actions are visually quieter.
- Headlines say something specific enough to be wrong.
- Generated-copy tells. Each one costs credibility; rewrite unless the brief asks for it.
  - English: "unlock", "elevate", "seamless", "supercharge", "revolutionize", "in today's fast-paced world", "not just X — it's Y", triplets of adjectives.
  - Korean: "~의 새로운 기준", "혁신적인", "차원이 다른", "한 단계 업그레이드", "~을 경험하세요", "여정", "단 하나의", "완벽한", rhythmic triplets ("빠르고, 쉽고, 안전하게"), sentences that read as translations ("~하는 것을 가능하게 합니다"), em-dash chains.
- Write Korean copy as Korean first; do not translate an English draft line by line.

## 7. References

Look at references before writing candidates — this step is not optional. Having enough product material is not a reason to skip it; references inform composition and pacing, not content. Skip only when the user says so. Use every source below that is available, in this order; one does not replace the next:

1. Sites the user names as references. When `awesome-design` is installed and holds a specification for a named site, read its `design-md/<site>/DESIGN.md` file directly — for how that site handles type, color, and spacing, never as values to import. Do not run that skill's own procedure; it copies the specification into the project. Other companies' material inside a source the user gave for product facts is not this; it counts as structure-only input (section 5).
2. The curated library of `design-taste-frontend`, when installed (its lane in `design-skills.md`) — craft and composition. Invoke the skill rather than reading its files, so its own procedure picks the entries — and run only its drawing of directions and section blueprints. Its build steps, house rules, font and image hosts do not apply here: the brand layer and the Non-negotiables win, and what it writes to the working folder is not page output.
3. Three to five live pages for products in the same category, found by web search — how that category orders its argument. Search often returns listings and articles instead of product sites; then open the category's known product sites directly and say they did not come from search. In a session without web access, say so.

References set mood and structure only — density, pacing, temperature, how the argument is ordered. Do not copy layouts, illustrations, copy, or brand marks from another company. Record each reference's URL and what you took from it in the report. Look at the pages, not only their text: capture the first viewport at desktop and phone width in a fresh headless browser context (a throwaway profile: no saved logins or cookies), JavaScript on — many sites render nothing without it. A blank or half-drawn capture is not a look at the page: retake it after the page settles, or drop that page and say so. A text-only fetch shows the argument's order but not density or temperature; say which you used. Third-party designs used as input follow the rights check in `design-handoff.md`.

**Reference board — the user's pick comes before the candidates.** People judge real pages far better than described directions, so in an interactive session show what you collected before writing candidates: one local HTML page (a question dialog cannot show images) with five to eight references, each with its desktop and phone captures, URL, source (user, library, search, or opened directly), and one line on what you would take from it. Ask once, as one of the page's questions: which ones to keep, which to avoid, and any site the user wants added. Build the candidates from the kept ones; a reference the user rejected does not come back. Skip the board when the user already named the references and asked for nothing more. In an unattended run, choose yourself and record what you kept, what you dropped, and why.
