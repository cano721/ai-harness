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

# 실행 중인 bg 세션에 답하기(#380): --resume은 이미 도는 세션의 복제본을 띄운다. 입력을 기다리는(idle) 세션은 claude attach를
# PTY로 붙여 원래 세션의 입력창에 넣고 떼며, 대화 기록에 그 글이 들어갔는지로 확인한다. 권한 창에서 Enter는 허용을 고르므로
# 붙기 전·붙여넣기 전·Enter 전 상태 확인, 화면의 창 표지, 입력창 에코를 모두 통과해야 Enter를 보낸다. 작업 중·창 대기 세션은
# 보내지 않고 attach 명령을 안내한다. 멈춘 세션만 --resume으로 깨운다.
BA3_T="$TEST_TMP/board-attach"
mkdir -p "$BA3_T/bin" "$BA3_T/cwd" "$BA3_T/data"
# 가짜 claude: agents는 상태 파일의 첫 줄("status:state" 또는 stopped)을 돌려주고 두 줄 이상이면 그 줄을 지운다(호출마다 다음 상태).
# attach는 진짜 TUI처럼 raw 모드로 받는다: 붙여넣기가 끝나면 입력창 에코(❯ + 글)를 그리고, Enter(CR)를 받으면 Enter 표시 파일과
# 대기열 기록을 남긴다. FAKE_ATTACH_DIALOG=before|after면 붙을 때·붙여넣은 뒤 권한 창(실측 문구)을 그린다.
cat >"$BA3_T/bin/claude" <<'FAKE'
#!/usr/bin/env bash
printf '%s|%s|%s\n' "${CLAUDE_CONFIG_DIR-UNSET}" "$([ -t 0 ] && echo tty || echo notty)" "$*" >>"$FAKE_CLAUDE_CALLS"
case "$1" in
  agents)
    cur=$(head -n 1 "$FAKE_STATUS_FILE")
    if [ "$(wc -l <"$FAKE_STATUS_FILE")" -gt 1 ]; then tail -n +2 "$FAKE_STATUS_FILE" >"$FAKE_STATUS_FILE.next"; mv "$FAKE_STATUS_FILE.next" "$FAKE_STATUS_FILE"; fi
    if [ "$cur" = stopped ]; then
      echo '[{"sessionId": "abcd1234-0000-4000-8000-000000000001", "pid": null, "status": null, "state": "done"}]'
    else
      jq -cn --arg s "${cur%%:*}" --arg st "${cur#*:}" '[{sessionId: "abcd1234-0000-4000-8000-000000000001", pid: 4242, status: $s, state: $st}]'
    fi ;;
  --bg) echo 'backgrounded' ;;
  attach)
    exec python3 -c '
import json, os, sys, time, tty
tty.setraw(0)
dialog = os.environ.get("FAKE_ATTACH_DIALOG", "")
prompt = "Do you want to proceed?\r\n\xe2\x9d\xaf 1. Yes\r\n  2. No\r\nEsc to cancel \xc2\xb7 Tab to amend\r\n".encode("latin-1")
os.write(1, b"Claude Code\r\n" + (prompt if dialog == "before" else b"\xe2\x9d\xaf \r\n"))
buf = b""
while True:
    chunk = os.read(0, 65536)
    if not chunk:
        sys.exit(0)
    buf += chunk
    if b"\x1b[201~" in chunk:
        pasted = buf.split(b"\x1b[200~", 1)[-1].split(b"\x1b[201~", 1)[0]
        if dialog == "after":
            os.write(1, prompt)
        elif not os.environ.get("FAKE_ATTACH_NOECHO"):
            os.write(1, b"\x1b[2K\xe2\x9d\xaf\xc2\xa0" + pasted.replace(b"\n", b"\r\n  ") + b"\r\n")
    if buf.endswith(b"\r"):
        break
open(os.environ["FAKE_ENTER"], "w").close()
if not os.environ.get("FAKE_ATTACH_DROP"):
    with open(os.environ["FAKE_TRANSCRIPT"], "a") as f:
        f.write(json.dumps({"type": "queue-operation", "operation": "enqueue", "content": buf[:-1].decode()}, ensure_ascii=False) + "\n")
time.sleep(30)
' ;;
esac
FAKE
chmod +x "$BA3_T/bin/claude"
: >"$BA3_T/t.jsonl"; : >"$BA3_T/calls.log"
HARNESS_METRICS_DIR="$BA3_T/data" FAKE_CLAUDE_CALLS="$BA3_T/calls.log" FAKE_TRANSCRIPT="$BA3_T/t.jsonl" FAKE_STATUS_FILE="$BA3_T/status" \
  FAKE_ENTER="$BA3_T/enter" BOARD_ATTACH_CONFIRM=4 python3 -I -B -c '
import importlib.util, os, sys, threading, time
spec = importlib.util.spec_from_file_location("bs", sys.argv[1]); bs = importlib.util.module_from_spec(spec); spec.loader.exec_module(bs)
bin_dir, cwd, calls_log, tpath, sfile, enter = (sys.argv[2], sys.argv[3], os.environ["FAKE_CLAUDE_CALLS"], os.environ["FAKE_TRANSCRIPT"],
                                                os.environ["FAKE_STATUS_FILE"], os.environ["FAKE_ENTER"])
os.environ["PATH"] = bin_dir + os.pathsep + os.environ["PATH"]
def calls():
    with open(calls_log) as f:
        lines = f.read().splitlines()
    open(calls_log, "w").close()
    return lines
def cmds(c):
    return [l.split("|", 2)[2] for l in c if not l.split("|", 2)[2].startswith("agents")]
def states(*s):
    with open(sfile, "w") as f:
        f.write("\n".join(s) + "\n")
    if os.path.exists(enter):
        os.remove(enter)
def env(**kv):
    for k in ("FAKE_ATTACH_DIALOG", "FAKE_ATTACH_NOECHO", "FAKE_ATTACH_DROP"):
        os.environ.pop(k, None)
    os.environ.update(kv)
base = {"kind": "bg", "short_id": "abcd1234", "sid": "abcd1234-0000-4000-8000-000000000001", "cwd": cwd, "transcript": tpath,
        "config_dir": "/cfg/work", "live": True, "pid": 4242, "status": "idle", "bg_state": "done"}
calls()
# 입력을 기다리는 세션: 붙기 전·붙여넣기 전·Enter 전에 상태를 보고, 입력창에 글이 보이면 Enter
states("idle:done")
res = bs.send_to_bg(dict(base), "첫 줄\n둘째 줄\x1b[201~\x9b끝")
c = calls()
assert res["ok"], res
assert cmds(c) == ["attach abcd1234"], c  # --resume·stop 없이 원래 세션에 붙는다
assert all(l.startswith("/cfg/work|") for l in c), c  # 그 세션의 설정 폴더로
assert [l for l in c if "attach" in l][0].startswith("/cfg/work|tty|"), c  # 터미널(PTY)로 붙는다
assert len([l for l in c if "|agents" in l]) == 3, c
assert "둘째 줄[201~끝" in open(tpath).read()  # 여러 줄 그대로, 제어 문자(ESC·C1)는 빼고
big = "긴 글 " + "가" * 7990
states("idle:done")
assert bs.send_to_bg(dict(base), big)["ok"]  # 8000자 붙여넣기도 PTY 큐에 막히지 않는다
assert big in open(tpath).read()
calls()
# 작업 중·질문/권한 창·사용량 한도로 멈춘 세션에는 키를 하나도 보내지 않고 attach를 안내한다(작업 중에는 언제든 권한 창이 뜬다)
for st, bgs in (("busy", "working"), ("waiting", "blocked"), ("idle", "blocked")):
    res = bs.send_to_bg(dict(base, status=st, bg_state=bgs), "예")
    assert not res["ok"] and "claude attach abcd1234" in res["message"], (st, res)
    assert calls() == [], st
