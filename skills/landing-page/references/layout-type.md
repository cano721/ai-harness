# Layout and Type

These are defaults for gaps only. Where the repository's design system defines a value — a type scale, spacing step, color, radius — use that value and skip the matching rule here.

## Structure

- One `h1`. Every section has a heading (visually hidden only when the design truly has none). DOM order matches visual order.
- Navigation: three to five links plus one action. Longer menus belong in the footer.
- Neighboring sections use different layouts (split, full-bleed, grid, single column) so the page does not read as one repeated block.
- Every empty area has a job (pause before a key claim, framing an image). Unexplained voids read as unfinished.
- The phone layout is composed, not shrunk: reorder or drop decorative elements, keep the primary action reachable in the first screen.
- Touch targets: at least 24×24 CSS px with spacing (WCAG 2.2 SC 2.5.8); aim for 44×44 on primary actions (SC 2.5.5).

## Spacing

| Token role | Default |
|---|---|
| Page gutter | `clamp(1rem, 2.2vw, 2rem)` |
| Section spacing, desktop | 120–240px |
| Section spacing, phone | 72–112px |
| Body measure | 45–75 Latin characters; 30–45 Hangul syllables |

## Type

- At most two families (one display, one text, or one family in two weights).
- Five steps when no scale exists: display, h2, h3, body, small. More than nine distinct sizes on one page is a smell to justify, unless the design system's steps produce them.
- Display size tops out around `6rem`; use `clamp()` between a phone and desktop value. Viewport-proportional display type that grows without a cap suits only a direction built around a name or one word.
- Desktop headlines fit in two lines. Check the actual line count in the browser rather than estimating from character count.
- Body text 16–20px, line height 1.45–1.6 for Latin text. These are defaults for a page with no system; a design system's own steps win.
- A design system's text styles are fixed steps. Switch styles at breakpoints instead of interpolating between them with `clamp()`.
- Self-host fonts where the license allows; `font-display: swap`; preload only the one file the first viewport needs.

### Korean text

- `word-break: keep-all` on Korean text so words are not split mid-syllable-group, with `overflow-wrap: anywhere` so long URLs and numbers still wrap. Set `lang="ko"` on the document or the Korean blocks.
- Line height runs taller than Latin: body 1.6–1.8, headings 1.25–1.4.
- Letter spacing: Hangul glyphs fill the em box, so negative tracking that suits Latin display type makes syllables collide. Keep body at 0, display at no tighter than about `-0.02em`, and check it in the browser. Never inherit Latin display tracking onto Korean.
- Headline line count: a Hangul syllable is roughly 1em wide, so characters per line ≈ container width ÷ font size. Recompute; do not reuse a Latin estimate.
- `text-wrap: balance` on headings is a safe progressive enhancement.
- Korean webfonts are large. Use subset files (the 2,350-syllable KS X 1001 set covers most copy) or `unicode-range` split files, WOFF2 only, and a fallback stack with system Korean fonts (`"Apple SD Gothic Neo", "Malgun Gothic", "Noto Sans KR", sans-serif`). Confirm every glyph in the copy exists in the subset.

## Color

- Choose a strategy first, then values:
  - **Quiet** — neutrals with one accent used sparingly.
  - **Committed** — one brand color carries large surfaces.
  - **Full** — several colors with assigned meanings.
  - **Saturated** — color floods whole sections; text sits on color.
- Define six roles: background, surface, text, muted text, accent, text-on-accent. Build scales in OKLCH so lightness steps look even.
- Contrast: 4.5:1 for body text, 3:1 for large text (24px, or 18.66px bold) and for UI components and focus indicators (WCAG 2.2 SC 1.4.3, 1.4.11). Never carry meaning by color alone (SC 1.4.1).
- Dark theme is derived, not inverted: lower surface lightness, reduce accent chroma, re-check every contrast pair.
- Text over photographs needs a scrim (30–55% overlay or gradient) and a contrast check at the busiest part of the image.

## Images

- Source at 2× the displayed size, no wider than 2400px. Always set `width` and `height` (or `aspect-ratio`) to prevent layout shift.
- `fetchpriority="high"` on the hero image only; `loading="lazy"` below the first viewport.
- Serve AVIF or WebP with `srcset`/`sizes`; keep a JPEG or PNG fallback where the stack does not negotiate formats.
- Squint test: blur the page; the primary claim and action must still be the darkest or brightest marks.

## Generated-look tells

Each pattern below is a choice with a cost, not a ban. Use one only when the direction calls for it, and expect reviewers to read it as template output.

| Pattern | Cost | Acceptable when |
|---|---|---|
| Small uppercase label above every heading (eyebrow) | Repetition flattens hierarchy | The design system already uses it — keep it then |
| Gradient-filled headline text | Low contrast at one end; reads as template | Brand gradient exists and contrast holds across the gradient |
| Frosted-glass cards | Contrast varies with what is behind | Background is controlled and contrast is measured |
| Rows of icon + title + two lines cards | Says nothing specific | Each card links to real detail |
| Centered text in more than ~72% of blocks | No reading line; monotone pacing | Single-statement pages |
| Purple-to-blue gradients, glowing orbs, grain on everything | Category default | The brand owns those colors |
