# Output format

## Rule document

Default path: `docs/design-system.md`. Use an existing path instead when the project already has a rule document or when `.ai-harness/docs/frontend.md` / `ui.md` names one.

### Required sections — the design-audit input contract

`design-audit` scores against these sections, so their headings are fixed. Write each heading text exactly as below, in this order. When the project's docs are in another language, keep the heading and append a translation in parentheses (`## 레이아웃 (Layout)`); translate only the body.

| # | Heading | design-audit axis | Must contain |
|---|---|---|---|
| 1 | `## 메타` | — | Status, sources, token file paths, themes, viewports (below) |
| 2 | `## 원칙` | all | 3–5 principles, each a decision a reviewer can apply ("one primary action per screen"), not an adjective |
| 3 | `## 레이아웃` | **A** skeleton & hierarchy | Screen class table, skeleton per class, minimum width, breakpoints |
| 4 | `## 색과 상태` | **B** color, emphasis & state | Role table, where the accent may appear and its share, status colors with their text/icon pairing, selection and open indicators, floating surfaces, elevation, dark-theme principle |
| 5 | `## 타이포그래피` | A (title sizes), C | Type role table (size, line-height, weight token triples), language-specific rules |
| 6 | `## 컴포넌트` | **C** component grammar | Purpose → component, size ladder, states, icons, focus, empty states (`components.md`) |
| 7 | `## 형제 목록` | **D** sibling consistency | For each screen class, the screens that must match in the same places, and which places |
| 8 | `## 문구` | **E** tone & honesty | Voice patterns and banned phrases (below) |
| 9 | `## 모션` | — | Motion token roles and rules (`motion-tokens.md`) |
| 10 | `## 접근성` | B, C | Contrast targets, focus, target size, labels, color-not-alone rule |
| 11 | `## 반응형` | A | Breakpoints and what changes at each; supported minimum width |
| 12 | `## 토큰 변경 규칙` | — | How a token is added, renamed, or retired; who confirms |
| 13 | `## 결정 기록` | — | Confirmed decisions only (below) |

A project may add sections after these. It may not rename or drop a required one; a section that does not apply says so in one line ("다크 테마 미지원 — 결정 기록 2026-…") so the audit can tell "not applicable" from "missing".

**Values live in the token file.** Sections name tokens (`--color-danger`, `--space-4`) and state rules about them. A literal value in the document is either an example in a code block or a bug.

### `## 메타`

```markdown
## 메타

- 상태: seed | draft | confirmed
- 원천: <extract from code | design | mockup <link or file>>, <date>
- 토큰 파일: <path>[, <path>]
- 기준 화면: <URL path or Storybook command and address>
- 테마: <light | light, dark | …> — 전환 방식: <attribute/class/media/platform>
- 뷰포트: <supported minimum width>, <breakpoints by token or px>
- 확인 대기: <count> — 목록은 마지막 보고에 있다
```

Status meaning:

- `seed` — extracted from code, nothing proposed, not yet reviewed by a person.
- `draft` — contains proposed values or rules the user has not confirmed.
- `confirmed` — every rule and value in the document has been confirmed by the user.

Unconfirmed candidates and open questions are **not** written into the rule sections. They are counted in `확인 대기` and listed in the report. When the user confirms one, it becomes a rule in its section and an entry in `## 결정 기록`. (The same rule `fe-designer` follows: no open items inside the rule document.)

### `## 레이아웃` (axis A)

A screen class table, then one skeleton block per class:

| Class | How to recognize it | Examples |
|---|---|---|
| e.g. list | a collection with filters and row actions | `<route or template>` |

Per class: columns, content max width, minimum supported width, vertical rhythm (spacing tokens between header, toolbar, body), title type role, toolbar position, and which container holds the horizontal padding. Breakpoints are named here and defined as tokens or constants.

### `## 형제 목록` (axis D)

For each screen class, the sibling screens and the places that must match:

```markdown
### <class>
- 형제: <screen>, <screen>, <screen>
- 같아야 하는 자리: page padding, toolbar control size, primary action position, selection indicator
```

`design-audit` compares a target with one or two of these siblings. A class with one screen says so.

### `## 문구` (axis E)

Derived from the product's real strings (`extract.md`), confirmed with the user:

- **Errors** — cause, then the action the user can take. No blame, no bare codes.
- **Labels** — the grammatical form for buttons, fields, menu items, and column headers (verb-first or noun-first; ending style).
- **Numbers** — lead with the number when the number is the news; units, thousands separators, date and currency formats.
- **Empty and loading states** — what each says.
- **Banned phrases** — words the product never uses, with the replacement.
- **Honesty** — never show data, counts, or states the system does not have. Placeholders look like placeholders.

### `## 결정 기록`

Dated entries of decisions the user confirmed: what was decided, the alternatives, and why. One line to a short paragraph each.

This is not a changelog of screens or features. "Added the calendar picker to the schedule page" belongs in commit history or a changelog; "Date inputs use the calendar picker, never free text, because…" belongs here. When a project document mixes the two, propose moving feature history out during `refresh` or `merge`.

## Token file

Format and location by stack: `tokens.md`. Put a header comment naming the rule document as the place the rules live.

## Reference screen

`components.md`. Record its address in `## 메타`.

## Harness handoff (only when `.ai-harness/` exists)

These files are protected. Prepare a unified diff, show it, and apply it only after the user approves.

- **`.ai-harness/docs/frontend.md` `## 디자인 점검`** — when the harness has `frontend.md`. For a server-rendered project without `frontend.md`, put the same section in `.ai-harness/docs/ui.md`. Contents:
  - rule document path
  - axis map: A → `## 레이아웃`, B → `## 색과 상태`, C → `## 컴포넌트`, D → `## 형제 목록`, E → `## 문구` (or the project's sections if it kept older names)
  - screen classes and siblings: a pointer to the rule document sections, not a copy
  - source locations of pages, blocks, and components, and the reference screen location
  - token file path, and the files that hold layout width constants
- **`.ai-harness/docs/frontend.md` `## 팀 역할`** — where it lists motion token names, replace the list with a pointer to the rule document's `## 모션` section.
- **`.ai-harness/docs/ui.md`** — design document path, token file path, reference screen address, supported themes and viewports.

If the harness does not yet run `design-audit`, mention `/harness-init --reconfigure` (SKILL.md step 5).

## Final report

```markdown
## 디자인 시스템 — <mode> · 상태 <seed|draft|confirmed>

### 만든 것 / 바꾼 것
- <path> — <what>

### 손대지 않은 것
- <path> — <why>

### 확인 대기
- <proposed value or rule> — <recommended answer and reason>

### 제외한 값
- <value> (<source file:line or mockup frame>) — <reason: contrast, off-grid, near-duplicate, single use>

### 하네스 변경 제안 (승인 대기)
- <protected file> — diff above

### 검증
- contrast: <pairs checked, failures>
- token references: <resolved / missing>
- reference screen: <opened in which themes and widths | not opened — why>
- project checks: <commands and results>

### 지키기 자동화 제안 (선택)
- <hardcoded-value lint, contrast check in CI — what it would catch>
```
