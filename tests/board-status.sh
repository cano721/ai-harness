#!/usr/bin/env bash
# 회귀 테스트 — 보드 status.sh·work.sh·정리 동작·화면 문구
# 실행: bash tests/run.sh board-status
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# 정리 중 되살아남 방지(#296): 숨긴 세션은 '숨긴 뒤 새 활동'이 있을 때만 다시 보인다. 닫는 중이라 아직 살아 있는 세션이 되살아나면 안 된다.
BH_DATA="$TEST_TMP/board-hidden-data"
mkdir -p "$BH_DATA/board"
jq -cn '{"s-old": {at: "2026-11-10T00:00:00Z", title: "a"}, "s-new": {at: "2026-11-10T00:00:00Z", title: "b"},
  "s-legacy-old": "2026-11-10T00:00:00Z", "s-legacy-new": "2026-11-10T00:00:00Z", "s-ended": {at: "2026-11-10T00:00:00Z"}}' >"$BH_DATA/board/hidden.json"
HARNESS_METRICS_DIR="$BH_DATA" python3 -I -B -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("bs", sys.argv[1]); bs = importlib.util.module_from_spec(spec); spec.loader.exec_module(bs)
base = {"section": "work", "kind": "bg", "state": "done", "status": "idle", "live": True, "cwd": "/nope", "project": "shop", "actions": []}
mk = lambda sid, at, **k: dict(base, sid=sid, id="claude|" + sid, short_id=sid, title=sid, at=at, **k)
items = [mk("s-old", "2026-11-09T00:00:00Z"), mk("s-new", "2026-11-11T00:00:00Z"),
         mk("s-legacy-old", "2026-11-09T00:00:00Z"), mk("s-legacy-new", "2026-11-11T00:00:00Z"),
         mk("s-ended", "2026-11-11T00:00:00Z", live=False)]
before = bs._load(bs.HIDDEN)
shown = {i["sid"] for i in bs.classify_work(items)}
assert shown == {"s-new", "s-legacy-new"}, shown  # 살아 있어도 숨긴 뒤 새 활동이 없으면 숨김 유지, 있으면 다시 보인다(구형 문자열 기록도 같은 규칙)
after = bs._load(bs.HIDDEN)
assert set(after) == {"s-old", "s-legacy-old", "s-ended"}, after  # 풀린 것만 hidden에서 빠진다
assert all(after[k] == before[k] for k in after), after  # 남긴 기록은 그대로
' "$ROOT/scripts/board/board-server.py" || fail "a hidden live session stays hidden until it has activity after it was hidden (old string records follow the same rule)"
pass "board keeps a hidden live session hidden until new activity after the cleanup"

# 정리는 세션을 닫기 전에 숨김을 기록한다(닫는 동안 목록에 되살아나지 않게). 닫기가 실패하면 그 숨김만 되돌린다.
BC_DATA="$TEST_TMP/board-cleanup-order"
mkdir -p "$BC_DATA"
HARNESS_METRICS_DIR="$BC_DATA" python3 -I -B -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("bs", sys.argv[1]); bs = importlib.util.module_from_spec(spec); spec.loader.exec_module(bs)
mk = lambda sid: {"section": "work", "sid": sid, "id": "claude|" + sid, "kind": "bg", "short_id": sid, "cwd": "/nope", "title": sid,
                  "project": "shop", "at": "2026-01-01T00:00:00Z", "live": True, "status": "idle", "state": "idle"}
bs.hide_items([dict(mk("keep"), live=False)])
seen = {}
def closing(ok):
    def end(i):
        seen[i["sid"]] = i["sid"] in (bs._load(bs.HIDDEN) or {})  # 닫는 시점에 이미 숨겨져 있는가
        return ok
    return end
bs.end_session = closing(True)
res = bs.cleanup(mk("s-ok"), False)
assert res["ok"] and seen == {"s-ok": True}, (res, seen)
assert {"s-ok", "keep"} <= set(bs._load(bs.HIDDEN)), bs._load(bs.HIDDEN)
bs.end_session = closing(False)
res = bs.cleanup(mk("s-bad"), False)
assert res["ok"] is False and seen["s-bad"] is True, (res, seen)
assert "s-bad" not in bs._load(bs.HIDDEN) and {"s-ok", "keep"} <= set(bs._load(bs.HIDDEN)), bs._load(bs.HIDDEN)  # 실패한 키만 지운다
' "$ROOT/scripts/board/board-server.py" || fail "cleanup records the hiding before it closes the session and takes it back only when closing fails"
pass "board cleanup hides before closing and undoes the hiding when closing fails"

# 정리 속도(#305) A: 항목 조회는 캐시가 아무리 오래됐어도 캐시에서 한다(status.sh 재수집 없이). 캐시에 없을 때만 한 번 수집하고, fresh=True는 예전처럼 다시 모은다.
FI_DATA="$TEST_TMP/board-find-cached"
mkdir -p "$FI_DATA"
HARNESS_METRICS_DIR="$FI_DATA" python3 -I -B -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("bs", sys.argv[1]); bs = importlib.util.module_from_spec(spec); spec.loader.exec_module(bs)
mk = lambda sid: {"section": "work", "sid": sid, "id": "claude|" + sid, "kind": "bg", "short_id": sid, "cwd": "/nope", "title": sid,
                  "project": "shop", "at": "2026-01-01T00:00:00Z", "live": True, "status": "idle", "state": "idle", "actions": ["cleanup"]}
calls = []
def fake_status(*a, **k):
    calls.append(1)
    return {"items": [mk("s-other")]}
bs.status = fake_status
bs._cache["data"] = {"items": [mk("s-cached")]}
bs._cache["at"] = 0  # 아주 오래된 캐시
got = bs.find_item("claude|s-cached")
assert got and got["id"] == "claude|s-cached" and calls == [], (got, calls)  # 캐시에서 찾고 수집하지 않는다
got = bs.find_item("claude|s-other")
assert got and got["id"] == "claude|s-other" and len(calls) == 1, (got, calls)  # 캐시에 없으면 한 번 수집
calls.clear()
bs._cache["data"] = {"items": [mk("s-cached")]}
bs.find_item("claude|s-cached", fresh=True)
assert len(calls) == 1, calls  # fresh는 다시 모은다
' "$ROOT/scripts/board/board-server.py" || fail "find_item answers from the cache however old it is and recollects only when the id is missing or fresh is asked"
pass "board find_item uses the cached list without recollecting status"

# 상태 갱신 가속(#348): /status.json은 캐시만 읽는다. 캐시가 조금 오래됐으면 갱신 중인 lock을 기다리지 않고 캐시를 돌려주며
# 백그라운드 갱신을 깨운다. 캐시가 없거나(동작 뒤 비움) 아주 오래됐으면 그 자리에서 모은다. 백그라운드 갱신은 보는 사람이 있을 때만 돈다.
SR_DATA="$TEST_TMP/board-status-refresh"
mkdir -p "$SR_DATA"
HARNESS_METRICS_DIR="$SR_DATA" python3 -I -B -c '
import importlib.util, sys, time
spec = importlib.util.spec_from_file_location("bs", sys.argv[1]); bs = importlib.util.module_from_spec(spec); spec.loader.exec_module(bs)
calls = []
def fake_build(cached=False):
    calls.append(1)
    return {"items": [{"id": "n%d" % len(calls)}]}
bs._build = fake_build
d = bs.status()
assert d["items"][0]["id"] == "n1" and len(calls) == 1, calls  # 캐시가 없으면 그 자리에서 모은다
assert bs.status() is d and len(calls) == 1, calls  # 갓 모은 캐시는 그대로
bs._cache["at"] = time.time() - 10
bs._wake.clear()
with bs._lock:  # 다른 갱신이 lock을 쥐고 있어도
    t0 = time.time(); got = bs.status(); took = time.time() - t0
assert got is d and took < 0.5 and len(calls) == 1, (took, calls)  # 기다리지 않고 캐시를 돌려준다
assert bs._wake.is_set()  # 백그라운드 갱신을 깨운다
bs._cache["at"] = time.time() - bs.STALE_SYNC - 1
assert bs.status()["items"][0]["id"] == "n2", calls  # 아주 오래된 캐시는 그 자리에서 새로 모은다
bs._cache["data"] = None
assert bs.status()["items"][0]["id"] == "n3", calls  # 동작 뒤 비운 캐시도 그 자리에서
bs._cache["at"] = time.time() - 10
bs.refresh_once()
assert len(calls) == 3, calls  # 막 켜져 아직 아무도 안 봤으면 백그라운드 갱신은 쉰다
bs._active["at"] = time.time()
bs.refresh_once()
assert len(calls) == 4, calls  # 보는 사람이 있으면 백그라운드에서 모은다
bs.refresh_once()
assert len(calls) == 4, calls  # 방금 모았으면 다시 모으지 않는다
bs._active["at"] = time.time() - bs.REFRESH_IDLE - 1; bs._cache["at"] = time.time() - 10
bs.refresh_once()
assert len(calls) == 4, calls  # 보는 사람이 없으면 쉰다
# 모으는 사이에 동작이 캐시를 비우면(답 보내기·정리), 그 수집 결과는 동작 전 상태라 그대로 내보내지 않는다:
# 다음 읽기(동작 쪽 find_item(fresh=True) 포함)가 그 자리에서 다시 모은다.
def build_then_invalidate(cached=False):
    calls.append(1)
    bs._cache["data"] = None  # 수집 도중 동작이 비움
    return {"items": [{"id": "before-action"}]}
bs._build = build_then_invalidate
bs._collect(0)
bs._build = fake_build
assert bs.status()["items"][0]["id"] == "n%d" % len(calls), calls  # 동작 전 결과가 아니라 새로 모은 결과
bs._cache["data"] = None  # 이미 비어 있던 캐시를 모으는 사이에 다른 동작이 또 비워도 같다
bs._build = build_then_invalidate
bs._collect(3)
bs._build = fake_build
assert bs.status()["items"][0]["id"] == "n%d" % len(calls), calls
# 보는 사람 표시는 mark_active() 하나로 한다(폴링 말고 다른 연결도 같은 함수로 갱신을 살린다).
bs._active["at"] = 0.0
bs.mark_active()
assert time.time() - bs._active["at"] < 1, bs._active
# 백그라운드 수집이 계속 실패하면 0.5초마다 다시 돌리지 않고 최대 5초까지 늦춘다. 성공하면 원래 주기로.
def broken_build(cached=False):
    calls.append(1)
    raise RuntimeError("status.sh failed")
bs._build = broken_build
waits = []
for _ in range(6):
    bs._cache["at"] = 0.0
    bs._timing["dur"] = 0  # 직전 수집의 쉬는 시간(#380)과 상관없이 실패 백오프만 본다
    bs.refresh_once()
    waits.append(bs.refresh_wait())
