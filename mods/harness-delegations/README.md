# harness-delegations

Claude Code mod. 이 세션이 Orca 탭으로 맡긴 세션(workspace 멤버 인계, `orca agent launch`, `orca worktree create --agent`)의 진행 상태를 프롬프트 위 한 줄로 보여 준다.

```
위임  ? api-server 2분 · ▶ web-front · ✓ batch PR #12  [자세히]
```

- 상태: `▶` 작업 중 · `?` 입력 대기 · `⚠` 정체(작업 중 표시로 10분째 화면 그대로) · `✓` 완료(화면에 PR 번호) · `⏸` 턴 끝남 · `✕` 종료
- 항목을 누르면 `orca terminal switch`로 그 탭으로 간다. 탭이 닫히고 같은 worktree에 세션이 다시 떴으면 그 탭을 이어 추적한다.
- 상태가 바뀌면 알림을 띄우고, 조율 세션(모델)에게 메시지를 보내 결과를 사용자에게 보고하게 한다.
- `/harness-delegations` — 자세한 패널. `clear`(끝난 항목 빼기), `add <term_…>`, `forget <term_…>`.

맡긴 탭은 이 세션의 Bash 결과(`orca terminal create|split`, `orca agent launch`, `orca worktree create`가 돌려준 handle)와 `wait-delegation.sh --terminal`, 세션을 다시 열면 대화 기록에서 찾는다. 판정 문구는 `scripts/wait-delegation.sh`와 같다(`tests/automation.sh`가 검사).

## 설치

ai-harness 마켓플레이스에 함께 있다. mod를 켠 Claude Code에서:

```
/plugin install harness-delegations@ai-harness
```

`orca` CLI가 필요하다. 없거나 막혀 있으면 줄이 뜨지 않고 다른 동작에는 영향이 없다 — 같은 정보는 `/ai-harness:board`의 작업 묶음에서 본다.

## 개발

```bash
claude plugin validate mods/harness-delegations
claude plugin test mods/harness-delegations
```
