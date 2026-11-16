#!/usr/bin/env python3
"""보드 상주 세션 호스트 테스트용 작은 클라이언트(#364). 화면처럼 SSE를 열고 보드 HTTP를 부른다.
관찰한 사실만 JSON 한 줄로 출력하고 판정은 tests/run.sh가 한다.

사용: client.py <base url> <token> <명령> [인자...]
  roundtrip <id> <text> [기대 글자]  SSE를 연 채로 보내고, 그 글의 답(기본: 가짜 claude의 echo)이 결과 확인으로
                            밀려 올 때까지 걸린 초
  send <id> <text>          보내기만
  new <cwd> <prompt>        새 세션
  end <id>                  세션 끝내기
  item <id>                 /status.json의 그 항목(없으면 null)
  allow <id>                그 항목에 붙잡힌 권한 요청 허용
  waitperm <id> <초>        /status.json으로 그 항목의 권한 요청이 보일 때까지 기다린 초(못 보면 null)와
                            첫 목록에 이미 실려 있었는지(first)
"""
import http.client, json, queue, sys, threading, time, urllib.request
from urllib.parse import urlparse, quote

BASE, TOKEN, CMD = sys.argv[1:4]
ARGS = sys.argv[4:]
u = urlparse(BASE)


def post(path, body):
    req = urllib.request.Request(BASE + path, data=json.dumps({"t": TOKEN, **body}).encode(), method="POST",
                                 headers={"Origin": BASE, "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.loads(r.read())


def item(iid):
    with urllib.request.urlopen(f"{BASE}/status.json?t={quote(TOKEN)}", timeout=20) as r:
        data = json.loads(r.read())
    return next((i for i in data.get("items", []) if i.get("id") == iid), None)


def sse(events):
    conn = http.client.HTTPConnection(u.hostname, u.port, timeout=30)
    conn.request("GET", f"/events?t={quote(TOKEN)}")
    r = conn.getresponse()
    name, data = None, []
    while True:
        line = r.readline()
        if not line:
            return
        line = line.decode().rstrip("\n")
        if line.startswith("event:"):
            name = line[6:].strip()
        elif line.startswith("data:"):
            data.append(line[5:].strip())
        elif line == "":
            if name:
                events.put((name, json.loads("\n".join(data)) if data else None, time.time()))
            name, data = None, []


def open_sse():
    events = queue.Queue()
    threading.Thread(target=sse, args=(events,), daemon=True).start()
    name, _, _ = events.get(timeout=10)
    assert name == "hello", name
    return events


def wait_event(events, pred, timeout):
    end = time.time() + timeout
    while time.time() < end:
        try:
            name, data, at = events.get(timeout=max(0.05, end - time.time()))
        except queue.Empty:
            break
        if name == "item" and pred(data):
            return data, at
    return None, None


if CMD == "roundtrip":
    iid, text = ARGS[:2]
    expect = ARGS[2] if len(ARGS) > 2 else "echo " + text[:20]  # 실제 claude로 잴 때는 기대하는 답 글자를 준다
    events = open_sse()
    t0 = time.time()
    ok = post("/action", {"id": iid, "action": "send", "text": text}).get("ok")
    hit, at = wait_event(events, lambda i: i.get("id") == iid and i.get("state") == "review"
                         and expect in (i.get("detail") or ""), 60)
    print(json.dumps({"ok": ok, "seconds": round(at - t0, 3) if hit else None}))
elif CMD == "send":
    print(json.dumps(post("/action", {"id": ARGS[0], "action": "send", "text": ARGS[1]})))
elif CMD == "new":
    print(json.dumps(post("/new", {"cwd": ARGS[0], "prompt": ARGS[1], "name": ARGS[1][:20]})))
elif CMD == "end":
    print(json.dumps(post("/action", {"id": ARGS[0], "action": "end"})))
elif CMD == "item":
    print(json.dumps(item(ARGS[0])))
elif CMD == "allow":
    it = item(ARGS[0]) or {}
    pid = (it.get("permission") or {}).get("pid")
    print(json.dumps(post("/permission", {"pid": pid, "decision": "allow"}) if pid else {"ok": False, "message": "no permission"}))
elif CMD == "waitperm":
    iid, limit = ARGS[0], float(ARGS[1])
    t0 = time.time()
    seen, polls = None, 0
    while time.time() - t0 < limit:
        it = item(iid)
        polls += 1
        if it and it.get("permission"):
            seen = round(time.time() - t0, 3)
            break
        time.sleep(0.05)
    print(json.dumps({"seconds": seen, "first": seen is not None and polls == 1}))
else:
    sys.exit(2)
