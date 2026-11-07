#!/usr/bin/env python3
"""Claude Code PermissionRequest 훅: 보드가 떠 있을 때만 권한 요청을 보드에 넘기고, 보드에서 누른 답을 돌려준다.

- 보드가 꺼져 있거나(server.json 없음·연결 실패) 보드를 보는 사람이 없으면 아무것도 출력하지 않는다.
  그러면 Claude Code가 평소처럼 터미널에서 묻는다.
- AskUserQuestion은 넘기지 않는다 — 질문 답은 사람이 터미널이나 보드 입력으로 한다.
- 보드는 사람이 누른 허용/거부만 돌려준다. 스스로 답하지 않는다.
설치(~/.claude/settings.json 등록)는 /ai-harness:setup 선택 항목이 board.sh hook on으로 한다.
표준 라이브러리만 쓴다. board.sh가 이 파일을 $HARNESS_METRICS_DIR/board/bin/에 복사해 등록하므로 플러그인 경로가 바뀌어도 그대로 돈다.
"""
import json, os, sys, urllib.request

DATA = os.environ.get("HARNESS_METRICS_DIR") or os.path.expanduser("~/.ai-harness")
CONF = os.path.join(DATA, "board", "server.json")
WAIT = 3590  # 서버가 붙잡는 최대 시간(BOARD_PERMISSION_WAIT 3500)보다 길고, 등록한 훅 timeout(3600)보다 짧게


def main():
    try:
        req = json.loads(sys.stdin.read())
        if req.get("tool_name") == "AskUserQuestion":
            return
        with open(CONF) as f:
            c = json.load(f)
        req["orca_terminal"] = os.environ.get("ORCA_TERMINAL_HANDLE", "")
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
