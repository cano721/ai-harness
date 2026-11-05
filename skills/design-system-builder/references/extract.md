# Extracting a design system

Extraction turns values the code already repeats into named tokens and components. It records what the product *is*, then the user decides what it *should be*. Never invent a value during extraction — a gap is reported, not filled.

## Where to look, in priority order

Read every source that exists. When two sources disagree about the same intent, the higher one wins and the conflict goes into the report.

1. **CSS custom properties** — `:root`, theme selectors, `@theme` blocks.
2. **Tailwind config** — `theme` / `theme.extend` (v3), `@theme` in CSS (v4).
3. **CSS-in-JS theme** — `theme.ts`, `createTheme`, styled-system or vanilla-extract theme contracts.
4. **`tokens.json`** or any design-token export already in the repository.
5. **Component library** — props, variants, and default sizes of the project's own components (not of a third-party library's internals).
6. **Global and screen CSS** — literal values in stylesheets, templates, and inline styles.
7. **Computed styles** — only when the source cannot settle a value (inheritance, cascade order). Read them from a running page, never as the first source.

Native apps follow the same order with their equivalents: theme objects and `ThemeExtension` (Flutter), `MaterialTheme` and `CompositionLocal` values (Compose), asset catalog colors and style extensions (SwiftUI).

## What becomes a token

- **Three or more uses with the same intent.** Count uses of a value *for the same job* — "card padding", "error text" — not raw occurrences. The same hex used once for a border and twice for a link is not three uses of one intent.
- **Existing names stay.** A variable the team already uses keeps its name even when it breaks the naming rules in `tokens.md`. Propose an alias or a rename in the report; do not rename in place.
- **Near-duplicates are a question, not a merge.** `#333` and `#343434`, `15px` and `16px` used for the same intent are listed as merge candidates with every location. The user decides.
- **One-off values stay where they are** and are listed as hardcoded values to review, with file and line.

## Record each finding

For every candidate keep: proposed name, value, intent, use count, and the file:line of each use. That table drives three outputs: the token file, the hardcoded-value migration list, and the evidence the user needs to confirm merges.

## Hardcoded value migration

Extraction produces a migration list, not a migration. Order it by user-visible risk: colors carrying state meaning first (error, success, selection), then text colors, then spacing on shared components, then the rest. Replace literals only when the user asks, one intent at a time, and re-render the affected screens after each batch.

## Screens, siblings, and copy

Extraction also feeds the axis sections of the rule document (`output-format.md`):

- **Screen classes (axis A)** — group routes or templates by structure. For each class record its skeleton: columns, max and min width, vertical rhythm, title size token, toolbar position.
- **Siblings (axis D)** — within each class, list the screens that must look the same in the same places.
- **Copy (axis E)** — collect the product's real strings: error and empty-state messages, button and field labels, confirmations, number formats. Derive the patterns actually in use and flag the inconsistent ones as decisions for the user.

## From a mockup

A mockup (design file, exported frames, screenshot) is an input, not the standard.

1. Read values from the mockup the same way: same-intent values, three or more uses within the mockup set.
2. **Leave defective values out of the token draft.** A value is defective when it fails contrast in its pairing, sits off the spacing grid, duplicates a near-identical value for the same intent, or exists in only one frame. List each excluded value with its reason.
3. Map what remains onto the project's existing tokens first; propose new tokens only for intents the project does not yet have.
4. The whole token draft is `draft` until the user confirms it. Ask **once**, with the excluded list beside the draft — not value by value.
5. If the mockup exposes design variables (collections, modes), map collections to token categories and keep the project's names. Modes are not always themes: a collection can switch brands (`Brand A` / `Brand B`) or densities. Record what each mode set means in `## 메타` (`테마:` for light/dark, `브랜드 모드:` for brands) instead of forcing brands into the theme line.

### A Figma design kit as the source

When the design system already lives in Figma (an existing kit, no token file) and the user wants a rule document from it:

- Read through the Figma MCP (`figma-mcp.md`). Whole kit pages are too large for `get_metadata`; inventory variables, text and effect styles, and component sets with a read-only `use_figma` script run on the kit file, and screenshot frames, not pages.
- Treat the kit's values as already decided — they are the system, not a mockup draft — but still exclude spec screens' off-scale values from the rules, as above.
- Screen classes, siblings, and copy come from the product's existing screens (planning files, the live product), not from the kit. Sections with no source say `근거 없음 — 미확인`.
- `## 메타`: `토큰 파일: 없음 — <kit URL>의 Figma Variables가 값의 원천` and the `Figma 라이브러리` line in its source variant (`references/output-format.md`), with the `libraryKey`. Rule sections name variables by the kit's own names; the "values live in the token file" rule then means "values live in the kit".
- Generating a token file from the kit is a separate, explicit step (Design mode for the format, values from the kit).
