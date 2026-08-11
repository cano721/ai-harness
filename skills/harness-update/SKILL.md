---
name: harness-update
description: ai-harness 최신 버전을 확인하고 사용자가 명시적으로 요청한 경우에만 Claude Code 또는 Codex CLI 플러그인을 업데이트한다.
---

# /harness-update — ai-harness 업데이트

세션 시작 알림 또는 사용자의 요청으로 ai-harness의 최신 릴리스와 설치 버전을 비교한다. **자동 업데이트는 하지 않는다.** 인자: `$ARGUMENTS` (`--check` 기본, `--apply` 명시 시에만 설치 변경).

경로 표기: 아래 `$ROOT` = 이 SKILL.md가 있는 디렉터리의 두 단계 상위(플러그인 루트).

## 1. 확인 (`--check`, 기본)

```bash
$ROOT/scripts/check-update.sh status
```

- `update_available:false`이면 최신 상태임을 간단히 알린다.
- 조회 실패(`last_result: failure`)는 기존 캐시를 보존한 상태다. 오류를 보여 주되 세션 작업을 막지 말고, 나중에 다시 확인하도록 안내한다.
- 이 단계에서는 플러그인·마켓플레이스·프로젝트 파일을 변경하지 않는다.

## 2. 적용 (`--apply`를 사용자가 명시한 경우만)

현재 호스트를 확인한 뒤 **그 호스트 하나만** 업데이트한다. Claude와 Codex가 모두 설치되어 어느 쪽인지 확실하지 않으면 사용자에게 선택을 묻는다. `git pull`, 임의의 설치 스크립트, `curl | sh`는 사용하지 않는다.

### Codex CLI

```bash
codex plugin marketplace upgrade ai-harness
codex plugin add ai-harness@ai-harness
codex plugin list
```

### Claude Code

```bash
claude plugin update ai-harness@ai-harness
claude plugin list
```

명령이 실패하면 출력과 함께 중단하고, 수동 재설치나 마켓플레이스 설정을 추측해서 바꾸지 않는다. 성공 후에는 새 대화/세션에서 플러그인 스킬과 hook을 다시 로드하도록 안내한다.

## 안전 경계

- SessionStart hook은 업데이트 여부만 알리고 설치를 실행하지 않는다.
- 최신 버전 정보는 로컬 `~/.ai-harness/update-check.json`에 기본 24시간 캐시된다. `HM_UPDATE_CHECK_HOURS`로 주기를 조절할 수 있고, `0`이면 매 시작마다 확인한다.
- 릴리스 메타데이터는 HTTPS로만 조회하며, 네트워크 실패 시 기존 성공 캐시를 계속 사용한다.
