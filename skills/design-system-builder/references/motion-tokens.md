# Motion tokens

Motion explains change: where something came from, where it went, what is now active. The rule document's `## 모션` section is the single source for motion token names — other harness docs point to it instead of listing names again.

## Tokens

If the project already has motion variables, keep their names and map them onto the roles below in the rule document. Otherwise create:

| Token | Role | Starting point to confirm |
|---|---|---|
| `--motion-duration-short` | Hover, press, toggle, small color or opacity change | 100–150ms |
| `--motion-duration-medium` | Expanding panels, dropdowns, tooltips, tab content | 200–250ms |
| `--motion-duration-long` | Dialogs, drawers, page-level transitions | 300–400ms |
| `--motion-ease-standard` | Something moving or resizing in place | an ease-in-out curve |
| `--motion-ease-enter` | Something arriving | a decelerating (ease-out) curve |
| `--motion-ease-exit` | Something leaving | an accelerating (ease-in) curve |

The starting points are a range to confirm with the user, not values to copy. Exits are usually a little shorter than entries.

Native stacks keep the same six roles as constants in the theme type (`Duration`/`Curve` in Flutter, `AnimationSpec` values in Compose, `Animation` values in SwiftUI).

## Rules for the rule document

- Every transition uses one duration token and one ease token. No literal milliseconds or cubic-bezier values in components.
- Animate `opacity` and `transform`; avoid animating layout properties (width, height, top, left) on screens with many elements.
- Nothing essential depends on an animation finishing: content and controls are usable at the end state immediately.
- Loading indicators appear only after a short delay so fast responses do not flash.

## Reduced motion

Under `prefers-reduced-motion: reduce` (or the platform equivalent):

- **Remove** movement: translation, scale, parallax, auto-playing and looping animation.
- **Keep** changes that carry meaning, as opacity or color only: focus, selection, state change, a fade for content swap.
- The interface must reach the same end state with the same information. Reduced motion is a different rendering, not a disabled feature.
