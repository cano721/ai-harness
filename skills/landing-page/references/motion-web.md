# Motion for Marketing Pages

How much moves is a direction decision, not a fixed budget. Each direction candidate names one **motion level**:

| Level | What it holds | Fits |
|---|---|---|
| Calm | One signature moment, entrance reveals, interaction feedback, at most one extra | The restrained candidate; dense or serious content |
| Lively | Several moments tied to the argument, a try-it demo, hover and pointer response on the evidence | Most product pages |
| Showpiece | Pinned scroll scenes, a scrubbed story, a try-it demo at the center, a WebGL or canvas moment | The bold candidate, launches, campaigns |

At every level, every effect answers the four questions below, and the floors at the end of this file hold. A higher level is not more decoration: each extra moment explains something or lets the visitor do something.

## Try-it demo

Watching an animation is not interaction. On a product page, let the visitor do the product's core action in a few seconds, inside the page. The mechanism comes from a kept interaction reference (`direction.md` section 7), not from a default — dragging, typing their own input, speaking into the microphone, moving the pointer, turning a 3D object, scrolling through a story, or choosing among the product's real options are all candidates:

- The visitor's action changes what the page shows — not a looping video of someone else doing it. Choosing a prepared option and reading a prepared answer is the weakest form; use it only when the product itself works that way.
- Input the visitor types, says, or films stays in the browser: no upload, no storage, said in one line next to the control. Microphone or camera access is asked only on the visitor's click, and the demo works without it.
- Run on fixed example data in the page, labeled as an example. No backend calls, no real model, no claims drawn from the demo.
- Works by keyboard and touch, announces changes to screen readers (`aria-live="polite"`), and under reduced motion still responds, just without movement.
- With JavaScript off, show the demo's default state as a static example.
- One per page is usually enough; it is often the signature moment.

## Four questions before any effect

1. **What does it explain?** Order, cause, continuity, or emphasis. "It looks nice" is not an answer.
2. **What does waiting cost?** Nothing the visitor needs may sit behind an animation longer than it takes to read.
3. **What remains under reduced motion?** Decide the reduced version first.
4. **What happens if the script never runs?** The content must already be there.

## Tokens

Use the design system's motion tokens when they exist. Otherwise:

| Token | Value | GSAP equivalent |
|---|---|---|
| `--ease-out` | `cubic-bezier(.22, 1, .36, 1)` | `power4.out` |
| `--ease-expo` | `cubic-bezier(.16, 1, .3, 1)` | `expo.out` |
| `--ease-in-out` | `cubic-bezier(.76, 0, .24, 1)` | `power3.inOut` |
| press | 140ms | |
| hover | 180ms | |
| UI change | 240ms | |
| reveal | 800ms | |
| scene opening | 1200ms | |
| stagger, lines / items | 90ms / 70ms | |

- Exits run at about 70% of the matching entrance.
- No overshoot, bounce, or elastic easing by default.
- A curve measured from a mockup or reference video is used as-is (a `cubic-bezier()` or GSAP `CustomEase`), not snapped to the nearest token. Durations measured from a video of a scroll-driven page keep their ratios only, since scroll speed varies.

## Load and reveal

- First-load sequence: at most 1.2s total, at most four elements. No preloader screens.
- Reveal once; trigger when the element's top reaches 85% of the viewport height. Travel 12–32px. Blur up to 8px, display type only.
- Items whose top sits in the last 15% of the page's scroll range never cross that line: leave them static, or use `start: "clamp(top 85%)"` in ScrollTrigger.
- Never put a reveal on the first-viewport LCP candidate; a late script would hide it for the fallback's whole delay.
- Code in this file shows patterns. Check every library API against the installed version's docs or types before using it.
- Hidden starting states live only under a JavaScript class and `prefers-reduced-motion: no-preference`, with a timed fallback that shows everything if the reveal script has not started:

```html
<script>
  document.documentElement.classList.add("js");
  setTimeout(function () {
    if (!window.revealReady) document.documentElement.classList.remove("js");
  }, 2500);
</script>
```

```css
@media (prefers-reduced-motion: no-preference) {
  html.js [data-reveal] {
    opacity: 0;
    transform: translateY(24px);
    transition: opacity 800ms var(--ease-out), transform 800ms var(--ease-out);
  }
  html.js [data-reveal].is-in {
    opacity: 1;
    transform: none;
  }
}
```

```js
const io = new IntersectionObserver((entries) => {
  for (const entry of entries) {
    if (!entry.isIntersecting) continue;
    entry.target.classList.add("is-in");
    io.unobserve(entry.target);
  }
}, { rootMargin: "0px 0px -15% 0px" });
const items = document.querySelectorAll("[data-reveal]");
items.forEach((el) => io.observe(el));
window.revealReady = true;
// After fonts load the page height is final: show items that can never reach the 85% line.
document.fonts.ready.then(() => {
  const lastReachable = document.documentElement.scrollHeight - innerHeight * 0.15;
  items.forEach((el) => {
    if (el.getBoundingClientRect().top + scrollY > lastReachable) el.classList.add("is-in");
  });
});
```

## Scroll scenes

