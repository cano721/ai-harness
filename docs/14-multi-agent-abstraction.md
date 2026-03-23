# AI Harness - 멀티 에이전트 추상화

## 문제 정의

AI 코딩 에이전트는 각각 설정 메커니즘이 다르다:

| 에이전트 | 설정 파일 | Hook 지원 | MCP 지원 | 컨텍스트 주입 |
|---------|----------|----------|---------|-------------|
| **Claude Code** | `.claude/settings.json` + `CLAUDE.md` | PreToolUse/PostToolUse | 네이티브 | CLAUDE.md 자동 로드 |
| **Codex CLI** | `AGENTS.md` + `codex.yaml` | 제한적 (pre/post command) | 미지원 | AGENTS.md 자동 로드 |
| **Cursor** | `.cursorrules` + `rules/` | 미지원 (확장 프로그램) | 제한적 | .cursorrules 로드 |
| **Windsurf** | `.windsurfrules` | 미지원 | 미지원 | .windsurfrules 로드 |
| **Gemini CLI** | `GEMINI.md` | 제한적 | MCP 호환 | GEMINI.md 자동 로드 |

하네스가 이 모든 에이전트를 하나의 설정으로 제어하려면 **추상화 레이어**가 필요하다.

---

## 설계 원칙

1. **공통 분모 우선**: 모든 에이전트가 지원하는 기능(컨텍스트 파일)을 핵심으로
2. **점진적 향상**: Hook/MCP 등 고급 기능은 지원하는 에이전트에서만 활성화
3. **에이전트 교체 용이**: 에이전트를 바꿔도 핵심 규칙은 그대로 적용

---

## 아키텍처: 어댑터 패턴

```
┌──────────────────────────────────────────────────┐
│              AI Harness Core Engine               │
│                                                    │
│  ┌──────────────────────────────────────────┐     │
│  │        Canonical Config (하네스 표준)      │     │
│  │  - rules (YAML)                          │     │
│  │  - hooks (표준 인터페이스)                  │     │
│  │  - guardrails (YAML)                     │     │
│  │  - context (Markdown)                    │     │
│  └─────────────────┬────────────────────────┘     │
│                     │                              │
│         ┌───────────┼───────────┐                  │
│         ↓           ↓           ↓                  │
│  ┌────────────┐ ┌────────┐ ┌────────────┐        │
│  │ Claude     │ │ Codex  │ │ Cursor     │  ...   │
│  │ Adapter    │ │Adapter │ │ Adapter    │        │
│  └────────────┘ └────────┘ └────────────┘        │
│         │           │           │                  │
└─────────┼───────────┼───────────┼──────────────────┘
          ↓           ↓           ↓
   .claude/        AGENTS.md   .cursorrules
   settings.json   codex.yaml
   CLAUDE.md
```

---

## 어댑터 인터페이스

```typescript
// src/adapters/agent-adapter.ts

export interface AgentAdapter {
  /** 에이전트 식별자 */
  readonly name: string;

  /** 지원 기능 수준 */
  readonly capabilities: AgentCapabilities;

  /** 에이전트 설치 여부 감지 */
  detect(): Promise<DetectResult>;

  /** 컨텍스트(규칙) 파일 생성/주입 */
  injectContext(context: HarnessContext): Promise<void>;

  /** Hook 등록 (지원하는 에이전트만) */
  registerHooks?(hooks: HarnessHook[]): Promise<void>;

  /** MCP 서버 등록 (지원하는 에이전트만) */
  registerMcp?(servers: McpServer[]): Promise<void>;

  /** 하네스 설정 제거 (uninstall) */
  cleanup(): Promise<void>;
}

export interface AgentCapabilities {
  /** 컨텍스트 파일 주입 */
  contextInjection: true;  // 모든 에이전트 필수

  /** Hook 시스템 지원 수준 */
  hooks: 'full' | 'partial' | 'none';

  /** MCP 서버 지원 */
  mcp: 'native' | 'partial' | 'none';

  /** settings.json 등 별도 설정 파일 */
  settingsFile: boolean;

  /** 다중 컨텍스트 파일 (서브디렉토리별) */
  hierarchicalContext: boolean;
}

export interface DetectResult {
  installed: boolean;
  version?: string;
  configDir?: string;
}
```

