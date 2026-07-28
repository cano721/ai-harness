# /harness-init — 프로젝트 AI 하네스 셋업 / 수준 변경

현재 프로젝트(cwd)를 분석해 `.ai-harness` 하네스 구조를 스캐폴딩한다. 이후 `/metrics`로 관찰, `/harvest`로 개선하는 사이클의 시작점. **기존 하네스가 있으면 수준 변경 모드로 동작한다.**

인자: `$ARGUMENTS` — 아래 인터뷰 답을 미리 줄 수도 있음 (예: `minimal`, `tdd`, `guard`). 준 항목은 질문 생략.

## 0. 모드 판정

- `.ai-harness/`와 `AGENTS.md` **둘 다 없음** → **신규 셋업** (1번부터 진행)
- **하나라도 있음** → **수준 변경 모드** (아래 6번으로) — AGENTS.md만 있는 프로젝트도 기존 하네스로 취급, 절대 덮어쓰지 않는다
- git repo가 아니면 사용자에게 `git init` 여부 확인

## 1. 프로젝트 분석 (질문보다 먼저 — 질문에 실측 컨텍스트를 담기 위해)

빌드 파일로 감지: 언어/프레임워크(`build.gradle*`, `pom.xml`, `package.json`, `pyproject.toml`, `go.mod` 등), 테스트 프레임워크·**기존 테스트 규모**(테스트 파일 수, 커버리지 게이트 유무), 빌드/실행 명령, git 컨벤션(최근 커밋 메시지·브랜치명 패턴 `git log --oneline -30`, `git branch -a`), 패키지/모듈 구조(주요 디렉토리와 의존 방향).

분석 결과는 문서 초안의 **실측 근거**가 된다 — 추측으로 채우지 않는다. 규모가 크면 탐색 서브에이전트(Explore 등)에 위임.

## 2. 수준 인터뷰 (AskUserQuestion — 엄격도는 사용자가 정한다)

하네스 엄격도는 프로젝트 성격에 따라 크게 다르다 (예: 프로덕션 백엔드는 TDD 강제 + 커버리지 게이트가 맞지만, 사이드 프로젝트에 그 수준은 과함). **기본값을 가정하지 말고 물어본다.** 단, 1단계 실측을 질문 설명에 반영한다 (예: "현재 테스트 파일 0개" / "jacoco 게이트 이미 있음").

1. **하네스 규모**: `minimal`(AGENTS.md+docs만) / `standard`(+워크플로·페르소나) / `full`(+편집 가드 hook)
2. **테스트 정책**: `TDD 강제`(Red→Green→Refactor, test-engineer가 RED 전담) / `테스트 필수`(순서 무관, 구현 후 작성 허용) / `권장만` / `없음`(testing.md·test-engineer 생성 안 함)
   - 실측과 모순되면 지적: 기존 테스트가 0개인데 TDD 강제를 고르면 "기존 코드엔 characterization부터 필요" 경고
3. **git 통제 수준**: `PR 필수`(에이전트는 PR까지만, 병합은 사람) / `직접 커밋 허용`

답에 따라 생성물 조정: 워크플로 본문의 TDD 절차 유무, test-engineer 페르소나 유무, guard hook 유무, AGENTS.md의 Git 룰 문구.

## 3. 생성 구조 (인터뷰 답 기준으로 가감)