def refused(why, *seq, **kv):
    states(*seq); env(**kv)
    before = open(tpath).read()
    res = bs.send_to_bg(dict(base), "보내면 안 되는 글")
    assert not res["ok"] and "claude attach abcd1234" in res["message"], (why, res)
    assert not os.path.exists(enter), why + ": Enter was sent"
    assert open(tpath).read() == before, why
    return res
# 붙기 직전 확인에서 이미 권한 창 → 붙지도 않는다
refused("waiting before attach", "waiting:blocked")
assert cmds(calls()) == []
states("stopped")
res = bs.send_to_bg(dict(base), "멈춘 사이 글")
assert not res["ok"] and "멈춤" in res["message"] and cmds(calls()) == [], res  # 그새 멈췄으면 다시 보내면 --resume으로 간다
# 두 번째(붙여넣기 전) 확인에서만 권한 창 → 붙여넣지도 않는다
r = refused("waiting before paste", "idle:done", "waiting:blocked")
assert "남아 있을 수" not in r["message"], r
# 세 번째(Enter 전) 확인에서만 권한 창 → Enter 없이, 붙여넣은 글이 남았을 수 있다고 알린다
r = refused("waiting before enter", "idle:done", "idle:done", "waiting:blocked")
assert "남아 있을 수" in r["message"], r
# 상태는 idle이어도 화면에 권한 창 표지가 보이면 Enter를 보내지 않는다(상태 파일이 화면보다 늦을 수 있다)
refused("dialog on screen", "idle:done", FAKE_ATTACH_DIALOG="before")
r = refused("dialog after paste", "idle:done", FAKE_ATTACH_DIALOG="after")
assert "권한" in r["message"] and "남아 있을 수" in r["message"], r
# 붙여넣은 글이 입력창에 보이지 않으면 Enter를 보내지 않는다
refused("no echo", "idle:done", FAKE_ATTACH_NOECHO="1")
env()
calls()
# 대화 기록의 사람 입력에 안 보이면 보냈다고 하지 않는다
states("idle:done"); env(FAKE_ATTACH_DROP="1")
res = bs.send_to_bg(dict(base), "안 들어가는 글")
assert not res["ok"] and "claude attach abcd1234" in res["message"], res
env()
with open(tpath, "a") as f:  # 답변에 같은 낱말이 나와도 사람 입력으로 치지 않는다
    f.write("{\"type\": \"assistant\", \"message\": {\"content\": \"계속 진행\"}}\n")
assert not bs._landed(tpath, 0, "계속 진행") and bs._landed(tpath, 0, "첫 줄")
calls()
# 같은 세션에 보내는 중이면 겹쳐 보내지 않는다
lock = bs._attach_locks.setdefault(base["sid"], threading.Lock()); lock.acquire()
res = bs.send_to_bg(dict(base), "겹친 글")
lock.release()
assert not res["ok"] and "이미 보내는 중" in res["message"] and calls() == [], res
# 대화 기록을 모르면 들어갔는지 확인할 수 없으므로 보내지 않는다
res = bs.send_to_bg(dict(base, transcript=None), "글")
assert not res["ok"] and "claude attach abcd1234" in res["message"] and calls() == [], res
# 쓸 수 없는 문자(짝 없는 서로게이트)는 친절한 오류
res = bs.send_to_bg(dict(base), "글 \ud800")
assert not res["ok"] and "문자" in res["message"] and calls() == [], res
# 멈춘 세션만 --resume
res = bs.send_to_bg(dict(base, live=False, pid=None, status=None, bg_state="done"), "다시 시작")
assert res["ok"], res
assert cmds(calls()) == ["--bg --resume abcd1234-0000-4000-8000-000000000001 다시 시작"]
res = bs.send_to_bg(dict(base, short_id="x; rm -rf /"), "글")
assert not res["ok"] and calls() == [], res  # 이상한 id로는 붙지 않는다
' "$ROOT/scripts/board/board-server.py" "$BA3_T/bin" "$BA3_T/cwd" || fail "a running background session gets the reply through claude attach, never a --resume copy"
# 화면: 입력을 기다리는 bg 세션(그리고 멈춘 세션)에만 보내기를 열고, 나머지는 attach 안내(명령 복사 버튼은 이미 있다).
BA3_WORK="$(sed -n '/^    | .actions = /,/\]'"'"' <<</p' "$ROOT/scripts/board/work.sh")"
assert_contains "$BA3_WORK" '(.status == "idle" and .state != "blocked") or .pid == null' "work.sh offers send only to background sessions waiting for input and stopped ones"
assert_contains "$(<"$ROOT/scripts/board/template.html")" "claude attach" "the board tells how to answer a background session that waits at a prompt"
pass "a running background session gets replies through claude attach, a stopped one through --resume, a prompt-waiting one gets the attach hint"

# 갱신 비용(#380): 다음 갱신은 직전 수집 시간의 두 배 뒤(수집이 시간의 절반을 넘지 않게), 값싼 변경 지문이 같으면 전체 수집을
# 건너뛰되 최소 주기(BOARD_FULL_REFRESH_SECONDS)마다는 모은다. 마지막 결과는 0600 스냅숏으로 남겨 다시 띄우면 그것부터 보인다.
BRC_T="$TEST_TMP/board-refresh-cost"
mkdir -p "$BRC_T/data/harvest-auto" "$BRC_T/cfg/sessions" "$BRC_T/cfg/jobs/j1" "$BRC_T/home"
printf '{}\n' >"$BRC_T/cfg/sessions/1.json"
printf '{}\n' >"$BRC_T/cfg/jobs/j1/state.json"
printf 'a\n' >"$BRC_T/t.jsonl"
HOME="$BRC_T/home" HARNESS_METRICS_DIR="$BRC_T/data" BOARD_REFRESH_SECONDS=0.2 BOARD_FULL_REFRESH_SECONDS=30 \
  BOARD_CLAUDE_CONFIG_DIRS="$BRC_T/cfg" BOARD_CLAUDE_PROFILE_GLOBS="$BRC_T/none/*" python3 -I -B -c '
import importlib.util, json, os, stat, sys, time
def load():
    spec = importlib.util.spec_from_file_location("bs", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m); return m
T, data = sys.argv[2], os.environ["HARNESS_METRICS_DIR"]
bs = load()
assert bs.restore_snapshot() is False  # 서버가 뜰 때 부른다. 스냅숏이 없으면 아무것도 올리지 않는다
calls = []
def slow_build(cached=False):
    calls.append(cached); time.sleep(0.4)
    return {"items": [{"id": "n%d" % len(calls), "transcript": T + "/t.jsonl"}], "snapshot_at": None}
