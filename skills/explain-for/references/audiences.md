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

## Proficiency — what they already hold

| Level | Vocabulary | Scaffolding | Analogy |
|---|---|---|---|
| Domain expert | Full jargon, no expansion | None. Go to the interesting part | Only to compare with a known system |
| Practitioner | Standard terms, expand only project-local ones | Brief context on unfamiliar boundaries | Rarely |
| Junior / onboarding | Standard terms, defined at first use | Step-by-step causality, name the files | Where a new model is needed |
| Adjacent professional | Their field's terms, not yours | Bridge from something they operate | Usually |
| Beginner | No jargon at all | One idea per sentence, concrete first | Always, and check it holds |

## Simplification dials

Pull these in order when the audience is further from the material. Stop at the first level that lands.

1. **Drop the why-not** — remove rejected alternatives and historical context.
2. **Drop the mechanism** — keep what it does, remove how.
3. **Replace the term** — swap each technical noun for a plain one, consistently.
4. **Replace the model** — introduce an analogy from what the reader operates daily, and name where it stops holding.
5. **Drop the parts** — keep one causal chain, discard branches, and say that it was simplified.

## ELI5 mode

An explicit "ELI5" / "다섯 살한테 설명하듯" request means: Beginner proficiency, no role, maximum simplification. Playful and concrete, never baby talk, and never so loose that the core claim becomes false. If the reader could act on the explanation, keep one line of real precision at the end.