assert waits[0] >= 1 and waits == sorted(waits) and waits[-1] == 5, waits
bs._build = fake_build
bs.refresh_once()
assert bs.refresh_wait() <= bs.REFRESH, bs.refresh_wait()
bs.worktree_candidates = lambda items: []  # 개발 머신의 실제 Orca·git worktree를 읽지 않게
# 일괄 정리는 30초 안의 캐시라도 믿지 않고 그 자리에서 새로 모은 목록으로 한다(그새 다시 일하는 세션을 닫지 않게). 미리보기는 캐시로.
bs._cache["data"] = {"items": []}; bs._cache["at"] = time.time() - 10
n = len(calls)
bs.bulk_cleanup({"dry_run": True})
assert len(calls) == n, calls  # 미리보기는 캐시
bs.bulk_cleanup({"older_days": 1})
assert len(calls) == n + 1, calls  # 실제 정리는 새로 모은다
' "$ROOT/scripts/board/board-server.py" || fail "status() serves the cache without waiting for a refresh and refreshes in the background only while someone is watching"
BOARD_REFRESH_SECONDS=abc HARNESS_METRICS_DIR="$SR_DATA" python3 -I -B -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("bs", sys.argv[1]); bs = importlib.util.module_from_spec(spec); spec.loader.exec_module(bs)
assert bs.REFRESH == 2.0, bs.REFRESH
' "$ROOT/scripts/board/board-server.py" || fail "a BOARD_REFRESH_SECONDS that is not a positive number falls back to two seconds instead of stopping the server"
assert_contains "$(<"$ROOT/scripts/board/template.html")" "(document.hidden ? '&bg=1' : '')" "a hidden board tab marks its polls so they keep the viewer alive without driving the background refresh"
assert_contains "$(<"$ROOT/scripts/board/board-server.py")" "threading.Thread(target=refresher, daemon=True).start()" "the board server starts the background refresher"
assert_contains "$(<"$ROOT/scripts/board/template.html")" "setInterval(() => { if (!sseLive()) refresh().catch(() => {}); }, 1000)" "the board polls the cached status every second while server events are down"
pass "board status reads the cache and refreshes it in the background"

# 정리 속도(#305) B: 정리는 캐시 항목을 쓰되 닫기 직전에 claude agents로 세션을 다시 확인한다. 그 사이 일을 시작했으면 정리하지 않고, 확인하지 못하면 멈춘다.
AI_T="$TEST_TMP/board-action-item"
mkdir -p "$AI_T/bin" "$AI_T/data" "$AI_T/cwd"
cat >"$AI_T/bin/claude" <<'FAKE'
#!/usr/bin/env bash
[[ "$1" == agents ]] || exit 0
[[ -f "$FAKE_AGENTS_FILE.exit1" ]] && exit 1
cat "$FAKE_AGENTS_FILE"
FAKE
chmod +x "$AI_T/bin/claude"
HARNESS_METRICS_DIR="$AI_T/data" FAKE_AGENTS_FILE="$AI_T/agents.json" python3 -I -B -c '
import importlib.util, json, os, sys
spec = importlib.util.spec_from_file_location("bs", sys.argv[1]); bs = importlib.util.module_from_spec(spec); spec.loader.exec_module(bs)
bin_dir, cwd, agents_file = sys.argv[2], sys.argv[3], os.environ["FAKE_AGENTS_FILE"]
os.environ["PATH"] = bin_dir + os.pathsep + os.environ["PATH"]
mk = lambda sid, **k: dict({"section": "work", "sid": sid, "id": "claude|" + sid, "kind": "bg", "short_id": sid[:8], "cwd": cwd, "title": sid,
                            "project": "shop", "at": "2026-01-01T00:00:00Z", "live": True, "status": "idle", "state": "idle", "actions": ["cleanup", "send"]}, **k)
def agents(*rows):
    with open(agents_file, "w") as f:
        f.write(rows[0] if rows and isinstance(rows[0], str) else json.dumps(list(rows)))
ag = lambda sid, status, pid=100, **k: dict({"sessionId": sid, "id": sid[:8], "kind": "background", "status": status, "pid": pid, "cwd": cwd, "name": "n-" + sid}, **k)
st_calls = []
def fake_status(*a, **k):
    st_calls.append(1)
    return {"items": [mk("s-send")]}
bs.status = fake_status
def prime(*items):
    bs._cache["data"] = {"items": list(items)}
    bs._cache["at"] = 0
ended = []
bs.end_session = lambda i: ended.append(i["sid"]) or True

# 캐시에는 쉬는 세션인데 지금은 작업 중 -> 정리하지 않는다
prime(mk("s-busy"))
agents(ag("s-busy", "busy"), ag("s-peer", "idle", cwd="/x/wt", name="peer task"), ag("s-dead", "idle", pid=None, cwd="/x/dead"))
item, err = bs.action_item("claude|s-busy", "cleanup")
assert err is None and item is not None and st_calls == [], (item, err, st_calls)
assert item["live"] is True and item["status"] == "busy" and item["state"] == "running" and not bs.can_close(item), item
assert [o["cwd"] for o in item["_live_others"]] == ["/x/wt"], item.get("_live_others")  # 다른 살아 있는 세션만(pid 없는 것·자기 자신 제외)
res = bs.cleanup(item, False)
assert res["ok"] is False and ended == [], (res, ended)
assert bs._cache["data"]["items"][0]["status"] == "idle", "the cached item itself is not modified"  # 돌려주는 것은 복사본

# 지금은 응답·권한을 기다림 -> needs_human
prime(mk("s-wait"))
agents(ag("s-wait", "waiting"))
item, err = bs.action_item("claude|s-wait", "cleanup")
assert err is None and item["state"] == "needs_human" and not bs.can_close(item), (item, err)

# 그대로 쉬는 중 -> 정리할 수 있다
prime(mk("s-idle"))
agents(ag("s-idle", "idle"))
item, err = bs.action_item("claude|s-idle", "cleanup")
assert err is None and item["live"] is True and bs.can_close(item), (item, err)
assert bs.cleanup(item, False)["ok"] is True and ended == ["s-idle"], ended

# 목록에 없거나 pid가 없음 -> 이미 끝난 세션
for rows in ([ag("s-gone2", "idle")], [ag("s-gone", "idle", pid=None)]):
    prime(mk("s-gone"))
    agents(*rows)
    item, err = bs.action_item("claude|s-gone", "cleanup")
    assert err is None and item["live"] is False, (item, err)

# 확인하지 못하면(claude 실패·이상한 출력) 정리하지 않는다
prime(mk("s-fail"))
agents("not json at all")
item, err = bs.action_item("claude|s-fail", "cleanup")
assert item is None and "확인하지 못함" in err, (item, err)
agents(ag("s-fail", "idle"))
open(agents_file + ".exit1", "w").close()
item, err = bs.action_item("claude|s-fail", "cleanup")
assert item is None and "확인하지 못함" in err, (item, err)
os.remove(agents_file + ".exit1")

# 세션이 아닌 항목(sid 없음)은 다시 확인하지 않는다
prime({"section": "harvest", "id": "harvest|p1", "kind": "harvest", "title": "p1", "project": "p1", "actions": ["cleanup"]})
open(agents_file + ".exit1", "w").close()
item, err = bs.action_item("harvest|p1", "cleanup")
assert err is None and item["id"] == "harvest|p1", (item, err)
os.remove(agents_file + ".exit1")

# 정리가 아닌 작업은 예전처럼 다시 수집한다
del st_calls[:]
bs._cache["data"] = {"items": [mk("s-stale")]}
item, err = bs.action_item("claude|s-send", "send")
assert err is None and item["id"] == "claude|s-send" and len(st_calls) == 1, (item, err, st_calls)

# 모르는 id
prime(mk("s-known"))
del st_calls[:]
bs.status = lambda *a, **k: st_calls.append(1) or {"items": []}
item, err = bs.action_item("claude|nope", "cleanup")
assert item is None and err, (item, err)
' "$ROOT/scripts/board/board-server.py" "$AI_T/bin" "$AI_T/cwd" || fail "action_item re-checks the session right before cleanup (busy, waiting, gone, unreadable) and recollects for other actions"
pass "board action_item re-checks a session's live state before cleanup and refuses when it cannot"

# 정리 속도(#305) C: 이 보드가 닫기 직전에 확인한 다른 살아 있는 세션(_live_others)도 worktree 사용 중으로 본다(캐시가 비어 있어도).
WL_T="$(mkdir -p "$TEST_TMP/board-wt-live" && cd "$TEST_TMP/board-wt-live" && pwd -P)"
git init -q --bare "$WL_T/remote.git"
git init -q -b main "$WL_T/repo"
git -C "$WL_T/repo" config user.email test@example.com
git -C "$WL_T/repo" config user.name tester
git -C "$WL_T/repo" config commit.gpgsign false
git -C "$WL_T/repo" commit -q --allow-empty -m init
git -C "$WL_T/repo" remote add origin "$WL_T/remote.git"
git -C "$WL_T/repo" push -q origin main
git -C "$WL_T/repo" worktree add -q -b feat/example "$WL_T/wt"
git -C "$WL_T/wt" push -q -u origin feat/example
mkdir -p "$WL_T/data"
HARNESS_METRICS_DIR="$WL_T/data" python3 -I -B -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("bs", sys.argv[1]); bs = importlib.util.module_from_spec(spec); spec.loader.exec_module(bs)
wt = sys.argv[2]
# 이 블록은 세션 점유 판정만 확인한다. 병합 여부는 독립 조건이므로 여기서는 병합 확인을 고정한다.
bs._merged_pr_state = lambda path, branch: (True, "")
bs._cache["data"] = None
item = {"section": "work", "sid": "s-mine", "id": "claude|s-mine", "kind": "bg", "cwd": wt, "title": "mine", "live": True, "status": "idle", "state": "idle"}
base = bs.worktree_check(item)
assert base["removable"] is True, base  # 다른 세션이 없으면 지울 수 있다
outside = bs.worktree_check(dict(item, _live_others=[{"cwd": "/somewhere/else", "title": "far"}]))
assert outside["removable"] is True, outside
inside = bs.worktree_check(dict(item, _live_others=[{"cwd": wt + "/sub", "title": "other"}]))
assert inside["removable"] is False and "세션" in inside["reason"] and "other" in inside["reason"], inside
' "$ROOT/scripts/board/board-server.py" "$WL_T/wt" || fail "worktree_check counts the live sessions found right before cleanup (_live_others) as users of the folder"
pass "board worktree_check refuses a worktree another live session found at cleanup time still uses"

# 정리 직전 확인은 설정 폴더가 여럿이어도 모든 폴더를 본다(#305): 다른 폴더에서 같은 worktree를 쓰는 세션도 막고, 다른 폴더를 확인하지 못하면 worktree는 지우지 않는다.
AO_T="$(mkdir -p "$TEST_TMP/board-action-folders" && cd "$TEST_TMP/board-action-folders" && pwd -P)"
mkdir -p "$AO_T/bin" "$AO_T/data" "$AO_T/lists"
git init -q --bare "$AO_T/remote.git"
git init -q -b main "$AO_T/repo"
git -C "$AO_T/repo" config user.email test@example.com
git -C "$AO_T/repo" config user.name tester
git -C "$AO_T/repo" config commit.gpgsign false
git -C "$AO_T/repo" commit -q --allow-empty -m init
git -C "$AO_T/repo" remote add origin "$AO_T/remote.git"
git -C "$AO_T/repo" push -q origin main
git -C "$AO_T/repo" worktree add -q -b feat/example "$AO_T/wt"
git -C "$AO_T/wt" push -q -u origin feat/example
cat >"$AO_T/bin/claude" <<'FAKE'
#!/usr/bin/env bash
cfg="${CLAUDE_CONFIG_DIR-UNSET}"
printf '%s\n' "$cfg" >>"$FAKE_CLAUDE_CALLS"
[[ "$1" == agents ]] || exit 0
f="$FAKE_LISTS/agents-$(printf '%s' "$cfg" | tr '/' '_').json"
[[ -f "$f.exit1" ]] && exit 1
cat "$f" 2>/dev/null || echo '[]'
FAKE
chmod +x "$AO_T/bin/claude"
HARNESS_METRICS_DIR="$AO_T/data" FAKE_LISTS="$AO_T/lists" FAKE_CLAUDE_CALLS="$AO_T/calls.log" python3 -I -B -c '
import importlib.util, json, os, sys
spec = importlib.util.spec_from_file_location("bs", sys.argv[1]); bs = importlib.util.module_from_spec(spec); spec.loader.exec_module(bs)
bin_dir, wt, lists, calls_log = sys.argv[2], sys.argv[3], os.environ["FAKE_LISTS"], os.environ["FAKE_CLAUDE_CALLS"]
os.environ["PATH"] = bin_dir + os.pathsep + os.environ["PATH"]
os.environ.pop("CLAUDE_CONFIG_DIR", None)
def lst(cfg, *rows):
    with open(os.path.join(lists, "agents-" + cfg.replace("/", "_") + ".json"), "w") as f:
        json.dump(list(rows), f)
