# AI Harness - Init 플로우 상세

## 전체 플로우

```
Step 1: 환경 감지 → Step 2: 설정 패키지 연결 → Step 3: OMC 확인
    → Step 4: 팀 선택 → Step 5: 프로젝트 스택 감지 → Step 6: 설치 실행
```

## Step 1: 환경 감지

Node.js, Git 저장소, Claude Code 설치 여부 확인. 기존 하네스 설정이 있으면 업데이트/초기화 선택.

## Step 2: 설정 패키지 연결

회사 설정 패키지(@company/harness-config) 또는 기본 템플릿 선택.

## Step 3: OMC 확인

OMC 설치 여부 감지. 있으면 Full 모드(Core + OMC 연동), 없으면 Core 모드.

## Step 4: 팀 선택

복수 선택 가능. 프리셋 지원 (fullstack, product, all). 프로젝트 파일 기반 자동 추천.

## Step 5: 프로젝트 스택 감지

package.json, build.gradle 등으로 기술 스택 자동 감지. 감지 실패 시 수동 선택.

## Step 6: 설치 실행

```
설치 항목:
[Core] .ai-harness/config.yaml, .claude/CLAUDE.md, .claude/settings.json
[Hooks] block-dangerous, audit-logger, secret-scanner + 팀별 Hook
[OMC] Hook 체이닝, 모드별 guardrail, 커스텀 에이전트/스킬
[MCP] jira-server, confluence-server
```

## 비파괴적 설치 원칙

- CLAUDE.md: `<!-- harness:start -->` ~ `<!-- harness:end -->` 구간만 관리, 기존 내용 보존
- settings.json: `_managed_by: "ai-harness"` 마커로 하네스 항목 식별, 기존 Hook 보존

## CLI 옵션

```bash
ai-harness init [options]
  --config <package>     설정 패키지 지정
  --team <teams>         팀 직접 지정
  --preset <name>        프리셋 사용
  --no-omc               Core 모드
  --dry-run              설치 계획만 출력
  --non-interactive      CI/CD용 기본값 설치
```