bs._build = slow_build
fp = [("a", "t")]
real_fp, bs.fingerprint = bs.fingerprint, lambda: fp[0]
bs._active["at"] = time.time()
bs.refresh_once()
assert calls == [True], calls  # 백그라운드 갱신은 status.sh의 입력 캐시를 쓴다
assert bs.refresh_wait() <= max(0.5, bs.REFRESH) + 0.01, bs.refresh_wait()  # 지문 확인은 느린 수집 뒤에도 REFRESH마다
bs._cache["at"] = time.time() - 5
bs.refresh_once()
assert len(calls) == 1, calls  # 지문이 같으면 건너뛴다
assert time.time() - bs._cache["at"] < 1  # 확인한 캐시는 새것으로 친다(요청이 그 자리에서 모으지 않게)
# 지문이 바뀌어도 직전 수집 시작 뒤 그 수집 시간의 두 배가 지나기 전에는 모으지 않고, 열리는 때에 맞춰 다시 본다
bs._timing.update(start=time.time(), dur=1.0)
fp[0] = ("b", "t"); bs._cache["at"] = time.time() - 5
bs.refresh_once()
assert len(calls) == 1 and bs._pending["at"] is not None, (calls, bs._pending)
assert bs.refresh_wait() <= max(0.5, bs.REFRESH) + 0.01, bs.refresh_wait()
bs._timing["start"] -= 3
bs.refresh_once()
assert len(calls) == 2 and bs._pending["at"] is None, calls  # 쉬는 시간이 지나면 바로 모은다
fp[0] = ("b", "t2"); bs._cache["at"] = time.time() - 5
bs.refresh_once()
assert len(calls) == 2, calls  # 대화 기록만 바뀌었으면(일하는 세션) TRANSCRIPT_REFRESH 안에서는 건너뛴다
bs._cache["at"] = time.time() - 5; bs._full["at"] = time.time() - bs.TRANSCRIPT_REFRESH - 1; bs._timing["dur"] = 0
bs.refresh_once()
assert len(calls) == 3, calls  # 그 뒤에는 모은다
bs._cache["at"] = time.time() - 5; bs._full["at"] = time.time() - bs.FULL_REFRESH - 1; bs._timing["dur"] = 0
bs.refresh_once()
assert len(calls) == 4, calls  # 지문이 같아도 최소 주기마다는 모은다
bs.worktree_candidates = lambda items: []  # 개발 머신의 실제 Orca·git worktree를 읽지 않게
# 정리(B1): 지문 확인은 캐시 시각만 새로 매기므로, 실제 일괄 정리는 나이와 관계없이 입력 캐시 없이 새로 모은다
bs._cache["at"] = time.time() - 5; bs.refresh_once()  # 건너뛴 확인 직후
n = len(calls)
bs.bulk_cleanup({"older_days": 1})
assert len(calls) == n + 1 and calls[-1] is False, calls
bs._cache["data"] = None
bs.status()
assert calls[-1] is False, calls  # 동작 뒤 비운 캐시는 입력 캐시 없이 새로 모은다
# 진짜 지문: 하네스 기록·세션 상태 파일·보이는 세션의 대화 기록이 바뀌면 달라진다
bs.fingerprint = real_fp
a = bs.fingerprint()
assert a == bs.fingerprint()
time.sleep(1.1)
with open(T + "/t.jsonl", "a") as f: f.write("b\n")
b = bs.fingerprint(); assert b != a
with open(data + "/harvest-auto/runs.jsonl", "a") as f: f.write("{}\n")
c = bs.fingerprint(); assert c != b
with open(T + "/cfg/sessions/2.json", "w") as f: f.write("{}")
d = bs.fingerprint(); assert d != c
with open(T + "/cfg/jobs/j1/state.json", "a") as f: f.write(" ")
assert bs.fingerprint() != d
# 스냅숏: 0600 파일, 다시 띄우면 첫 응답은 수집을 기다리지 않는 스냅숏
snap = os.path.join(data, "board", "snapshot.json")
assert stat.S_IMODE(os.stat(snap).st_mode) == 0o600, oct(os.stat(snap).st_mode)
saved = json.load(open(snap))
bs2 = load(); fresh = []
bs2._build = lambda cached=False: (fresh.append(1), {"items": [{"id": "fresh"}], "snapshot_at": None})[1]
assert bs2.restore_snapshot() is True
t0 = time.time(); d = bs2.status()
assert not fresh and time.time() - t0 < 0.5, fresh
assert [i["id"] for i in d["items"]] == [i["id"] for i in saved["items"]], d
assert d["snapshot_at"], d  # 화면이 "N분 전 상태 — 새로 모으는 중"을 보인다
assert bs2._wake.is_set()  # 바로 새로 모으도록 깨운다
bs2._active["at"] = time.time()
bs2.fingerprint = lambda: ("same", "x"); bs2._fp["last"] = ("same", "x")
bs2.refresh_once()
assert fresh, "a restored snapshot is replaced by a fresh collection even when the fingerprint did not change"
d = bs2.status()
assert d["items"][0]["id"] == "fresh" and d["snapshot_at"] is None, d
os.remove(snap)
bs3 = load(); bs3._build = lambda cached=False: {"items": [], "snapshot_at": None}
assert bs3.status()["snapshot_at"] is None  # 스냅숏이 없으면 예전처럼 그 자리에서 모은다
' "$ROOT/scripts/board/board-server.py" "$BRC_T" || fail "the board refresh backs off after slow collections, skips unchanged inputs within the full-refresh period and restores the last snapshot first"
# status.sh가 받는 환경: 백그라운드 갱신만 BOARD_CACHE_SECONDS를 넘긴다
assert_contains "$(sed -n '/^def _build(/,/^    data = json.loads/p' "$ROOT/scripts/board/board-server.py")" "BOARD_CACHE_SECONDS" "the background refresh lets status.sh reuse unchanged inputs"
BRC_TPL="$(<"$ROOT/scripts/board/template.html")"
assert_contains "$BRC_TPL" "새로 모으는 중" "the board says the list is a saved snapshot being refreshed"
assert_contains "$BRC_TPL" "data.snapshot_at" "the board reads when the snapshot was taken"
pass "board refresh backs off, skips unchanged inputs and opens with the last snapshot"

# status.sh·work.sh 입력 캐시(#380): BOARD_CACHE_SECONDS가 있으면 하네스 기록(무인 실행·러너·대기열)이 그대로일 때 지난 결과를,
# 설정 폴더의 세션 상태 파일(sessions/·jobs/)이 그대로일 때 지난 claude agents 결과를 그 초 동안 다시 쓴다. 없으면(기본) 늘 새로.
BSC_T="$TEST_TMP/board-status-cache"
mkdir -p "$BSC_T/bin" "$BSC_T/data/harvest-auto" "$BSC_T/data/board" "$BSC_T/cfg/sessions" "$BSC_T/projects"
BSC_REAL_JQ="$(command -v jq)"
cat >"$BSC_T/bin/jq" <<'FAKE'
#!/usr/bin/env bash
printf 'jq\n' >>"$FAKE_JQ_LOG"
exec "$REAL_JQ" "$@"
FAKE
cat >"$BSC_T/bin/claude" <<'FAKE'
#!/usr/bin/env bash
[[ "$1" == agents ]] || exit 1
printf 'agents\n' >>"$FAKE_CLAUDE_LOG"
echo '[]'
FAKE
chmod +x "$BSC_T/bin/jq" "$BSC_T/bin/claude"
bsc_fin() { jq -cn --arg at "$(jq -rn --argjson m "$1" '(now - $m * 60) | floor | todate')" --arg p "$2" \
  '{at: $at, event: "finished", project: $p, batch: "b", scope: "project", result: "left_for_user", exit_code: 0, artifact: null, log: null}'; }
