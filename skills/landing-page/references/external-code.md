# External Code

Libraries, component registries, CDN scripts, and WebGL effects change between versions, and remembered code is plausible but wrong in the details that matter: prop names, defaults, dependency names, cleanup.

## Fetch, do not recall

- Never reproduce third-party component or library code from memory. Get it from the package, the official registry, or the source repository at a known version.
- If the source cannot be reached, say so in the report and stop for that component. Do not fall back to a remembered version.
- A registry or SPA can answer HTTP 200 with an HTML shell for a missing path. Parse the body and check its shape (for example, valid JSON with the expected `files` entries) before using it.
- Read the fetched component's own prop types or interface before wiring it up; do not guess names or defaults.
- Check the license before adding code: some component collections add restrictions (for example a Commons Clause) on top of MIT, and some animation libraries use their own no-charge license rather than an open-source one. Record the license in the report.

## Installing

- Detect the package manager from the lockfile. Reuse libraries already in the dependency list before adding a new one.
- Do not run an install command without the user's approval. Propose the exact command and the reason.
- CDN scripts: pin an exact version, add `integrity` (SRI) and `crossorigin`, and check the site's Content Security Policy allows the host. Prefer a package import when the project has a bundler.

## Stack detection

| Signal | Rule |
|---|---|
| `next` with an `app/` directory | Components that touch `window`, GSAP, or WebGL start with `"use client"`. Never run them at module scope during server rendering |
| `react` | Use `useGSAP()` from `@gsap/react` with a `scope` ref; wrap event-handler animations in `contextSafe` so they are reverted with the component |
| `vue` / `nuxt` | Create a `gsap.context()` in `onMounted`, call `ctx.revert()` in `onUnmounted`; render browser-only effects client-side (`<ClientOnly>` in Nuxt) |
| `svelte` / `@sveltejs/kit` | Create the context in `onMount` and return a cleanup that reverts it; guard browser APIs |
| `astro` | Put motion in a component script or an island loaded with `client:visible` |
| Plain HTML | ES module or `defer` scripts; no inline scripts the CSP forbids |
| `tailwindcss` | Use the project's configured theme values; no arbitrary values for things the theme already defines |

React example — the pattern, not a component to copy blindly:

```jsx
"use client";
import { useRef } from "react";
import gsap from "gsap";
import { ScrollTrigger } from "gsap/ScrollTrigger";
import { useGSAP } from "@gsap/react";

gsap.registerPlugin(ScrollTrigger, useGSAP);

export function RevealGroup({ children }) {
  const root = useRef(null);
  useGSAP(() => {
    const mm = gsap.matchMedia();
    mm.add("(prefers-reduced-motion: no-preference)", () => {
      gsap.from("[data-reveal]", {
        y: 24,
        opacity: 0,
        duration: 0.8,
        ease: "power4.out",
        stagger: 0.07,
        scrollTrigger: { trigger: root.current, start: "top 85%", once: true },
      });
    });
    return () => mm.revert();
  }, { scope: root });
  return <div ref={root}>{children}</div>;
}
```

## ScrollTrigger pitfalls

- Register plugins once, before first use.
- `from()` tweens render their start state immediately, including when attached to a ScrollTrigger. A second `from()` on the same property of the same element then records the first one's start state as its end, and the element never returns to its real value; use `fromTo()` or `immediateRender: false` on the later tween.
- Use either `scrub` or `toggleActions` on one trigger, not both.
- Do not animate the pinned element itself; animate its children.
- Tweens driven by `containerAnimation` (horizontal scroll) use `ease: "none"` on the container tween.
- Create triggers in page order, top to bottom, or set `refreshPriority`. Call `ScrollTrigger.refresh()` after layout-shifting content loads (`document.fonts.ready`, late images).
- Remove `markers` before shipping.
- Split-text animation: keep the accessible text — use the library's accessibility option (GSAP SplitText's `aria` handling) or put the full text in `aria-label` on the parent and hide the split pieces. Re-split on resize (`autoSplit` with `onSplit`) and revert when done.

## WebGL effect libraries

- Give the target element an explicit size before initializing.
- Keep the instance handle and call its destroy method on unmount or route change; most of these libraries leak a WebGL context otherwise.
- Follow the fallback, lazy-init, and pause rules in `motion-web.md`.
