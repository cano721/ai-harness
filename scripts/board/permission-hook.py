#!/usr/bin/env python3
"""Claude Code PermissionRequest 훅: 보드가 떠 있을 때만 권한 요청을 보드에 넘기고, 보드에서 누른 답을 돌려준다.

- 보드가 꺼져 있거나(server.json 없음·연결 실패) 보드를 보는 사람이 없으면 아무것도 출력하지 않는다.
  그러면 Claude Code가 평소처럼 터미널에서 묻는다.
- AskUserQuestion은 넘기지 않는다 — 질문 답은 사람이 터미널이나 보드 입력으로 한다.
- headless 세션(`claude -p` — 워크플로 러너·자동 harvest·autofix 등)의 요청은 넘기지 않는다. 답할 사람이 없는 세션을
  보드가 붙잡으면 그 실행이 통째로 멈춘다. 아무것도 출력하지 않으면 Claude Code가 평소처럼 바로 거부하고 세션이 이어 간다.
- 보드는 사람이 누른 허용/거부만 돌려준다. 스스로 답하지 않는다.
설치(~/.claude/settings.json 등록)는 /ai-harness:setup 선택 항목이 board.sh hook on으로 한다.
표준 라이브러리만 쓴다. board.sh가 이 파일을 $HARNESS_METRICS_DIR/board/bin/에 복사해 등록하므로 플러그인 경로가 바뀌어도 그대로 돈다.
"""
import json, os, subprocess, sys, urllib.request

DATA = os.environ.get("HARNESS_METRICS_DIR") or os.path.expanduser("~/.ai-harness")
CONF = os.path.join(DATA, "board", "server.json")
WAIT = 3590  # 서버가 붙잡는 최대 시간(BOARD_PERMISSION_WAIT 3500)보다 길고, 등록한 훅 timeout(3600)보다 짧게


def headless():
    """실측(Claude Code 2.1.322): 훅 프로세스의 CLAUDE_CODE_ENTRYPOINT는 `claude -p`면 sdk-cli, 대화형·백그라운드(--bg) 세션이면 cli다.
    SDK 세션(sdk-ts 등) 안에서 띄운 `claude -p`는 부모 값을 물려받아 구분되지 않는다. 그래서 하네스 러너는 AI_HARNESS_HEADLESS=1을 함께 넘기고,
    그 신호가 없는 실행(예전 러너)은 세션 프로세스의 인자로 가린다 — `-p`로 떴고 권한을 대신 받을 호스트(--permission-prompt-tool)가 없다.
    CLAUDE_CODE_SESSION_ATTENDED는 백그라운드 세션에서도 0이라 쓰지 않는다 — 그 세션의 요청은 보드가 받아야 한다."""
    if os.environ.get("AI_HARNESS_HEADLESS") == "1" or os.environ.get("CLAUDE_CODE_ENTRYPOINT") == "sdk-cli":
        return True
    try:
        pid = os.environ.get("CLAUDE_PID", "")
        argv = subprocess.run(["ps", "-o", "command=", "-p", pid if pid.isdigit() else str(os.getppid())],
                              capture_output=True, text=True, timeout=5).stdout.split()
    except Exception:
        return False
    return any("claude" in a for a in argv[:2]) and ("-p" in argv or "--print" in argv) \
        and "--permission-prompt-tool" not in argv


def main():
    if headless():
        return
    try:
        req = json.loads(sys.stdin.read())
        if req.get("tool_name") == "AskUserQuestion":
            return
        with open(CONF) as f:
            c = json.load(f)
        req["orca_terminal"] = os.environ.get("ORCA_TERMINAL_HANDLE", "")
        req["entrypoint"] = os.environ.get("CLAUDE_CODE_ENTRYPOINT", "")
        with urllib.request.urlopen(urllib.request.Request(
                f"http://127.0.0.1:{int(c['port'])}/hook/permission", data=json.dumps(req).encode(), method="POST",
                headers={"Content-Type": "application/json", "X-Board-Hook": c["token"]}), timeout=WAIT) as r:
            res = json.loads(r.read() or b"{}")
    except Exception:
        return
    behavior = res.get("behavior") if isinstance(res, dict) else None
    if behavior not in ("allow", "deny"):
        return
    decision = {"behavior": behavior}
    if behavior == "deny":
        decision["message"] = "Harness Board에서 사람이 거부함"
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": decision}}))


if __name__ == "__main__":
    main()