bsc_fin 30 p1 >"$BSC_T/data/harvest-auto/runs.jsonl"
bsc_status() {
  : >"$BSC_T/jq.log"; : >"$BSC_T/claude.log"
  env -u CLAUDE_CONFIG_DIR PATH="$BSC_T/bin:$PATH" REAL_JQ="$BSC_REAL_JQ" FAKE_JQ_LOG="$BSC_T/jq.log" FAKE_CLAUDE_LOG="$BSC_T/claude.log" \
    HARNESS_METRICS_DIR="$BSC_T/data" HARNESS_CLAUDE_PROJECTS_DIR="$BSC_T/projects" HOME="$BSC_T/home" \
    BOARD_CLAUDE_PROFILE_GLOBS="$BSC_T/none/*" BOARD_CLAUDE_CONFIG_DIRS="$BSC_T/cfg" "$@" bash "$ROOT/scripts/board/status.sh"
}
BSC_COLD="$(bsc_status BOARD_CACHE_SECONDS=600)"
BSC_COLD_JQ="$(wc -l <"$BSC_T/jq.log" | tr -d ' ')"
assert_eq "1" "$(jq '[.items[] | select(.project == "p1")] | length' <<<"$BSC_COLD")" "the cold run lists the harness run"
BSC_WARM="$(bsc_status BOARD_CACHE_SECONDS=600)"
BSC_WARM_JQ="$(wc -l <"$BSC_T/jq.log" | tr -d ' ')"
assert_eq "$(jq -c 'del(.generated_at)' <<<"$BSC_COLD")" "$(jq -c 'del(.generated_at)' <<<"$BSC_WARM")" "a warm run prints the same status"
[ "$BSC_WARM_JQ" -lt $((BSC_COLD_JQ / 2)) ] || fail "a warm run reuses the harness part (jq calls cold=$BSC_COLD_JQ warm=$BSC_WARM_JQ)"
assert_eq "0" "$(grep -c agents "$BSC_T/claude.log")" "a warm run reuses claude agents while the session state files are unchanged"
for f in "$BSC_T/data/board/"status-cache* "$BSC_T/data/board/"agents-cache*; do
  [ -e "$f" ] || continue
  assert_eq "" "$(find "$f" -perm -g+r 2>/dev/null; find "$f" -perm -o+r 2>/dev/null)" "status caches are readable only by the user: $f"
done
bsc_fin 5 p2 >>"$BSC_T/data/harvest-auto/runs.jsonl"
assert_eq "1" "$(bsc_status BOARD_CACHE_SECONDS=600 | jq '[.items[] | select(.project == "p2")] | length')" "a new harness record is picked up at once"
printf '{}\n' >"$BSC_T/cfg/sessions/9.json"
bsc_status BOARD_CACHE_SECONDS=600 >/dev/null
assert_eq "1" "$(grep -c agents "$BSC_T/claude.log")" "a changed session state file asks that folder's claude agents again (only that folder)"
bsc_status >/dev/null
assert_eq "2" "$(grep -c agents "$BSC_T/claude.log")" "without BOARD_CACHE_SECONDS every folder is asked again"
pass "status.sh and work.sh reuse unchanged harness records and session lists only when the board asks"

# '세션으로 열기'가 띄우는 세션 이름은 원문 로그 제목이 아니라 시그니처다(#296): 원문 로그가 세션 이름·카드 제목으로 새지 않고, 시그니처로 에러 카드와 이어진다.
BO_DATA="$TEST_TMP/board-open-agent"
mkdir -p "$BO_DATA"
HARNESS_METRICS_DIR="$BO_DATA" python3 -I -B -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("bs", sys.argv[1]); bs = importlib.util.module_from_spec(spec); spec.loader.exec_module(bs)
got = {}
bs.new_bg = lambda cwd, prompt, name=None: got.update(cwd=cwd, name=name) or {"ok": True, "message": "ok"}
raw = "2026-11-11 23:59:04.078 ERROR 12345 --- [nio-8080-exec-1] c.a.s.FooService : 주문 저장 실패"
af = {"id": "autofix:orders:datadog:7c1e5a9b3d2f4e60", "kind": "autofix", "section": "autofix", "project": "orders", "signature": "datadog:7c1e5a9b3d2f4e60",
      "title": raw, "repo": "/work/acme/orders", "actions": ["open_agent"], "stage": "skipped", "stage_label": "건너뜀", "link": None, "detail": "요약"}
bs.run_action(af, "open_agent", {})
assert got["name"] == "orders 에러 이어 보기 datadog:7c1e5a9b3d2f4e60", got
assert "FooService" not in got["name"] and "12345" not in got["name"], got
named = {"id": "w1", "section": "work", "project": "orders", "title": got["name"], "detail": ""}
bs.link_autofix_sessions([af, named])
assert af.get("session_id") == "w1" and named.get("autofix_id") == af["id"], (af, named)
harness = {"id": "harvest|docs|t", "kind": "harvest", "section": "harness", "project": "docs", "title": "개선 — draft PR 검토", "repo": "/work/acme/docs",
           "actions": ["open_agent"], "link": "https://example.com/acme/docs/pull/77"}
bs.run_action(harness, "open_agent", {})
assert got["name"] == "docs 개선 — draft PR 검토", got  # 하네스 카드의 세션 이름은 그대로
' "$ROOT/scripts/board/board-server.py" || fail "open_agent names an autofix session by project and signature, not by the raw error title, and the card still links to it"
pass "board names the session opened from an autofix card by signature, not by the raw log title"

# 보드 화면(#296, 정적): 정리 즉시 반영·남은 이유·실패 카드·빈 로그·무변경 요약·자동 수정 제목이 template.html에 들어갔다.
BOARD_TPL2="$(<"$ROOT/scripts/board/template.html")"
# 정리 응답 뒤에는 정리된 것(ok)만 숨김에 남는다 — 그 사이 다시 돌기 시작해 서버가 뺀 세션도 바로 되돌아온다.
for BOARD_PART2 in "hiding.has(" "hiding.add(" "hiding.delete(" "res.results.filter((x) => x.ok)" "quiet_runs" "log_note" "fail_reason" "streak"; do
  assert_contains "$BOARD_TPL2" "$BOARD_PART2" "the board screen uses $BOARD_PART2"
done
[[ "$(grep -c -E '\.left\b' <<<"$BOARD_TPL2" || true)" -ge 2 ]] || fail "the cleanup plan screen and the result screen both show the reasons items were left"
if command -v node >/dev/null 2>&1; then
  # 자동 수정 제목: Spring Boot 로그 머리(pid --- [thread] logger :)도 걷어 낸다. 함수 본문만 잘라 실행한다.
  sed -n '/function humanTitle(raw) {/,/^  }$/p' "$ROOT/scripts/board/template.html" >"$TEST_TMP/human-title.js"
  printf '%s\n' 'console.log(JSON.stringify([
    humanTitle("2026-11-11 23:59:04.078 ERROR 12345 --- [nio-8080-exec-1] c.a.s.FooService : 주문 저장 실패"),
    humanTitle("2026-11-11 23:59:04.078  WARN 4242 --- [           main] c.a.OrderService : 결제 승인 실패"),
    humanTitle("2026-11-11 23:59:04.078 ERROR 12345 --- [shop] [nio-8080-exec-1] c.a.s.PayService : 환불 처리 실패"),
    humanTitle("2026-11-10 09:14:15.264 ERROR trace_id:4af2c9e1b7d84a0f9c3e - CartController:88: 장바구니 합계 계산에 실패했습니다. cartSn: 1042")]))' >>"$TEST_TMP/human-title.js"
  assert_eq '["주문 저장 실패","결제 승인 실패","환불 처리 실패","장바구니 합계 계산에 실패했습니다"]' "$(node "$TEST_TMP/human-title.js")" "a Spring Boot log head is stripped to the human message, other log heads still are"
fi
pass "board screen carries instant hiding, left reasons, failure cards, quiet runs and Spring Boot title cleanup"

# 화면 확인용 가짜 데이터(#296): 실패 streak 카드·quiet_runs·정리 left·Spring Boot 형식 제목이 있어 브라우저로 볼 수 있다. 가짜 값만.
python3 -I -B -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("pv", sys.argv[1]); pv = importlib.util.module_from_spec(spec); spec.loader.exec_module(pv)
s = pv.status("demo")
fail = [i for i in s["items"] if i.get("fail_reason")]
assert len(fail) == 1 and fail[0]["kind"] == "sync" and fail[0]["state"] == "needs_human" and fail[0]["streak"] == 3, fail
assert fail[0]["log"] is None and fail[0]["log_note"] and fail[0]["fail_reason"] == "45분 시간 제한으로 중단됨" and fail[0]["exit_code"] == 143, fail
assert s["quiet_runs"] and all({"kind", "count", "last_at"} <= set(q) for q in s["quiet_runs"]), s.get("quiet_runs")
assert any(i["kind"] == "autofix" and " --- [" in i["title"] and "ERROR" in i["title"] for i in s["items"]), "a Spring Boot style autofix title"
for req in ({"dry_run": True, "older_days": 1}, {"older_days": 1}):
    r = pv.bulk("demo", dict(req, t="demo"))
    assert r["left"] and all({"reason", "count", "label"} <= set(l) and l["count"] > 0 for l in r["left"]), r
