#!/usr/bin/env bash
# 회귀 테스트 — 보드 실행 중인 bg 세션에 답하기(claude attach·--resume)
# 실행: bash tests/run.sh board-status-attach
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

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

finish_tests
