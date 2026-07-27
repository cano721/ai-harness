# /harness-init — 프로젝트 AI 하네스 최초 셋업

현재 프로젝트(cwd)를 분석해 `.ai-harness` 하네스 구조를 스캐폴딩한다. 이후 `/metrics`로 관찰, `/harvest`로 개선하는 사이클의 시작점.

인자: `$ARGUMENTS`
- `--minimal` — AGENTS.md + docs만 (워크플로/페르소나/가드 없이 가볍게 시작)
- `--guard` — direct-edit-guard hook 포함 (소스 수정 전 컨벤션 docs Read 강제)

## 0. 전제 확인 — 하나라도 걸리면 중단

- 이미 `.ai-harness/` 또는 `AGENTS.md`가 있으면 **중단하고 보고** (덮어쓰기 금지 — 기존 하네스 개선은 `/harvest` 소관)
- git repo가 아니면 사용자에게 `git init` 여부 확인

## 1. 프로젝트 분석 (생성 전에 실측)

빌드 파일로 감지: 언어/프레임워크(`build.gradle*`, `pom.xml`, `package.json`, `pyproject.toml`, `go.mod` 등), 테스트 프레임워크·실행 명령, 빌드/실행 명령, git 컨벤션(최근 커밋 메시지·브랜치명 패턴 `git log --oneline -30`, `git branch -a`), 패키지/모듈 구조(주요 디렉토리와 의존 방향).

분석 결과는 다음 단계 문서 초안의 **실측 근거**가 된다 — 추측으로 채우지 않는다. 규모가 크면 탐색 서브에이전트(Explore 등)에 위임.

## 2. 생성 구조

```
AGENTS.md                    # 진입점 (아래 구성)
CLAUDE.md                    # 내용: "@AGENTS.md" 한 줄 (이미 있으면 @AGENTS.md 참조만 추가)
.ai-harness/
  docs/
    code-conventions.md      # 실측된 네이밍·구조·스타일 규칙
    architecture.md          # 모듈 구조, 기술 스택, 빌드/배포 (실측)
    testing.md               # 테스트 실행법, 프레임워크, 작성 규칙 (실측)
    domain.md                # 도메인 인덱스 (초기엔 표 틀만 — 도메인 문서는 필요해질 때 domain/{name}.md로 추가)
  workflows/                 # --minimal이면 생략
    implement-feature.md     # 기능 개발 절차 (TDD 여부는 프로젝트 관행 따름)
    fix-bug.md
    review.md
  agents/                    # --minimal이면 생략
    developer.md             # 구현 전담 (write scope: 소스+빌드 설정)
    test-engineer.md         # 테스트 전담 (write scope: 테스트 디렉토리만)
    reviewer.md              # 리뷰 전담 (read-only)
  hooks/
    direct-edit-guard.sh     # --guard일 때만
.claude/
  agents/{developer,test-engineer,reviewer}.md   # 위 페르소나의 frontmatter 위임본 (--minimal이면 생략)
  commands/{implement-feature,fix-bug,review}.md # 워크플로 진입 슬래시 커맨드 (--minimal이면 생략)
  settings.json              # 감지된 빌드/테스트 명령 allowlist (+ --guard면 PreToolUse hook)
```

## 3. 작성 원칙

- **AGENTS.md 구성**: Preflight(작업 시작 절차) / Hard constraints / Direct edit guard 룰(--guard 시) / 워크플로·페르소나 표 / docs 목록 / Quick Commands(감지된 명령) / Git 컨벤션(실측)
- **Hard constraints는 틀만 만들고 비워둔다** — "실측으로 검증된 룰만 추가. 추측 금지" 주석 한 줄. 이 섹션은 `/harvest`가 시간을 들여 채우는 영역
- docs는 실측 내용만. 확인 못 한 건 쓰지 말고 "코드를 source of truth로 확인" 문구로 대체
- 페르소나 write scope는 좁게 (test-engineer는 테스트 디렉토리만 등)
- settings.json allowlist는 read-only·빌드·테스트 명령만. deny에 force push
- direct-edit-guard.sh는 소스 경로 수정 전 code-conventions.md(테스트면 testing.md 추가) Read 여부를 transcript에서 grep — 미Read 시 exit 2 + 안내. transcript 접근 불가 시 fail-open(exit 0)

## 4. 마무리

1. 생성 파일 목록 + 각 파일이 실측에서 가져온 근거 요약 보고
2. 커밋/PR은 사용자 확인 후 (프로젝트 git 컨벤션 따름)
3. 안내: "이후 세션부터 활동이 자동 수집됩니다. 2~4주 뒤 `/metrics`로 관찰, `/harvest <프로젝트>`로 개선 사이클을 시작하세요."
