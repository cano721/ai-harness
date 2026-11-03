---
name: web-design-guidelines
description: Review UI code for Web Interface Guidelines compliance. Use when asked to "review my UI", "check accessibility", "audit design", "review UX", or "check my site against best practices".
license: MIT
metadata:
  source: rules from vercel-labs/web-interface-guidelines@434b7f91364665f2f733b310ec54809bf8f37937 command.md; procedure adapted from vercel-labs/agent-skills skills/web-design-guidelines
  argument-hint: <file-or-pattern>
---

# Web Interface Guidelines

Review files for compliance with the Web Interface Guidelines. The rules ship with this skill as a pinned copy — this skill never fetches them.

## How It Works

1. Read the rules in `references/web-interface-guidelines.md` (a byte-identical copy of the upstream `command.md` at the commit named in `metadata.source`).
2. Read the specified files, or ask the user which files or pattern to review.
3. Check them against every rule in that file.
4. Output findings in the `file:line` format the rules file specifies.

Do not fetch `raw.githubusercontent.com/vercel-labs/web-interface-guidelines` or any other copy of the rules. The pinned copy keeps the result the same on every machine and works offline; the rules change only when ai-harness updates the copy.

## Precedence

The project's design rules (design document, tokens, `.ai-harness/docs/`) win over these rules where they disagree — report the disagreement instead of flagging the project value. In a repository with an ai-harness UI contract (`ui-review`, `frontend-team`, `design-audit`), this check is one lane of the design skill map; passing it does not replace rendering and operating the screen.

## Usage

When a user provides a file or pattern argument:

1. Read `references/web-interface-guidelines.md`
2. Read the specified files
3. Apply all rules from the rules file
4. Output findings using the format specified in the rules file

If no files are specified, ask the user which files to review.