---

## 에이전트별 어댑터 구현

### Claude Code Adapter (Tier 1 - Full Support)

```typescript
// src/adapters/claude-adapter.ts

export class ClaudeAdapter implements AgentAdapter {
  readonly name = 'claude-code';
  readonly capabilities: AgentCapabilities = {
    contextInjection: true,
    hooks: 'full',
    mcp: 'native',
    settingsFile: true,
    hierarchicalContext: true,  // .claude/CLAUDE.md + 프로젝트 CLAUDE.md
  };

  async detect(): Promise<DetectResult> {
    // claude --version 실행
    // .claude/ 디렉토리 확인
  }

  async injectContext(context: HarnessContext): Promise<void> {
    // CLAUDE.md에 <!-- harness:start --> ~ <!-- harness:end --> 주입
    // 기존 내용 보존
  }

  async registerHooks(hooks: HarnessHook[]): Promise<void> {
    // .claude/settings.json의 hooks 섹션에 등록
    // _managed_by: "ai-harness" 마커 추가
  }

  async registerMcp(servers: McpServer[]): Promise<void> {
    // .claude/settings.json의 mcpServers 섹션에 등록
  }

  async cleanup(): Promise<void> {
    // _managed_by: "ai-harness" 마커가 있는 항목만 제거
    // CLAUDE.md에서 harness:start ~ harness:end 구간 제거
  }
}
```

### Codex CLI Adapter (Tier 2 - Context + Partial Hooks)

```typescript
// src/adapters/codex-adapter.ts

export class CodexAdapter implements AgentAdapter {
  readonly name = 'codex-cli';
  readonly capabilities: AgentCapabilities = {
    contextInjection: true,
    hooks: 'partial',    // pre/post command만 지원
    mcp: 'none',
    settingsFile: true,  // codex.yaml
    hierarchicalContext: true,  // AGENTS.md 계층 구조
  };

  async injectContext(context: HarnessContext): Promise<void> {
    // AGENTS.md에 하네스 규칙 주입
    // CLAUDE.md 내용을 AGENTS.md 포맷으로 변환
  }

  async registerHooks(hooks: HarnessHook[]): Promise<void> {
    // codex.yaml의 hooks 섹션에 등록
    // PreToolUse → pre_command, PostToolUse → post_command 매핑
    // 지원하지 않는 Hook 타입은 경고 후 스킵
  }
}
```

### Cursor Adapter (Tier 3 - Context Only)

```typescript
// src/adapters/cursor-adapter.ts

export class CursorAdapter implements AgentAdapter {
  readonly name = 'cursor';
  readonly capabilities: AgentCapabilities = {
    contextInjection: true,
    hooks: 'none',
    mcp: 'partial',
    settingsFile: false,
    hierarchicalContext: true,  // .cursor/rules/ 디렉토리
  };

  async injectContext(context: HarnessContext): Promise<void> {
    // .cursorrules 파일에 하네스 규칙 주입
    // 또는 .cursor/rules/ 디렉토리에 규칙 파일 생성
  }

  // registerHooks는 구현하지 않음 (capabilities.hooks === 'none')
  // Hook 기능은 Cursor 확장 프로그램으로 대체 가능 (별도 문서)
}
```

---

## 기능 수준별 지원 매트릭스

