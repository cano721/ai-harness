#!/usr/bin/env bash
# 회귀 테스트 — Harness Board 상주 세션 단위 검사(Feed·안전장치·다시 띄우기 규칙)와 Python 3.9 호환
# 실행: bash tests/run.sh board-resident-unit
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# 상주 세션 모듈(scripts/board/resident.py)을 보드 서버 없이 직접 불러 확인한다. 가짜 claude는 tests/fixtures/board-resident.
BR_T="$TEST_TMP/board-resident"
chmod +x "$ROOT/tests/fixtures/board-resident/claude"
# Feed는 상태를 직접 모으지 않고 캐시만 비교한다(모으기는 #351 백그라운드 갱신이 하고 poke로 알린다).
# poke가 오면 바로, 없어도 interval마다 바뀐 항목을 민다. 넘친 구독자는 끊김 표시를 받는다.
python3 -I -B -c '
import sys, time, queue
sys.path.insert(0, sys.argv[1])
import resident as r
hub = r.Hub(); q = hub.subscribe()
cache = {"n": 0}
feed = r.Feed(hub, lambda: {"items": [{"id": "a", "n": cache["n"]}]}, interval=0.5)
feed.ensure_running(); feed.prime()
cache["n"] = 1; t = time.time(); feed.poke()
ev = q.get(timeout=2)
assert ev == ("item", {"id": "a", "n": 1}) and time.time() - t < 0.3, ev  # 캐시를 새로 쓴 쪽이 알리면 바로
cache["n"] = 2
ev = q.get(timeout=2)
assert ev == ("item", {"id": "a", "n": 2}), ev  # 알림이 없어도 interval 안에 비교한다
try:
    q.get(timeout=0.8); raise SystemExit("no change, no event")
except queue.Empty:
    pass
small = r.Hub(); sq = small.subscribe()
for n in range(600):
    small.publish("item", {"n": n})
assert getattr(sq, "dead", False) and small.count() == 0  # 넘친 구독자는 떼어 내고 끊김을 표시한다
' "$ROOT/scripts/board" || fail "the feed pushes changed cache items on a poke or within its interval and drops an overflowing subscriber"
pass "the resident feed pushes changed cache items on a poke or within its interval and drops an overflowing subscriber"

# 상주 세션 관리의 안전장치: 이상한 줄 하나로 읽기 스레드가 죽지 않고, 동시에 쥐는 수에 상한이 있고, 오래 끝난 기록은 빠지고,
# 보드가 SIGKILL로 죽어 이전 claude가 남아 있으면 같은 id로 다시 띄우지 않고, 꺼질 때는 도구 하위 프로세스까지 끝낸다.
BRU_T="$BR_T/unit"
mkdir -p "$BRU_T/board" "$BRU_T/cwd"
python3 -I -B -c '
import json, os, signal, subprocess, sys, time
sys.path.insert(0, sys.argv[1])
import resident as r
stub, data, cwd = sys.argv[2], sys.argv[3], sys.argv[4]
res = r.Residents(data, lambda: None, claude_bin=stub)

class Fake:
    def __init__(self, lines): self.stdout, self.pid = lines, 0
    def wait(self): return 0
    def poll(self): return 0
s = r.Session("11111111-1111-4111-8111-111111111111", cwd, None, "t")
fake = Fake([json.dumps({"type": "control_request", "request_id": "x", "request": "not a dict"}) + "\n",
             json.dumps({"type": "assistant", "message": {"content": [{"type": "text", "text": "after"}]}}) + "\n"])
s.proc = fake
res._read(s, fake)
assert s.last_text == "after" and s.state == "ended", (s.last_text, s.state)  # 이상한 줄 뒤에도 계속 읽는다

r.MAX_LIVE = 1
one = res.start(cwd, "hello", "one")
two = res.start(cwd, "hello", "two")
assert one["ok"] and not two["ok"] and "1개" in two["message"], (one, two)  # 상한을 넘으면 친절히 거절
res.end(one["id"])
time.sleep(0.5)
import threading
r.MAX_LIVE = 2
got = []
ts = [threading.Thread(target=lambda: got.append(res.start(cwd, "race", None))) for _ in range(6)]
[t.start() for t in ts]; [t.join() for t in ts]
assert sum(1 for x in got if x["ok"]) == 2, got  # 동시에 온 새 세션 요청도 상한을 넘지 않는다
res.shutdown(grace=1)
r.MAX_LIVE = 8

old = "22222222-2222-4222-8222-222222222222"; recent = "33333333-3333-4333-8333-333333333333"
sleeper = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)", recent])
reg = {old: {"cwd": cwd, "title": "old", "at": "2020-01-01T00:00:00Z", "pid": None},
       recent: {"cwd": cwd, "title": "recent", "at": r.utc(), "pid": sleeper.pid}}
data2 = os.path.join(data, "again")  # 앞 인스턴스의 읽기 스레드가 늦게 _save해도 덮지 않게 따로 둔다
os.makedirs(os.path.join(data2, "board"), exist_ok=True)
with open(os.path.join(data2, "board", "residents.json"), "w") as f:
    json.dump(reg, f)