- Two or three scenes per page, each one to four screens long, with a quiet section between them.
- Pinned sections: at most two, each at most three screens; the held (pinned, nothing else moving) share stays under 60% of its length.
- Parallax travel under 8% of the viewport height; scale between 0.94 and 1.15.
- Horizontal galleries: prefer native `scroll-snap` over pinned horizontal scrolling.

## Implementation

- Animate `transform`, `opacity`, and `clip-path`. Add `will-change` only while an animation is active.
- Hover effects only inside `@media (hover: hover) and (pointer: fine)`; touch gets the same information without hover.
- Pause loops and canvases when offscreen (IntersectionObserver) and when the tab is hidden (`visibilitychange`).
- Content that moves, blinks, or scrolls automatically for more than five seconds needs a visible pause control (WCAG 2.2 SC 2.2.2). Nothing flashes more than three times per second (SC 2.3.1).
- Reduced motion: remove translation, scale, parallax, smooth scrolling, and autoplay; keep opacity and color changes and all content.
- Visitors' devices are slower than yours, and their browsers busier. Do the expensive work before the moment, not during it: a blur, shadow, or filter over a large area becomes a pre-rendered image; a photo that will be scaled or revealed is decoded first (`img.decode()`); particle counts and canvas sizes scale with the element, capped at a device pixel ratio of 2.
- **Degrade on a slow device.** A scroll scene, canvas, WebGL, or try-it effect watches its own frame rate while it runs; when it stays under 30 frames per second for about a second, it switches to its simpler form (unpinned scenes, fewer particles, a still image) for the rest of the visit. The simpler form keeps the content and the interaction's result.

## GSAP and ScrollTrigger

- Choose GSAP only when the plan needs timelines, scrubbed scenes, or pinning; CSS and IntersectionObserver cover simple reveals. Reuse an animation library the project already has. A direction whose signature moment is a scroll scene (walking from one place to the next, a story told by scrolling) needs pinning and scrub: propose the library with the candidate and ask for approval then, rather than faking the scene with reveals.
- Wrap all motion in `gsap.matchMedia()` with a `(prefers-reduced-motion: no-preference)` condition so it reverts cleanly when the preference changes.
- Use `gsap.quickTo()` for values updated on every pointer move.
- Scrub: `scrub: true` when smooth scrolling already smooths input; otherwise a small number (≤ 0.5).
- Framework setup and ScrollTrigger pitfalls: `external-code.md`.

## Smooth scrolling (Lenis)

Off by default: it overrides native scrolling and is the most common source of "the page feels wrong" complaints. Turn it on only when the direction depends on scrubbed scenes. When on:

- `lerp` 0.1–0.12.
- Do not create it for touch input or under reduced motion.
- Drive it from the GSAP ticker so ScrollTrigger stays in sync, and check that anchor links, keyboard scrolling, and focus moves still land correctly.

```js
const reduce = matchMedia("(prefers-reduced-motion: reduce)").matches;
const coarse = matchMedia("(pointer: coarse)").matches;
if (!reduce && !coarse) {
  const lenis = new Lenis({ lerp: 0.1 });
  lenis.on("scroll", ScrollTrigger.update);
  gsap.ticker.add((time) => lenis.raf(time * 1000));
  gsap.ticker.lagSmoothing(0);
}
```

## 3D scenes and objects

A 3D object or scene the visitor turns, drags, or scrolls through, when an interaction reference calls for it:

- Build with three.js (or a Spline export) at an exact version, approved like any outside script; a model file or texture from another source needs its license and approval. A shape built from primitives in code needs neither.
- The visitor's input drives it (drag to rotate, pointer to tilt, scroll to advance), and keyboard users get the same result from buttons or arrow keys.
- Load after first paint, only near the viewport; cap the device pixel ratio at 2; pause when offscreen or the tab is hidden; dispose geometry, materials, and the renderer on leave.
- Measure as `verify.md` Performance says for every moving moment; otherwise simplify or fall back.
- Fallback: a still render of the same object, shown when WebGL (or WebGPU) is unavailable, under reduced motion, with JavaScript off, and on small or low-power screens. Text never depends on the 3D layer to be read.

## WebGL and canvas backgrounds

- One, at most two per page. Attach to a sized container, not `body`.
- Provide a static fallback (image or CSS gradient) shown when WebGL is unavailable, under reduced motion, and on small or low-power screens.
- Initialize lazily when near the viewport; pause offscreen; destroy on unmount or page leave.
- Text over the effect keeps measured contrast at every frame; add a scrim if it does not.

## Optional effects with a cost

Not banned. Each reads as template work to many reviewers and carries an accessibility or performance cost; use one only when the direction calls for it.

| Effect | Conditions if used |
|---|---|
| Custom cursor | Only under `(pointer: fine)` and no reduced-motion preference; keep the system cursor visible; no information available only through the cursor |
| Magnetic buttons | Same conditions; displacement under 16px, scale under 1.03 |
| Text scramble or typewriter | Never on headlines or calls to action; the final text is in the DOM from the start |
| Marquee or ticker | Pause control (SC 2.2.2); stops under reduced motion |
| Split-letter headline animation | Accessible text preserved (see `external-code.md`); runs once |
