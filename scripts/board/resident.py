"""보드가 띄운 새 세션을 stream-json 상주 프로세스로 쥔다(#349). 표준 라이브러리만 쓴다.

예전 경로(`claude --bg` + 답할 때마다 `--resume`)는 매번 새 프로세스가 콜드 스타트해 왕복이 8–12초 걸렸다.
여기서는 `claude -p --input-format stream-json --output-format stream-json --verbose --permission-prompt-tool stdio`를
띄워 stdin·stdout을 쥔다. 실측(Claude Code 2.1.325):
- 추가 입력은 stdin의 user 메시지 한 줄 — 같은 프로세스·같은 세션 id로 이어진다(--resume 없음).
- 권한 요청과 AskUserQuestion은 stdout의 control_request(subtype can_use_tool)로 오고, stdin에 control_response
  (behavior allow|deny, AskUserQuestion은 updatedInput.answers {질문: 고른 라벨})를 쓸 때까지 그 턴이 멈춘다.
  --permission-prompt-tool stdio가 없으면 묻지 않고 바로 거부된다.
- stdin을 닫으면 붙잡힌 요청은 "permission stream closed"로 실패하고 프로세스가 끝난다. 대화 기록은 남아
  `claude -p --resume <id>`(stream-json)로 같은 id를 이어 쥘 수 있다.
- `--resume <id>`로 띄운 stream-json은 입력이 오기 전에는 모델을 부르지 않는다(SessionStart 훅 이벤트만 나오고 init·
  대화 기록 추가 없음). 그래서 호스트가 새로 뜰 때 끝나지 않은 세션을 다시 띄워 입력 대기로 둘 수 있다(#364).
보드는 사람이 화면에서 누른 답만 돌려준다 — 스스로 허용·거부·답하지 않는다.
Residents는 보드 서버가 아니라 resident_host.py의 호스트 프로세스가 쥔다(#364). 보드가 꺼져도 세션·붙잡은 요청이 남는다.
상태가 바뀌면 notify()를 불러 호스트가 붙은 보드에 알리고, 보드는 SSE(GET /events)로 바뀐 항목을 바로 민다.
"""
import glob, json, os, queue, re, secrets, signal, subprocess, sys, threading, time, uuid
from datetime import datetime, timezone

FLAGS = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
         "--permission-prompt-tool", "stdio"]
KEEP_HOURS = 48  # 끝난 상주 세션 기록을 목록·기록 파일에 두는 시간(work.sh의 BOARD_DONE_HOURS와 같은 기본값)
MAX_TEXT = 8000
MAX_LIVE = 8  # 보드가 한꺼번에 쥐는 상주 세션 수 — 세션마다 claude 프로세스 하나라 끝없이 늘지 않게


def utc():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _summary(tool, inp):
    if not isinstance(inp, dict):
        return str(inp)[:2000]
    if tool == "Bash":
        return str(inp.get("command", ""))[:2000]
    if inp.get("file_path"):
        return str(inp["file_path"])
    return json.dumps(inp, ensure_ascii=False)[:2000]


class Hub:
    """SSE 구독자마다 큐를 하나씩 두고 이벤트를 나눈다. 큐가 넘치는(멈춘) 구독자는 떼어 낸다 — 다시 붙으면 hello부터 받는다."""

    def __init__(self):
        self._subs = []
        self._lock = threading.Lock()

    def subscribe(self):
        q = queue.Queue(maxsize=512)
        with self._lock:
            self._subs.append(q)
        return q

    def unsubscribe(self, q):
        with self._lock:
            if q in self._subs:
                self._subs.remove(q)

    def count(self):
        with self._lock:
            return len(self._subs)

    def publish(self, event, data):
        with self._lock:
            subs = list(self._subs)
        for q in subs:
            try:
                q.put_nowait((event, data))
            except queue.Full:  # 큐가 차 있어 끊김 신호를 넣을 수 없다 — 표시로 알리고 핸들러가 연결을 닫는다
                q.dead = True
                self.unsubscribe(q)


