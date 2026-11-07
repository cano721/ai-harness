#!/usr/bin/env python3
"""Claude Code PermissionRequest 훅: 권한 질문을 Harness Board에 알리기만 하고 바로 끝난다.
훅이 답을 기다리면 Claude가 터미널에 yes/no 창을 띄우지 않으므로 절대 붙잡지 않는다.
보드에서 허용/거부를 누르면 보드 서버가 이 세션의 Orca 터미널에 키를 보내 같은 창에 답한다."""
import json, os, sys, urllib.request

CONF = os.path.join(os.environ.get("HARNESS_METRICS_DIR", os.path.expanduser("~/.ai-harness")), "board", "server.json")


def main():
    try:
        req = json.loads(sys.stdin.read())
        if req.get("tool_name") == "AskUserQuestion":
            return
        with open(CONF) as f:
            c = json.load(f)
        req["orca_terminal"] = os.environ.get("ORCA_TERMINAL_HANDLE", "")
        urllib.request.urlopen(urllib.request.Request(
            f"http://127.0.0.1:{int(c['port'])}/hook/permission", data=json.dumps(req).encode(), method="POST",
            headers={"Content-Type": "application/json", "X-Board-Hook": c["token"]}), timeout=2).read()
    except Exception:
        pass


if __name__ == "__main__":
    main()
