# Figma target

How `design-screen` draws in Figma. Read [Figma MCP](figma-mcp.md) first — preflight, the precedence over Figma's own skills, writing rules, how to read for review. The audit scores frames by the rubric's section "Figma 프레임이 대상일 때".

## Preflight

Run the checks in `figma-mcp.md`. Then:

- **Figma library**: rule document `## 메타` → `Figma 라이브러리`; else the library URL the user gives. Its components, variables, and styles must import by key into the target file. If none can be found, stop and offer `design-system-builder` (Figma output from code tokens).
- **Rule document missing, library present**: offer to extract a `draft` document from the library and the spec's existing screens with `design-system-builder` ("From a mockup"; a Figma kit is the value source, so the token-file line says so).

## Build

Follow the writing rules in `figma-mcp.md`. In addition:

- Target: the page and position the user named, or a new page `<screen name>` in the file the user named or created in drafts. A file the user named as the target may also hold the spec ("이 피그마 화면에 필터 추가해줘"); a file given only as a spec or reference stays read-only. Never inside the library.
- **Same organization as the library.** Text styles need the library's fonts; an organization's shared fonts (and its team libraries) are not available in a file owned by another team or plan, and the first text write fails. Preflight: in the target, `loadFontAsync` the families the library's text styles use; if one is missing, stop and recommend a target file in the library's organization.
- One frame per state, named `<screen> / <state>`, side by side in a section named after the screen. Set the brief's mode on each.
- Skeleton first (auto layout frames with the class's spacing variables), then instances, then text. Read back after each.
- Elements are library instances, values are library variables. Gaps go in a frame named `제안 / <name>` built from library instances and variables only — no plain-layer look-alike, no detached near match, no local component.
- **Content assets** (photos, logos, illustrations the spec already shows): copy them from the spec with `download_assets` → `upload_assets` as image fills. When that is not possible, place a sized frame named `자산 필요 / <name>`.
- Extending an existing screen: duplicate the frame first if the user did not say to edit in place.

## For the auditor

The target file, state frame node-ids, sibling node-ids, and `figma-mcp.md`. The auditor reads with `get_screenshot`, `get_metadata`, and read-only `use_figma` scripts only.
