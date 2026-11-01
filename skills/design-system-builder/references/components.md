# Components

Shared components record what the product already does consistently. They are extracted from repetition, not designed ahead of need.

## When a pattern becomes a shared component

- **Three or more places use the same structure for the same purpose.** Two similar places stay local; note them as candidates in the report.
- Reuse the project's existing component names and class or prop conventions (`.btn`, `<Button>`, `AppButton`).
- One purpose, one component. Variants express real differences in meaning (primary vs. danger), not one-off layout tweaks.
- Components consume semantic tokens. Add component-layer tokens only under the condition in `tokens.md`.

## What the rule document records per component

The `## 컴포넌트` section of the rule document lists, for each shared component:

- **Purpose → component.** A table from "the job on screen" to the component that does it: primary action, secondary action, destructive action, navigation link, inline field error, page-level alert, status label. Two components may not answer the same purpose.
- **Size ladder.** The allowed sizes in a single table, each with height, padding, type role, and icon size as token names:

  | Size | Height | Padding | Type role | Icon | Used for |
  |---|---|---|---|---|---|
  | sm | token | token | label | token | dense tables, toolbars |
  | md | token | token | body | token | default |
  | lg | token | token | title | token | primary page action |

  Sizes not in the ladder are violations. Keep the ladder short; most products need two or three sizes.
- **States.** Default, hover, focus-visible, active, disabled, loading, selected/open where it applies — each drawn with tokens, and each distinguishable without color alone.
- **Icons.** One icon source, the allowed sizes from the ladder, and whether icons stand alone (then they need an accessible name) or always sit beside text.
- **Focus.** One visible focus style for every interactive component, meeting 3:1 against its neighbors, never removed without a replacement.
- **Empty states.** What an empty list, a no-results search, and a first-use screen show: a sentence saying why it is empty and the next action.
- **Touch and pointer targets.** At least 24×24 CSS px (WCAG 2.2 AA); primary touch targets larger on mobile.

## Reference screen

The reference screen shows every shared component in every state with the real tokens, so people and review skills can open it and operate it.

| Project | Reference screen |
|---|---|
| Server-rendered (Jinja, Thymeleaf, JSP, ERB, Blade) | An example page served by the app itself (for instance `/design-system`), using the same stylesheets as product screens |
| Component library (React, Vue, Svelte…) | Storybook, or the project's existing component workshop |
| Native | A gallery screen or preview catalog in the app's debug build |

- Show each component's states side by side, in each supported theme.
- Example copy follows the rule document's `## 문구` section — the reference screen is where new screens copy from.
- When a component changes, its reference example changes in the same change.
