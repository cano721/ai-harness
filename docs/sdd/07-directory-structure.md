# SDD 07 - 소스 코드 디렉토리 구조

```
ai-harness/
├── docs/                           # 설계 문서 (기존)
│   ├── 01-overview.md ~ 28-performance-benchmark.md
│   └── sdd/                        # SDD 문서
│
├── bin/
│   └── ai-harness.js               # CLI 진입점 (#!/usr/bin/env node)
│
├── src/
│   ├── cli/                        # CLI 명령어
│   │   ├── index.ts                # commander 설정, 서브커맨드 등록
│   │   ├── init.ts                 # ai-harness init
│   │   ├── status.ts               # ai-harness status
│   │   ├── doctor.ts               # ai-harness doctor
│   │   └── hook-test.ts            # ai-harness hook test
│   │
│   ├── engine/                     # 핵심 엔진
│   │   ├── config-loader.ts        # YAML 로드, 기본값 적용
│   │   ├── config-merger.ts        # global + team + project 병합
│   │   ├── lock-enforcer.ts        # 잠금 정책 검증
│   │   ├── claudemd-injector.ts    # CLAUDE.md 주입/제거
│   │   ├── settings-manager.ts     # settings.json Hook 등록/제거
│   │   └── hook-tester.ts          # Hook 테스트 실행기
│   │
│   ├── types/                      # 타입 정의
│   │   └── index.ts                # HarnessConfig, LockPolicy 등
│   │
│   └── utils/                      # 유틸리티
│       └── logger.ts               # chalk 기반 출력 헬퍼
│
├── hooks/                          # Hook 스크립트 (bash)
│   ├── block-dangerous.sh
│   ├── block-dangerous.test.yaml
│   ├── audit-logger.sh
│   ├── audit-logger.test.yaml
│   ├── secret-scanner.sh
│   └── secret-scanner.test.yaml
│
├── templates/                      # 기본 템플릿
│   ├── global/
│   │   └── CLAUDE.md               # 범용 코딩 원칙
│   ├── config.yaml                 # 기본 설정 템플릿
│   └── lock-policy.yaml            # 기본 잠금 정책
│
├── tests/                          # 테스트
│   ├── unit/                       # 단위 테스트
│   │   ├── config-loader.test.ts
│   │   ├── config-merger.test.ts
│   │   ├── lock-enforcer.test.ts
│   │   ├── claudemd-injector.test.ts
│   │   ├── settings-manager.test.ts
│   │   └── hook-tester.test.ts
│   │
│   ├── integration/                # 통합 테스트
│   │   └── init-flow.test.ts
│   │
│   └── fixtures/                   # 테스트 픽스처
│       ├── sample-config.yaml
│       ├── sample-lock-policy.yaml
│       ├── sample-claude.md
│       └── sample-settings.json
│
├── package.json
├── tsconfig.json
├── vitest.config.ts
└── .gitignore
```