assert pv.status("empty")["quiet_runs"] == []
' "$ROOT/tests/fixtures/board-preview/serve.py" || fail "the board preview server has the failure streak card, quiet runs, cleanup reasons and a Spring Boot style title"
pass "board preview fixture reproduces the #296 screens with fake data"

# 보드 정확도(#299) — harvest 대기열: 무인 실행이 batch마다 남긴 시도 표시로 다음 실행에서 실제로 돌 batch만 카드로 낸다.
# 같은 batch가 이미 하네스 없음·세션 수만·포기·실행됨으로 끝났으면 카드 대신 이유별 수(queue_hidden)로만 센다. batch 파일은 그대로 둔다.
BA_T="$TEST_TMP/board-accuracy"
BA_DATA="$BA_T/data"
mkdir -p "$BA_T/bin" "$BA_DATA"
ba_batch() { # $1=폴더 $2=project $3=batch_id $4=시도 표시 batch_id(없으면 -) $5=시도 결과
  mkdir -p "$BA_DATA/harvest-queue/$1"
  jq -cn --arg p "$2" --arg b "$3" '{project: $p, batch_id: $b, has_analysis_batch: true, created_at: "2026-11-01T00:00:00Z", counts: {sessions: 4}, reasons: ["errors"]}' \
    >"$BA_DATA/harvest-queue/$1/analysis-batch.json"
  [[ "$4" == - ]] || jq -cn --arg b "$4" --arg r "$5" '{batch_id: $b, at: "2026-11-02T00:00:00Z", result: $r, fails: 0}' >"$BA_DATA/harvest-queue/$1/auto-attempted-batch"
}
ba_batch p-home home b1 b1 no_harness
ba_batch p-notes notes b2 b2 sessions_only
ba_batch p-ran ran b3 b3 launched
ba_batch p-gone gone b4 b4 gave_up
ba_batch p-old2 old2 b5 b5 no_harness
ba_batch p-next next b6 b0 launched
ba_batch p-new new b7 - -
ba_batch p-retry retry b8 b8 failed
cat >"$BA_T/bin/claude" <<'FAKE'
#!/usr/bin/env bash
if [[ "$1" == agents ]]; then cat "$BA_AGENTS" 2>/dev/null || echo "[]"; exit 0; fi
exit 1
FAKE
chmod +x "$BA_T/bin/claude"
# 워크플로 러너: incomplete로 멈춘 것, running인데 실행 폴더에 오래 기록이 없는 것, 방금 기록이 있는 running.
ba_run() { # $1=run 폴더 $2=status $3=node
  mkdir -p "$BA_DATA/runs/$1"
  jq -cn --arg s "$2" --arg n "$3" --arg r "$BA_T/repo-$1" '{run_id: "r1", workflow: "feature", status: $s, node: $n, repo: $r, request: "가짜 요청", started_at: "2026-11-01T00:00:00Z"}' \
    >"$BA_DATA/runs/$1/state.json"
  printf 'x\n' >"$BA_DATA/runs/$1/progress.log"
}
ba_run a/1 incomplete publish
ba_run b/1 running discover
ba_run c/1 running repair
ba_run d/1 baseline_changed approval
jq '.needs_user_decision = true' "$BA_DATA/runs/d/1/state.json" >"$BA_T/d.json" && mv "$BA_T/d.json" "$BA_DATA/runs/d/1/state.json"
touch -t 202601010000 "$BA_DATA/runs/b/1/state.json" "$BA_DATA/runs/b/1/progress.log"
ba_status() {
  env -u CLAUDE_CONFIG_DIR PATH="$BA_T/bin:$PATH" BA_AGENTS="$BA_T/agents.json" HARNESS_METRICS_DIR="$BA_DATA" HARNESS_CLAUDE_PROJECTS_DIR="$BA_T/projects" \
    BOARD_CLAUDE_PROFILE_GLOBS="$BA_T/none/*" BOARD_CLAUDE_CONFIG_DIRS= "$@" bash "$ROOT/scripts/board/status.sh"
}
BA_OUT="$(ba_status)"
assert_eq "new,next,retry" "$(jq -r '[.items[] | select(.kind == "harvest" and .state == "queued") | .project] | sort | join(",")' <<<"$BA_OUT")" \
  "only batches the next unattended run will take are queued cards"
assert_eq "gave_up:1|launched:1|no_harness:2|sessions_only:1" "$(jq -r '[.queue_hidden[] | "\(.reason):\(.count)"] | sort | join("|")' <<<"$BA_OUT")" \
  "batches that will not run are counted by reason instead of shown"
assert_file "$BA_DATA/harvest-queue/p-home/analysis-batch.json"
pass "board status queues only the harvest batches the next run takes and counts the rest by reason"

# 러너: 프로세스 기록(pid)이 없어 실행 폴더의 마지막 기록 시각을 본다. 중단(incomplete)·오래 조용한 running은 '중단됨'과 이어 가는 명령.
assert_eq "blocked|incomplete|workflow-driver.sh resume --workflow feature" "$(jq -r '.items[] | select(.kind == "runner" and (.cwd | endswith("repo-a/1"))) | "\(.state)|\(.stall)|\(.cmd)"' <<<"$BA_OUT")" \
  "an incomplete runner is stopped, not working"
assert_eq "blocked|no_activity" "$(jq -r '.items[] | select(.kind == "runner" and (.cwd | endswith("repo-b/1"))) | "\(.state)|\(.stall)"' <<<"$BA_OUT")" \
  "a running runner with no record for a long time is stopped"
assert_eq "running|null" "$(jq -r '.items[] | select(.kind == "runner" and (.cwd | endswith("repo-c/1"))) | "\(.state)|\(.stall)"' <<<"$BA_OUT")" \
  "a runner that just wrote its record is still working"
assert_eq "needs_human" "$(jq -r '.items[] | select(.kind == "runner" and (.cwd | endswith("repo-d/1"))) | .state' <<<"$BA_OUT")" \
  "a runner stopped because the repository changed after it stopped waits for a person (#371)"
assert_eq "null" "$(jq -r '.items[] | select(.kind == "runner" and (.cwd | endswith("repo-d/1"))) | .cmd' <<<"$BA_OUT")" \
  "a baseline-changed run does not offer approve even when a polish measurement awaited a decision (#371)"
assert_eq "running" "$(ba_status BOARD_RUNNER_STALE_MIN=99999999 | jq -r '.items[] | select(.kind == "runner" and (.cwd | endswith("repo-b/1"))) | .state')" \
  "BOARD_RUNNER_STALE_MIN sets how long a quiet runner still counts as working"
pass "board status shows a dead or incomplete workflow runner as stopped"

