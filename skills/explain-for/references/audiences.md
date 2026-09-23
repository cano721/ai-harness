# Audience catalog

Two independent axes. Read the role row for *what the explanation is about*, the proficiency row for *how it is worded*. A project's own `.ai-harness/workflows/explain-for.md` overrides anything here.

## Role — what they decide

| Role | They are accountable for | Frame the explanation around | Leave out unless asked |
|---|---|---|---|
| Engineer (peer) | Correctness, maintenance cost | Mechanism, trade-offs, failure modes, what it touches next | Business framing, motivation |
| Engineer (other stack) | Their own side of the contract | The interface, the contract, what breaks them | Internals behind the contract |
| Tech lead / architect | Direction, consistency, debt | Boundary choices, alternatives rejected and why, precedent set | Line-level implementation |
| Engineering manager | Timeline, risk, people | Impact, effort, what is blocked, what decision is needed now | Architecture detail |
| Product manager | User value, scope | What users can now do, what changed in behavior, scope traded | Implementation entirely |
| Designer | Experience, flow | What the user sees and feels, states, edge cases in the flow | Backend mechanics |
| QA | Verifiable behavior | Observable before/after, how to reproduce, regression surface | Rationale |
| Director / executive | Strategy, cost | Outcome, cost, risk if not done, one recommendation | Everything else |
| Support / CS | Answering users | Symptom → cause → what to tell the user, workaround | Root-cause detail |
| Non-technical reader | Nothing here | What it does for a person, in their own daily terms | All implementation |

## Relationship — personal readers

For someone outside work — family or a friend — role is **Non-technical reader** and proficiency is **Beginner** unless the request says otherwise (a parent who is an engineer is a peer). The relationship sets tone and where analogies come from.

| Reader | Tone | Draw analogies from |
|---|---|---|
| Partner (wife / husband) | Warm, conversational, patient — like explaining over dinner | Household tasks, shared routines and experiences |
| Parents | Respectful and clear, never condescending | Technology and devices they already use, running a home |
| Kids | Playful and encouraging, short — use a **Child** proficiency level | Games, cartoons, school, animals |
| Friend | Casual, a little humor is fine | Pop culture, shared interests, "you know how…" |

## Proficiency — what they already hold

| Level | Vocabulary | Scaffolding | Analogy |
|---|---|---|---|
| Domain expert | Full jargon, no expansion | None. Go to the interesting part | Only to compare with a known system |
| Practitioner | Standard terms, expand only project-local ones | Brief context on unfamiliar boundaries | Rarely |
| Junior / onboarding | Standard terms, defined at first use | Step-by-step causality, name the files | Where a new model is needed |
| Adjacent professional | Their field's terms, not yours | Bridge from something they operate | Usually |
| Beginner | No jargon at all | One idea per sentence, concrete first | Always, and check it holds |
| Child (~10, 5th grade) | Everyday words; a needed term gets a kid-friendly definition | Step-by-step cause and effect | Always — school, sports, video games |
| Child (~5) | Simplest words, sentences under ~15 words | One idea at a time, nothing abstract | Always — toys, animals, candy, playground |

## Simplification dials

Pull these in order when the audience is further from the material. Stop at the first level that lands.

1. **Drop the why-not** — remove rejected alternatives and historical context.
2. **Drop the mechanism** — keep what it does, remove how.
3. **Replace the term** — swap each technical noun for a plain one, consistently.
4. **Replace the model** — introduce an analogy from what the reader operates daily, and name where it stops holding.
5. **Drop the parts** — keep one causal chain, discard branches, and say that it was simplified.

## ELI5 mode

The default when no audience and no destination is named, and what an explicit "ELI5" / "아주 쉽게" / "다섯 살한테 설명하듯" / "어린아이도 알아듣게" request means: **Child (~5)** proficiency, no role, maximum simplification. When the request says "초등학생" or "5th grader", use **Child (~10)** instead.

- **Words** — no jargon. If a technical term is unavoidable, define it in the same sentence with a word the child already knows.
- **Analogy** — at least one, from the child's world: toys, animals, picture books, snacks, the playground (age ~10: school projects, sports, games). Check it holds for the core claim.
- **Shape** — what it is for → the analogy → one or two concrete steps → why it is cool or useful. Short, usually a few paragraphs at most.
- **Tone** — warm and enthusiastic, like a favorite teacher. Delightful, never condescending, never baby talk.
- **Truth** — never so loose that the core claim becomes false. If the adult asking could act on the explanation, add one line of real precision at the end, marked as for the grown-up.

Example — "ELI5 what a database index is":

> Imagine a huuuge book with thousands of pages. If I asked you to find the page about dinosaurs, you could flip through every page… or you could look at the list at the front that says "dinosaurs: page 212"! A database index is that list. It helps the computer find things super fast without looking at everything.
