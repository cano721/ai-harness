# AI Harness - 배포 & 패키지 구조

## 배포 전략: 하이브리드

프레임워크는 공개(오픈소스), 회사 설정은 사내 전용으로 분리.

```
공개 저장소 (프레임워크)                사내 저장소 (회사 설정)
github.com/{org}/ai-harness            github.com/{company}/harness-config
npm: @ai-harness/core                  npm: @{company}/harness-config

├── cli/         CLI 엔진              ├── global/         회사 공통 규칙
├── engine/      Hook 실행, 설정 로더   ├── teams/          팀별 프로필
├── templates/   기본 템플릿            ├── custom-agents/  회사 전용 에이전트
├── plugins/     플러그인 인터페이스     ├── custom-skills/  회사 전용 스킬
└── examples/    사용 예시              ├── lock-policy.yaml 잠금 정책
                                        └── mcp/            회사 전용 MCP 서버
```

## 관계

- **@ai-harness/core** (공개): "어떻게" 동작하는가 — CLI 엔진, Hook 체이닝, 설정 병합, CLAUDE.md 주입
- **@{company}/harness-config** (사내): "무엇을" 적용하는가 — 회사 보안 규칙, 팀별 컨벤션, 커스텀 에이전트/스킬

## 플러그인 인터페이스

```typescript
export interface HarnessConfigPlugin {
  name: string;
  version: string;

  /** 이 config가 요구하는 최소 core 버전 */
  minCoreVersion: string;        // 예: ">=1.2.0"

  /** 플러그인 인터페이스 버전 (메이저 호환용) */
  interfaceVersion: number;      // 예: 1 (core v1.x와 호환)

  globalDir: string;
  teamsDir: string;
  lockPolicyPath: string;
  availableTeams: string[];
  presets: Record<string, string[]>;
  customAgentsDir?: string;
  customSkillsDir?: string;
  mcpDir?: string;
}
```

> 정본 인터페이스 정의는 [24-config-compatibility.md](24-config-compatibility.md)에 있다. 여기와 [13-plugin-guide.md](13-plugin-guide.md)는 동일한 정의를 유지해야 한다.

## 설치 흐름

```bash
# 1. 프레임워크 설치 (공개)
$ npm install -g @ai-harness/core

# 2. 프로젝트에서 init (회사 설정 연결)
$ ai-harness init --config @our-company/harness-config

# 3. 업데이트
$ npm update -g @ai-harness/core       # 프레임워크
$ ai-harness update                    # 회사 설정
```
