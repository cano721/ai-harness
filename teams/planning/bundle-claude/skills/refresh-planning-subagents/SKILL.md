---
name: refresh-planning-subagents
description: ai-harness가 설치한 planner agents를 기준으로 Claude Code용 서브에이전트 자산을 다시 생성하거나 보정한다.
user-invocable: true
allowed-tools: Bash, Read, Write, Edit, Glob, Grep
---

# Refresh Planning Subagents

Claude Code에서는 `~/.claude/agents/*.md` 복사만으로 planner subagent 구성이 완전히 반영되지 않을 수 있다.
이 skill은 설치된 agent 정의를 기준으로 Claude Code가 기대하는 추가 디렉토리, 파생 파일, 메타데이터를 다시 맞춘다.

## 목표

- `~/.claude/agents/*.md` 에 있는 ai-harness planner agent 정의를 기준으로 현재 Claude Code 환경에 맞는 subagent 자산을 다시 세팅한다.
- Claude Code가 요구하는 추가 디렉토리나 보조 파일이 있으면 생성한다.
- ai-harness planner bundle이 설치한 agent 이름과 일치하는 `~/.claude/agents/*.md` 만 관리 대상으로 본다.
- 수동으로 만든 agent나 ai-harness가 관리하지 않는 자산은 덮어쓰거나 삭제하지 않는다.

## 작업 순서

1. `~/.claude/agents/*.md` 를 읽어 ai-harness planner agent 목록을 파악한다.
2. 각 agent의 frontmatter를 기준으로 이름, 설명, 모델, 지침 본문을 확인한다.
3. 현재 Claude Code가 기대하는 native subagent 구조를 점검한다.
4. 부족한 디렉토리, 파생 파일, 등록 파일이 있으면 생성하거나 갱신한다.
5. 기존 native 자산이 ai-harness 관리 하위로 이미 존재하면 가능한 범위에서 업데이트한다.
6. 작업 후 생성/수정된 경로와 아직 수동 확인이 필요한 항목을 요약한다.

## 실행 원칙

- 단순 복사가 아니라 "현재 설치된 agent 정의를 Claude Code 네이티브 형식으로 다시 반영"하는 작업으로 해석한다.
- 구현 세부 형식은 현재 Claude Code 런타임이 요구하는 실제 구조를 우선한다.
- 불확실하면 planner agent 본문은 그대로 유지하고, 래핑 구조만 Claude Code 규칙에 맞춘다.
- agent별 모델은 frontmatter의 `model` 값을 그대로 사용한다.
- 문제를 해결하기 위해 필요한 최소 범위만 수정한다.

## 사용자에게 보고할 내용

- 확인한 ai-harness planner agent 수
- 새로 만든 디렉토리/파일
- 업데이트한 디렉토리/파일
- Claude Code 제약 때문에 자동화하지 못한 항목

$ARGUMENTS
