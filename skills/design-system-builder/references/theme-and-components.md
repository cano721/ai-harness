# Theme switching and component structure

How a theme is chosen and applied at runtime, and how shared components expose variants and composition. `tokens.md` owns token layers, names, dark re-mapping and contrast; `components.md` owns when a pattern becomes a component and what the rule document records. This file covers only the mechanics those two leave open. Existing project mechanics win — use this when the project has none or asks for a new one.

Adapted from `design-system-patterns` (wshobson/agents, MIT, `plugins/ui-design/skills/design-system-patterns` at `7e2fb559`) — the theming and component architecture parts only, rewritten to defer to this skill's token rules.

## Theme switching

### Preference resolution

- Three user choices: `light`, `dark`, `system`. Store the choice, not the resolved value. `system` follows `prefers-color-scheme` and updates when the OS setting changes (`matchMedia(...).addEventListener('change', …)`).
- A manual choice beats the system preference. With no stored choice, the default is `system` unless the rule document says otherwise.
- Apply the resolved theme on the root element with the project's existing switch (`[data-theme]` or a `.dark` class — `tokens.md` "Dark theme"). Set `color-scheme` to the resolved value as well, so form controls and scrollbars follow.
- Keep the choice where the page can read it before first paint: `localStorage` for client-rendered apps, a cookie when the server renders the root element.

### No flash on load

- Server-rendered or statically generated pages paint before the app runs. Resolve the theme with a small inline script in `<head>` that reads the stored choice and `prefers-color-scheme`, then sets the root attribute and `color-scheme` — before any stylesheet-dependent paint.
- The script is static text written by the project, never built from request data. When the framework hydrates the root element, suppress only the root attribute mismatch the script causes (for example `suppressHydrationWarning` on `<html>`), not mismatches elsewhere.
- Server templates (Jinja, Thymeleaf, JSP, ERB, Blade) can render the attribute directly from the cookie and skip the script.

### Switching without jank

- Suppress transitions for one frame while the theme changes (insert a `* { transition: none !important }` style, force a style read, remove it on the next frame), so every surface does not animate its color at once.
- The toggle is a real `<button>` (or a three-option menu when `system` is offered) with an accessible name that states the current or next theme; it must reach the same end state with the keyboard.

### More than one axis

- Brand and mode are separate axes. A multi-brand product sets `[data-brand]` and `[data-theme]` independently; each brand re-maps semantic tokens to its own primitives, and each brand × mode pair is checked for contrast (`tokens.md` "Contrast").
- Add a brand axis only when the product actually ships several brands. One brand is the semantic layer, not an axis.

### User and system settings

- `prefers-contrast: more` — optionally strengthen text, border and focus tokens. It re-maps semantic tokens like any other theme; it does not add new names.
- `forced-colors: active` — the browser replaces colors with system colors. Make boundaries that relied on background color alone visible with a border (`currentColor`, `CanvasText`), keep focus outlines, and do not set `forced-color-adjust: none` except on content whose color is the information (charts, swatches).
- `prefers-reduced-motion` — handled by `motion-tokens.md`; the theme switch itself never animates under it.

### Verifying themes

- Every documented pair is checked in every supported theme (`tokens.md`). In addition, check the mechanics: the stored choice survives reload, `system` follows an OS change without reload, the first paint already has the right theme, and the toggle works by keyboard.
- The reference screen shows each component in every supported theme side by side (`components.md`).

## Component structure

`components.md` decides **whether** a pattern is a shared component. These patterns decide **how** it is built, for component-library stacks (React, Vue, Svelte, Solid). Server-template and native projects use their own partial or view composition and skip this section.

- **Variants map to the rule document.** Each variant prop value is a row in the rule document's size ladder or purpose table, styled with semantic tokens. A variant helper (`cva`, `tailwind-variants`, or a plain object map) declares base classes, variants, compound variants and defaults in one place. No variant value exists only in code.
- **Compound components** for parts that share state (`Tabs` + `Tabs.List` + `Tabs.Trigger` + `Tabs.Panel`; `Select` + options). The parent owns state and passes it through context; the parts throw a clear error when used outside the parent.
- **Composition over props.** When callers need to swap the rendered element (a button that is a link), prefer a slot/`asChild` pattern that merges props and refs onto the child, or a polymorphic `as` prop with correct typing. Never ship two components that differ only by element.
- **Headless behavior.** When the project already uses a headless library (Radix, React Aria, Headless UI, Ark, Melt), build styled components on it instead of re-implementing focus management, keyboard navigation and ARIA. Choose one; mixing two for the same widget is a violation.
- **Controlled and uncontrolled.** Interactive components accept both `value` + `onChange` and a `defaultValue`; internal state is used only when `value` is absent.
- **Responsive variants** only when the rule document defines them. Breakpoint-dependent variant props (`size={{ base: 'sm', md: 'lg' }}`) follow the project's breakpoint tokens; do not invent breakpoints inside a component.
- **Ref and prop forwarding.** Shared components forward refs and unknown DOM props (`className`, `aria-*`, `data-*`) to the root element so callers can lay them out and label them.