```
┌──────────────────┬──────────┬──────────┬──────────┬──────────┬──────────┐
│ 기능              │ Claude   │ Codex    │ Cursor   │ Windsurf │ Gemini   │
│                  │ Code     │ CLI      │          │          │ CLI      │
├──────────────────┼──────────┼──────────┼──────────┼──────────┼──────────┤
│ 컨텍스트 주입     │ ✅ Full  │ ✅ Full  │ ✅ Full  │ ✅ Full  │ ✅ Full  │
│ 보안 규칙        │ ✅ Full  │ ✅ Full  │ ✅ Full  │ ✅ Full  │ ✅ Full  │
│ 팀별 규칙        │ ✅ Full  │ ✅ Full  │ ✅ Full  │ ✅ Full  │ ✅ Full  │
│ Pre Hook (차단)  │ ✅ Full  │ ⚠ Partial│ ❌ None  │ ❌ None  │ ⚠ Partial│
│ Post Hook (검증) │ ✅ Full  │ ⚠ Partial│ ❌ None  │ ❌ None  │ ⚠ Partial│
│ 감사 로깅        │ ✅ Hook  │ ⚠ Wrapper│ ⚠ Wrapper│ ⚠ Wrapper│ ⚠ Wrapper│
│ MCP 서버         │ ✅ Native│ ❌ None  │ ⚠ Partial│ ❌ None  │ ✅ Native│
│ 비용 추적        │ ✅ Hook  │ ⚠ 추정   │ ⚠ 추정   │ ⚠ 추정   │ ⚠ Wrapper│
│ 모드별 guardrail │ ✅ OMC   │ ❌ N/A   │ ❌ N/A   │ ❌ N/A   │ ❌ N/A   │
└──────────────────┴──────────┴──────────┴──────────┴──────────┴──────────┘

✅ Full: 네이티브 지원, 모든 기능 동작
⚠ Partial/Wrapper: 제한적 지원 또는 래퍼로 우회
❌ None/N/A: 미지원 또는 해당 없음
```

---

## Tier별 전략

### Tier 1: Full Support (Claude Code)

모든 하네스 기능을 네이티브로 지원. 하네스의 기준 에이전트.
- 컨텍스트 + Hook + MCP + 감사 로깅 + 비용 추적 + OMC 연동
- 새로운 기능은 항상 Claude Code에서 먼저 구현, 이후 다른 에이전트로 확장

### Tier 2: Context + Partial Hooks (Codex CLI, Gemini CLI)

컨텍스트 주입은 완전, Hook은 제한적.
- 컨텍스트 주입: 네이티브 포맷으로 변환하여 완전 지원
- Hook: 지원하는 범위 내에서 매핑, 미지원 부분은 **래퍼 스크립트**로 보완
- 감사 로깅: CLI 래퍼로 실행 전후 로깅

```bash
# 래퍼 스크립트 예시: Codex를 하네스 래퍼로 실행
$ ai-harness wrap codex "fix the login bug"

# 내부 동작:
# 1. Pre Hook 실행 (하네스 보안 검증)
# 2. codex 실행
# 3. Post Hook 실행 (결과 검증)
# 4. 감사 로그 기록
```

### Tier 3: Context Only (Cursor, Windsurf)

컨텍스트 주입만 지원. Hook/MCP는 에이전트 특성상 불가.
- 컨텍스트 파일 생성으로 규칙/보안정책은 적용 가능
- Hook 부재로 **강제 차단은 불가**, 규칙 위반은 에이전트가 자율적으로 판단
- 감사 로깅은 불가하거나 제한적

---

## 컨텍스트 변환 엔진

하네스의 표준 규칙을 각 에이전트의 네이티브 포맷으로 변환한다.

### 표준 규칙 포맷 (Canonical)

```yaml
# harness-rules.yaml (하네스 내부 표준 형식)

context:
  global:
    coding_principles:
      - "기존 코드 컨벤션을 먼저 파악하고 따른다"
      - "변경 범위를 최소화한다"
    security:
      - "하드코딩된 시크릿 금지"
      - "SQL 파라미터 바인딩 필수"
    forbidden_patterns:
      - pattern: "console.log"
        scope: "production"
        severity: "warning"

  team:
    backend:
      api_rules:
        - "RESTful 원칙 준수"
        - "Request/Response DTO 분리 필수"
      db_rules:
        - "DDL 변경은 마이그레이션 스크립트로"
```

### 변환 결과

