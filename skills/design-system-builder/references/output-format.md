# Output format

## Rule document

Default path: `docs/design-system.md`. Use an existing path instead when the project already has a rule document or when `.ai-harness/docs/frontend.md` / `ui.md` names one.

### Required sections — the design-audit input contract

`design-audit` scores against these sections, so their headings are fixed. Write each heading text exactly as below, in this order. When the project's docs are in another language, keep the heading and append a translation in parentheses (`## 레이아웃 (Layout)`); translate only the body. `design-audit` ignores the parenthesized part when matching.

Widths, breakpoints, and viewports in the document are referenced by token or constant name; their values live in the token file, like every other value.

| # | Heading | design-audit axis | Must contain |
|---|---|---|---|
| 1 | `## 메타` | — | Status, sources, token file paths, themes, viewports (below) |
| 2 | `## 원칙` | all | Leading subsection `### 서비스` (below), then 3–5 principles, each a decision a reviewer can apply ("one primary action per screen"), not an adjective |
| 3 | `## 레이아웃` | **A** skeleton & hierarchy | Screen class table, skeleton per class, minimum width, breakpoints; subsections `### 여백 관계` and `### 묶기` (below) |
| 4 | `## 색과 상태` | **B** color, emphasis & state | Role table, where the accent may appear and its share, status colors with their text/icon pairing, selection and open indicators, floating surfaces, elevation, dark-theme principle |
| 5 | `## 타이포그래피` | A (title sizes), C | Type role table (size, line-height, weight token triples), language-specific rules |
| 6 | `## 컴포넌트` | **C** component grammar | Purpose → component, size ladder, states, icons, focus, empty states (`components.md`) |
| 7 | `## 형제 목록` | **D** sibling consistency | For each screen class, the screens that must match in the same places, and which places |
| 8 | `## 문구` | **E** tone & honesty | Voice patterns and banned phrases, or a pointer to the UX writing rule document (below) |
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
- Figma 라이브러리: <file URL> (libraryKey <key>) — 생성 <YYYY-MM-DD>, 기준 <token file path>@<commit>   ← Figma output을 만든 경우
- Figma 라이브러리: <kit URL> (libraryKey <key>) — 원천   ← Figma 키트가 값의 원천인 경우
- 브랜드 모드: <mode names> — 화면별 기본: <rule> (변수 모드가 테마가 아니라 브랜드일 때만)
- 문구 규칙 미분리   ← `## 문구` is the full form because there is no UX writing rule document
```

Status meaning:

- `seed` — extracted from code, nothing proposed, not yet reviewed by a person.
- `draft` — contains proposed values or rules the user has not confirmed.
- `confirmed` — every rule and value in the document has been confirmed by the user.

Unconfirmed candidates and open questions are **not** written into the rule sections. They are counted in `확인 대기` and listed in the report. When the user confirms one, it becomes a rule in its section and an entry in `## 결정 기록`. (The same rule `fe-designer` follows: no open items inside the rule document.)

### `### 서비스` (first subsection of `## 원칙`)

What the product is for and how it should feel, so every design skill reads it instead of asking again. It is a `###` heading, so the 13 required sections keep their names and order; the principles follow it under their own `###` heading.

```markdown
### 서비스

- 사용자와 상황: <who uses it, where, doing what — "a developer with the board open beside the editor while agents run">
- 핵심 일: <the one job the product does for them>
- 성격: <contrast pairs in the form "A보다 B" — "화려함보다 조용함", "설명보다 다음 행동">
- 피할 것: <looks, words, or patterns that break the character>
- 근거: <where each line came from — the user's answer (date), an existing brand guide, or the product's live screens>
```

- The five labels — `사용자와 상황`, `핵심 일`, `성격`, `피할 것`, `근거` — are fixed, in this order, so other skills find them.
- `핵심 일` is one job, not a list.
- `성격` is written as contrast pairs (`A보다 B`): each names what the product gives up, so a screen can be judged against it. A list of adjectives ("modern, clean, friendly") is not a character.
- Write only sentences a reviewer could call violated by pointing at a screen. A line nobody could ever break is decoration; leave it out.
- An item the user has not confirmed is written as a proposal in the report and counted in `확인 대기`, and the document stays `draft`.

When `refresh` or `merge` meets an existing rule document whose `## 원칙` has no `### 서비스`, propose adding it from the answers and evidence and list it in `확인 대기`; do not rewrite the existing principles.

### `## 레이아웃` (axis A)

A screen class table, then one skeleton block per class:

| Class | How to recognize it | Examples |
|---|---|---|
| e.g. list | a collection with filters and row actions | `<route or template>` |

Per class: columns, content max width, minimum supported width, vertical rhythm (spacing tokens between header, toolbar, body), title type role, toolbar position, and which container holds the horizontal padding. Breakpoints are named here and defined as tokens or constants.

Then two subsections, in this order, at the end of `## 레이아웃`. They are `###` headings, so the 13 required sections keep their names and order. The invariants and the decisions behind them are in `tokens.md` (Spacing relationships).

`### 여백 관계` — relationship → spacing token:

| 관계 | 예 | 토큰 |
|---|---|---|
| 요소 안 | icon and label, pieces of one meta line | `--space-…` |
| 그룹 안 항목 사이 | rows of a list, fields of a form group | `--space-…` |
| 그룹 사이 | columns, page header to body | `--space-…` |
| 구획 사이 | sections of a summary page | `--space-…` |

Each step is larger than the one above it. State the two fixed invariants (inner < outer; one boundary, one means) in a sentence.

`### 묶기` — when each rung of the ladder is used: space (default), divider (token), surface/card (token, elevation), collapse (which content folds). Then the nesting limit (how many surfaces may sit inside one another) and alignment (shared start line for titles and body, numeric alignment, primary action position).

When `refresh` or `merge` meets an existing rule document whose `## 레이아웃` has no `### 여백 관계` or `### 묶기`, do not overwrite the section: propose adding the missing subsection with the extracted defaults and list it in `확인 대기`.

### `## 형제 목록` (axis D)

For each screen class, the sibling screens and the places that must match:

```markdown
### <class>
- 형제: <screen>, <screen>, <screen>
- 같아야 하는 자리: page padding, toolbar control size, primary action position, selection indicator
```

`design-audit` compares a target with one or two of these siblings. A class with one screen says so.

### `## 문구` (axis E)

The UX writing rule document (`.ai-harness/docs/ux-writing.md` by default; found with the detection rule in `ux-writing-audit`) is the one source of copy rules. `## 문구` takes one of two forms:

- **Pointer form** — when the UX writing rule document exists. Only the source and the honesty rule:

  ```markdown
  ## 문구

  - 원본: <경로>
  - 정직: <the honesty rule below>
  ```

- **Full form** — when there is no UX writing rule document. The minimum rules below, and `## 메타` carries the line `- 문구 규칙 미분리` so the next run knows the copy rules have not been split out.

When `refresh` or `merge` finds the UX writing rule document and a full `## 문구`, propose reducing `## 문구` to the pointer form; rules missing from the UX writing rule document go there through `ux-writing-builder`, not into `## 문구`.

The full form is derived from the product's real strings (`extract.md`), confirmed with the user:

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
