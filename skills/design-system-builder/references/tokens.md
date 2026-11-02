# Tokens

The token file is the single source of values. Everything else — rule document, components, reference screen — refers to token names.

## Layers

| Layer | Purpose | Name shape | Who may use it |
|---|---|---|---|
| Primitive | The raw scale: every color step, every size | `--<brand>-<hue>-<step>` or `--palette-<hue>-<step>` | Only the semantic layer |
| Semantic | A role in the interface | `--color-<role>-<variant>-<state>` | Screens and components |
| Component | A value one component needs that no role describes | `--<component>-<property>` | That component only |

- Add the component layer **only** when a component needs a value that no semantic token expresses and the value is shared by its variants. Otherwise components use semantic tokens directly.
- Screens never reference primitives. A new role gets a new semantic token first.

## Naming

- Every token starts with a category prefix: `--color`, `--space`, `--radius`, `--font`, `--shadow`, `--motion`, `--z`. Platforms without custom properties keep the same category grouping in their theme type.
- Semantic color: `--color-<role>-<variant>-<state>` — role (`surface`, `text`, `border`, `accent`, `danger`, `success`, `warning`, `info`, `focus`…), optional variant (`muted`, `strong`, `subtle`, `inverse`), optional state (`hover`, `active`, `disabled`, `selected`). Omit segments that do not apply: `--color-text`, `--color-text-muted`, `--color-accent-hover`.
- Existing names win. Apply these rules to new tokens; propose aliases for old ones in the report.

## Color

- **Notation:** keep the notation the project already uses. For new web tokens write OKLCH with the hex value beside it (`oklch(...) /* #rrggbb */`) so lightness steps stay even and the value is still searchable.
- **Generating a scale** (design mode, no brand scale yet): pick the brand hue with the user, build 9–11 steps by stepping lightness evenly in OKLCH while easing chroma toward both ends, then tint the neutral scale slightly toward the brand hue only if the user wants warmth. Check every step that will carry text for contrast before naming it a text role.
- **Status colors** (danger, success, warning, info) each need a foreground, a subtle background, and a border that pass contrast together. Never convey status by color alone — the rule document requires a text label or icon beside it.
- **Accent share and elevation** are project decisions. Ask (flat / layered / hybrid; how much of a screen the accent may cover) and write the answer in the rule document.

## Dark theme

Ask whether dark is supported now, later, or never. If supported:

- **Re-map semantic tokens; do not invert.** Dark is a second set of semantic → primitive links. Primitives do not change.
- Build surfaces as a lightness ladder (base, raised, overlay) instead of relying on shadows, which barely read on dark backgrounds.
- Desaturate and lighten accents that vibrate on dark surfaces.
- **Verify contrast separately in dark.** A pair that passes in light proves nothing in dark.
- Select the dark set the way the project already switches themes:

| Stack | Dark selector |
|---|---|
| CSS / server templates | the existing switch — `[data-theme="dark"]`, a `.dark` class, or `@media (prefers-color-scheme: dark)`; when both a manual toggle and system preference exist, honor the toggle first |
| Tailwind v3 | `darkMode: 'class'` or `'media'` as configured, values from CSS variables |
| Tailwind v4 | `@custom-variant dark` matching the existing switch, values from CSS variables |
| CSS-in-JS | a second theme object with identical keys, chosen by the provider |
| Flutter | `darkTheme` with the same `ThemeExtension` types |
| Compose | a second color set chosen with `isSystemInDarkTheme()` or the app setting |
| SwiftUI | asset catalog colors with an Any/Dark appearance, or an environment-driven palette |

## Contrast (WCAG 2.2 AA)

| Pair | Minimum |
|---|---|
| Body text on its background | 4.5:1 |
| Large text (24px+, or 18.66px+ bold) | 3:1 |
| UI component boundaries and states, icons that carry meaning | 3:1 |
| Focus indicator against adjacent colors | 3:1 |

Compute every documented pair in every theme. A failing pair is not documented as a rule until fixed or explicitly accepted by the user as a known exception.

## Spacing and density

- A 4px base with 8–12 steps. Name by step (`--space-1` … `--space-12`) or by size (`--space-xs` …) — follow what the project uses.
- Density modes (compact / standard / comfortable) only when the product has dense data screens and roomy ones. Implement density by re-mapping the spacing and control-height tokens, not by new components.
- Control heights (button, input, row) are part of the size ladder in `components.md` and reference spacing tokens.

## Typography

- Name sizes by role: `display`, `heading`, `title`, `body`, `label`, `caption`. Add a step suffix only when a role needs two sizes (`--font-size-heading-1`).
- **Task-focused products:** 6–8 fixed `rem` steps; the scale does not change with viewport width, so tables and forms stay predictable.
- **Marketing and content surfaces:** at most 5 steps, using `clamp()` for the large roles only.
- Pair each size with a line-height and weight token; the rule document names the triples, not loose values.
- **Korean (and other CJK) text:**
  - `word-break: keep-all` with `overflow-wrap: anywhere` (or `break-word`) so words are not split mid-syllable and long strings still wrap.
  - Body line-height around 1.6–1.7 — Hangul needs more vertical room than Latin at the same size.
  - Do not rely on italics for emphasis; most Hangul faces have none. Use weight or color.
  - Web fonts: subset (common-syllable or per-page subsets), `font-display: swap`, and a fallback stack that includes system Korean faces.
  - Numbers in tables use tabular figures when the face supports them.

## Radius, shadow, z-index

- Radius: 3–5 steps plus `full`. Nested surfaces use a smaller inner radius than their container.
- Shadow: only if the elevation answer is layered or hybrid; 3–4 levels, each tied to a use (raised card, popover, modal).
- Z-index: named layers (`--z-dropdown`, `--z-sticky`, `--z-modal`, `--z-toast`), never raw numbers in components.

## Token file by stack

| Stack | Token file | Notes |
|---|---|---|
| Plain CSS, server-rendered templates | `tokens.css` with custom properties on `:root` and the dark selector | Load before component and screen CSS |
| Tailwind v3 | CSS variables file + `theme.extend` entries that reference `var(--…)` | Variables stay the source so non-Tailwind CSS and dark mode share them |
| Tailwind v4 | `@theme` in the main CSS for values that should generate utilities; remaining tokens (`--motion-*`, `--z-*`) on `:root` | Keep one definition per value |
| CSS-in-JS, React Native | `theme.ts` typed object (`as const`), one object per theme with identical keys | Export the type so components cannot use unknown keys |
| Flutter | `ThemeData` for what Material covers + `ThemeExtension` classes for project roles | Both light and dark `ThemeData` |
| Jetpack Compose | `ColorScheme`/`Typography` + project data classes provided through `CompositionLocal` | One provider at the app root |
| SwiftUI | asset catalog color sets + `extension` namespaces for spacing, radius, type | Dynamic Type sizes map to the type roles |
| Two or more platforms | DTCG `tokens.json` (`$value`, `$type`) as the source, platform files generated from it | Only when more than one platform consumes the tokens |
