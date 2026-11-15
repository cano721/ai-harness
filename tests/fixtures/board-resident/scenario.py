#!/usr/bin/env python3
"""보드 상주 세션 시나리오(#349): SSE(GET /events)를 연 채로 '새 세션'을 띄우고, 가짜 claude가 묻는 권한·질문을
보드 화면처럼 받아 사람이 누른 것처럼 답한다. 관찰한 사실만 JSON 한 줄로 출력하고 판정은 tests/run.sh가 한다.

사용: scenario.py <base url> <token> <cwd> <stub log>
"""
import json, queue, sys, threading, time, urllib.request
from urllib.parse import urlparse
import http.client

BASE, TOKEN, CWD, STUB_LOG = sys.argv[1:5]
u = urlparse(BASE)
events = queue.Queue()
report = {}


def sse():
    conn = http.client.HTTPConnection(u.hostname, u.port, timeout=30)
    conn.request("GET", f"/events?t={TOKEN}")
    r = conn.getresponse()
    report["sse_status"] = r.status
    report["sse_type"] = r.getheader("Content-Type", "")
    name, data = None, []
    while True:
        line = r.readline()
        if not line:
            events.put(("closed", None, time.time()))
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


def post(path, body):
    req = urllib.request.Request(BASE + path, data=json.dumps({"t": TOKEN, **body}).encode(), method="POST",
                                 headers={"Origin": BASE, "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.loads(r.read())


def get(path):
    with urllib.request.urlopen(BASE + path, timeout=20) as r:
        return json.loads(r.read())


def wait_item(pred, timeout=8):
    end = time.time() + timeout
    while time.time() < end:
        try:
            name, data, at = events.get(timeout=max(0.05, end - time.time()))
        except queue.Empty:
            break
        if name == "item" and pred(data):
            return data, at
    return None, None


def stub():
    with open(STUB_LOG) as f:
        return [json.loads(l) for l in f if l.strip()]


def wait_stub(pred, timeout=5):
    end = time.time() + timeout
    while time.time() < end:
        hit = [e for e in stub() if pred(e)]
        if hit:
            return hit
        time.sleep(0.05)
    return []


threading.Thread(target=sse, daemon=True).start()
name, _, _ = events.get(timeout=10)
report["sse_first_event"] = name

res = post("/new", {"cwd": CWD, "prompt": "PERM first", "name": "resident test"})
report["new_ok"] = res.get("ok")
rid = res.get("id")
report["new_id"] = rid
item, got = wait_item(lambda i: i.get("id") == rid and i.get("permission"))
report["perm_pushed"] = bool(item)
if item:
    emitted = [e for e in stub() if e.get("emitted") == "Bash"][0]["at"]
    report["perm_latency"] = round(got - emitted, 3)
    report["perm_tool"] = item["permission"]["tool"]
    report["item_kind"] = item.get("kind")
    report["item_state"] = item.get("state")
time.sleep(1.2)
report["auto_answered"] = any("control_response" == (e.get("stdin") or {}).get("type") for e in stub())
polled = get(f"/status.json?t={TOKEN}")
report["polled_perm"] = any(i.get("id") == rid and i.get("permission") for i in polled.get("items", []))
if item:
    report["allow"] = post("/permission", {"pid": item["permission"]["pid"], "decision": "allow"}).get("ok")
    hit = wait_stub(lambda e: (e.get("stdin") or {}).get("type") == "control_response")
    report["allow_behavior"] = hit[0]["stdin"]["response"]["response"]["behavior"] if hit else None
    report["allow_same_request"] = bool(hit) and hit[0]["stdin"]["response"]["request_id"] == \
        [e for e in stub() if e.get("emitted") == "Bash"][0]["request_id"]
    idle, _ = wait_item(lambda i: i.get("id") == rid and i.get("state") == "review")
    report["idle_after_turn"] = bool(idle)

report["send"] = post("/action", {"id": rid, "action": "send", "text": "ASK next"}).get("ok")
q, _ = wait_item(lambda i: i.get("id") == rid and i.get("question"))
report["question_pushed"] = bool(q)
if q:
    report["question_text"] = q["question"]["questions"][0]["question"]
    tr = get(f"/transcript?t={TOKEN}&id={urllib.request.quote(rid)}&offset=0")
    report["transcript_question"] = bool(tr.get("question"))
    report["answer"] = post("/answer", {"id": rid, "pid": q["question"]["pid"], "answers": {"Pick a color": "red"}}).get("ok")
    hit = wait_stub(lambda e: (e.get("stdin") or {}).get("type") == "control_response"
                    and "answers" in json.dumps(e["stdin"]))
    report["answers_sent"] = hit[0]["stdin"]["response"]["response"]["updatedInput"]["answers"] if hit else None
    wait_item(lambda i: i.get("id") == rid and i.get("state") == "review")
report["bad_answer"] = post("/answer", {"id": rid, "pid": "nope", "answers": {}}).get("ok")

log = stub()
launches = [e["argv"] for e in log if "argv" in e]
report["launches"] = len(launches)
report["resume_used"] = any("--resume" in a for a in launches)
report["stdin_users"] = len([e for e in log if (e.get("stdin") or {}).get("type") == "user"])
report["permission_tool_stdio"] = bool(launches) and "--permission-prompt-tool" in launches[0] \
    and launches[0][launches[0].index("--permission-prompt-tool") + 1] == "stdio"
sid = launches[0][launches[0].index("--session-id") + 1] if launches and "--session-id" in launches[0] else None
report["id_has_sid"] = bool(sid) and rid == "res|" + sid

report["end"] = post("/action", {"id": rid, "action": "end"}).get("ok")
ended, _ = wait_item(lambda i: i.get("id") == rid and not i.get("live"))
report["ended_cmd"] = (ended or {}).get("cmd")
report["send_after_end"] = post("/action", {"id": rid, "action": "send", "text": "again"}).get("ok")
wait_stub(lambda e: (e.get("stdin") or {}).get("type") == "user" and "again" in json.dumps(e["stdin"]))
launches = [e["argv"] for e in stub() if "argv" in e]
report["relaunch_resume_sid"] = len(launches) == 2 and "--resume" in launches[1] and launches[1][launches[1].index("--resume") + 1] == sid
back, _ = wait_item(lambda i: i.get("id") == rid and i.get("live"))
report["same_id_after_resume"] = bool(back)
print(json.dumps(report, ensure_ascii=False))
