# Design Polish — ai-harness

노드·전이의 계약은 `.ai-harness/workflows/design-polish-graph.json`이 단일 출처다. 이 문서는 이 저장소에서 기존 화면을 다듬을 때 쓰는 **프로젝트 사실**만 적는다. 화면 실행·뷰포트·테마·기계 검사의 원본은 `.ai-harness/docs/ui.md`다.

## 1. 측정 (measure)

- 대상 화면: Harness Board(`scripts/board/template.html`), 하네스 효과 리포트(`skills/harness-impact/report-template.html`), 기준 화면(`docs/design-system/reference.html`).
- 보드는 `ui.md`의 "보드를 격리해 띄우기"대로 임시 `HARNESS_METRICS_DIR`·비어 있는 `BOARD_PORT`로 띄운다. 사용자의 보드(8765, `~/.ai-harness`)를 건드리지 않고, 끝나면 같은 환경 변수로 `board.sh stop`.
- 형제 화면: 세 화면이 같은 `tokens.css`·`components.css` 사본을 싣는다. 보드의 한 탭을 다듬으면 같은 분류의 다른 탭(`docs/design-system.md`의 `## 형제 목록`)과 기준 화면을 함께 캡처한다.
- 뷰포트 360·760 근처·1280, 테마 light·dark(`?theme=light|dark`).
- 채점: `design-audit` 스킬(`.claude/skills/design-audit`·`.agents/skills/design-audit`), 규칙 문서 `docs/design-system.md`.

## 2. 진단 (diagnose)

- 근거는 캡처와 `docs/design-system.md`의 절(필수 절 이름 그대로)이다. 규칙 문서가 `draft`라 "확인 대기" 결정은 고칠 목록이 아니라 사람이 정할 점으로 둔다.

## 3. 수정 (fix)

- 토큰·공용 부품 원본(`docs/design-system/tokens.css`·`components.css`)을 고쳤으면 `bash scripts/design-system.sh sync`로 세 화면의 사본을 맞춘다. 사본을 손으로 고치지 않는다.
- 기계로 잡히는 위반(중단점 폭·disabled 커서·강조 면 글자색·danger 알림 문구 같은 것)은 `scripts/design-system.sh lint`에 검사를 더한다. 그 밖의 간격·색·위계 수정에는 테스트를 만들지 않는다.
- 소스를 고치기 전에 `.ai-harness/docs/code-conventions.md`를 Read한다(`AGENTS.md` Preflight).

## 4. 검증 (verify)

러너가 수정마다 직접 실행하는 검사는 화면 기계 검사 셋이다(측정 노드가 `checks`로 낸다).

```bash
bash scripts/design-system.sh check
bash scripts/design-system.sh contrast
bash scripts/design-system.sh lint
```

전체 회귀 `bash tests/run.sh`는 수십 분 걸려 수정마다 돌리지 않는다 — publish 뒤 원격 CI(`.github/workflows/test.yml`)가 같은 명령을 돌리고 `remote_ci` 노드가 그 결과를 본다. 셸 스크립트를 함께 고쳤으면 `start --check "bash tests/run.sh"`로 더한다.

## 5. 내보내기 (publish)

`AGENTS.md`의 Git 규칙: 작업 브랜치 `<타입>/<한-일-요약>`, Conventional Commits에 `(#<이슈>)`, `gh pr create --base develop`. 사용자에게 보이는 변경이면 `CHANGELOG.md`의 `## Unreleased`에 항목을 남긴다.