# 러너 상태(#564): 아는 status마다 알맞은 칸·명령으로 분류한다. 사람 결정·승인·불변식 위반은 사람 필요, stopped는 이어 가기, 포기·fix_list는 끝남, 모르는 status는 막힘이고 어느 것도 '작업 중'이 아니다.
B5_T="$BA_T/data564"
b5_run() { # $1=데이터 폴더 $2=run 폴더 $3=status $4=node $5=추가 jq
  mkdir -p "$1/runs/$2"
  jq -cn --arg s "$3" --arg n "$4" --arg r "$BA_T/repo-$2" '{run_id: "r1", workflow: "feature", status: $s, node: $n, repo: $r, request: "가짜 요청", started_at: "2026-11-01T00:00:00Z"}' \
    | jq -c "${5:-.}" >"$1/runs/$2/state.json"
  printf 'x\n' >"$1/runs/$2/progress.log"
}
b5_item() { # $1=데이터 폴더 $2=run 폴더 $3=jq 출력식 나머지는 ba_status 환경
  local d="$1" r="$2" f="$3"
  shift 3
  ba_status HARNESS_METRICS_DIR="$d" "$@" | jq -r --arg r "repo-$r" ".items[] | select(.kind == \"runner\" and (.cwd | endswith(\$r))) | $f"
}
B5_NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$B5_T"
b5_run "$B5_T" ud/1 user_decision user_decision ".message = \"결정 필요 이유\" | .finished_at = \"$B5_NOW\""
b5_run "$B5_T" wa/1 waiting_approval approval ".presented_at = \"$B5_NOW\""
b5_run "$B5_T" iv/1 invariant_violation invariant_violation ".message = \"불변식 위반\" | .finished_at = \"$B5_NOW\""
b5_run "$B5_T" st/1 stopped fix ".finished_at = \"$B5_NOW\""
b5_run "$B5_T" ab/1 abandoned brief ".started_at = \"$B5_NOW\""
b5_run "$B5_T" zz/1 weird_unknown review ".started_at = \"$B5_NOW\""
b5_run "$B5_T" fl/1 fix_list brief ".started_at = \"$B5_NOW\""
B5_ITEMS="$(ba_status HARNESS_METRICS_DIR="$B5_T" | jq -c '[.items[] | select(.kind == "runner")]')"
b5_get() { jq -r --arg r "repo-$1" ".[] | select(.cwd | endswith(\$r)) | $2" <<<"$B5_ITEMS"; }
assert_eq "needs_human|null" "$(b5_get ud/1 '"\(.state)|\(.cmd)"')" "a user_decision runner waits for a person with no command"
assert_contains "$(b5_get ud/1 .detail)" "결정 필요 이유" "a user_decision runner shows its message"
assert_eq "needs_human|workflow-driver.sh approve --run r1" "$(b5_get wa/1 '"\(.state)|\(.cmd)"')" "a waiting_approval runner offers approve"
assert_eq "needs_human|null" "$(b5_get iv/1 '"\(.state)|\(.cmd)"')" "an invariant_violation runner waits for a person"
assert_contains "$(b5_get iv/1 .detail)" "불변식 위반" "an invariant_violation runner shows its message"
assert_eq "blocked|stopped|workflow-driver.sh resume --workflow feature" "$(b5_get st/1 '"\(.state)|\(.stall)|\(.cmd)"')" "a stopped runner is stopped and offers resume"
assert_eq "done" "$(b5_get ab/1 .state)" "a recent abandoned runner is done"
assert_contains "$(b5_get ab/1 .detail)" "abandoned" "an abandoned runner detail keeps the original status"
assert_eq "done" "$(b5_get fl/1 .state)" "a recent fix_list runner is done"
assert_contains "$(b5_get fl/1 .detail)" "fix_list" "a fix_list runner detail keeps the original status"
assert_eq "blocked|null" "$(b5_get zz/1 '"\(.state)|\(.cmd)"')" "an unknown runner status is blocked, not working"
assert_contains "$(b5_get zz/1 .detail)" "weird_unknown" "an unknown runner status shows the original value"
assert_eq "0" "$(jq '[.[] | select(.state == "running")] | length' <<<"$B5_ITEMS")" "none of these runner statuses count as running"
pass "board status classifies each workflow runner status instead of calling it running"

# 결정 대기 나이(#564): 오래 방치된 결정 대기는 '사람 필요'로 계속 두지 않고 막힘(decision_stale)으로 내린다. 기준은 BOARD_DECISION_STALE_DAYS(기본 7).
B5_OLD="$BA_T/data564-old"
b5_run "$B5_OLD" old/1 await_approval await_approval '.needs_user_decision = true | .presented_at = "2026-01-01T00:00:00Z"'
b5_run "$B5_OLD" new/1 await_approval await_approval ".needs_user_decision = true | .presented_at = \"$B5_NOW\""
assert_eq "blocked|decision_stale|workflow-driver.sh approve --run r1" "$(b5_item "$B5_OLD" old/1 '"\(.state)|\(.stall)|\(.cmd)"')" \
  "a decision wait older than the limit is stale but still offers approve"
assert_eq "needs_human" "$(b5_item "$B5_OLD" new/1 .state)" "a decision wait presented just now still waits for a person"
assert_eq "needs_human" "$(b5_item "$B5_OLD" old/1 .state BOARD_DECISION_STALE_DAYS=99999)" "BOARD_DECISION_STALE_DAYS raises how long a decision wait stays with a person"
pass "board status marks a long-waiting runner decision as stale"

# 입력 캐시(#564): BOARD_DECISION_STALE_DAYS가 판정을 바꾸므로 캐시 키에 들어가야 한다. 같은 캐시 아래에서 이 값만 바꿔도 결과가 바뀐다.
B5_CACHE="$BA_T/data564-cache"
b5_run "$B5_CACHE" old/1 await_approval await_approval '.needs_user_decision = true | .presented_at = "2026-01-01T00:00:00Z"'
assert_eq "blocked" "$(b5_item "$B5_CACHE" old/1 .state BOARD_CACHE_SECONDS=600)" "the first run with the cache on sees the stale decision"
assert_eq "needs_human" "$(b5_item "$B5_CACHE" old/1 .state BOARD_CACHE_SECONDS=600 BOARD_DECISION_STALE_DAYS=99999)" \
  "changing only BOARD_DECISION_STALE_DAYS does not reuse the cached result"
pass "board status input cache key includes BOARD_DECISION_STALE_DAYS"

# 러너 카드 link(#588): 끝나지 않은 러너도 publish.pr_url이 있으면 카드 link로 실어야 보드가 PR 상태(병합·닫힘)를 읽을 수 있다. pr_url이 없으면 null.
B5_LINK="$BA_T/data588"
b5_pr() { printf '.publish.pr_url = "https://github.com/acme/shop/pull/%s" | .finished_at = "%s"' "$1" "$B5_NOW"; }
mkdir -p "$B5_LINK"
b5_run "$B5_LINK" ud/1 user_decision user_decision "$(b5_pr 601)"
b5_run "$B5_LINK" st/1 stopped fix "$(b5_pr 602)"
b5_run "$B5_LINK" fa/1 failed fix "$(b5_pr 603)"
b5_run "$B5_LINK" iv/1 invariant_violation invariant_violation "$(b5_pr 604)"
b5_run "$B5_LINK" np/1 stopped fix ".finished_at = \"$B5_NOW\""
for B5_CASE in ud/1:601:needs_human st/1:602:blocked fa/1:603 iv/1:604:needs_human; do
  B5_DIR="${B5_CASE%%:*}"
  B5_N="$(cut -d: -f2 <<<"$B5_CASE")"
  assert_eq "https://github.com/acme/shop/pull/$B5_N" "$(b5_item "$B5_LINK" "$B5_DIR" .link)" "an unfinished runner ($B5_DIR) carries its publish.pr_url as link"
done
assert_eq "null" "$(b5_item "$B5_LINK" np/1 .link)" "an unfinished runner without publish.pr_url has a null link"
pass "board status carries publish.pr_url as the link of unfinished runner cards"

# 러너 카드 PR 상태(#588): 멈춘 러너(needs_human·blocked)의 PR이 러너 밖에서 병합·닫히면 prstate.apply가 done으로 내려야 한다. 열림·캐시 없음·running·agent·bg는 그대로, harness는 기존 동작.
B5_PS="$(python3 -I -B -c '
import sys, time
sys.path.insert(0, sys.argv[1])
import prstate
url = lambda n: "https://github.com/acme/shop/pull/%d" % n
now = time.time()
prstate._cache.update({url(701): {"state": "MERGED", "at": now}, url(702): {"state": "CLOSED", "at": now},
                       url(703): {"state": "OPEN", "at": now}, url(705): {"state": "MERGED", "at": now},
                       url(706): {"state": "MERGED", "at": now}, url(707): {"state": "MERGED", "at": now},
                       url(708): {"state": "MERGED", "at": now}})