class Feed:
    """보드 목록의 바뀐 항목만 SSE로 민다. snapshot()은 board-server가 넘기는 함수로, 상태 캐시를 그대로 읽는다(모으지 않는다).
    상태를 새로 모으는 일은 board-server의 백그라운드 갱신(#351)이 맡고, 캐시를 새로 쓸 때마다 poke()한다.
    상주 세션·권한 훅도 바뀔 때 poke()한다. 구독자가 있을 때만 비교하고, poke가 없어도 interval마다 한 번 비교한다(안전망).
    비교·기준 교체는 한 lock 안에서 한다 — 먼저 읽은 낡은 목록이 나중 기준을 덮어 되살아나지 않게."""

    def __init__(self, hub, snapshot, interval=15.0):
        self.hub, self.snapshot, self.interval = hub, snapshot, interval
        self._wake = threading.Event()
        self._last = None
        self._started = False
        self._lock = threading.Lock()
        self._run = threading.Lock()

    def poke(self):
        self._wake.set()

    def ensure_running(self):
        with self._lock:
            if not self._started:
                self._started = True
                threading.Thread(target=self._loop, daemon=True).start()

    def _loop(self):
        while True:
            self._wake.wait(self.interval)
            self._wake.clear()
            if not self.hub.count():
                with self._run:
                    if not self.hub.count():
                        self._last = None
                continue
            try:
                with self._run:
                    self.push(self.snapshot())
            except Exception:
                pass

    def push(self, data):
        items = {i["id"]: i for i in data.get("items", []) if isinstance(i, dict) and i.get("id")}
        meta = {k: v for k, v in data.items() if k not in ("items", "generated_at")}
        with self._lock:
            last, self._last = self._last, (items, meta)
        if last is None:
            return
        old_items, old_meta = last
        for iid, it in items.items():
            if old_items.get(iid) != it:
                self.hub.publish("item", it)
        for iid in old_items:
            if iid not in items:
                self.hub.publish("gone", {"id": iid})
        if meta != old_meta:
            self.hub.publish("meta", meta)

    def prime(self):
        """구독자가 붙을 때, hello를 보내기 전에 비교 기준을 잡는다. 그 뒤 바뀐 것은 모두 밀리고, 그 전 상태는
        구독자가 hello를 받고 한 번 읽는 전체 목록에 들어 있다. 이미 기준이 있으면 그대로 둔다(다른 구독자 몫)."""
        with self._run:
            if self._last is None:
                self.push(self.snapshot())


class Session:
    def __init__(self, sid, cwd, name, title):
        self.sid, self.cwd, self.name, self.title = sid, cwd, name, title
        self.proc = None
        self.state = "ended"  # busy | waiting | idle | ended
        self.pending = {}  # pid -> {rid, tool, input, at}
        self.at = utc()
        self.last_text = ""
        self.transcript = None
        self.looked = 0.0
        self.seen = False  # 쉬는 세션의 결과를 사람이 읽었는가('결과 확인' → '쉬는 중')
        self.prev_pid = None  # 지난 호스트가 띄운 프로세스(기록에서). 호스트가 SIGKILL로 죽으면 잠깐 살아 있을 수 있다
        self.closed = False  # 사람이 '세션 끝내기'로 끝냈다 — 호스트가 새로 떠도 다시 띄우지 않는다
        self.interrupted = False  # 호스트가 꺼질 때 턴·권한·질문이 끊겼다 — 다시 보낼 때까지 카드에 알린다
        self.quiet = False  # --resume으로 다시 띄워 아직 입력을 받지 않았다(이때 오는 init은 턴 시작이 아니다)
        self.saved_state = None
        self.wlock = threading.Lock()
        self.slock = threading.Lock()  # 다시 띄우기가 겹쳐 같은 id 프로세스가 둘 뜨지 않게


