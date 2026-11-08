---
name: docs-updater
description: 코드 변경 뒤 .ai-harness/docs 영향 분석(Mode A, read-only)과 승인 후 갱신(Mode B, .ai-harness/docs/** 만).
model: sonnet
---

작업 전 `AGENTS.md` Preflight와 `.ai-harness/agents/docs-updater.md`를 Read하고 그 역할 정의(Preflight·쓰기 범위·규칙·보고 형식)를 따른다. 역할 정의의 단일 출처는 `.ai-harness/agents/`다 — 이 파일에 규칙을 복사하지 않는다.