def calls():
    try:
        with open(calls_log) as f:
            got = f.read().split()
    except OSError:
        got = []
    open(calls_log, "w").close()
    return sorted(got)
ag = lambda sid, status, pid, cwd, name: {"sessionId": sid, "id": sid[:8], "kind": "background", "status": status, "pid": pid, "cwd": cwd, "name": name}
mk = lambda sid, cfg: {"section": "work", "sid": sid, "id": "claude|" + sid, "kind": "bg", "short_id": sid, "cwd": wt if sid == "s-a" else "/elsewhere",
                       "title": sid, "project": "shop", "at": "2026-01-01T00:00:00Z", "live": True, "status": "idle", "state": "idle",
                       "config_dir": cfg, "actions": ["cleanup"]}
def prime():
    bs._cache["data"] = {"items": [mk("s-a", "/cfg/a"), mk("s-b", "/cfg/b")]}
    bs._cache["at"] = 0
bs.status = lambda *a, **k: (_ for _ in ()).throw(AssertionError("status must not be recollected for cleanup"))
ended = []
bs.end_session = lambda i: ended.append(i["sid"]) or True
lst("UNSET")
lst("/cfg/a", ag("s-a", "idle", 1, wt, "target"))
lst("/cfg/b", ag("s-a", "busy", 2, wt, "stale copy"), ag("s-peer", "idle", 5, wt + "/sub", "peer"), ag("s-gone", "idle", None, wt, "ended"))
calls()

# 폴더마다 한 번씩(기본 폴더 포함), 자기 상태는 자기 폴더 것을 쓴다. 다른 폴더의 살아 있는 세션이 worktree를 쓰면 지우지 않는다.
prime()
item, err = bs.action_item("claude|s-a", "cleanup")
assert err is None and item is not None, (item, err)
assert calls() == ["/cfg/a", "/cfg/b", "UNSET"], "one agents call per distinct folder of the cached session items, plus the default folder"
assert item["live"] is True and item["status"] == "idle" and bs.can_close(item), item
assert [o["cwd"] for o in item["_live_others"]] == [wt + "/sub"], item["_live_others"]
wc = bs.worktree_check(item)
assert wc["removable"] is False and "세션" in wc["reason"], wc

# 다른 폴더를 확인하지 못하면: 항목은 돌려주되 worktree는 지우지 않고(확인하지 못함), 세션만 정리하는 것은 허용
open(os.path.join(lists, "agents-_cfg_b.json.exit1"), "w").close()
prime()
item, err = bs.action_item("claude|s-a", "cleanup")
assert err is None and item is not None, (item, err)
assert "/cfg/b" in (item.get("_others_unchecked") or []), item.get("_others_unchecked")
wc = bs.worktree_check(item)
assert wc["removable"] is False and "확인하지 못함" in wc["reason"], wc
assert bs.can_close(item) and bs.cleanup(item, False)["ok"] is True and ended == ["s-a"], ended
os.remove(os.path.join(lists, "agents-_cfg_b.json.exit1"))

# 자기 폴더를 확인하지 못하면 정리하지 않는다
open(os.path.join(lists, "agents-_cfg_a.json.exit1"), "w").close()
prime()
item, err = bs.action_item("claude|s-a", "cleanup")
assert item is None and "확인하지 못함" in err, (item, err)
os.remove(os.path.join(lists, "agents-_cfg_a.json.exit1"))
' "$ROOT/scripts/board/board-server.py" "$AO_T/bin" "$AO_T/wt" || fail "action_item checks every settings folder: peers in other folders block the worktree, an unreadable other folder keeps the worktree but not the session cleanup"
pass "board action_item re-checks every settings folder before cleanup"

# 정리 속도(#305) D: background=True 정리는 안전 확인까지만 동기로 하고 숨긴 뒤 바로 돌려준다. 세션 닫기·worktree 삭제는 뒤에서 하고, 실패하면 숨김을 되돌리고 cleanup_failed로 알린다.
BG_DATA="$TEST_TMP/board-cleanup-bg"
mkdir -p "$BG_DATA"
HARNESS_METRICS_DIR="$BG_DATA" python3 -I -B -c '
import importlib.util, sys, threading, time
spec = importlib.util.spec_from_file_location("bs", sys.argv[1]); bs = importlib.util.module_from_spec(spec); spec.loader.exec_module(bs)
mk = lambda sid, **k: dict({"section": "work", "sid": sid, "id": "claude|" + sid, "kind": "bg", "short_id": sid, "cwd": "/nope", "title": "title " + sid,
                            "project": "shop", "at": "2026-01-01T00:00:00Z", "live": True, "status": "idle", "state": "idle"}, **k)
hidden = lambda: set(bs._load(bs.HIDDEN) or {})
bs.status = lambda *a, **k: {"items": []}
def failed_ids():
    return [f["id"] for f in (bs.status_with_permissions().get("cleanup_failed") or [])]

# 안전 확인은 동기: 작업 중이면 바로 거절하고 숨기지 않는다
res = bs.cleanup(mk("s-busy", status="busy", state="running"), False, background=True)
assert res["ok"] is False and "s-busy" not in hidden(), (res, hidden())

# 실패 사례: 닫기가 오래 걸려도 바로 돌려주고, 끝내 실패하면 숨김을 되돌리고 알린다
gate, entered = threading.Event(), threading.Event()
def slow_fail(i):
    entered.set()
    gate.wait(10)
    return False
bs.end_session = slow_fail
t0 = time.time()
res = bs.cleanup(mk("s-fail"), False, background=True)
took = time.time() - t0
assert took < 1 and res["ok"] is True and res.get("pending") is True, (took, res)
assert "s-fail" in hidden(), hidden()  # 닫는 동안은 숨겨져 있다
assert entered.wait(5), "the closing runs in the background"
assert "claude|s-fail" not in failed_ids()  # 아직 실패 아님
gate.set()
deadline = time.time() + 5
while time.time() < deadline and "claude|s-fail" not in failed_ids():
    time.sleep(0.05)
assert "claude|s-fail" in failed_ids(), failed_ids()
note = next(f for f in bs.status_with_permissions()["cleanup_failed"] if f["id"] == "claude|s-fail")
assert note["title"] == "title s-fail" and note["message"] and note["at"], note
assert "s-fail" not in hidden(), hidden()  # 숨김을 되돌렸다

# 성공 사례: 실패 알림 없이 숨김 유지
done = threading.Event()
def ok_end(i):
    done.set()
    return True
bs.end_session = ok_end
res = bs.cleanup(mk("s-ok"), False, background=True)
assert res["ok"] is True and res.get("pending") is True, res
assert done.wait(5)
time.sleep(0.5)
assert "claude|s-ok" not in failed_ids() and "s-ok" in hidden(), (failed_ids(), hidden())
' "$ROOT/scripts/board/board-server.py" || fail "background cleanup checks safety first, returns at once after hiding, and reports a failed closing while undoing the hiding"
pass "board background cleanup returns at once and reports a failed closing through cleanup_failed"

# 뒤에서 하는 정리의 기록(#305): 실패로 알린 항목을 같은 항목이 나중에 정리되면 실패 목록에서 지운다. 이미 정리하는 중인 항목은 다시 받지 않는다.
BK_DATA="$TEST_TMP/board-cleanup-bookkeeping"
mkdir -p "$BK_DATA"
HARNESS_METRICS_DIR="$BK_DATA" python3 -I -B -c '
import importlib.util, sys, threading, time
spec = importlib.util.spec_from_file_location("bs", sys.argv[1]); bs = importlib.util.module_from_spec(spec); spec.loader.exec_module(bs)
mk = lambda sid: {"section": "work", "sid": sid, "id": "claude|" + sid, "kind": "bg", "short_id": sid, "cwd": "/nope", "title": "title " + sid,
                  "project": "shop", "at": "2026-01-01T00:00:00Z", "live": True, "status": "idle", "state": "idle"}
bs.status = lambda *a, **k: {"items": []}
failed_ids = lambda: [f["id"] for f in (bs.status_with_permissions().get("cleanup_failed") or [])]
def wait_for(cond, secs=5):
    end = time.time() + secs
    while time.time() < end and not cond():
        time.sleep(0.05)
    return cond()

# (a) 실패로 알린 뒤 같은 항목의 정리가 성공하면 실패 알림이 사라진다
bs.end_session = lambda i: False
assert bs.cleanup(mk("s-x"), False, background=True)["ok"] is True
assert wait_for(lambda: "claude|s-x" in failed_ids()), failed_ids()
bs.end_session = lambda i: True
assert bs.cleanup(mk("s-x"), False, background=True)["ok"] is True
assert wait_for(lambda: "claude|s-x" not in failed_ids()), failed_ids()

# (b) 정리하는 중인 항목은 다시 받지 않고, 끝난 뒤에는 다시 받는다
gate, calls = threading.Event(), []
def blocked_end(i):
    calls.append(i["sid"])
    gate.wait(10)
    return True
bs.end_session = blocked_end
assert bs.cleanup(mk("s-y"), False, background=True)["ok"] is True
assert wait_for(lambda: calls == ["s-y"]), calls
res = bs.cleanup(mk("s-y"), False, background=True)
assert res["ok"] is False and "이미 정리하는 중" in res["message"], res
assert calls == ["s-y"], calls  # 두 번째는 세션을 다시 닫으러 가지 않는다
gate.set()
accepted = []
def again():
    r = bs.cleanup(mk("s-y"), False, background=True)
    if r["ok"]:
        accepted.append(r)
    return bool(accepted)
assert wait_for(again), "a new cleanup of the same item is accepted once the first has finished"
' "$ROOT/scripts/board/board-server.py" || fail "a later successful background cleanup clears the failure notice, and an item being cleaned up is not accepted twice"
pass "board background cleanup clears old failure notices and rejects a duplicate while one is running"

# 정리 속도(#305) E: 핸들러 연결 — 단건 정리는 캐시 항목+직전 확인(action_item)·background 정리, 미리보기는 캐시 조회.
BH_SRC="$(<"$ROOT/scripts/board/board-server.py")"
BH_POST="$(sed -n '/if path != "\/action":/,/self._send(200, res)/p' "$ROOT/scripts/board/board-server.py")"
assert_contains "$BH_POST" "action_item(" "the action handler looks the item up through action_item"
case "$BH_POST" in *'find_item(req.get("id"), fresh=True)'*) fail "the action handler no longer recollects status for every action" ;; esac
BH_RUN="$(sed -n '/^def run_action(/,/^    if action == "open_agent"/p' "$ROOT/scripts/board/board-server.py")"
assert_contains "$BH_RUN" "cleanup(item, bool(req.get(\"worktree\")), background=True" "a single cleanup runs in the background"
BH_PREV="$(sed -n '/if u.path == "\/cleanup-preview":/,/worktree_check/p' "$ROOT/scripts/board/board-server.py")"
assert_contains "$BH_PREV" "find_item(" "the cleanup preview looks the item up"
case "$BH_PREV" in *fresh=True*) fail "the cleanup preview reads the cached list" ;; esac
case "$BH_SRC" in *"def action_item("*) ;; *) fail "board-server defines action_item" ;; esac
pass "board server wires the cleanup handlers to the cached lookup and background cleanup"

