# Figma output

Publish the design system this skill built into a Figma library so designers work from the same values. Read `figma-mcp.md` first; its preflight and writing rules apply to every step here.

## Direction

**The token file is the source. The Figma library is generated from it.** Designers change values by asking for a token change (`## 토큰 변경 규칙`), and the next run regenerates Figma. When someone edits the library directly, the next run reports the drift (below) instead of silently overwriting it or copying it back.

Run this only after the token file and the rule document exist — on the same run when the user asked for Figma from the start, or later on its own ("디자인 시스템 피그마에 반영해줘"). Do not start Figma output from a mockup draft whose values are not yet confirmed; publish `draft` tokens only if the user says so, and then name the library page `Draft`.

## Target

- A dedicated library file. Use the URL the user gives, or create one with `create_new_file` after the user agrees. Never write the design system into a product or screen file.
- Record it in the rule document's `## 메타`: `- Figma 라이브러리: <file URL> — 생성 <YYYY-MM-DD>, 기준 <token file path>@<short commit or "uncommitted">`.
- Tell the user that publishing the file as a team library is a manual step in Figma (Assets → Publish); this skill does not publish.

## Variables

| Token layer | Collection | Modes |
|---|---|---|
| Primitive | `Primitives` | one (`Value`) |
| Semantic | `Semantic` | one per theme in `## 메타` (`Light`, `Dark`, …) |
| Component | `Component` (only if the token file has this layer) | same as `Semantic` |

- **Name:** drop the leading `--`, turn the category prefix into a group: `--color-text-muted` → `color/text-muted`, `--space-4` → `space/4`, `--radius-md` → `radius/md`. Non-CSS stacks map their theme keys the same way (category / rest). The rule is mechanical so the next run and the audit can find a variable from its token name without a mapping file.
- **Aliases stay aliases.** A semantic token that points at a primitive becomes a variable aliasing that primitive in each mode — never the resolved value.
- **Types:** colors → COLOR; spacing, radius, size, border width → FLOAT in px (convert rem at the project's root size and say which size you used); font family, weight name → STRING.
- **Scopes** limit where designers can pick each variable: color text roles → text fill; surface/background roles → frame and shape fill; border roles → stroke; space → gap and padding (and width/height only for size tokens); radius → corner radius. Primitives get no scopes, so designers reach them only through semantic tokens — the same rule as code.
- **Code syntax:** set the Web code syntax to the token as code uses it (`var(--color-text-muted)`, or the theme path for CSS-in-JS), so Dev Mode shows the real name.
- Motion and z-index tokens have no Figma counterpart; leave them out and say so in the report.

## Styles

- **Text styles** from the type role table in `## 타이포그래피`: one style per role (`Heading/L`, `Body/M`), family, size, line height, and weight bound to variables where they exist.
- **Effect styles** for shadow tokens; elevation names follow the token names.
- No color styles — color comes only from variables.

## Components

Build only the shared components listed in `## 컴포넌트`. Each becomes a component set:

- Variants from the size ladder and states the rule document records (`Size=M, State=Hover`). States the document does not record are not invented.
- Every fill, stroke, padding, gap, radius, and text style bound to the variables and styles above; auto layout throughout.
- Text and icon slots as component properties so designers do not detach to change a label.
- The component description names the rule document section it implements.
- When the code component path is known and the user wants Dev Mode links, add a Code Connect mapping with `add_code_connect_map`. Optional; skip silently when Code Connect is not set up.

## Pages

| Page | Contents |
|---|---|
| `Cover` | Library name, status (`seed`/`draft`/`confirmed`), source token file and commit, generation date |
| `Foundations` | Color swatches per semantic role in every mode, type specimens per text style, spacing and radius scales — each element bound to the variable it shows |
| `Components` | One section per component set, with every variant visible |
| `Rules` | The rule document's principles and the do/don't lines a designer needs while drawing (`## 원칙`, accent share, status color pairing, component purpose table). Marked "generated copy — <rule document path> is the source". Never edited by hand. |

## Updating an existing library

- Match by name. Existing variables, styles, and components keep their IDs so instances in designers' files stay linked; update values and add what is missing.
- Variables or components in Figma that the token file does not have are **not deleted**. List them as orphans and ask once whether to remove them.

## Drift check

Before writing, and whenever the user asks "피그마랑 코드 값 맞아?", compare the library with the token file and report a table: token, value in code, value in Figma, per mode. Then ask once per run:

- `code wins` — regenerate Figma from the token file.
- `figma wins` — treat the Figma values as a proposal: run the token change through this skill's normal rules (contrast, naming, `draft` until confirmed), then regenerate.
- `leave` — report only.

## Verify

- Read back with `get_variable_defs` and `get_metadata`: every token the rule document names has a variable; every semantic variable resolves in every mode; every component set has the variants the document records; no fill or spacing inside a component is raw.
- Recompute contrast for the documented pairs from the values Figma now holds.
- `get_screenshot` the `Foundations` and `Components` pages in each mode and look at them.
- Report what was created, updated, skipped, and orphaned, and anything the write tool refused.
