#!/usr/bin/env python3
"""SSE만 연결된 화면(#349 + #351): /status.json을 한 번도 부르지 않고 이벤트 연결만 연 채로, 다른 터미널 세션이 새로 생기면
서버의 백그라운드 갱신이 캐시를 다시 모아 그 세션이 item 이벤트로 오는지 본다. 관찰한 사실만 JSON 한 줄로 출력한다.

사용: sse-only.py <base url> <token> <agents 파일> <agents JSON> <sid> <timeout 초> [bg]
bg를 주면 숨은 탭처럼 /events?bg=1로 붙는다 — 그 연결은 백그라운드 갱신을 살리지 않아야 한다(pushed=false).
"""
import http.client, json, sys, threading, time
from urllib.parse import urlparse

BASE, TOKEN, AGENTS, BODY, SID, TIMEOUT = sys.argv[1:7]
BG = "&bg=1" if sys.argv[7:8] == ["bg"] else ""
u = urlparse(BASE)
found = {}


def sse():
    c = http.client.HTTPConnection(u.hostname, u.port, timeout=float(TIMEOUT) + 10)
    c.request("GET", f"/events?t={TOKEN}{BG}")
    r = c.getresponse()
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
            if name == "hello":
                found["hello"] = time.time()
            elif name == "item":
                it = json.loads("".join(data))
                if it.get("sid") == SID:
                    found.setdefault("item", time.time())
            name, data = None, []


threading.Thread(target=sse, daemon=True).start()
end = time.time() + 10
while "hello" not in found and time.time() < end:
    time.sleep(0.05)
time.sleep(0.5)
with open(AGENTS, "w") as f:  # 다른 터미널에서 새 세션이 생김
    f.write(BODY)
changed = time.time()
end = changed + float(TIMEOUT)
while "item" not in found and time.time() < end:
    time.sleep(0.05)
print(json.dumps({"hello": "hello" in found, "pushed": "item" in found,
                  "after": round(found["item"] - changed, 2) if "item" in found else None}))