# 정리 속도(#305) UI: 정리 대화상자는 서버 응답을 기다리지 않고 목록에서 먼저 뺀다(실패하면 되돌림). refresh()는 서버가 알린 cleanup_failed를 토스트로 알리고 되돌린다.
BOARD_CDLG="$(sed -n "/\$('cdlg').addEventListener('close'/,/^  });\$/p" "$ROOT/scripts/board/template.html")"
assert_contains "$BOARD_CDLG" "hiding.add(" "the cleanup dialog removes the item from the list first"
assert_contains "$BOARD_CDLG" "hiding.delete(" "the cleanup dialog puts the item back when cleanup fails"
BOARD_CDLG_ADD="${BOARD_CDLG%%hiding.add(*}"
BOARD_CDLG_POST="${BOARD_CDLG%%"post('/action'"*}"
[[ ${#BOARD_CDLG_ADD} -lt ${#BOARD_CDLG_POST} ]] || fail "the item leaves the list before the cleanup request is sent"
BOARD_REFRESH="$(sed -n '/async function refresh()/,/^  }$/p' "$ROOT/scripts/board/template.html")"
assert_contains "$BOARD_REFRESH" "cleanup_failed" "refresh handles cleanup failures reported by the server"
assert_contains "$BOARD_REFRESH" "hiding.delete(" "refresh puts a failed cleanup back in the list"
assert_contains "$BOARD_REFRESH" "toast(" "refresh tells the person a cleanup failed"
pass "board UI hides on cleanup first and refresh restores and reports failed cleanups"

# 언제나 정리(#306): 세션 정리는 상태와 관계없이 노출된다. 상태는 확인 수준(close_level)만 정하고, 서버는 화면이 보낸 확인 수준(confirm)보다
# 실제 상태가 무거우면 거부하며 새 수준을 돌려준다. 작업 중 세션은 worktree를 지우지 않는다. 대화 기록 파일은 읽기만 한다.
CA_T="$TEST_TMP/board-cleanup-always"
mkdir -p "$CA_T/data"
printf '{"type":"user","message":{"content":"가상 요청"}}\n' >"$CA_T/session.jsonl"
HARNESS_METRICS_DIR="$CA_T/data" python3 -I -B -c '
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("bs", sys.argv[1]); bs = importlib.util.module_from_spec(spec); spec.loader.exec_module(bs)
transcript = sys.argv[2]
before = open(transcript, "rb").read()
term = "term_00000000-0000-0000-0000-000000000000"
base = {"section": "work", "kind": "bg", "state": "done", "status": "idle", "live": True, "cwd": "/nope", "project": "shop",
        "at": "2026-01-01T00:00:00Z", "actions": ["view"], "transcript": transcript}
mk = lambda sid, **k: dict(base, sid=sid, id="claude|" + sid, short_id=sid, title=sid, **k)
bs._save(bs.SEEN, {})
items = [mk("s-idle"),
         mk("s-ask", reply_tail="고칠 범위를 정했습니다. 진행할까요?"),
         mk("s-wait", state="needs_human", status="waiting"),
         mk("s-busy", state="running", status="busy"),
         mk("s-term", kind="agent", state="running", status="busy", orca_handle=term),
         mk("s-noterm", kind="agent"),
         mk("s-ended", kind="agent", live=False, status=None)]
out = {i["sid"]: i for i in bs.classify_work(items)}
exposed = {s for s, i in out.items() if "cleanup" in i["actions"]}
assert exposed == {"s-idle", "s-ask", "s-wait", "s-busy", "s-term", "s-ended"}, exposed  # 닫을 방법이 없는 대화형 세션만 빠진다
levels = {s: bs.close_level(out[s]) for s in ("s-idle", "s-ask", "s-wait", "s-busy", "s-term", "s-ended")}
assert levels == {"s-idle": "idle", "s-ask": "ask", "s-wait": "waiting", "s-busy": "busy", "s-term": "busy", "s-ended": "idle"}, levels
assert not bs.can_close(out["s-busy"]) and not bs.can_close(out["s-ask"]), "bulk cleanup still takes only resting sessions"

ended = []
bs.end_session = lambda i: ended.append(i["sid"]) or True
bs.status = lambda *a, **k: {"items": []}
# 확인 수준 없이(또는 더 가벼운 수준으로) 보내면 거부하고 실제 수준을 돌려준다 — 세션을 닫지도 숨기지도 않는다
for sid, confirm, want in (("s-busy", None, "busy"), ("s-busy", "waiting", "busy"), ("s-wait", "ask", "waiting"), ("s-ask", None, "ask")):
    res = bs.cleanup(dict(out[sid]), False, confirm=confirm)
    assert res["ok"] is False and res.get("confirm") == want and res.get("message"), (sid, confirm, res)
res = bs.cleanup(dict(out["s-busy"]), False, background=True)
assert res["ok"] is False and res.get("confirm") == "busy", res
assert ended == [] and not (bs._load(bs.HIDDEN) or {}), (ended, bs._load(bs.HIDDEN))
# 맞는 수준이나 더 무거운 수준이면 정리한다
assert bs.cleanup(dict(out["s-busy"]), False, confirm="busy")["ok"] is True
assert bs.cleanup(dict(out["s-wait"]), False, confirm="waiting")["ok"] is True
assert bs.cleanup(dict(out["s-ask"]), False, confirm="ask")["ok"] is True
assert bs.cleanup(dict(out["s-idle"]), False, confirm="busy")["ok"] is True
assert bs.cleanup(dict(out["s-ended"]), False)["ok"] is True
assert ended == ["s-busy", "s-wait", "s-ask", "s-idle"], ended
# 작업 중 세션은 확인해도 worktree를 지우지 않는다(세션도 그대로)
bs.worktree_check = lambda i: {"path": "/nope", "removable": True, "branch": "feat/x"}
res = bs.cleanup(dict(out["s-term"]), True, confirm="busy")
assert res["ok"] is False and "worktree" in res["message"] and "s-term" not in ended, res
# 닫을 방법이 없는 살아 있는 세션은 확인 수준과 관계없이 거부
assert bs.cleanup(dict(out["s-noterm"]), False, confirm="busy")["ok"] is False
# 확인과 닫기 사이에 세션이 파일을 바꿨으면(닫은 뒤 다시 본 판정이 지울 수 없음) worktree는 남기고 세션 정리만 끝낸다
checks = iter([{"path": "/nope", "removable": True, "branch": "feat/x"}, {"path": "/nope", "removable": False, "reason": "커밋 안 한 변경 1개"}])
bs.worktree_check = lambda i: next(checks)
res = bs.cleanup(dict(out["s-wait"], sid="s-wait2", id="claude|s-wait2"), True, confirm="waiting")
assert res["ok"] is True and "남김" in res["message"] and res.get("worktree_kept") == "커밋 안 한 변경 1개" and ended[-1] == "s-wait2", res
assert open(transcript, "rb").read() == before, "the transcript file is left as it was"
' "$ROOT/scripts/board/board-server.py" "$CA_T/session.jsonl" || fail "session cleanup is offered in every state and the confirmation level must cover the actual state"
assert_file "$CA_T/session.jsonl"
CA_RUN="$(sed -n '/^def run_action(/,/^    if action == "open_agent"/p' "$ROOT/scripts/board/board-server.py")"
assert_contains "$CA_RUN" 'confirm=req.get("confirm")' "a single cleanup passes the confirmation level the screen sent"
CA_PREV="$(sed -n '/if u.path == "\/cleanup-preview":/,/self._send(200/p' "$ROOT/scripts/board/board-server.py")"
assert_contains "$CA_PREV" "close_level(" "the cleanup preview tells the screen the confirmation level"
pass "board cleanup is offered in every state and refuses when the confirmation level is lighter than the state"

# 언제나 정리(#306) UI: 확인창 문구·무게는 수준별, 작업 중은 취소에 기본 포커스, 서버가 더 무거운 수준을 돌려주면 새 경고로 다시 묻는다.
CA_OPEN="$(sed -n "/let cleaning = null/,/\$('cdlg').addEventListener('close'/p" "$ROOT/scripts/board/template.html")"
for CA_TEXT in '질문을 남기고 쉬는 중입니다. 답하지 않고 닫습니다.' '답을 기다리는 중입니다. 닫으면 그 요청은 거절된 것으로 끝납니다.' '작업 중입니다. 지금 닫으면 진행 중인 작업이 중간에 끊깁니다.'; do
  assert_contains "$CA_OPEN" "$CA_TEXT" "the cleanup dialog explains the state"
done
assert_contains "$CA_OPEN" "focus()" "the cleanup dialog moves focus for a running session"
# Esc로 닫으면 returnValue가 그대로라, 열 때마다 비우지 않으면 다시 연 창에서 Esc가 지난 '정리'를 다시 실행한다
CA_OPENFN="$(sed -n '/async function openCleanup(/,/^  }$/p' "$ROOT/scripts/board/template.html")"
assert_contains "$CA_OPENFN" "\$('cdlg').returnValue = ''" "opening the cleanup dialog forgets the previous choice"
CA_RESET="${CA_OPENFN%%"returnValue = ''"*}"
CA_SHOW="${CA_OPENFN%%"showModal()"*}"
[[ ${#CA_RESET} -lt ${#CA_SHOW} ]] || fail "the previous choice is cleared before the dialog opens"
assert_contains "$(<"$ROOT/scripts/board/template.html")" 'aria-describedby="cwarn cdesc"' "the cleanup dialog reads its warning when it opens"
CA_CLOSE="$(sed -n "/\$('cdlg').addEventListener('close'/,/^  });\$/p" "$ROOT/scripts/board/template.html")"
assert_contains "$CA_CLOSE" "confirm:" "the cleanup request carries the confirmation level"
assert_contains "$CA_CLOSE" "res.confirm" "a refused cleanup asks again with the new level"
pass "board cleanup dialog warns by state and asks again when the state got heavier"

# 남은 이유 안내(#296): '끝난 일 정리' 미리보기·결과가 정리 대상이 아닌 항목을 이유별 개수와 한 줄 안내(label)로 알린다. 0건인 이유는 없다.
BL_DATA="$TEST_TMP/board-cleanup-left"
mkdir -p "$BL_DATA"
HARNESS_METRICS_DIR="$BL_DATA" python3 -I -B -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("bs", sys.argv[1]); bs = importlib.util.module_from_spec(spec); spec.loader.exec_module(bs)
old, now = "2026-01-01T00:00:00Z", bs.utc()
S = lambda sid, **k: {"section": "work", "sid": sid, "id": "claude|" + sid, "kind": "bg", "short_id": sid, "cwd": "/nope", "title": sid,
                      "project": "shop", "at": old, **k}
items = [S("idle", state="idle", status="idle", live=True),
         S("recent", state="idle", status="idle", live=False, at=now),
         S("busy", state="running", status="busy", live=True), S("busy2", state="running", status="busy", live=True),
         S("agent-live", state="idle", status="idle", live=True, kind="agent"),
         S("asking", state="needs_human", status="idle", live=True, ask="할까요?"),
         S("perm", state="needs_human", status="waiting", live=True, permission={"pid": "p"}),
         {"section": "harness", "id": "sync|docs|" + now, "kind": "sync", "state": "done", "at": now, "title": "변경 없음", "project": "docs"},
         {"section": "harness", "id": "schedule|x|" + old, "kind": "schedule", "state": "blocked", "at": old, "title": "건너뜀", "project": "스케줄"}]
bs.worktree_candidates = lambda items: []  # 개발 머신의 실제 Orca·git worktree를 읽지 않게
bs.worktree_check = lambda i: {"removable": False, "reason": "x", "path": "/nope"}
bs.end_session = lambda i: True
by = lambda left: {l["reason"]: l for l in left}
left = by(bs.bulk_cleanup({"dry_run": True, "older_days": 1}, items)["left"])
assert set(left) == {"too_recent", "in_use", "waiting", "unfinished"}, left
assert [left[r]["count"] for r in ("too_recent", "in_use", "waiting", "unfinished")] == [2, 3, 2, 1], left
assert left["too_recent"]["label"] == "하루 안 된 2건은 남겨 둠", left
assert left["in_use"]["label"] == "지금 쓰는 세션 3건 제외", left
assert left["waiting"]["label"] == "답·확인을 기다리는 2건 제외", left
assert left["unfinished"]["label"] == "아직 끝나지 않은 1건 제외", left
assert by(bs.bulk_cleanup({"dry_run": True, "older_days": 7}, items)["left"])["too_recent"]["label"] == "일주일 안 된 2건은 남겨 둠"
assert by(bs.bulk_cleanup({"dry_run": True, "older_days": 3}, items)["left"])["too_recent"]["label"] == "3일 안 된 2건은 남겨 둠"
assert "too_recent" not in by(bs.bulk_cleanup({"dry_run": True}, items)["left"]), "nothing is too recent when no age limit is set"
res = bs.bulk_cleanup({"older_days": 1, "worktree": False}, items)
assert by(res["left"]) == left, res["left"]
assert res["message"].startswith("1개 정리 · 세션 1개 닫음"), res["message"]
assert all(" · " + l["label"] in res["message"] for l in res["left"]), res["message"]
' "$ROOT/scripts/board/board-server.py" || fail "bulk cleanup preview and result report what stays and why (too_recent, in_use, waiting, unfinished) with labels"
pass "board bulk cleanup explains why items were left"

# 무인 실행 기록 → 카드(#296): status.sh를 가짜 runs.jsonl로 돌린다. work.sh는 가짜 claude(빈 목록)로, HOME의 실제 프로필은 보지 않는다.
ST_T="$TEST_TMP/board-status"
ST_DATA="$ST_T/data"
mkdir -p "$ST_T/bin" "$ST_T/logs" "$ST_DATA/harvest-auto"
cat >"$ST_T/bin/claude" <<'FAKE'
#!/usr/bin/env bash
if [[ "$1" == agents ]]; then echo "[]"; exit 0; fi
exit 1
FAKE
chmod +x "$ST_T/bin/claude"
st_ago() { jq -rn --argjson m "$1" '(now - $m * 60) | floor | todate'; } # 분 전 ISO 시각
st_fin() { # $1=분 전 $2=project $3=scope $4=result $5=exit_code $6=log $7=덧붙일 JSON 객체
  local extra="${7:-}"
  [[ -n "$extra" ]] || extra='{}'
  jq -cn --arg at "$(st_ago "$1")" --arg project "$2" --arg scope "$3" --arg result "$4" --argjson exit "$5" --arg log "$6" --argjson extra "$extra" \
    '{at: $at, event: "finished", project: $project, batch: "b", scope: $scope, result: $result, exit_code: $exit, artifact: null, log: $log} + $extra'
}
jq -cn --arg at "$(st_ago 12)" '{type: "progress", at: $at, tool: "Read", target: "src/a.py"}, {type: "progress", at: $at, tool: "Bash", target: "테스트 실행"}' >"$ST_T/logs/ops.log"
jq -cn --arg at "$(st_ago 52)" '{type: "progress", at: $at, tool: "Read", target: "src/a.py"}, {type: "result", is_error: true, api_error: "usage_limit_reached", result: "사용량 한도 안내 문장"}' >"$ST_T/logs/api.log"
: >"$ST_T/logs/empty.log"
{
  st_fin 30 docs sync no-change 0 "$ST_T/logs/q1.log" '{"no_agent": true}'
  st_fin 90 web2 sync no-change 0 "$ST_T/logs/q2.log" '{"no_agent": true}'
  st_fin 120 svc project no-change 0 "$ST_T/logs/q3.log"
  st_fin 1800 oldq sync no-change 0 "$ST_T/logs/q4.log" '{"no_agent": true}'
  st_fin 400 web sync failed 1 "$ST_T/logs/none-0.log"
  st_fin 300 web sync failed 143 "$ST_T/logs/none-1.log" '{"duration_s": 2700}'
  st_fin 200 web sync failed 143 "$ST_T/logs/none-2.log" '{"duration_s": 2700}'
  st_fin 100 web sync failed 143 "$ST_T/logs/none-3.log" '{"duration_s": 2700}'
  st_fin 50 api project failed 1 "$ST_T/logs/api.log" '{"reason": "usage_limit"}'
  st_fin 400 blog sync failed 143 "$ST_T/logs/none-b.log" '{"duration_s": 2700}'
  st_fin 100 blog sync improved 0 "$ST_T/logs/blog-new.log" '{"artifact": "https://example.com/acme/blog/pull/1"}'
  st_fin 20 ops global failed 143 "$ST_T/logs/ops.log" '{"duration_s": 600}'
  st_fin 15 hollow project failed 143 "$ST_T/logs/empty.log" '{"duration_s": 3000}'
  st_fin 14 p137 project failed 137 "$ST_T/logs/none-137.log" '{"duration_s": 100}'
  st_fin 13 p70 sync failed 70 "$ST_T/logs/none-70.log"
  st_fin 12 p71 sync failed 71 "$ST_T/logs/none-71.log"
  st_fin 11 perr project failed 1 "$ST_T/logs/none-err.log" '{"reason": "agent_error"}'
  st_fin 10 pexit2 project failed 2 "$ST_T/logs/none-2x.log"
  st_fin 9 pnodur project failed 143 "$ST_T/logs/none-nd.log"
} >"$ST_DATA/harvest-auto/runs.jsonl"
st_status() {
  env -u CLAUDE_CONFIG_DIR PATH="$ST_T/bin:$PATH" HARNESS_METRICS_DIR="$ST_DATA" HARNESS_CLAUDE_PROJECTS_DIR="$ST_T/projects" \
    BOARD_CLAUDE_PROFILE_GLOBS="$ST_T/none/*" BOARD_CLAUDE_CONFIG_DIRS= bash "$ROOT/scripts/board/status.sh"
}
ST_OUT="$(st_status)"
st_item() { jq -c --arg p "$1" '[.items[] | select(.project == $p)]' <<<"$ST_OUT"; }

# 변경 없이 끝난 실행은 카드가 아니다: items에서 빠지고, 최근 24시간 분량이 종류별로 quiet_runs에 모인다(24시간 넘은 것은 세지 않는다).
assert_eq "0" "$(jq '[.items[] | select(.project | IN("docs", "web2", "svc", "oldq"))] | length' <<<"$ST_OUT")" "a run that changed nothing is not a card (sync no_agent included)"
assert_eq "harvest:1|sync:2" "$(jq -r '[.quiet_runs[] | "\(.kind):\(.count)"] | sort | join("|")' <<<"$ST_OUT")" "quiet runs are counted per kind over the last day"
assert_eq "$(jq -sr '[.[] | select(.project == "docs") | .at] | max' "$ST_DATA/harvest-auto/runs.jsonl")" "$(jq -r '.quiet_runs[] | select(.kind == "sync") | .last_at' <<<"$ST_OUT")" "a quiet run kind carries the time of its latest run"
pass "board status folds unchanged runs into quiet_runs instead of cards"

# 실패는 완료가 아니다: 같은 project+scope의 최신 실패는 사람 확인 카드이고, 같은 이유가 이어진 횟수가 제목에 붙는다.
assert_eq "1" "$(st_item web | jq 'length')" "a failing target is one card, not one per failed run"
assert_eq "needs_human|sync|실행 실패 (45분 시간 제한으로 중단됨) · 3번 연속|45분 시간 제한으로 중단됨|3" \
  "$(st_item web | jq -r '.[0] | "\(.state)|\(.kind)|\(.title)|\(.fail_reason)|\(.streak)"')" "a time-limit failure streak is a needs_human card with its reason and run count"
assert_eq "실행 실패 (사용량 한도에 닿음)|사용량 한도에 닿음|1" "$(st_item api | jq -r '.[0] | "\(.title)|\(.fail_reason)|\(.streak)"')" "a usage limit is said in plain words and a single failure carries no run count"
pass "board status turns the latest failed run into a needs_human card with a plain reason and streak"

# 실패 이유 사람 말(종료 코드·reason 매핑).
assert_eq "실행 실패 (10분 시간 제한으로 중단됨)" "$(st_item ops | jq -r '.[0].title')" "exit 143 names the minutes from the run duration"
assert_eq "실행 실패 (시간 제한으로 중단됨)" "$(st_item pnodur | jq -r '.[0].title')" "exit 143 without a duration still says time limit"
assert_eq "실행 실패 (강제 종료됨)" "$(st_item p137 | jq -r '.[0].title')" "exit 137 is a forced kill"
assert_eq "실행 실패 (작업 worktree를 만들지 못함)" "$(st_item p70 | jq -r '.[0].title')" "exit 70 is a worktree failure"
assert_eq "실행 실패 (동기화 계획을 세우지 못함)" "$(st_item p71 | jq -r '.[0].title')" "exit 71 is a sync plan failure"
assert_eq "실행 실패 (에이전트 오류 (agent_error))" "$(st_item perr | jq -r '.[0].title')" "an agent reason is shown after a plain label"
assert_eq "실행 실패 (exit 2)" "$(st_item pexit2 | jq -r '.[0].title')" "an unknown exit code is shown as is"
pass "board status explains failure reasons in plain words"

# 같은 project+scope의 최신이 아닌 실패는 카드로 만들지 않는다(최신 결과가 대신 보인다).
assert_eq "0" "$(st_item blog | jq '[.[] | select(.title | startswith("실행 실패"))] | length')" "an older failure behind a newer run is not a card"
assert_eq "1" "$(st_item blog | jq 'length')" "only the newest run of that target is a card"
pass "board status shows only the newest run per target, so an old failure does not linger"

# 빈 로그: 로그 파일이 없거나 비었으면 log는 null이고 실패 카드는 이유(log_note)를 단다. 내용이 있는 로그는 그대로 연다.
assert_eq "null|중간에 끊겨 로그가 남지 않았습니다" "$(st_item web | jq -r '.[0] | "\(.log)|\(.log_note)"')" "a failure whose log file never appeared says why"
assert_eq "null|중간에 끊겨 로그가 남지 않았습니다" "$(st_item hollow | jq -r '.[0] | "\(.log)|\(.log_note)"')" "a failure with a zero-byte log says why"
assert_eq "$ST_T/logs/api.log|null" "$(st_item api | jq -r '.[0] | "\(.log)|\(.log_note // null)"')" "a log with content stays openable and needs no note"
pass "board status drops missing and empty logs and notes why on failure cards"

# 진행 기록: 끝맺음(result)이 없는 실패 로그에서는 마지막 진행 줄을 detail로 보인다. result가 있으면 그 보고가 우선이다.
assert_contains "$(st_item ops | jq -r '.[0].detail')" "끊기기 전 마지막 진행: Bash 테스트 실행" "a cut-off run shows the last progress line"
assert_contains "$(st_item api | jq -r '.[0].detail')" "사용량 한도 안내 문장" "a run with a result shows its report"
[[ "$(st_item api | jq -r '.[0].detail')" != *"끊기기 전 마지막 진행"* ]] || fail "a run with a result does not show the last progress line"
pass "board status shows the last progress of a run that was cut off"

# 로그인 만료(#315): 여러 저장소의 인증 실패는 한 카드로 묶고 사람이 읽는 제목을 단다. 과거 버전이 agent_error로 남긴 실패도
# 로그가 인증 실패면 같이 묶는다. 그 뒤 성공한 실행이 있으면(다시 로그인함) 카드가 사라진다.
ST_AUTH="$ST_T/auth-data"
mkdir -p "$ST_AUTH/harvest-auto"
printf '%s\n' '{"type":"result","is_error":true,"result":"Failed to authenticate: this login reached its time limit. Run claude auth login"}' >"$ST_T/logs/auth-1.log"
cp "$ST_T/logs/auth-1.log" "$ST_T/logs/auth-2.log"
printf '%s\n' '{"type":"result","is_error":true,"result":"도구 실패"}' >"$ST_T/logs/auth-other.log"
{
  st_fin 30 a1 sync failed 1 "$ST_T/logs/auth-1.log" '{"reason": "auth_expired"}'
  st_fin 20 a2 project failed 1 "$ST_T/logs/auth-2.log" '{"reason": "agent_error"}'
  st_fin 10 a3 project failed 1 "$ST_T/logs/auth-other.log" '{"reason": "agent_error"}'
} >"$ST_AUTH/harvest-auto/runs.jsonl"
ST_OUT="$(env -u CLAUDE_CONFIG_DIR PATH="$ST_T/bin:$PATH" HARNESS_METRICS_DIR="$ST_AUTH" HARNESS_CLAUDE_PROJECTS_DIR="$ST_T/projects" \
  BOARD_CLAUDE_PROFILE_GLOBS="$ST_T/none/*" BOARD_CLAUDE_CONFIG_DIRS= bash "$ROOT/scripts/board/status.sh")"
assert_eq "0|0|1" "$(st_item a1 | jq 'length')|$(st_item a2 | jq 'length')|$(st_item a3 | jq 'length')" "expired-login failures leave the per-target cards, other failures stay"
ST_AUTH_CARD="$(jq -c '[.items[] | select(.reason == "auth_expired")]' <<<"$ST_OUT")"
assert_eq "1|needs_human" "$(jq -r 'length' <<<"$ST_AUTH_CARD")|$(jq -r '.[0].state' <<<"$ST_AUTH_CARD")" "expired-login failures are one card"
assert_eq "로그인이 만료돼 무인 실행이 멈췄어요 — claude auth login 또는 claude setup-token" "$(jq -r '.[0].title' <<<"$ST_AUTH_CARD")" "the card says what happened and what to run"
assert_contains "$(jq -r '.[0].detail' <<<"$ST_AUTH_CARD")" "a1" "the card lists the stopped targets"
assert_contains "$(jq -r '.[0].detail' <<<"$ST_AUTH_CARD")" "a2" "including one recorded by an older version"
st_fin 5 a3 project no-change 0 "$ST_T/logs/ok.log" >>"$ST_AUTH/harvest-auto/runs.jsonl"
ST_OUT="$(env -u CLAUDE_CONFIG_DIR PATH="$ST_T/bin:$PATH" HARNESS_METRICS_DIR="$ST_AUTH" HARNESS_CLAUDE_PROJECTS_DIR="$ST_T/projects" \
  BOARD_CLAUDE_PROFILE_GLOBS="$ST_T/none/*" BOARD_CLAUDE_CONFIG_DIRS= bash "$ROOT/scripts/board/status.sh")"
assert_eq "0" "$(jq '[.items[] | select(.reason == "auth_expired" or .project == "a1" or .project == "a2")] | length' <<<"$ST_OUT")" "a run that worked afterwards clears the expired-login card"
assert_contains "$(<"$ROOT/scripts/board/template.html")" "i.reason === 'auth_expired'" "the board shows the expired-login title as is"
pass "board status folds expired-login failures into one card that clears after a working run"

# 로그인 만료 후속(#326): 자동 수정만 쓰는 사용자도 묶음 카드를 받고, 세션 안내와 보드는 같은 기준(마지막 성공 실행 이후인가)으로 판정한다.
# 로그인 만료 뒤 에이전트를 띄우지 못한 실패(exit 70)는 성공이 아니므로 안내도 카드도 남는다.
ST_AF="$ST_T/af-data"
mkdir -p "$ST_AF/autofix"
st_af_fin() { # $1=분 전 $2=project $3=outcome $4=exit_code $5=log $6=덧붙일 JSON 객체
  local extra="${6:-}"
  [[ -n "$extra" ]] || extra='{}'
  jq -cn --arg at "$(st_ago "$1")" --arg p "$2" --arg o "$3" --argjson e "$4" --arg log "$5" --argjson x "$extra" \
    '{at: $at, event: "finished", project: $p, signature: "sig-1", outcome: $o, exit_code: $e, log: $log} + $x'
}
{
  st_af_fin 30 af-svc failed 1 "$ST_T/logs/auth-1.log" '{"reason": "auth_expired"}'
  st_af_fin 20 af-svc failed 70 "$ST_T/logs/none-af70.log"
} >"$ST_AF/autofix/runs.jsonl"
st_af_status() {
  env -u CLAUDE_CONFIG_DIR PATH="$ST_T/bin:$PATH" HARNESS_METRICS_DIR="$ST_AF" HARNESS_CLAUDE_PROJECTS_DIR="$ST_T/projects" \
    BOARD_CLAUDE_PROFILE_GLOBS="$ST_T/none/*" BOARD_CLAUDE_CONFIG_DIRS= bash "$ROOT/scripts/board/status.sh"
}
st_af_notify() { HARNESS_METRICS_DIR="$ST_AF" "$ROOT/scripts/harvest-auto.sh" notify; }
ST_AF_CARD="$(st_af_status | jq -c '[.items[] | select(.reason == "auth_expired")]')"
assert_eq "1|needs_human" "$(jq -r 'length' <<<"$ST_AF_CARD")|$(jq -r '.[0].state // ""' <<<"$ST_AF_CARD")" "an expired login in an autofix run is the same bundled card, without any harvest run"
assert_contains "$(jq -r '.[0].detail // ""' <<<"$ST_AF_CARD")" "af-svc(autofix)" "the card names the stopped autofix target"
assert_contains "$(st_af_notify | jq -r '.systemMessage // ""')" "claude auth login" "a failure that launched no agent after the expired login keeps the session notice, like the board"
assert_eq "" "$(st_af_notify)" "the notice is still shown once per failure"
st_af_fin 10 af-svc pr_opened 0 "$ST_T/logs/ok.log" >>"$ST_AF/autofix/runs.jsonl"
assert_eq "0" "$(st_af_status | jq '[.items[] | select(.reason == "auth_expired")] | length')" "an autofix run that worked afterwards clears the card"
st_af_fin 5 af-svc failed 1 "$ST_T/logs/auth-2.log" '{"reason": "auth_expired"}' >>"$ST_AF/autofix/runs.jsonl"
assert_contains "$(st_af_notify | jq -r '.systemMessage // ""')" "claude auth login" "a newer expired login after a working run is told again"
st_af_fin 1 af-svc pr_opened 0 "$ST_T/logs/ok.log" >>"$ST_AF/autofix/runs.jsonl"
: >"$ST_AF/harvest-auto/auth-notified"
assert_eq "" "$(st_af_notify)" "a working run after the expired login clears the notice"
# 이전 버전이 agent_error로 남긴 자동 수정 실패는 로그로 판정한다: 인증 실패 로그면 카드·안내에 넣고, 다른 실패 로그는 건너뛰어 그 전의 로그인 만료를 찾는다.
st_af_fin 0 af-old failed 1 "$ST_T/logs/auth-1.log" '{"reason": "agent_error"}' >>"$ST_AF/autofix/runs.jsonl"
assert_contains "$(st_af_status | jq -r '[.items[] | select(.reason == "auth_expired")] | .[0].detail // ""')" "af-old(autofix)" "a legacy autofix failure whose log is an expired login joins the card"
assert_contains "$(st_af_notify | jq -r '.systemMessage // ""')" "claude auth login" "and is told at session start"
jq -cn --arg at "$(st_ago 0)" --arg log "$ST_T/logs/auth-other.log" \
  '{at: $at, event: "finished", project: "af-other", signature: "sig-2", outcome: "failed", exit_code: 1, reason: "agent_error", log: $log}' >>"$ST_AF/autofix/runs.jsonl"
: >"$ST_AF/harvest-auto/auth-notified"
assert_eq "0" "$(st_af_status | jq '[.items[] | select(.reason == "auth_expired")] | .[0].detail // "" | test("af-other") | if . then 1 else 0 end')" "a legacy failure with another log stays out of the card"
assert_contains "$(st_af_notify | jq -r '.systemMessage // ""')" "claude auth login" "a newer unrelated failure does not hide the earlier expired login"
pass "the session notice and the board agree on expired logins, autofix included"

# 여러 Claude 설정 폴더(#296): work.sh가 기본 폴더·서버 환경의 폴더·프로필 자동 감지·사용자 지정 폴더마다 claude agents를 불러 sessionId로 합친다.
# HOME을 바꾸지 않고 환경변수로만 격리한다(서버 환경에 CLAUDE_CONFIG_DIR이 있을 수 있어 명시적으로 빼거나 지정한다).
WK_T="$(mkdir -p "$TEST_TMP/work-cfg" && cd "$TEST_TMP/work-cfg" && pwd -P)"
mkdir -p "$WK_T/bin" "$WK_T/cwd" "$WK_T/default-projects/p" "$WK_T/profiles/p1/home/projects/p" "$WK_T/profiles/p2/home/projects/p" \
  "$WK_T/custom/projects/p" "$WK_T/envdir/projects/p"
cat >"$WK_T/bin/claude" <<'FAKE'
#!/usr/bin/env bash
cfg="${CLAUDE_CONFIG_DIR-UNSET}"
printf '%s|%s\n' "$cfg" "$*" >>"$FAKE_CLAUDE_CALLS"
[[ "$1" == agents ]] || exit 1
cat "$FAKE_CLAUDE_DIR/agents-$(printf '%s' "$cfg" | tr '/' '_').json" 2>/dev/null || echo '[]'
FAKE
chmod +x "$WK_T/bin/claude"
WK_SID_D="aaaaaaaa-0000-4000-8000-000000000001"
WK_SID_S="aaaaaaaa-0000-4000-8000-000000000002"
WK_SID_P="aaaaaaaa-0000-4000-8000-000000000003"
WK_SID_C="aaaaaaaa-0000-4000-8000-000000000004"
WK_SID_E="aaaaaaaa-0000-4000-8000-000000000005"
wk_agent() { # $1=sessionId $2=pid(숫자 또는 null)
  jq -cn --arg sid "$1" --argjson pid "$2" --arg cwd "$WK_T/cwd" --argjson t "$(($(date +%s) * 1000))" \
    '{sessionId: $sid, id: $sid[0:8], kind: "background", status: "idle", state: "running", pid: $pid, cwd: $cwd, name: ("task " + $sid[-1:]), startedAt: $t}'
}
wk_list() { jq -s . >"$WK_T/agents-$(printf '%s' "$1" | tr '/' '_').json"; } # stdin의 줄들을 그 설정 폴더의 목록으로
{ wk_agent "$WK_SID_D" null; wk_agent "$WK_SID_S" null; } | wk_list UNSET
{ wk_agent "$WK_SID_P" 4242; wk_agent "$WK_SID_S" 4243; } | wk_list "$WK_T/profiles/p1/home"
printf '' | wk_list "$WK_T/profiles/p2/home"
wk_agent "$WK_SID_C" null | wk_list "$WK_T/custom"
wk_agent "$WK_SID_E" null | wk_list "$WK_T/envdir"
WK_NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
for WK_TR in "$WK_T/default-projects/p/$WK_SID_D.jsonl" "$WK_T/profiles/p1/home/projects/p/$WK_SID_S.jsonl" "$WK_T/profiles/p1/home/projects/p/$WK_SID_P.jsonl" \
  "$WK_T/custom/projects/p/$WK_SID_C.jsonl" "$WK_T/envdir/projects/p/$WK_SID_E.jsonl"; do
  jq -cn --arg t "$WK_NOW" '{type: "user", message: {content: "hello"}, timestamp: $t}' >"$WK_TR"
done
wk_work() { # 덧붙일 환경변수는 인자로
  : >"$WK_T/calls.log"
  env -u CLAUDE_CONFIG_DIR PATH="$WK_T/bin:$PATH" FAKE_CLAUDE_CALLS="$WK_T/calls.log" FAKE_CLAUDE_DIR="$WK_T" HARNESS_METRICS_DIR="$WK_T/metrics" \
    HARNESS_CLAUDE_PROJECTS_DIR="$WK_T/default-projects" BOARD_CLAUDE_PROFILE_GLOBS="$WK_T/profiles/*/home" \
    BOARD_CLAUDE_CONFIG_DIRS="$WK_T/custom:$WK_T/missing" "$@" bash "$ROOT/scripts/board/work.sh"
}
WK_OUT="$(wk_work)"
assert_eq "$WK_SID_D,$WK_SID_S,$WK_SID_P,$WK_SID_C" "$(jq -r '[.[].sid] | sort | join(",")' <<<"$WK_OUT")" "sessions from every settings folder are listed once per sessionId"
assert_eq "$(jq -cnS --arg d "$WK_SID_D" --arg s "$WK_SID_S" --arg p "$WK_SID_P" --arg c "$WK_SID_C" --arg p1 "$WK_T/profiles/p1/home" --arg cu "$WK_T/custom" \
  '{($d): null, ($s): $p1, ($p): $p1, ($c): $cu}')" "$(jq -cS 'map({(.sid): .config_dir}) | add' <<<"$WK_OUT")" \
  "each item records its settings folder (null for the default one); a shared sessionId goes to the folder where it is alive"
assert_eq "$(jq -cnS --arg d "$WK_SID_D" --arg s "$WK_SID_S" --arg p "$WK_SID_P" --arg c "$WK_SID_C" --arg r "$WK_T" \
  '{($d): "\($r)/default-projects/p/\($d).jsonl", ($s): "\($r)/profiles/p1/home/projects/p/\($s).jsonl", ($p): "\($r)/profiles/p1/home/projects/p/\($p).jsonl", ($c): "\($r)/custom/projects/p/\($c).jsonl"}')" \
  "$(jq -cS 'map({(.sid): .transcript}) | add' <<<"$WK_OUT")" "a transcript is found under its own settings folder (the default one keeps HARNESS_CLAUDE_PROJECTS_DIR)"
pass "work.sh merges sessions from the default, auto-detected and custom Claude settings folders"

# 폴더마다 한 번만 부르고, 기본 폴더는 CLAUDE_CONFIG_DIR 없이(설정해 버리면 다른 설정 파일을 읽는다) 부른다. 없는 폴더는 건너뛴다.
WK_CALLS="$(<"$WK_T/calls.log")"
assert_eq "UNSET|agents --json --all" "$(grep "^UNSET|" "$WK_T/calls.log")" "the default folder is asked without CLAUDE_CONFIG_DIR"
assert_eq "$WK_T/custom,$WK_T/profiles/p1/home,$WK_T/profiles/p2/home,UNSET" "$(cut -d'|' -f1 "$WK_T/calls.log" | LC_ALL=C sort | paste -sd, -)" "every existing folder is asked exactly once"
case "$WK_CALLS" in *"$WK_T/missing"*) fail "a folder that does not exist is not asked" ;; esac
pass "work.sh asks each existing settings folder once and the default one without CLAUDE_CONFIG_DIR"

# 서버 환경에 CLAUDE_CONFIG_DIR이 있으면 그 폴더도 본다(기본 폴더는 여전히 그 변수 없이). 같은 실경로는 한 번만.
WK_OUT_ENV="$(wk_work CLAUDE_CONFIG_DIR="$WK_T/envdir" BOARD_CLAUDE_CONFIG_DIRS="$WK_T/envdir:$WK_T/profiles/p1/home")"
assert_eq "UNSET|agents --json --all" "$(grep "^UNSET|" "$WK_T/calls.log")" "even then the default folder is asked without the variable"
assert_eq "1|1" "$(grep -c -F "$WK_T/envdir|" "$WK_T/calls.log" | tr -d ' ')|$(grep -c -F "$WK_T/profiles/p1/home|" "$WK_T/calls.log" | tr -d ' ')" "a folder named by several sources is asked once"
assert_eq "$WK_T/envdir|$WK_T/envdir/projects/p/$WK_SID_E.jsonl" "$(jq -r --arg s "$WK_SID_E" '.[] | select(.sid == $s) | "\(.config_dir)|\(.transcript)"' <<<"$WK_OUT_ENV")" "a session from the server environment's folder is listed with that folder"
pass "work.sh also reads the folder from the server's CLAUDE_CONFIG_DIR and de-duplicates by real path"

assert_contains "$(<"$ROOT/skills/board/SKILL.md")" "BOARD_CLAUDE_CONFIG_DIRS" "the board skill documents how to add settings folders"

# transcript 파싱 캐시(#305): work.sh가 transcript마다 파싱 결과(제목·요약)를 크기:수정시각 키로 work-cache.json에 남겨 변하지 않은 파일은 다시 파싱하지 않는다.
# 이번 실행에 나온 세션의 transcript만 남기고, 출력은 캐시가 있든 없든 같으며, transcript 파일은 건드리지 않는다.
WKC_T="$(mkdir -p "$TEST_TMP/work-cache" && cd "$TEST_TMP/work-cache" && pwd -P)"
mkdir -p "$WKC_T/bin" "$WKC_T/cwd" "$WKC_T/projects/p" "$WKC_T/metrics"
cat >"$WKC_T/bin/claude" <<'FAKE'
#!/usr/bin/env bash
[[ "$1" == agents ]] || exit 1
cat "$FAKE_AGENTS"
FAKE
chmod +x "$WKC_T/bin/claude"
WKC_SID_1="bbbbbbbb-0000-4000-8000-000000000001"
WKC_SID_2="bbbbbbbb-0000-4000-8000-000000000002"
WKC_TR1="$WKC_T/projects/p/$WKC_SID_1.jsonl"
WKC_TR2="$WKC_T/projects/p/$WKC_SID_2.jsonl"
WKC_NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
wkc_agent() { # $1=sessionId
  jq -cn --arg sid "$1" --arg cwd "$WKC_T/cwd" --argjson t "$(($(date +%s) * 1000))" \
    '{sessionId: $sid, id: $sid[0:8], kind: "background", status: "idle", state: "running", pid: 4242, cwd: $cwd, name: ("task " + $sid[-1:]), startedAt: $t}'
}
{ wkc_agent "$WKC_SID_1"; wkc_agent "$WKC_SID_2"; } | jq -s . >"$WKC_T/agents-both.json"
wkc_agent "$WKC_SID_1" | jq -s . >"$WKC_T/agents-one.json"
for WKC_TR in "$WKC_TR1" "$WKC_TR2"; do
  { jq -cn --arg t "$WKC_NOW" '{type: "user", message: {content: "hello"}, timestamp: $t}'
    jq -cn '{type: "ai-title", aiTitle: "Example summary title"}'
  } >"$WKC_TR"
done
wkc_work() { # $1=agents 목록 파일
  env -u CLAUDE_CONFIG_DIR PATH="$WKC_T/bin:$PATH" FAKE_AGENTS="$1" HARNESS_METRICS_DIR="$WKC_T/metrics" HARNESS_CLAUDE_PROJECTS_DIR="$WKC_T/projects" \
    BOARD_CLAUDE_PROFILE_GLOBS="$WKC_T/none/*" BOARD_CLAUDE_CONFIG_DIRS= bash "$ROOT/scripts/board/work.sh"
}
WKC_CACHE="$WKC_T/metrics/board/work-cache.json"
WKC_COLD="$(wkc_work "$WKC_T/agents-both.json")"
assert_file "$WKC_CACHE"
assert_eq "600" "$(filemode "$WKC_CACHE")" "the work cache is readable only by its owner"
assert_eq "true|true" "$(jq -r --arg a "$WKC_TR1" --arg b "$WKC_TR2" '"\(.[$a] | has("key") and has("titles") and has("summary"))|\(.[$b] | has("key") and has("titles") and has("summary"))"' "$WKC_CACHE")" \
  "the cache keeps the parse result of every transcript listed in this run, keyed by path"
WKC_SUM="$(shasum "$WKC_TR1" "$WKC_TR2")"
WKC_WARM="$(wkc_work "$WKC_T/agents-both.json")"
assert_eq "$WKC_COLD" "$WKC_WARM" "work.sh prints the same list on a cold run and a warm run"
assert_eq "$WKC_SUM" "$(shasum "$WKC_TR1" "$WKC_TR2")" "work.sh never changes a transcript"
# 캐시가 쓰였는지: 항목을 바꿔 두면 그 값이 그대로 나온다(파일이 그대로면 다시 파싱하지 않는다).
jq --arg p "$WKC_TR1" '.[$p].titles.custom = "CACHED"' "$WKC_CACHE" >"$WKC_T/tampered.json" && mv "$WKC_T/tampered.json" "$WKC_CACHE"
assert_eq "CACHED" "$(wkc_work "$WKC_T/agents-both.json" | jq -r --arg s "$WKC_SID_1" '.[] | select(.sid == $s) | .title')" "an unchanged transcript is not parsed again"
# 파일이 바뀌면(크기가 달라지면) 다시 파싱한다.
jq -cn '{type: "custom-title", customTitle: "Renamed by person"}' >>"$WKC_TR1"
assert_eq "Renamed by person" "$(wkc_work "$WKC_T/agents-both.json" | jq -r --arg s "$WKC_SID_1" '.[] | select(.sid == $s) | .title')" "a transcript that grew is parsed again"
assert_eq "true" "$(jq -r --arg p "$WKC_TR1" '.[$p].titles.custom == "Renamed by person"' "$WKC_CACHE")" "the cache entry follows the re-parsed transcript"
# 이번 목록에 없는 세션의 transcript는 캐시에서 뺀다.
wkc_work "$WKC_T/agents-one.json" >/dev/null
assert_eq "$WKC_TR1" "$(jq -r 'keys | join(",")' "$WKC_CACHE")" "transcripts of sessions no longer listed are pruned from the cache"
pass "work.sh caches transcript parse results by size and mtime, prunes unlisted ones and prints the same output"

# 캐시가 JSON으로는 맞지만 모양이 틀려도(값이 문자열·숫자·누락) work.sh는 멈추지 않고 실제 제목으로 목록을 낸다. 틀린 항목은 지우고 다시 쓴다.
WKC_REAL_KEY="$(stat -c '%s:%Y' "$WKC_TR1" 2>/dev/null || stat -f '%z:%m' "$WKC_TR1")"
wkc_title() { wkc_work "$WKC_T/agents-one.json" | jq -r --arg s "$WKC_SID_1" '.[] | select(.sid == $s) | .title'; }
jq -cn --arg p "$WKC_TR1" '{($p): "garbage", "/x/other.jsonl": {key: 1}}' >"$WKC_CACHE"
assert_eq "Renamed by person" "$(wkc_title)" "a cache whose entries are the wrong shape does not break the list"
assert_eq "object|string" "$(jq -r --arg p "$WKC_TR1" '"\(.[$p] | type)|\(.[$p].key | type)"' "$WKC_CACHE")" "a malformed cache entry is replaced by a parsed one"
assert_eq "false" "$(jq -r 'has("/x/other.jsonl")' "$WKC_CACHE")" "a malformed entry for an unlisted path is gone"
jq -cn --arg p "$WKC_TR1" --arg k "$WKC_REAL_KEY" '{($p): {key: $k, titles: "x", summary: 3}}' >"$WKC_CACHE"
WKC_BAD_OUT="$(wkc_work "$WKC_T/agents-one.json")"
assert_eq "Renamed by person" "$(jq -r --arg s "$WKC_SID_1" '.[] | select(.sid == $s) | .title' <<<"$WKC_BAD_OUT")" "an entry with the right key but wrong value types still gives the real title"
pass "work.sh survives a cache with wrong-shaped entries and writes a well-formed one back"

# 상태 갱신 가속(#348): 설정 폴더마다 부르는 claude agents는 동시에 돌고, transcript 키(크기:수정시각)는 transcript 수와 상관없이
# stat 한 번으로 모은다. 경로에 공백이 있는 설정 폴더(macOS 'Application Support' 같은)도 같은 transcript를 찾는다.
WKP_T="$(mkdir -p "$TEST_TMP/work-fast" && cd "$TEST_TMP/work-fast" && pwd -P)"
mkdir -p "$WKP_T/bin" "$WKP_T/cwd" "$WKP_T/metrics" "$WKP_T/default/projects/p" \
  "$WKP_T/profiles/a b/home/projects/p" "$WKP_T/profiles/c/home/projects/p" "$WKP_T/profiles/d/home/projects/p"
WKP_REAL_STAT="$(command -v stat)"
cat >"$WKP_T/bin/claude" <<'FAKE'
#!/usr/bin/env bash
[[ "$1" == agents ]] || exit 1
printf 'start\n' >>"$FAKE_CLAUDE_LOG"
sleep 1
printf 'end\n' >>"$FAKE_CLAUDE_LOG"
cat "${CLAUDE_CONFIG_DIR:-$FAKE_DEFAULT}/agents.json" 2>/dev/null || echo '[]'
FAKE
cat >"$WKP_T/bin/stat" <<'FAKE'
#!/usr/bin/env bash
printf 'stat\n' >>"$FAKE_STAT_LOG"
exec "$REAL_STAT" "$@"
FAKE
chmod +x "$WKP_T/bin/claude" "$WKP_T/bin/stat"
WKP_NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
WKP_EXPECT=""
wkp_n=0
for WKP_CFG in "$WKP_T/default" "$WKP_T/profiles/a b/home" "$WKP_T/profiles/c/home" "$WKP_T/profiles/d/home"; do
  : >"$WKP_T/list.jsonl"
  for _ in 1 2; do
    wkp_n=$((wkp_n + 1))
    WKP_SID="cccccccc-0000-4000-8000-00000000000$wkp_n"
    jq -cn --arg sid "$WKP_SID" --arg cwd "$WKP_T/cwd" --argjson t "$(($(date +%s) * 1000))" \
      '{sessionId: $sid, id: $sid[0:8], kind: "background", status: "idle", state: "running", pid: null, cwd: $cwd, name: ("task-0" + $sid[-1:]), startedAt: $t}' >>"$WKP_T/list.jsonl"
    { jq -cn --arg t "$WKP_NOW" --arg n "$wkp_n" '{type: "user", message: {content: ("hello " + $n)}, timestamp: $t}'
      jq -cn --arg n "$wkp_n" '{type: "ai-title", aiTitle: ("Title " + $n)}'
    } >"$WKP_CFG/projects/p/$WKP_SID.jsonl"
    WKP_EXPECT="$WKP_EXPECT$WKP_SID=$WKP_CFG/projects/p/$WKP_SID.jsonl=Title $wkp_n
"
  done
  jq -s . "$WKP_T/list.jsonl" >"$WKP_CFG/agents.json"
done
wkp_work() {
  : >"$WKP_T/claude.log"; : >"$WKP_T/stat.log"
  env -u CLAUDE_CONFIG_DIR PATH="$WKP_T/bin:$PATH" REAL_STAT="$WKP_REAL_STAT" FAKE_CLAUDE_LOG="$WKP_T/claude.log" FAKE_STAT_LOG="$WKP_T/stat.log" \
    FAKE_DEFAULT="$WKP_T/default" HARNESS_METRICS_DIR="$WKP_T/metrics" HARNESS_CLAUDE_PROJECTS_DIR="$WKP_T/default/projects" \
    BOARD_CLAUDE_PROFILE_GLOBS="$WKP_T/profiles/*/home" BOARD_CLAUDE_CONFIG_DIRS= bash "$ROOT/scripts/board/work.sh"
}
WKP_COLD="$(wkp_work)"
assert_eq "4" "$(awk '/^end$/ {exit} /^start$/ {n++} END {print n + 0}' "$WKP_T/claude.log")" "every settings folder is asked before the first answer comes back"
assert_eq "$(printf '%s' "$WKP_EXPECT" | LC_ALL=C sort)" "$(jq -r '.[] | "\(.sid)=\(.transcript)=\(.title)"' <<<"$WKP_COLD" | LC_ALL=C sort)" \
  "every session keeps its own transcript and title, a settings folder with a space included"
WKP_STATS="$(wc -l <"$WKP_T/stat.log" | tr -d ' ')"
[ "$WKP_STATS" -le 2 ] || fail "transcript keys are read with one stat call, not one per transcript (got $WKP_STATS calls for 8 transcripts)"
WKP_WARM="$(wkp_work)"
assert_eq "$WKP_COLD" "$WKP_WARM" "a warm run prints the same list"
WKP_STATS="$(wc -l <"$WKP_T/stat.log" | tr -d ' ')"
[ "$WKP_STATS" -le 2 ] || fail "a warm run also reads every transcript key with one stat call (got $WKP_STATS)"
# 지난 캐시의 경로를 먼저 쓰되, 그 파일이 없어졌으면(다른 프로젝트 폴더로 옮겨짐) 다시 찾는다.
WKP_MOVED_SID="cccccccc-0000-4000-8000-000000000003"
mkdir -p "$WKP_T/profiles/a b/home/projects/q"
mv "$WKP_T/profiles/a b/home/projects/p/$WKP_MOVED_SID.jsonl" "$WKP_T/profiles/a b/home/projects/q/"
assert_eq "$WKP_T/profiles/a b/home/projects/q/$WKP_MOVED_SID.jsonl|Title 3" \
  "$(wkp_work | jq -r --arg s "$WKP_MOVED_SID" '.[] | select(.sid == $s) | "\(.transcript)|\(.title)"')" "a transcript that moved since the last run is found again"
pass "work.sh asks the settings folders in parallel and reads transcript keys in one batch"

# 보드 서버는 항목의 설정 폴더로 claude를 부른다(#296): 입력·재개(send_to_bg)·정리(end_session)·정지 확인(wait_stopped)이 같은 폴더를 쓰고, 없으면 환경에서 뺀다.
BS_T="$TEST_TMP/board-cfg-env"
mkdir -p "$BS_T/bin" "$BS_T/data" "$BS_T/cwd"
cat >"$BS_T/bin/claude" <<'FAKE'
#!/usr/bin/env bash
printf '%s|%s\n' "${CLAUDE_CONFIG_DIR-UNSET}" "$*" >>"$FAKE_CLAUDE_CALLS"
case "$1" in
  agents) echo '[]' ;;
  --bg) echo 'backgrounded' ;;
esac
FAKE
chmod +x "$BS_T/bin/claude"
HARNESS_METRICS_DIR="$BS_T/data" FAKE_CLAUDE_CALLS="$BS_T/calls.log" python3 -I -B -c '
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("bs", sys.argv[1]); bs = importlib.util.module_from_spec(spec); spec.loader.exec_module(bs)
bin_dir, cwd, calls_log = sys.argv[2], sys.argv[3], os.environ["FAKE_CLAUDE_CALLS"]
os.environ["PATH"] = bin_dir + os.pathsep + os.environ["PATH"]
os.environ["CLAUDE_CONFIG_DIR"] = "/server/env/dir"  # 서버 환경에 있어도 항목에 폴더가 없으면 넘기지 않는다
def calls():
    with open(calls_log) as f:
        lines = f.read().splitlines()
    open(calls_log, "w").close()
    return lines
item = {"kind": "bg", "short_id": "abcd1234", "sid": "sid-1", "cwd": cwd, "live": False, "status": None, "state": "done"}
with_cfg = dict(item, config_dir="/cfg/work")
res = bs.send_to_bg(with_cfg, "이어서 해줘")
c = calls()
assert res["ok"], res
assert [l.split("|", 1)[1].split()[0] for l in c] == ["--bg"], c  # 멈춘 세션은 같은 ID로 깨운다(실행 중 세션은 아래 #380 블록)
assert all(l.startswith("/cfg/work|") for l in c), c
assert bs.end_session(with_cfg) is True
c = calls()
assert [l.split("|", 1)[1].split()[0] for l in c] == ["stop", "agents"] and all(l.startswith("/cfg/work|") for l in c), c
for plain in (item, dict(item, config_dir=None)):
    bs.send_to_bg(plain, "다시")
    bs.end_session(plain)
    c = calls()
    assert c and all(l.startswith("UNSET|") for l in c), c  # 기본 폴더는 서버 환경의 CLAUDE_CONFIG_DIR이 있어도 빼고 부른다
bs.new_bg(cwd, "새 일")
c = calls()
assert c and all(l.startswith("UNSET|") for l in c), c  # 새 세션은 기본 환경
bs.claude(["agents", "--json", "--all"], cwd, 5, config_dir="/cfg/direct")
assert calls() == ["/cfg/direct|agents --json --all"]
bs.claude(["agents", "--json", "--all"], cwd, 5)
assert calls() == ["UNSET|agents --json --all"]
' "$ROOT/scripts/board/board-server.py" "$BS_T/bin" "$BS_T/cwd" || fail "the board calls claude with the item's own settings folder for send, stop and the stopped check, and without the variable otherwise"
pass "board server passes an item's settings folder to claude and drops CLAUDE_CONFIG_DIR when it has none"

finish_tests
