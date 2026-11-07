# Code target

How `design-screen` draws a screen in the repository's code. The audit scores source as the rubric does by default; the captures below settle what it would otherwise leave under "렌더 확인 필요".

## Preflight

Stop at the first failure with the fix in one line.

1. **Project facts.** If `.ai-harness/` exists, read `AGENTS.md` and `.ai-harness/docs/frontend.md` (or `ui.md`, server-rendered) — source locations of pages, blocks, and components, the reference screen, supported themes and viewports. They override the defaults here.
2. **Stack** from the build files: React, Vue, Svelte, Next.js, Nuxt, server templates (Jinja, Thymeleaf, JSP, ERB, Blade), Flutter, Jetpack Compose, SwiftUI. A native stack draws in the platform's preview (Flutter widget preview or a debug route, Compose `@Preview`, SwiftUI `#Preview`) and follows the project's `native-ui` skill when present.
3. **Design system in code.** The token file (`## 메타` path) and the shared components (the reference screen or Storybook lists them). Tokens only, with no shared components, is enough; every element then becomes a composition of tokens on plain markup, and anything with a role the rule document's `## 컴포넌트` names but the code lacks is a gap.
4. **It runs.** The dev server, Storybook, or platform preview starts with the project's own command (`package.json` scripts, `README`, `.ai-harness/docs`). Do not install new dependencies; if the project's install step is needed and has not run, ask before running it.
5. **A browser or preview tool** can open the screen and capture it. Without one, the screen can still be built and audited from source, but every render item stays under "렌더 확인 필요" and the report says the screen was not seen.

## Where the screen lives

- The route, page, or component path the user named. Else where the project keeps that screen class (`frontend.md` source locations; else the sibling pages' directory), with a route name from the requirement.
- When the project has Storybook, also one story per state next to the screen. Otherwise each state is reachable by the route plus a query parameter (`?state=empty`) or a development-only preview route, whichever the project already uses; prefer the existing pattern.
- **Data is a local fixture.** A typed fixture module beside the screen, shaped by the requirement's fields and counts, one fixture per state. No network calls, no changes to API clients, stores, or server code. Name the fixture so it is obvious to replace (`<screen>.fixture.ts`).
- Extending an existing screen: edit it in place on the working tree; the user's version control is the undo.

## Build

- Import shared components from where the project exports them; values come from the token file through the project's own channel (CSS variables, Tailwind theme classes, theme object, `ThemeData`, `MaterialTheme`). A literal color, spacing, radius, or font size that a token covers is a violation even when it renders the same.
- Use variants and props the components already have. Do not add a prop, variant, or style override to a shared component — that is a design system change.
- Gaps: a component file named for its role with `제안 / <name>` in a comment at its top, built from shared components and tokens only, kept beside the screen, not in the shared component directory.
- Content assets the spec shows: reuse files the repository already holds; otherwise a sized placeholder element labeled `자산 필요 / <name>`. Do not download images from the spec into the repository without the user's go-ahead.
- Follow the project's linters and type checker; run them on the files you touched before the first audit.
- Leave every change uncommitted.

## Captures

Open each state at every viewport in the brief and every theme the token file defines. Capture after fonts load and motion settles. Measure overflow, alignment, and sizes with `getBoundingClientRect()` and computed styles instead of by eye. Keep captures outside the repository (the session's scratch directory).

## For the auditor

Source paths of the screen, its stories or fixtures, and any `제안 /` files; the address of each state; the capture paths with viewport and theme; sibling paths and the reference screen address. The auditor reads source and captures and may open the addresses itself, read-only. Items the captures show are judged from them; only states not driven (hover, focus, open menus) stay under "렌더 확인 필요".