```
하네스 표준 규칙
    │
    ├─→ CLAUDE.md       (Claude Code용)
    ├─→ AGENTS.md       (Codex CLI용)
    ├─→ .cursorrules    (Cursor용)
    ├─→ .windsurfrules  (Windsurf용)
    └─→ GEMINI.md       (Gemini CLI용)
```

### 변환기 인터페이스

```typescript
// src/engine/context-transformer.ts

export interface ContextTransformer {
  /** 표준 규칙을 에이전트별 포맷으로 변환 */
  transform(canonical: CanonicalConfig, agent: string): string;
}

// 변환 시 고려사항:
// - 마크다운 구조는 공통이므로 대부분 그대로 사용
// - 에이전트별 특수 지시어가 있으면 추가 (예: Cursor의 @codebase)
// - 토큰 절약을 위해 에이전트별로 컨텍스트 크기 최적화
```

---

## 멀티 에이전트 Init 플로우

```
$ ai-harness init

  ━━━ 에이전트 감지 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  감지된 에이전트:
  ✔ Claude Code v2.1.x (Tier 1 - Full Support)
  ✔ Codex CLI v1.x.x   (Tier 2 - Context + Hooks)
  ⚠ Cursor v0.x.x      (Tier 3 - Context Only)

  모든 에이전트에 하네스를 적용합니다.
  에이전트별 지원 수준이 다릅니다:

  ┌──────────────┬────────┬────────┬─────────┐
  │              │ Claude │ Codex  │ Cursor  │
  ├──────────────┼────────┼────────┼─────────┤
  │ 규칙 적용    │ ✅     │ ✅     │ ✅      │
  │ 위험 차단    │ ✅     │ ⚠      │ ❌ 규칙만│
  │ 감사 로깅    │ ✅     │ ⚠ 래퍼 │ ❌      │
  │ MCP 연동     │ ✅     │ ❌     │ ⚠      │
  └──────────────┴────────┴────────┴─────────┘

  계속 진행할까요? (Y/n): _
```

---

## 에이전트 동기화

여러 에이전트가 같은 프로젝트에서 사용될 때 설정을 동기화한다.

### 단일 소스 원칙

```
.ai-harness/config.yaml     ← 유일한 진실의 원천 (Single Source of Truth)
    │
    ├─→ .claude/CLAUDE.md     자동 생성 (수동 편집 금지)
    ├─→ AGENTS.md             자동 생성 (수동 편집 금지)
    ├─→ .cursorrules          자동 생성 (수동 편집 금지)
    └─→ ...
```

### 동기화 명령

```bash
# 수동 동기화 (규칙 변경 후)
$ ai-harness sync
  ✔ CLAUDE.md 업데이트
  ✔ AGENTS.md 업데이트
  ✔ .cursorrules 업데이트

# 자동 동기화 (Git hook으로)
# .ai-harness/config.yaml 변경 감지 시 자동 실행
```

### .gitignore 전략

```gitignore
# 하네스가 자동 생성하는 파일은 커밋하지 않음
# (각 개발자가 ai-harness sync로 로컬 생성)
.claude/CLAUDE.md      # harness:start ~ harness:end 구간만
AGENTS.md              # 하네스 자동 생성 시
.cursorrules           # 하네스 자동 생성 시

# 하네스 설정은 커밋
.ai-harness/config.yaml
```

> **대안**: 자동 생성 파일도 커밋하여 하네스 미설치 환경에서도 규칙이 적용되게 할 수 있다.
> 프로젝트별로 선택 가능 (`ai-harness config set sync.commit_generated true`).

---

## 향후 확장: 에이전트 추가

새로운 AI 코딩 에이전트가 등장하면:

1. `AgentAdapter` 인터페이스 구현
2. Tier 판단 (Full / Context+Hooks / Context Only)
3. 컨텍스트 변환 로직 추가
4. `ai-harness doctor`에 감지 로직 추가

```bash
# 커뮤니티 어댑터 설치
$ ai-harness adapter install @community/aider-adapter
```
