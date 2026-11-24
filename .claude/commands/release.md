---
description: Start a project-local tag-based release with the graph runner. Use when the source branch (for example develop) is ready to ship as a new version: it fixes the version, cuts the release branch, opens the release pull request, and, as far as the personal delivery level allows, merges it with a merge commit, tags it with notes, and records it; not for feature work, bug fixes, or hotfixes.
argument-hint: "[버전 x.y.z]"
---

# Release

This is a project adapter, not the source of project policy. Read these files in order before releasing:

1. @AGENTS.md
2. @.ai-harness/workflows/release.md
3. @.ai-harness/workflows/release-graph.json
4. The personas and `.ai-harness/docs/` files selected by the workflow

The project workflow and graph are authoritative. The repository facts the runner uses live in `.ai-harness/harness.json` under `release_policy`: `flow` (`tag` or `unknown`), `evidence`, `base` (the released branch, for example `main`), `source` (the branch that is released, for example `develop`), `branch_prefix` (for example `release/v`), `tag_prefix` (for example `v`), `prepare_cmd` (updates the version files and the changelog for the release), `notes_cmd` (prints the release notes), `generate_notes`, `verify_cmd` and `verify_timeout_minutes` (confirms the release is out), and `record_cmds` (bookkeeping after the tag, such as milestones). Empty extension points are skipped. When `release_policy` is missing or `flow` is not `tag`, the runner refuses to start; run `/ai-harness:harness-init --sync` to detect how the repository releases.

## Graph runner

Start a release with the runner; do not cut the branch, tag, or merge by hand when it is available:

```bash
bash .ai-harness/workflows/workflow-driver.sh start --workflow release --version <x.y.z>
```

`--version` is optional: without it the plan node proposes the next version from the project's versioning rule (or MINOR when the Unreleased changes include a new feature or a behavior change, otherwise PATCH). `--request` is optional for a release. The runner checks the version itself: `x.y.z`, no tag `<tag_prefix><x.y.z>` on origin yet, and above the latest version tag. Start from a clean work branch or worktree, not from `base` or `source`.

Steps, as the graph defines them:

1. **plan** (read-only) — the version and why, what ships, and the `checks` and `final_checks` to run on the release branch. It waits for approval like a brief (`승인` then `resume`, or `approve` in a terminal; `HM_APPROVAL=auto` approves a plan that records its choices as decisions).
2. **prepare** (the runner) — `git fetch origin <source>`, cut `<branch_prefix><x.y.z>` from `origin/<source>`, run `prepare_cmd` with `HM_RELEASE_VERSION` and `HM_RELEASE_TAG`, commit `chore: release v<x.y.z>`, and run the checks. A failure goes to a person; a release never repairs code.
3. **publish** → **remote_ci** — a normal push and a pull request into `base` titled `chore: release v<x.y.z>` (with the milestone `v<x.y.z>` when one is open, and the plan's `결정 사항`), then the remote CI of the pushed commit.
4. **merge** → **post_merge_verify** — only when the personal delivery level (`HM_DELIVERY_LEVEL`, per repository `HM_DELIVERY_LEVEL_REPOS`) is `merge` or `deploy`, and never in an unattended run. The release is merged with a merge commit only (`gh pr merge --merge`), whatever squash setting the host allows; a repository that forbids merge commits stops at a person. Then the CI of the merge commit.
5. **release** — `notes_cmd` writes the notes. Empty notes or a failing notes command stop before any tag. GitHub: `gh release create <tag> --target <merge commit> --notes-file <notes> --latest` (`--generate-notes` when `generate_notes` is true); other hosts: an annotated tag with the notes, pushed. An existing tag is never created again.
6. **verify** — level `deploy` only: `verify_cmd` with `HM_RELEASE_VERSION`, `HM_RELEASE_TAG`, `HM_MERGE_COMMIT`, `HM_BASE_BRANCH`. A failure is checked again on `resume` until `verify_timeout_minutes` (default 60), then goes to a person.
7. **record** — each `record_cmds` entry in order with the same variables; a failure stops the rest and goes to a person.
8. **sync** — whether `source` can fast-forward to `base`. The runner never pushes `source` or `base`: it leaves the command (`git switch <source> && git merge --ff-only origin/<base> && git push origin <source>`) in the report for a person.

When `source` moves during the run, the runner catches up before publishing or merging: a rebase before the first push, a merge after it (never a force push), then `prepare_cmd` and the checks again. A conflict aborts the rebase or merge and goes to a person with the conflicting files.

Delivery level `pr` (or no level) stops after remote CI and leaves the remaining manual steps in the report: `gh pr merge <PR> --merge`, then the tag and notes. `status` shows the stage, what was published, and why the run stopped. The runner picks the node runtime from `--runtime`, then `HM_RUNTIME_REPOS` (matching repository), then `HM_RUNTIME` in `~/.ai-harness/config`, then the calling CLI and integrations; pass `--runtime` only when the user asks for a specific CLI.

## Without the runner

Follow `release-graph.json` in this conversation with the same rules: approval before any branch, commit, or push; a merge commit only; no tag without notes; checks again when `source` moves; no force push and no direct push to `base` or `source`.

## Request

$ARGUMENTS
