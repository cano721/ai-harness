# AI Harness - 플러그인(설정 패키지) 개발 가이드

## 빠른 시작

```bash
# 스캐폴딩
$ ai-harness create-config my-company-harness

# 규칙 작성
$ vi global/CLAUDE.md
$ vi teams/frontend/CLAUDE.md

# 테스트
$ ai-harness init --config ./

# 배포
$ npm publish
```

## 디렉토리 구조

```
my-company-harness/
├── package.json
├── index.ts                      # 플러그인 인터페이스 구현
├── global/
│   ├── CLAUDE.md
│   ├── hooks/
│   └── guardrails/
├── teams/
│   ├── frontend/
│   └── backend/
├── custom-agents/
├── custom-skills/
├── mcp/
├── lock-policy.yaml
└── presets.yaml
```

## 플러그인 인터페이스 구현

```typescript
import { HarnessConfigPlugin } from '@ai-harness/core';
import path from 'path';

const config: HarnessConfigPlugin = {
  name: '@my-company/my-company-harness',
  version: '1.0.0',

  // 호환성 필드 (24-config-compatibility.md 참조)
  minCoreVersion: '>=1.0.0',
  interfaceVersion: 1,

  globalDir: path.join(__dirname, 'global'),
  teamsDir: path.join(__dirname, 'teams'),
  lockPolicyPath: path.join(__dirname, 'lock-policy.yaml'),
  availableTeams: ['planning', 'design', 'frontend', 'backend', 'qa', 'devops'],
  presets: {
    fullstack: ['frontend', 'backend'],
    product: ['planning', 'design', 'frontend', 'backend'],
    all: ['planning', 'design', 'frontend', 'backend', 'qa', 'devops'],
  },
  customAgentsDir: path.join(__dirname, 'custom-agents'),
  customSkillsDir: path.join(__dirname, 'custom-skills'),
  mcpDir: path.join(__dirname, 'mcp'),
};

export default config;
```

> 인터페이스 정본: [24-config-compatibility.md](24-config-compatibility.md)

## Hook 작성

```bash
#!/bin/bash
# exit 0 = 통과, exit 2 = 차단
TOOL_NAME="$1"
TOOL_INPUT="$2"

if [ "$TOOL_NAME" = "Bash" ]; then
  if echo "$TOOL_INPUT" | grep -qE 'rm\s+(-[a-zA-Z]*f|-[a-zA-Z]*r){2}'; then
    echo "BLOCKED: rm -rf 차단"
    exit 2
  fi
fi
exit 0
```

## 잠금 정책

```yaml
locked:   [hooks.block-dangerous, hooks.audit-logger]
bounded:  { test_coverage: { min: 60, default: 80 } }
free:     [hooks.lighthouse, team_skills]
```

## 검증 & 배포

```bash
$ ai-harness validate-config ./    # 유효성 검증
$ ai-harness hook test --all       # Hook 테스트
$ npm publish                      # GitHub Packages 배포
```

## 체크리스트

- [ ] `ai-harness validate-config ./` 통과
- [ ] global/CLAUDE.md에 핵심 규칙 포함
- [ ] 보안 Hook 포함 (block-dangerous, secret-scanner)
- [ ] lock-policy.yaml에 보안 항목 잠금
- [ ] 각 팀 프로필에 CLAUDE.md 존재
- [ ] Hook 스크립트 실행 권한 (chmod +x)
