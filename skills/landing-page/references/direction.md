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
| Tone and manner | How the page should feel, and how it must not | Propose it from the identity and audience; the user confirms it on the reference board |

Write the tone and manner under `## Tone and manner` in `brief.md` (the runner refuses a brief without it): three mood words and the feeling to avoid ("calm, encouraging, precise — not a test, not a hype campaign"), the palette (brand anchor and neutrals from the design system, with hex values), the type (faces and weights for display and body), a sample line in the page's voice, and the imagery (photo, illustration, 3D, product UI). Write the same content to `tone.json`, which the reference board draws: `{mood: [three words], avoid, palette: [{name, hex, role}], type: {display, body, display_sample, body_sample}, voice, imagery}` — the runner refuses it without exactly three mood words or with a palette entry that is not a hex color.

Ambiguity:

- **Interactive session** — ask the open questions together, at most two or three, about intent and audience. Never ask for CSS values; propose them. Mockup questions (`design-handoff.md`) share one budget with these: at most five for the whole page.
- **Unattended run** — state your interpretation in one line at the top of the report and proceed.
- An explicit brief beats every default in this skill.

## 2. Visual authority

Decide whose visual language the page speaks before designing anything.

| Situation | Signal | Rule |
|---|---|---|
| Redesign | The user asks for a new look | New identity allowed; keep logo and name unless told otherwise |
| Established brand | A brand or product design system, or a consistent set of live pages, exists | Keep the brand anchors (logo, name, one brand color, voice) and the product's component styles where product UI appears. Display type, extra colors, imagery, layout, composition, and pacing are this page's to direct (see `SKILL.md` precedence) |
| Established marketing site | Live marketing pages with their own look exist | Inherit them whole, layout included |
| Incomplete | Some brand assets exist (logo, one color) but no system | Keep what exists, fill the gaps, and list every value you added |
| None | Nothing exists | A new identity is yours to propose; confirm the direction once |

Adding a section or page to an established site never justifies a new identity.

## 3. Direction candidates

Skip this step only when a mockup of this page or an established marketing site already decides the look. An established brand fixes the anchors of every candidate (logo, name, one brand color, voice); everything else may differ.

1. **Theme inventory** — list 8–12 concrete things the product is about: materials, verbs, places, rituals, artifacts its users handle. Avoid category clichés (circuits for software, leaves for sustainability).
2. **Idea sentence** — one sentence that states the page's point of view. Test it by substituting a competitor's name; if the sentence still holds, it says nothing.
3. **Candidates** — propose two or three directions, built from the references the user kept (section 7), each naming the references it leads with in `primary_refs` (`{layout, interaction, components: {<slot id>: id|null}}` in `candidates.json`; the runner checks they are kept references of the right kind, and at least one candidate must lead with the picked primary exactly as picked — the others may lead with other kept references to differ) and the others it draws on, with: the idea sentence, type character, color strategy, one signature moment, its motion level and what the visitor can do on the page (`motion-web.md`), the outside resources it needs (a display face, video, a motion library — each needing approval), and what it rules out.
   - **They differ in the first viewport,** not only below it. The signature moment is visible in the first viewport at desktop and phone width. At most one candidate uses the text-left, visual-right hero.
   - **Not the stock hero.** A small colored label, a centered two-line headline, a paragraph, one or two buttons, and the visual stacked below or set to the right is the formula reviewers read as a template, whatever sits in the visual (a 3D ring under it does not change that). Compose the first viewport around the signature moment: the moment is the subject and fills the frame; the headline sits in it, on it, or beside it as part of one picture, and the action is reachable without the formula's stack. Write the composition for each candidate in one line (`first_viewport` in `candidates.json`), for desktop and phone, naming where the headline sits relative to the moment.
   - **They differ in what the visitor does.** Each candidate takes its interaction from a different kept interaction reference and names it; two candidates whose visitor action is the same verb (pick an option and read a scripted answer, for example) count as one. No interaction is fixed in advance — the references decide it.
   - **One bold, one restrained.** One candidate pushes as far as the brand anchors allow — scale, full-bleed imagery or color, an unexpected composition, a showpiece motion level; one is the restrained standard option as an exit.
   - In an unattended run, use only what the user approved in advance and keep the bold candidate within it.
4. **First-viewport drafts, then pick one.** In an interactive session, build only the first viewport of each candidate as a quick HTML draft (real copy, real assets, no polish), capture it at 1440 and 390, and show the captures side by side; the user picks, and only the pick is built as a page. Ask for the approvals the picked candidate needs at the same time. In an unattended run, every candidate's first viewport is drafted and reviewed (`draft_review`), and then one is finished: the runner holds each at `draft_choose` until all draft reviews are done, you pick one — one whose draft passed when there is one, otherwise one kept after its redo — and write `draft-pick.json` (`{kept: [id], dropped: [ids], via: "agent", reason}`), and submit `draft_choose` without a candidate. The others fold (`folded`); give the reason in the report. The runner refuses a second candidate entering `build` in an unattended run — two finished pages cost twice the time while the report uses one. When the user asks for more than one candidate built as a full page, build each in its own session or subagent, in its own folder, from the brief, the kept references, and its candidate alone — not from another candidate's files or an earlier round's page — so they do not converge.

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

