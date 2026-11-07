---
name: board
description: 하네스 대시보드(Harness Board)를 필요할 때 여는 로컬 화면. 작업 세션(Claude Code 세션 상태·대화·입력 보내기·질문과 권한 요청 답하기·끝난 세션 정리), 하네스 동작(자동 harvest·sync·정기 실행·워크플로 러너·자동 적용 규칙), 하네스 설정(개인 자동화 단계·자동 실행/병합·하루 상한, 저장소 사실 변경 PR)을 브라우저 한 화면에서 본다. "보드 열어줘", "하네스 대시보드", "세션들 한눈에", "보드 꺼줘", "보드 떠 있어?"에 쓴다. 상시 서비스가 아니다 — 데몬 없이 스킬이 띄우고 끈다.
---

# /board — Harness Board

자동 harvest·sync·자동 병합은 플러그인 정기 실행이 하고, 보드는 **보여 주고 사람이 답하는 화면**이다. 인자: `$ARGUMENTS` — 없거나 `open`이면 열기, `stop`이면 끄기, `status`면 상태.

경로 표기: 아래 `$ROOT` = 이 SKILL.md가 있는 디렉터리의 두 단계 상위(플러그인 루트).

## 열기 (`open`, 기본)

```bash
$ROOT/scripts/board/board.sh open
```

- 이미 떠 있으면(`~/.ai-harness/board/server.json`의 pid가 살아 있는 보드 서버) 그 주소를 다시 연다(`reused: true`). 없으면 백그라운드로 띄우고 브라우저를 연다.
- 출력 한 줄 JSON의 `url`(토큰 포함)을 사용자에게 그대로 보여 준다. 브라우저가 열리지 않는 환경이면 그 주소를 직접 열라고 안내한다. 이 주소의 토큰은 보드를 조작할 수 있는 열쇠이므로 PR·이슈·공유 문서에는 적지 않는다.
- 실패하면(종료 코드 1) stderr 이유를 그대로 전한다. 포트가 다른 프로세스에 잡혀 있으면 띄우지 않고 멈춘다 — 다른 포트로 띄울지 사용자에게 묻고, 원하면 `BOARD_PORT=<포트> $ROOT/scripts/board/board.sh open`. 이전 버전 서버가 주소 없이 떠 있다는 메시지면 `stop` 뒤 다시 열지 묻는다.
- 브라우저를 열지 않고 주소만 원하면 `--no-browser`.

## 끄기 (`stop`) · 상태 (`status`)

```bash
$ROOT/scripts/board/board.sh stop
$ROOT/scripts/board/board.sh status
```

`stop`은 보드 서버만 끈다(`server.json`의 pid가 보드 서버일 때만 신호를 보낸다). 작업 세션·worktree는 건드리지 않는다. `status`는 `running`·`url`을 보여 준다.

## 보드가 하는 일과 하지 않는 일

- **작업**: `claude agents --json --all`과 세션 대화 기록으로 상태를 보여 준다. 대화 보기(위로 올리면 이전 대화), 입력 보내기(백그라운드 세션은 멈춘 뒤 같은 ID로 이어 가기, Orca 터미널의 대화형 세션은 그 터미널에 입력), 질문(AskUserQuestion) 답 버튼, 권한 요청 허용/거부, 읽음 처리, 끝난 세션 정리.
- **하네스 동작**: 자동 harvest·sync 실행 기록, 대기 중인 harvest(지금 돌리기), 정기 실행, 워크플로 러너, 자동 적용 규칙. 사람 확인이 필요한 PR은 호스트에서 병합·거절되면 완료로 내린다.
- **하네스 설정**: `~/.ai-harness/config`의 개인 자동화 단계(`HM_DELIVERY_LEVEL`·`HM_DELIVERY_LEVEL_REPOS`), 자동 harvest·sync 실행/병합과 하루 상한을 바로 쓴다(다른 줄은 보존). 기준 브랜치·배포·스모크 명령 같은 저장소 사실은 `harness.json`을 직접 고치지 않고 그 저장소에서 `/ai-harness:harness-init` 설정 변경 세션을 띄워 draft PR로 낸다.
- 보드는 다른 세션의 질문·권한에 **사람 없이 답하지 않는다**. 대화 기록(transcript)은 지우지 않는다. 세션 정리에서 worktree는 변경·원격에 없는 커밋·다른 살아 있는 세션이 없을 때만 지우고 강제 삭제는 하지 않는다.
- Orca는 선택이다. 없으면 세션 묶음과 대화형 터미널 입력만 빠진다.

## 권한 요청을 보드로 받기 (선택)

보드에서 권한 요청을 허용/거부하려면 PermissionRequest 훅이 필요하다. 이 스킬은 훅을 몰래 연결하지 않는다 — 사용자가 원하면 `/ai-harness:setup`의 자동화 옵션(8-2)으로 연결한다. 훅은 보드가 떠 있고 누군가 보드를 보고 있을 때만 요청을 넘기며, 아니면 아무것도 출력하지 않아 평소처럼 터미널에서 묻는다.

## 보안

서버는 `127.0.0.1`에만 묶인다. 실행마다 새 URL 토큰을 만들고, 모든 요청의 Host(DNS rebinding 방어), POST의 Origin을 검사한다. 브라우저에서 명령 문자열을 받지 않고 항목별로 허용된 작업만 서버가 인자를 만들어 실행한다. 권한 훅 엔드포인트는 별도 토큰을 쓰며, 그 토큰과 주소는 `~/.ai-harness/board/server.json`(0600, 서버 종료 시 삭제)에만 있다.