class Residents:
    def __init__(self, data_dir, notify, claude_bin="claude"):
        self.registry = os.path.join(data_dir, "board", "residents.json")
        self.notify = notify
        self.claude_bin = claude_bin
        self._sessions = {}
        self._lock = threading.Lock()
        self._save_lock = threading.Lock()
        self._spawn_lock = threading.Lock()  # 살아 있는 수 확인 → 띄우기 → 등록을 한 묶음으로
        for sid, rec in (self._load() or {}).items():
            if isinstance(rec, dict) and isinstance(rec.get("cwd"), str):
                s = Session(sid, rec["cwd"], rec.get("name"), rec.get("title") or sid[:8])
                s.at = rec.get("at") or s.at
                s.prev_pid = rec.get("pid") if isinstance(rec.get("pid"), int) else None
                s.closed = rec.get("closed") is not False  # #364 이전 기록(키 없음)은 사람이 끝냈는지 몰라 다시 띄우지 않는다
                s.interrupted = rec.get("interrupted") is True or rec.get("state") in ("busy", "waiting")
                self._sessions[sid] = s

    # ---- 기록(보드를 다시 켜도 끝난 상주 세션을 이어 쥘 수 있게) ----
    def _load(self):
        try:
            with open(self.registry, encoding="utf-8") as f:
                data = json.load(f)
            return data if isinstance(data, dict) else {}
        except (OSError, ValueError):
            return {}

    def _save(self):
        """기록: 살아 있는 세션은 pid까지, 끝난 지 KEEP_HOURS 넘은 세션은 뺀다(목록에서도 이미 안 보인다)."""
        cut = time.time() - KEEP_HOURS * 3600
        with self._save_lock:  # 읽기 스레드·요청·종료 처리가 동시에 저장해도 먼저 복사한 낡은 목록이 나중에 덮지 않게
            with self._lock:
                for sid in [k for k, s in self._sessions.items() if s.state == "ended" and _epoch(s.at) < cut]:
                    del self._sessions[sid]
                data = {}
                for s in self._sessions.values():
                    s.saved_state = s.state
                    data[s.sid] = {"cwd": s.cwd, "name": s.name, "title": s.title, "at": s.at, "state": s.state,
                                   "closed": s.closed, "interrupted": s.interrupted,
                                   "pid": s.proc.pid if self._live(s) else s.prev_pid}
            os.makedirs(os.path.dirname(self.registry), exist_ok=True)
            tmp = self.registry + ".tmp"
            fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "w") as f:
                json.dump(data, f, ensure_ascii=False)
            os.replace(tmp, self.registry)

    # ---- 띄우기 ----
    def start(self, cwd, prompt, name=None):
        if not isinstance(cwd, str) or not os.path.isabs(cwd) or not os.path.isdir(cwd):
            return {"ok": False, "message": "작업 경로가 없거나 절대 경로가 아님"}
        if not isinstance(prompt, str) or not prompt.strip() or len(prompt) > MAX_TEXT:
            return {"ok": False, "message": "첫 지시가 비었거나 너무 김"}
        name = name[:160] if isinstance(name, str) and name.strip() else None
        sid = str(uuid.uuid4())
        s = Session(sid, cwd, name, name or " ".join(prompt.split())[:80])
        with self._spawn_lock:  # 수 세기와 띄우기·등록을 한 번에 — 동시에 온 /new가 상한을 넘지 않게
            if self._live_count() >= MAX_LIVE:
                return {"ok": False, "message": self._full_message()}
            err = self._spawn(s, ["--session-id", sid] + (["--name", name] if name else []))
            if err:
                return {"ok": False, "message": err}
            with self._lock:
                self._sessions[sid] = s
        self._save()
        self._write(s, prompt)
        self.notify()
        return {"ok": True, "message": "새 세션을 띄움 — 보드가 쥐고 있어 질문·권한이 바로 뜸", "id": "res|" + sid}

    def _spawn(self, s, extra):
        env = {**os.environ}
        env.pop("CLAUDECODE", None)
        env.pop("CLAUDE_CONFIG_DIR", None)  # new_bg와 같이 기본 설정 폴더로
        try:
            s.proc = subprocess.Popen([self.claude_bin, *FLAGS, *extra], cwd=s.cwd, env=env, text=True, bufsize=1,
                                      stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                      start_new_session=True)
        except OSError as e:
            return f"claude를 띄우지 못함: {e}"
        s.state, s.pending = "busy", {}
        threading.Thread(target=self._read, args=(s, s.proc), daemon=True).start()
        return None

    def resume_all(self, wait=5.0):
        """호스트가 새로 떴을 때(재부팅·호스트가 죽은 뒤): 사람이 끝내지 않았고 KEEP_HOURS 안인 세션을 같은 id로
        --resume해 입력 대기로 둔다. 입력 전에는 모델을 부르지 않는다. 최근 것부터 MAX_LIVE 안에서만.
        지난 호스트가 띄운 프로세스가 아직 살아 있으면(죽은 호스트의 stdin EOF를 받고 끝나는 중) wait초까지 기다리고,
        그래도 살아 있으면 두 프로세스가 같은 대화를 쓰지 않게 건너뛴다(사람이 보내면 send가 다시 확인한다)."""
        cut = time.time() - KEEP_HOURS * 3600
        cands = sorted((s for s in self._all() if s.proc is None and not s.closed and _epoch(s.at) >= cut),
                       key=lambda s: _epoch(s.at), reverse=True)
        end = time.time() + wait
        while time.time() < end and any(s.prev_pid and _alive_with(s.prev_pid, s.sid) for s in cands):
            time.sleep(0.1)
        started = []
        for s in cands:
            if s.prev_pid and _alive_with(s.prev_pid, s.sid):
                continue
            with s.slock, self._spawn_lock:
                if s.proc is not None or s.closed:  # 그 사이 사람이 보내 이미 다시 쥐었거나 끝냈다
                    continue
                if self._live_count() >= MAX_LIVE:
                    break
                if self._spawn(s, ["--resume", s.sid]):
                    continue
                s.state, s.quiet, s.prev_pid = "idle", True, None
                s.seen = not s.interrupted  # 끊긴 세션만 '결과 확인'으로 올려 눈에 띄게
            started.append(s.sid)
        if started:
            self._save()
            self.notify()
        return started

    def _write(self, s, text):
        line = json.dumps({"type": "user", "message": {"role": "user", "content": text}}, ensure_ascii=False)
        s.quiet = False
        return self._line(s, line)

    def _line(self, s, line):
        with s.wlock:
            try:
                s.proc.stdin.write(line + "\n")
                s.proc.stdin.flush()
                return True
            except (OSError, ValueError, AttributeError):
                return False

    # ---- stdout 읽기 ----
    def _read(self, s, proc):
        """stdout을 끝까지 비운다. 한 줄 처리에서 예외가 나도 다음 줄로 간다 — 이 스레드가 죽으면 stdout을 아무도
        비우지 않아 파이프가 차고 claude가 멈춘다."""
        for raw in proc.stdout:
            try:
                ev = json.loads(raw)
            except ValueError:
                continue
            if not isinstance(ev, dict) or s.proc is not proc:  # 다시 띄운 뒤 남은 이전 프로세스 출력은 버린다
                continue
            try:
                self._handle(s, ev)
            except Exception as e:
                print("resident:", type(e).__name__, e, file=sys.stderr, flush=True)
        proc.wait()
        if s.proc is proc:
            if not s.quiet:  # 입력 없이 다시 띄운 채 끝났으면(resume 실패 등) 시각을 그대로 둬 KEEP_HOURS가 지나면 빠지게
                s.at = utc()
            s.state, s.pending = "ended", {}
            self._save()
            self.notify()

    def _handle(self, s, ev):
        """stdout 한 줄(JSON 이벤트)을 세션 상태로 옮긴다."""
        t = ev.get("type")
        changed = False
        if t == "control_cancel_request":  # Claude가 거둔 요청은 붙잡은 목록에서도 뺀다
            gone = [k for k, p in list(s.pending.items()) if p["rid"] == ev.get("request_id")]
            for k in gone:
                s.pending.pop(k, None)
            if gone and not s.pending and s.state == "waiting":
                s.state = "busy"
            changed = bool(gone)
        if t == "control_request":
            req = ev.get("request") or {}
            if req.get("subtype") == "can_use_tool":
                pid = "res-" + secrets.token_hex(8)
                s.pending[pid] = {"rid": ev.get("request_id"), "tool": req.get("tool_name") or "?",
                                  "input": req.get("input") if isinstance(req.get("input"), dict) else {}, "at": utc()}
                s.state, changed = "waiting", True
            else:  # 보드가 맡지 않은 요청(훅 콜백 등)은 지원하지 않는다고 바로 알린다 — 권한 답이 아니다
                self._line(s, json.dumps({"type": "control_response", "response": {
                    "subtype": "error", "request_id": ev.get("request_id"), "error": "not supported by the board"}}))
        elif t == "assistant":
            texts = [c.get("text") for c in ((ev.get("message") or {}).get("content") or [])
                     if isinstance(c, dict) and c.get("type") == "text" and c.get("text")]
            if texts:
                s.last_text = texts[-1][:400]
            if s.state != "waiting":
                s.state = "busy"
            changed = True
        elif t == "result":
            s.state = "waiting" if s.pending else "idle"
            s.seen, changed = False, True
        elif t == "system" and ev.get("subtype") == "init" and s.state == "idle" and not s.quiet:
            s.state, changed = "busy", True
        if changed:
            s.at = utc()
            self._persist(s)
            self.notify()

    def _persist(self, s):
        """상태(작업 중·답 대기·쉼)가 바뀔 때만 기록한다 — 호스트가 갑자기 죽어도 끊긴 요청이 있었는지 남는다."""
        if s.state != s.saved_state:
            self._save()

    # ---- 사람이 보드에서 한 일 ----
    def send(self, item_id, text):
        s = self._get(item_id)
        if not s:
            return {"ok": False, "message": "보드가 쥔 세션이 아님"}
        if not isinstance(text, str) or not text.strip() or len(text) > MAX_TEXT:
            return {"ok": False, "message": f"보낼 내용이 비었거나 너무 김({MAX_TEXT}자 이하)"}
        if s.pending:
            return {"ok": False, "message": "권한·질문에 먼저 답해 주세요 — 답을 기다리는 동안 보낸 글은 그 요청의 답이 되지 않음"}
        with s.slock:
            if s.proc and s.proc.stdin and s.proc.stdin.closed:  # 막 끝낸 세션: 다 끝난 뒤 다시 쥔다
                try:
                    s.proc.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    return {"ok": False, "message": "세션이 아직 끝나는 중 — 잠시 뒤 다시 보내세요"}
            if s.state == "ended" or not s.proc or s.proc.poll() is not None:
                if s.prev_pid and _alive_with(s.prev_pid, s.sid):
                    return {"ok": False, "message": f"지난 보드가 띄운 같은 세션(pid {s.prev_pid})이 아직 돌고 있음 — "
                                                    "같은 대화를 두 프로세스가 쓰지 않게, 그 프로세스가 끝난 뒤 다시 보내세요"}
                with self._spawn_lock:
                    if self._live_count() >= MAX_LIVE:
                        return {"ok": False, "message": self._full_message()}
                    err = self._spawn(s, ["--resume", s.sid])  # 끝난 세션(보드 재시작 등): 같은 id로 다시 쥔다
                if err:
                    return {"ok": False, "message": err}
                s.prev_pid = None
            if not self._write(s, text):
                return {"ok": False, "message": "세션에 쓰지 못함 — 세션이 끝났을 수 있음"}
        s.state, s.at, s.closed, s.interrupted = "busy", utc(), False, False
        self._save()
        self.notify()
        return {"ok": True, "message": "보냄 — 같은 세션이 바로 이어서 받음"}

    def owns(self, pid):
        return isinstance(pid, str) and pid.startswith("res-") and any(pid in s.pending for s in self._all())

    def decide(self, pid, decision):
        s = next((x for x in self._all() if pid in x.pending), None)
        p = s.pending.get(pid) if s else None  # 그 사이 다른 클릭이나 세션 종료로 빠졌을 수 있다
        if not p or decision not in ("allow", "deny"):
            return {"ok": False, "message": "보드가 이 요청을 더 이상 붙잡고 있지 않음"}
        if p["tool"] == "AskUserQuestion":
            return {"ok": False, "message": "질문은 보기에서 골라 답해 주세요"}
        resp = ({"behavior": "allow", "updatedInput": p["input"]} if decision == "allow"
                else {"behavior": "deny", "message": "Harness Board에서 사람이 거부함"})
        return self._respond(s, pid, resp, "허용함 — 세션이 이어서 진행" if decision == "allow" else "거부함")

    def answer(self, item_id, pid, answers):
        s = self._get(item_id)
        p = s.pending.get(pid) if s and isinstance(pid, str) else None
        if not p or p["tool"] != "AskUserQuestion":
            return {"ok": False, "message": "보드가 이 질문을 더 이상 붙잡고 있지 않음"}
        questions = [q.get("question") for q in p["input"].get("questions", []) if isinstance(q, dict)]
        if not isinstance(answers, dict) or set(answers) != set(questions) \
                or not all(isinstance(v, str) and v.strip() and len(v) <= 2000 for v in answers.values()):
            return {"ok": False, "message": "모든 질문에 답을 골라 주세요"}
        return self._respond(s, pid, {"behavior": "allow", "updatedInput": {**p["input"], "answers": answers}},
                             "답함 — 세션이 이어서 진행")

    def _respond(self, s, pid, resp, message):
        p = s.pending.pop(pid, None)
        if p is None:
            return {"ok": False, "message": "보드가 이 요청을 더 이상 붙잡고 있지 않음"}
        ok = self._line(s, json.dumps({"type": "control_response", "response": {
            "subtype": "success", "request_id": p["rid"], "response": resp}}, ensure_ascii=False))
        if not s.pending and s.state == "waiting":
            s.state = "busy"
        s.at = utc()
        self._persist(s)
        self.notify()
        return {"ok": ok, "message": message if ok else "세션에 쓰지 못함 — 세션이 끝났을 수 있음"}

    def end(self, item_id):
        """세션을 끝낸다: stdin을 닫으면 Claude가 붙잡힌 요청을 실패로 끝내고 종료한다. 대화 기록은 지우지 않는다.
        사람이 끝낸 세션으로 기록해 호스트가 새로 떠도 다시 띄우지 않는다."""
        s = self._get(item_id)
        if not s:
            return {"ok": False, "message": "보드가 쥔 세션이 아님"}
        s.closed, s.interrupted = True, False
        self._save()
        if s.proc and s.proc.poll() is None:
            with s.wlock:
                try:
                    s.proc.stdin.close()
                except OSError:
                    pass
        return {"ok": True, "message": f"세션을 끝냄 — 대화 기록은 남음(claude --resume {s.sid})"}

    def shutdown(self, grace=3.0):
        """호스트가 SIGTERM으로 꺼질 때: 쥔 세션의 stdin을 닫아 끝내고(대화 기록은 남는다), grace 안에 안 끝나면 그룹째 SIGTERM.
        사람이 끝낸 것이 아니므로 closed로 기록하지 않는다 — 다음 호스트가 같은 id로 이어 쥔다."""
        live = [s for s in self._all() if s.proc and s.proc.poll() is None]
        for s in live:
            s.interrupted = s.interrupted or s.state in ("busy", "waiting")
            with s.wlock:
                try:
                    s.proc.stdin.close()
                except OSError:
                    pass
        end = time.time() + grace
        for s in live:
            try:
                s.proc.wait(timeout=max(0.1, end - time.time()))
            except subprocess.TimeoutExpired:
                try:  # 세션은 자기 프로세스 그룹으로 띄웠다(start_new_session) — 도구가 띄운 하위 프로세스까지 함께 끝낸다
                    os.killpg(s.proc.pid, signal.SIGTERM)
                except (ProcessLookupError, PermissionError):
                    s.proc.terminate()
        self._save()

    # ---- 목록 ----
    @staticmethod
    def _live(s):
        return s.proc is not None and s.proc.poll() is None

    def _live_count(self):
        return sum(1 for s in self._all() if self._live(s))

    def live_count(self):
        return self._live_count()

    def _full_message(self):
        return (f"보드가 쥔 세션이 이미 {MAX_LIVE}개 돌고 있음 — 다 쓴 세션을 '세션 끝내기'로 닫은 뒤 다시 시도하세요"
                "(대화 기록은 남아 나중에 이어 쥘 수 있음)")

    def _all(self):
        with self._lock:
            return list(self._sessions.values())

    def _get(self, item_id):
        if not isinstance(item_id, str) or not item_id.startswith("res|"):
            return None
        with self._lock:
            return self._sessions.get(item_id[4:])

    def _transcript(self, s):
        if s.transcript and os.path.isfile(s.transcript):
            return s.transcript
        if time.time() - s.looked < 5:  # 목록을 만들 때마다 폴더를 훑지 않게
            return None
        s.looked = time.time()
        root = os.environ.get("HARNESS_CLAUDE_PROJECTS_DIR") or os.path.join(os.path.expanduser("~"), ".claude", "projects")
        hits = glob.glob(os.path.join(glob.escape(root), "*", s.sid + ".jsonl"))
        s.transcript = hits[0] if hits else None
        return s.transcript

    def item(self, item_id):
        s = self._get(item_id)
        return self._item(s) if s else None

    def mark_seen(self, ids):
        """'결과 확인'을 읽음으로. 다음 결과가 오면 다시 '결과 확인'이 된다."""
        hit = [s for s in (self._get(i) for i in ids or []) if s and s.state == "idle"]
        for s in hit:
            s.seen = True
        if hit:
            self.notify()

    def items(self):
        cut = time.time() - KEEP_HOURS * 3600
        out = []
        for s in self._all():
            if s.state == "ended" and _epoch(s.at) < cut:
                continue
            out.append(self._item(s))
        return out

    def _item(self, s):
        live = s.state != "ended"
        state = {"busy": "running", "waiting": "needs_human", "idle": "idle" if s.seen else "review"}.get(s.state, "idle")
        it = {"section": "work", "kind": "bg", "resident": True, "agent": "claude", "id": "res|" + s.sid, "sid": s.sid,
              "short_id": s.sid[:8], "cwd": s.cwd, "project": os.path.basename(s.cwd.rstrip("/")) or s.cwd,
              "title": s.title, "detail": s.last_text, "at": s.at, "state": state, "live": live,
              "status": {"busy": "busy", "waiting": "waiting"}.get(s.state, "idle"),
              "transcript": self._transcript(s), "actions": ["send"] + (["end"] if live else []),
              "cmd": None if live else f"claude --resume {s.sid}"}
        if s.interrupted:
            it["interrupted"] = True
            it["detail"] = "호스트가 꺼질 때 끊긴 요청이 있었음 — 다시 보내 이어가기"
        for pid, p in list(s.pending.items()):
            if p["tool"] == "AskUserQuestion":
                it.setdefault("question", {"pid": pid, "questions": p["input"].get("questions") or []})
            else:
                it.setdefault("permission", {"pid": pid, "sid": s.sid, "cwd": s.cwd, "tool": p["tool"],
                                             "input": _summary(p["tool"], p["input"]), "at": p["at"]})
        return it


def _epoch(iso):
    try:
        return datetime.strptime(str(iso), "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp()
    except ValueError:
        return 0.0


def _alive_with(pid, sid):
    """그 pid가 아직 살아 있고 명령줄에 이 세션 id가 있는가(재사용된 다른 프로세스 pid는 아니라고 본다)."""
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        pass
    try:
        out = subprocess.run(["ps", "-o", "command=", "-p", str(pid)], capture_output=True, text=True, timeout=5).stdout
    except Exception:
        return True  # 확인하지 못하면 안전한 쪽(거절)으로
    return sid in out


def sse_lines(event, data):
    """SSE 한 건. data는 한 줄 JSON이라 줄바꿈이 섞이지 않는다."""
    return f"event: {event}\ndata: {json.dumps(data, ensure_ascii=False)}\n\n".encode()


_RES_ID = re.compile(r"res\|[0-9a-f-]{36}")


def is_resident_id(item_id):
    return isinstance(item_id, str) and bool(_RES_ID.fullmatch(item_id))