Look at references before writing candidates — this step is not optional. Having enough product material is not a reason to skip it; references inform composition and pacing, not content. Skip only when the user says so (`references_skipped_by_user`, with `[]` in `references.json`).

**Gather them with the `design-references` procedure** (`$ROOT/skills/design-references/SKILL.md`), in `WORK`, with the run's mode: every search in one turn, every page captured by one `capture-refs` call, every bot check reopened in a real browser or swapped, `references.json`, `searches.json`, and `component-slots.json` with your recommendation starred, and `design-refs.sh check --mode <the run's mode>` passing. Do not write your own browser script for a reference. `landing-run.sh capture-refs` and `landing-run.sh board` are that skill's commands, and the runner's `submit` of `references_ready` runs the same check — enough of every kind for the mode, competitors on at least two domains, one site per kind, no `challenge` or `failed` capture left standing — so a set that fails it there fails here. Read section 5 for other companies' material inside a source the user gave for product facts (structure-only input), and `external-code.md` before taking anything from a gallery's code. In an interactive run the skill's served board is the one `reference_pick` shows; in an unattended run there is no board server and no wait.

The references feed the rest of this run: the take-lines (`take`, `keep_strength`, `must_not_shrink_to`) go into each candidate's build brief unchanged, the competitor analyses say where this page must not look interchangeable (`template_look`, a cover the logo could swap), and the report cites each reference's URL and what was taken from it. A text-only fetch shows the argument's order but not density or temperature; say which you used.

**Reference board — the user's pick comes before the candidates.** People judge real pages far better than described directions, so in an interactive session show what you collected before writing candidates. Do not write the board by hand: `landing-run.sh board --work "$WORK"` draws `board.html` (the `design-references` board: five tabs — 톤앤매너 with the tone shown rather than described, 구성요소, 레이아웃, 인터랙션, 경쟁사 분석 — each reference with its captures, URL, source, and take-line). A question dialog cannot show images, so the board is the page the user looks at. At `reference_pick`, serve it with `landing-run.sh board --port <n> --serve` (the board server on `WORK`, detached; the server the references step started on that port is reused; the user picks and starts on the board — SKILL.md, Picking on the board) and open `http://127.0.0.1:<port>/board.html`, never the file path — a `file://` page loses its images in browsers that block local files, Orca's among them — and look at it once (`capture`) to confirm every image and recording loads before asking. Ask once, as one of the page's questions: whether the tone and manner holds or what to change, the primary references (below), any reference never to use, and any site the user wants added — the board takes all of it and its start button records it, and a text answer in the session counts the same. Build the candidates around the primary references, with the rest as background; a reference the user excluded does not come back. The take-lines go into each candidate's build brief unchanged: borrowing means the mechanism at its strength, adapted to this product's content and brand — not a nod to it, and not the other company's composition. Skip the board when the user already named the references and asked for nothing more. In an unattended run, choose yourself and record what you kept, what you dropped, and why.

**Picking the primary references.** Asking the user to judge sixteen references one by one is hard, and a page that borrows from all of them has no reference leading it — the candidates blur. So each tab asks for its lead, not a sorting of everything:

| Tab | What is picked |
|---|---|
| 톤앤매너 | Nothing to pick: the tone holds, or what to change |
| 레이아웃 | One primary (★) |
| 인터랙션 | One primary (★) — the signature moment |
| 구성요소 | One primary per section slot, or none |
| 경쟁사 분석 | Nothing to pick: they are what the page is compared with |

The slots come from the section plan: in the references step write `component-slots.json` (`[{id, label}]`, ids in lowercase letters, digits, `-`, `_`) with each section that needs a reference of its own — the first viewport, proof, a feature tour, pricing, a comparison table, integrations, FAQ. A simple page has two; a page with many features has as many as it needs. Every section the user named in the request becomes a slot. Then star your recommendation in `references.json`: `recommended: "layout"` on one layout reference, `"interaction"` on one interaction reference, and a slot id on at most one component reference per slot (the runner refuses the step without the layout and interaction recommendations). The board shows them starred, and the user may move a star, empty a slot, or add a slot (「+ 섹션 추가」); pressing start without changing anything accepts them. References that are not starred stay as background; × still excludes one for good, and an excluded reference cannot be starred. The pick lands in `reference-pick.json` as `primary: {layout: id, interaction: id, components: {<slot id>: id|null}, added_slots: [{id, label}]}`, and the runner checks every id exists, has the right kind, and is not excluded. In an unattended run there is no board: write `reference-pick.json` yourself in the same shape, with `via: "agent"`, before submitting `references_ready`.