cmd = "workflow-driver.sh resume --workflow feature"
def card(n, kind, state, **kw):
    d = {"section": "work", "kind": kind, "state": state, "title": "t%d" % n, "link": url(n), "cmd": cmd, "actions": ["open_agent"]}
    d.update(kw)
    return d
cases = [("runner-needs-human-merged", card(701, "runner", "needs_human")),
         ("runner-blocked-closed", card(702, "runner", "blocked", stall="stopped")),
         ("runner-needs-human-open", card(703, "runner", "needs_human")),
         ("runner-blocked-uncached", card(704, "runner", "blocked", stall="stopped")),
         ("runner-running-merged", card(705, "runner", "running")),
         ("agent-merged", card(706, "agent", "needs_human")),
         ("bg-merged", card(707, "bg", "needs_human")),
         ("harness-merged", {"section": "harness", "state": "needs_human", "title": "t708", "link": url(708), "actions": ["open_agent"]})]
prstate.apply([c for _, c in cases])
for name, c in cases:
    print("%s|%s|%s|%s|%s" % (name, c["state"], c["title"], c.get("cmd"), "stall" in c))
print("want704|%s" % (url(704) in prstate._want))
' "$ROOT/scripts/board")"
b5_ps() { grep "^$1|" <<<"$B5_PS" || true; }
assert_eq "runner-needs-human-merged|done|t701 → PR 병합됨|None|False" "$(b5_ps runner-needs-human-merged)" "a merged PR moves a person-waiting runner card to done and drops its command"
assert_eq "runner-blocked-closed|done|t702 → PR 닫힘|None|False" "$(b5_ps runner-blocked-closed)" "a closed PR moves a stopped runner card to done and drops stall and command"
assert_eq "runner-needs-human-open|needs_human|t703|workflow-driver.sh resume --workflow feature|False" "$(b5_ps runner-needs-human-open)" "an open PR leaves the runner card as it is"
assert_eq "runner-blocked-uncached|blocked|t704|workflow-driver.sh resume --workflow feature|True" "$(b5_ps runner-blocked-uncached)" "a runner card without a cached PR state is unchanged"
assert_eq "want704|True" "$(b5_ps want704)" "a runner card without a cached PR state asks for a lookup"
assert_eq "runner-running-merged|running|t705|workflow-driver.sh resume --workflow feature|False" "$(b5_ps runner-running-merged)" "a running runner card is unchanged even when its PR is merged"
assert_eq "agent-merged|needs_human|t706|workflow-driver.sh resume --workflow feature|False" "$(b5_ps agent-merged)" "an agent work card is unchanged"
assert_eq "bg-merged|needs_human|t707|workflow-driver.sh resume --workflow feature|False" "$(b5_ps bg-merged)" "a background work card is unchanged"
assert_eq "harness-merged|done|t708 → PR 병합됨|None|False" "$(b5_ps harness-merged)" "a harness card keeps moving to done when its PR is merged"
pass "prstate moves stopped runner cards to done when their PR ended outside the runner"

# 세션: 마지막 답이 API 오류인 세션은 '멈춤 — 다시 시작 필요', 작업 중인데 프로세스가 없는 세션은 '중단됨'. 정상 작업 중은 그대로.
mkdir -p "$BA_T/projects/p"
BA_NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
ba_agent() { # $1=sessionId $2=status $3=pid
  jq -cn --arg sid "$1" --arg st "$2" --argjson pid "$3" --arg cwd "$BA_T" --argjson t "$(($(date +%s) * 1000))" \
    '{sessionId: $sid, id: $sid[0:8], kind: "background", status: $st, state: "running", pid: $pid, cwd: $cwd, name: ("task " + $sid[-1:]), startedAt: $t}'
}
{ ba_agent aaaaaaaa-0000-4000-8000-000000000001 busy 4101; ba_agent aaaaaaaa-0000-4000-8000-000000000002 busy null; ba_agent aaaaaaaa-0000-4000-8000-000000000003 busy 4103; } | jq -s . >"$BA_T/agents.json"
jq -cn --arg t "$BA_NOW" '{type: "user", message: {content: "고쳐줘"}, timestamp: $t},
  {type: "assistant", isApiErrorMessage: true, message: {content: [{type: "text", text: "API Error: The response stopped arriving. The response above may be incomplete."}]}, timestamp: $t}' \
  >"$BA_T/projects/p/aaaaaaaa-0000-4000-8000-000000000001.jsonl"
jq -cn --arg t "$BA_NOW" '{type: "user", message: {content: "고쳐줘"}, timestamp: $t}, {type: "assistant", message: {content: [{type: "text", text: "고치는 중입니다"}]}, timestamp: $t}' \
  >"$BA_T/projects/p/aaaaaaaa-0000-4000-8000-000000000002.jsonl"