```
AGENTS.md                    # 진입점 (아래 구성)
CLAUDE.md                    # 내용: "@AGENTS.md" 한 줄 (이미 있으면 @AGENTS.md 참조만 추가)
.ai-harness/
  harness.json               # 수준 매니페스트 (아래 참조) — 수준 변경 모드·/harvest가 읽음
  docs/
    code-conventions.md      # 실측된 네이밍·구조·스타일 규칙
    architecture.md          # 모듈 구조, 기술 스택, 빌드/배포 (실측)
    testing.md               # 테스트 실행법, 프레임워크, 작성 규칙 (테스트 정책 '없음'이면 생략)
    domain.md                # 도메인 인덱스 (초기엔 표 틀만 — 도메인 문서는 필요해질 때 domain/{name}.md로 추가)
  workflows/                 # standard 이상
    implement-feature.md     # 기능 개발 절차 (테스트 정책 답에 맞춰 TDD 절차 포함/제외)
    fix-bug.md
    review.md
  agents/                    # standard 이상
    developer.md             # 구현 전담 (write scope: 소스+빌드 설정)
    test-engineer.md         # 테스트 전담 (write scope: 테스트 디렉토리만. 테스트 정책 '없음'이면 생략)
    reviewer.md              # 리뷰 전담 (read-only)
  hooks/
    direct-edit-guard.sh     # full일 때만
.claude/
  agents/                    # 위 페르소나의 frontmatter 위임본 (standard 이상)
  commands/                  # 워크플로 진입 슬래시 커맨드 (standard 이상)
  settings.json              # 감지된 빌드/테스트 명령 allowlist (+ full이면 PreToolUse hook)
```

## 4. 작성 원칙

- **AGENTS.md 구성**: Preflight(작업 시작 절차) / Hard constraints / Direct edit guard 룰(full 시) / 워크플로·페르소나 표 / docs 목록 / Quick Commands(감지된 명령) / Git 컨벤션(실측 + 인터뷰 답)
- **Hard constraints는 틀만 만들고 비워둔다** — "실측으로 검증된 룰만 추가. 추측 금지" 주석 한 줄. 이 섹션은 `/harvest`가 시간을 들여 채우는 영역
- docs는 실측 내용만. 확인 못 한 건 쓰지 말고 "코드를 source of truth로 확인" 문구로 대체
- 페르소나 write scope는 좁게 (test-engineer는 테스트 디렉토리만 등)
- settings.json allowlist는 read-only·빌드·테스트 명령만. deny에 force push
- direct-edit-guard.sh는 소스 경로 수정 전 code-conventions.md(테스트면 testing.md 추가) Read 여부를 transcript에서 grep — 미Read 시 exit 2 + 안내. transcript 접근 불가 시 fail-open(exit 0)

매니페스트 형식 (인터뷰 답 기록 — 수준 변경·/harvest의 정책 참조용):

```json
{ "level": "standard", "test_policy": "tdd", "git_policy": "pr-only", "initialized": "YYYY-MM-DD", "harness_version": "<플러그인 버전>" }
```

## 5. 마무리

1. 생성 파일 목록 + 각 파일이 실측에서 가져온 근거 요약 보고
2. 커밋/PR은 사용자 확인 후 (프로젝트 git 컨벤션 따름)
3. 안내: "이후 세션부터 활동이 자동 수집됩니다. 2~4주 뒤 `/metrics`로 관찰, `/harvest <프로젝트>`로 개선 사이클을 시작하세요."

## 6. 수준 변경 모드 (기존 하네스 감지 시)

1. **현재 수준 파악**: `.ai-harness/harness.json` Read. 없으면(구버전/수동 셋업) 파일 구조로 역추정 — 워크플로·페르소나 유무 = standard 이상, guard hook 유무 = full, test-engineer·testing.md 유무 = 테스트 정책 — 하고 역추정 결과를 사용자에게 확인받은 뒤 harness.json 생성
2. **재인터뷰**: 2번과 동일한 질문을 현재 값 보여주며 진행 ("현재: standard / TDD / PR 필수")
3. **diff만 적용**:
   - 업그레이드(컴포넌트 추가): 자동 진행 — 신규 셋업과 동일한 작성 원칙, 기존 docs는 건드리지 않음
   - **다운그레이드(삭제)**: 삭제 대상 파일 목록을 보여주고 **사용자 확인 후** 삭제 — `/harvest`가 채워온 커스텀 내용이 날아갈 수 있음. AGENTS.md에서 해당 섹션(워크플로 표, guard 룰 등)도 함께 제거
   - 테스트 정책 변경: 워크플로 본문의 테스트 절차 재작성, test-engineer·testing.md 추가/제거(제거는 확인 후), AGENTS.md 위임 규칙 갱신
4. harness.json 갱신 + 변경 요약 보고. 커밋/PR은 사용자 확인 후
