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
| Established | A design system or a consistent set of live pages exists | Inherit it. Do not introduce new fonts, colors, or component styles |
| Incomplete | Some brand assets exist (logo, one color) but no system | Keep what exists, fill the gaps, and list every value you added |
| None | Nothing exists | A new identity is yours to propose; confirm the direction once |

Adding a section or page to an established site never justifies a new identity.

## 3. Direction candidates

Skip this step when a mockup or an established identity already decides the look.

1. **Theme inventory** — list 8–12 concrete things the product is about: materials, verbs, places, rituals, artifacts its users handle. Avoid category clichés (circuits for software, leaves for sustainability).
2. **Idea sentence** — one sentence that states the page's point of view. Test it by substituting a competitor's name; if the sentence still holds, it says nothing.
3. **Candidates** — propose two or three directions, each with: the idea sentence, type character, color strategy, one signature moment, and what it rules out. Always include one restrained standard option as an exit.
4. **Pick one.** In an unattended run, pick and give the reason in one line.

Record the chosen direction in the report (idea, audience, action, color strategy, type pair, signature moment). Keep it out of the code.

## 4. Sections

- Each section makes one **claim** and shows **evidence** for it. Order sections by the argument, not by a stock template (hero → features → testimonials → pricing → CTA is a fallback, not a plan).
- The first viewport states the thesis and shows proof of it: the product itself, a result, or a concrete scene. A headline alone is not a thesis.
- For software, show real interface fragments at legible size instead of icon grids or abstract illustrations.
- Remove any section whose claim repeats another.

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

Reference sites set mood only — density, pacing, temperature. Do not copy layouts, illustrations, copy, or brand marks from another company. Third-party designs used as input follow the rights check in `design-handoff.md`.
