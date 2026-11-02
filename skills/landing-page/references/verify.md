# Verify

A page is done when it has been looked at, not when it builds. Without a browser tool, report every item below as unverified.

## Captures

- Viewports: 1440, 768, and 390px wide; also check reflow at 320px (WCAG 2.2 SC 1.4.10). Capture every theme the site supports.
- Capture after motion settles: scroll through once so reveals have fired, or capture with reduced motion on. A capture taken mid-animation is not evidence.
- Measure with `getBoundingClientRect()` and computed styles for overflow, alignment, and sizes; do not judge by eye.

Read each capture for:

| Check | Defect when |
|---|---|
| Headline lines | More than two at desktop, or a single orphaned word/syllable group |
| Contrast | Below WCAG AA (4.5:1 text, 3:1 large text and UI) |
| Body size | Under 15px; small text under 13px |
| Balance | Off-centre or lopsided composition that the direction did not intend |
| Gaps | Blank areas with no job; sections without a heading |
| First action | Primary action not visible in the first viewport |
| Overflow | Horizontal scroll or clipped text at any viewport |
| Assets | Broken images; fallback font rendering instead of the intended face |
| Monotony | More than ~72% centered blocks; more than nine distinct font sizes |
| Tells | Patterns from the tell lists in `direction.md`, `layout-type.md`, and `motion-web.md` that the direction did not choose |

## Critique pass

- One-second view: what is the page about? Five-second view: what should I do?
- Squint: the claim and the action stay dominant.
- Cover the logo: if a competitor could own the page, the direction is too generic.
- Phone: composed, not shrunk.
- Sameness: adjacent sections should not share a layout.

## State and environment checks

- Drive states: hover, `:focus-visible` on every interactive element, form error, empty or missing data, overlong text (long names, long Korean words without spaces).
- JavaScript disabled (or the motion script blocked): all content visible, links and forms usable.
- `prefers-reduced-motion: reduce`: no movement beyond opacity and color; nothing missing.
- Keyboard only: skip link first, logical tab order, visible focus, no trap.
- `forced-colors: active`: borders, focus rings, and icons remain visible; no meaning carried only by background images or color.

## Accessibility details

- Skip link to `main`; landmarks `header`, `nav`, `main`, `footer`; one `h1`.
- Meaningful `alt` on content images, empty `alt` on decorative ones.
- Video with speech has captions (SC 1.2.2); autoplay video is muted and has a pause control.
- Auto-moving content longer than five seconds can be paused (SC 2.2.2).
- Target size at least 24×24 CSS px (SC 2.5.8); visible focus (SC 2.4.7).

## SEO and sharing

- Unique `<title>` and meta description; `lang` on `<html>`; canonical URL.
- Open Graph `og:title`, `og:description`, `og:image` (1200×630), `og:url`; `twitter:card`.
- Favicon set.
- JSON-LD (`Organization`, `Product`, or `SoftwareApplication`) only for facts visible on the page — no invented ratings or prices.
- For a multi-page site: `robots.txt` and `sitemap.xml`.

## Performance budget

Targets at the 75th percentile, mobile (Core Web Vitals "good" thresholds, web.dev):

| Metric | Target |
|---|---|
| LCP | ≤ 2.5s |
| CLS | ≤ 0.1 |
| INP | ≤ 200ms |

- The LCP element is text or a hero image with `fetchpriority="high"`, never something revealed by animation.
- Images in AVIF/WebP with `srcset`; dimensions set.
- Fonts: WOFF2, subset, at most two families; preload only the first-viewport file.
- Motion and WebGL code loads after first paint and only where used.

## Legal and analytics

Analytics, cookie or tracking consent, privacy notice, and required business information: check the applicable country's law and the product's policy; do not invent the text.

## Rounds and reporting

- At most two or three fix-and-recheck rounds; then report what remains.
- When possible, have a reviewer with fresh context (no access to your reasoning) read the captures.
- Report per viewport and theme: what was checked, evidence (capture paths, measurements), defects fixed, and what stayed unverified.