cp "$BA_T/projects/p/aaaaaaaa-0000-4000-8000-000000000002.jsonl" "$BA_T/projects/p/aaaaaaaa-0000-4000-8000-000000000003.jsonl"
BA_WORK="$(env -u CLAUDE_CONFIG_DIR PATH="$BA_T/bin:$PATH" BA_AGENTS="$BA_T/agents.json" HARNESS_METRICS_DIR="$BA_DATA" HARNESS_CLAUDE_PROJECTS_DIR="$BA_T/projects" \
  BOARD_CLAUDE_PROFILE_GLOBS="$BA_T/none/*" BOARD_CLAUDE_CONFIG_DIRS= bash "$ROOT/scripts/board/work.sh")"
assert_eq "1:blocked|api_error 2:blocked|no_process 3:running|null" \
  "$(jq -r '[sort_by(.sid)[] | "\(.sid[-1:]):\(.state)|\(.stall)"] | join(" ")' <<<"$BA_WORK")" \
  "an API-error session must be restarted, a working session without a process stopped, a live one keeps working"
pass "board work list shows sessions cut off by an API error or without a process as stopped"

# 읽지 않은 결과: 살아 있지 않은 백그라운드 세션의 결과는 하루가 지나면 끝난 일(idle)로 넘긴다. 최근 결과·살아 있는 세션은 그대로.
mkdir -p "$BA_T/srv/board"
printf '{}' >"$BA_T/srv/board/seen.json"
HARNESS_METRICS_DIR="$BA_T/srv" python3 -I -B -c '
import importlib.util, sys
from datetime import datetime, timedelta, timezone
spec = importlib.util.spec_from_file_location("bs", sys.argv[1]); bs = importlib.util.module_from_spec(spec); spec.loader.exec_module(bs)
iso = lambda h: (datetime.now(timezone.utc) - timedelta(hours=h)).strftime("%Y-%m-%dT%H:%M:%SZ")
items = [{"section": "work", "kind": "bg", "sid": "old", "live": False, "state": "done", "at": iso(30)},
         {"section": "work", "kind": "bg", "sid": "new", "live": False, "state": "done", "at": iso(2)},
         {"section": "work", "kind": "bg", "sid": "alive", "live": True, "state": "done", "at": iso(30)}]
got = {i["sid"]: i["state"] for i in bs.classify_work(items)}
assert got == {"old": "idle", "new": "review", "alive": "review"}, got
' "$ROOT/scripts/board/board-server.py" || fail "a finished background result older than a day moves to done; recent and live ones stay unread"
pass "board moves day-old results of ended background sessions out of unread"

# 화면(#299): 숫자는 칸 제목과 같은 단위로, 내부 식별자 제목은 사람 말로, 같은 이유 건너뜀·대기열은 묶은 뒤 자른다. 함수만 잘라 node로 실행.
BOARD_TPL3="$(<"$ROOT/scripts/board/template.html")"
for BOARD_PART3 in "queue_hidden" "i.stall" "sync_pr_no_credentials" "작업 묶음 안 작업자 질문" "세션 안 하위 에이전트" "작업자 세션"; do
  assert_contains "$BOARD_TPL3" "$BOARD_PART3" "the board screen uses $BOARD_PART3"
done
if command -v node >/dev/null 2>&1; then
  { sed -n '/function todoTally(units) {/,/^  }$/p' "$ROOT/scripts/board/template.html"
    sed -n '/function sigTitle(t, project) {/,/^  }$/p' "$ROOT/scripts/board/template.html"
    sed -n '/function headKeys(keys, max) {/,/^  }$/p' "$ROOT/scripts/board/template.html"
    printf '%s\n' 'console.log(JSON.stringify([
      todoTally([{u: 1, asks: 0}, {u: 1, asks: 4}, {u: 3, asks: 0}]),
      sigTitle("shop datadog:5b1c0d2e9f8a7b6c", "shop"), sigTitle("billing sentry:4410293", "billing"), sigTitle("주문 목록 정렬 고치기", "shop"),
      [...headKeys(["r:a", "r:a", "q:harvest", "r:a", "t:1", "t:2", "q:harvest"], 2)]]))'
  } >"$TEST_TMP/board-299.js"
  assert_eq '[{"total":3,"parts":["답할 것 2","검토할 것 1"],"asks":4},"shop 운영 에러 이어 보기 (Datadog)","billing 운영 에러 이어 보기 (Sentry)",null,["r:a","q:harvest"]]' \
    "$(node "$TEST_TMP/board-299.js")" "todo summary counts cards like the lane title and shows worker asks apart; internal titles become words; lanes cut after grouping"
fi
pass "board screen counts todo like its title, names internal titles and groups before cutting a lane"

# 미리보기 서버(#299): 위 상황을 가짜 데이터로 재현한다.
python3 -I -B -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("pv", sys.argv[1]); pv = importlib.util.module_from_spec(spec); spec.loader.exec_module(pv)
s = pv.status("demo"); items = s["items"]
assert s["queue_hidden"] and all({"reason", "count"} <= set(q) for q in s["queue_hidden"]), s.get("queue_hidden")
assert {"api_error", "no_process", "no_activity"} <= {i.get("stall") for i in items}, [i.get("stall") for i in items]
assert any(i["section"] == "work" and not i.get("autofix_id") and " datadog:" in i["title"] for i in items), "an unlinked internal-id session title"
assert any(i.get("group") and i["group"]["role"] == "worker" and i["state"] == "needs_human" for i in items), "a worker asking inside a group"
assert any(i.get("group") and i.get("subagents") for i in items), "a group card with subagents"
assert sum(1 for i in items if i.get("reason") == "sync_pr_no_credentials") >= 2, "repeated skips with one cause"
assert pv.status("empty")["queue_hidden"] == []
' "$ROOT/tests/fixtures/board-preview/serve.py" || fail "the board preview server reproduces the #299 situations"
pass "board preview fixture reproduces the #299 screens with fake data"

# 위임한 세션의 결과 유지(#465): 대화형 세션은 살아 있는 동안만 claude agents 목록에 있다. 부모 대화 기록에서 띄운 것으로 확인된
# 터미널(links.json scan handles → 짝지은 sid)의 세션이 탭을 닫아 목록에서 빠지면, transcript로 끝난 항목을 되살려 묶음·PR이 남게 한다.
# 띄운 기록이 없는 세션(사람이 직접 연 탭)은 되살리지 않는다.
WD_T="$(mkdir -p "$TEST_TMP/work-delegated" && cd "$TEST_TMP/work-delegated" && pwd -P)"
mkdir -p "$WD_T/bin" "$WD_T/projects/parent" "$WD_T/projects/child" "$WD_T/metrics/board" "$WD_T/member"
cat >"$WD_T/bin/claude" <<'FAKE'
#!/usr/bin/env bash
[[ "$1" == agents ]] || exit 1
cat "$FAKE_AGENTS"
FAKE
chmod +x "$WD_T/bin/claude"
WD_PARENT="cccccccc-0000-4000-8000-000000000001"
WD_CHILD="cccccccc-0000-4000-8000-000000000002"
WD_SOLO="cccccccc-0000-4000-8000-000000000003"
WD_NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
jq -cn --arg sid "$WD_PARENT" --arg cwd "$WD_T" --argjson t "$(($(date +%s) * 1000))" \
  '[{sessionId: $sid, id: $sid[0:8], kind: "interactive", status: "idle", pid: 4242, cwd: $cwd, startedAt: $t}]' >"$WD_T/agents.json"
jq -cn --arg t "$WD_NOW" '{type: "user", message: {content: "작업 맡겨줘"}, timestamp: $t}' >"$WD_T/projects/parent/$WD_PARENT.jsonl"
for WD_SID in "$WD_CHILD" "$WD_SOLO"; do
  { jq -cn --arg t "$WD_NOW" --arg cwd "$WD_T/member" '{type: "user", cwd: $cwd, message: {content: "#12 고쳐줘"}, timestamp: $t}'
    jq -cn '{type: "ai-title", aiTitle: "Fix the example issue"}'
    jq -cn --arg t "$WD_NOW" '{type: "assistant", message: {content: [{type: "text", text: "PR을 열었습니다."}]}, timestamp: $t}'
  } >"$WD_T/projects/child/$WD_SID.jsonl"
done
jq -cn --arg p "$WD_T/projects/parent/$WD_PARENT.jsonl" --arg c "$WD_CHILD" --arg s "$WD_SOLO" \
  '{handles: {"term_11111111-2222-3333-4444-555555555555": $c, "term_aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee": $s},
    scan: {($p): {v: 2, offset: 0, handles: ["term_11111111-2222-3333-4444-555555555555"]}}}' >"$WD_T/metrics/board/links.json"
WD_OUT="$(env -u CLAUDE_CONFIG_DIR PATH="$WD_T/bin:$PATH" FAKE_AGENTS="$WD_T/agents.json" HARNESS_METRICS_DIR="$WD_T/metrics" \
  HARNESS_CLAUDE_PROJECTS_DIR="$WD_T/projects" BOARD_CLAUDE_PROFILE_GLOBS="$WD_T/none/*" BOARD_CLAUDE_CONFIG_DIRS= bash "$ROOT/scripts/board/work.sh")"
assert_eq "done|false|member|Fix the example issue" \
  "$(jq -r --arg s "$WD_CHILD" '.[] | select(.sid == $s) | "\(.state)|\(.live)|\(.project)|\(.title)"' <<<"$WD_OUT")" \
  "a delegated session whose tab closed comes back as an ended item named after its own folder"
assert_eq "" "$(jq -r --arg s "$WD_SOLO" '.[] | select(.sid == $s) | .sid' <<<"$WD_OUT")" "a closed session no parent spawned stays out"
assert_eq "1" "$(jq -r --arg s "$WD_PARENT" '[.[] | select(.sid == $s)] | length' <<<"$WD_OUT")" "the parent is listed once"
WD_TPL="$(<"$ROOT/scripts/board/template.html")"
# shellcheck disable=SC2016  # 템플릿 리터럴을 글자 그대로 찾는다
assert_contains "$WD_TPL" '`끝남 · PR #${n}`' "a finished worker in a group reads as ended with its PR, not as resting"
assert_contains "$WD_TPL" "memberStatus(it), ago(it.at)" "group member rows use the worker status"
pass "work.sh keeps a delegated session after its tab closes"

finish_tests