again = r.Residents(data2, lambda: None, claude_bin=stub)
again._save()
kept = json.load(open(os.path.join(data2, "board", "residents.json")))
assert old not in kept and recent in kept and kept[recent]["pid"] == sleeper.pid, kept  # 오래 끝난 기록은 빠지고 pid는 남는다
busy = again.send("res|" + recent, "continue")
assert not busy["ok"] and str(sleeper.pid) in busy["message"], busy  # 이전 프로세스가 살아 있으면 같은 id로 다시 띄우지 않는다
sleeper.kill(); sleeper.wait()
ok = again.send("res|" + recent, "continue")
assert ok["ok"], ok
again.shutdown(grace=1)

group = subprocess.Popen(["bash", "-c", "sleep 30 & wait"], stdin=subprocess.PIPE, start_new_session=True)
g = r.Session("44444444-4444-4444-8444-444444444444", cwd, None, "g"); g.proc = group; g.state = "busy"
again._sessions[g.sid] = g
again.shutdown(grace=0.3)
group.wait(timeout=5)  # 그룹 리더를 거둔다(macOS는 거두지 않은 리더가 있으면 killpg 확인이 EPERM)
time.sleep(0.5)
try:
    os.killpg(group.pid, 0); raise SystemExit("tool child survived the board shutdown")
except ProcessLookupError:
    pass
' "$ROOT/scripts/board" "$ROOT/tests/fixtures/board-resident/claude" "$BRU_T" "$BRU_T/cwd" \
  || fail "resident sessions survive a bad line, cap live sessions, drop old records, refuse a second process and end tool children"
pass "resident sessions survive a bad line, cap live sessions, drop old records, refuse a second process and end tool children"

# 다시 띄우기 규칙(단위): 사람이 끝낸 것·KEEP_HOURS 넘은 것·이전 프로세스가 살아 있는 것은 안 띄우고, MAX_LIVE 안에서 최근 것부터.
python3 -I -B -c '
import json, os, subprocess, sys, time
sys.path.insert(0, sys.argv[1])
import resident as r
stub, data, cwd = sys.argv[2], sys.argv[3], sys.argv[4]
ids = ["5555555%d-5555-4555-8555-555555555555" % n for n in range(6)]
sleeper = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)", ids[2]])
now = r.utc()
reg = {ids[0]: {"cwd": cwd, "title": "closed", "at": now, "pid": None, "closed": True},
       ids[1]: {"cwd": cwd, "title": "old", "at": "2020-01-01T00:00:00Z", "pid": None},
       ids[2]: {"cwd": cwd, "title": "alive", "at": now, "pid": sleeper.pid, "closed": False},
       ids[3]: {"cwd": cwd, "title": "older open", "at": "2099-01-01T00:00:00Z", "pid": None, "state": "busy", "closed": False},
       ids[4]: {"cwd": cwd, "title": "newest open", "at": "2099-01-02T00:00:00Z", "pid": None, "state": "waiting", "closed": False},
       ids[5]: {"cwd": cwd, "title": "legacy record without closed", "at": "2099-01-03T00:00:00Z", "pid": None},
       "--help": {"cwd": cwd, "title": "not a session id", "at": "2099-01-04T00:00:00Z", "pid": None, "closed": False}}
d = os.path.join(data, "resume")
os.makedirs(os.path.join(d, "board"), exist_ok=True)
with open(os.path.join(d, "board", "residents.json"), "w") as f:
    json.dump(reg, f)
r.MAX_LIVE = 1
res = r.Residents(d, lambda: None, claude_bin=stub)
started = res.resume_all(wait=0.5)
assert started == [ids[4]], started  # 상한 1 → 가장 최근 것 하나만(#364 이전 기록은 사람이 끝냈는지 몰라 빼고)
it = res.item("res|" + ids[4])
assert it["live"] and it["interrupted"] and it["status"] == "idle", it
assert not res.item("res|" + ids[2])["live"]  # 이전 프로세스가 살아 있으면 두 프로세스가 같은 대화를 쓰지 않게 건너뛴다
assert "--help" not in res._sessions  # UUID가 아닌 id는 기록에서 읽지 않는다(--resume 인자로 넘기지 않게)
res.shutdown(grace=1)  # 호스트 SIGTERM 경로: 사람이 끝낸 것이 아니므로 다음 호스트가 다시 쥔다
kept = json.load(open(os.path.join(d, "board", "residents.json")))
assert kept[ids[4]]["closed"] is False, kept[ids[4]]
sleeper.kill(); sleeper.wait()
' "$ROOT/scripts/board" "$ROOT/tests/fixtures/board-resident/claude" "$BRU_T" "$BRU_T/cwd" \
  || fail "resume on host start skips ended, old and still-running sessions and stays within MAX_LIVE"
# 보드는 macOS CommandLineTools의 Python 3.9로도 뜬다 — 3.10+ 문법(match, 괄호 with 등)을 쓰지 않는다.
python3 -I -c '
import ast, glob, sys
for p in sorted(glob.glob(sys.argv[1] + "/*.py")):
    ast.parse(open(p, encoding="utf-8").read(), p, feature_version=(3, 9))
' "$ROOT/scripts/board" || fail "board python stays Python 3.9 compatible"
assert_contains "$(<"$ROOT/skills/board/SKILL.md")" "세션을 쥔 동안만 사는 호스트" "the board skill describes the host that lives only while it holds sessions"
assert_contains "$(<"$ROOT/skills/board/SKILL.md")" "board.sh host-stop" "the board skill tells how to stop the resident host"
pass "resume on host start stays within MAX_LIVE, board python stays 3.9 compatible, and the skill describes the host"

finish_tests
