# SDD 01 - 시스템 개요

## 아키텍처 요약

```
┌─────────────────────────────────────────────────────┐
│                    @ai-harness/core                  │
│                                                      │
│  CLI Layer          Engine Layer         Hook Layer   │
│  ┌──────────┐      ┌──────────────┐    ┌──────────┐ │
│  │ init     │      │ config-loader│    │ bash     │ │
│  │ status   │─────▶│ config-merger│    │ scripts  │ │
│  │ doctor   │      │ lock-enforcer│    │ (Pre/    │ │
│  │ hook test│      │ claudemd-    │    │  Post)   │ │
│  └──────────┘      │  injector    │    └──────────┘ │
│                    └──────────────┘                  │
│                                                      │
│  Data Layer                                          │
│  ┌──────────────────────────────────────────────┐   │
│  │ .ai-harness/config.yaml                       │   │
│  │ .ai-harness/logs/*.jsonl                      │   │
│  │ .claude/settings.json (Hook 등록)              │   │
│  │ .claude/CLAUDE.md (규칙 주입)                  │   │
│  └──────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────┘
```

## 실행 흐름

```
1. ai-harness init
   → config-loader: 설정 패키지 or 기본 템플릿 로드
   → config-merger: global + team + project 병합
   → lock-enforcer: 잠금 정책 검증
   → claudemd-injector: CLAUDE.md에 하네스 구간 주입
   → settings-manager: .claude/settings.json에 Hook 등록

2. 에이전트 사용 중 (자동)
   → PreToolUse Hook 실행 (block-dangerous → secret-scanner)
   → 도구 실행
   → PostToolUse Hook 실행 (audit-logger)

3. ai-harness doctor
   → 환경 검증 + Hook 연결 확인 + 잠금 정책 준수 확인
```

## Phase 1 범위

| 구현 대상 | 설명 |
|----------|------|
| Hook 3개 | block-dangerous.sh, audit-logger.sh, secret-scanner.sh |
| config-loader | YAML 설정 파일 로드 |
| config-merger | global + team + project 병합 |
| lock-enforcer | 잠금 정책(locked/bounded/free) 강제 |
| claudemd-injector | CLAUDE.md에 harness:start~end 구간 주입/업데이트 |
| settings-manager | .claude/settings.json에 Hook 등록/제거 |
| CLI: init | 프로젝트에 하네스 설치 |
| CLI: status | 현재 하네스 상태 출력 |
| CLI: doctor | 설정 검증 + 진단 |
| CLI: hook test | Hook 단독 테스트 실행 |
