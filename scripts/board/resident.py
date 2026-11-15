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
보드는 사람이 화면에서 누른 답만 돌려준다 — 스스로 허용·거부·답하지 않는다.
상태가 바뀌면 notify()를 불러 SSE(GET /events)가 바뀐 항목을 바로 밀게 한다.
"""
import glob, json, os, queue, re, secrets, subprocess, threading, time, uuid
from datetime import datetime, timezone

FLAGS = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
         "--permission-prompt-tool", "stdio"]
KEEP_HOURS = 48  # 끝난 상주 세션 기록을 목록에 보여 주는 시간(work.sh의 BOARD_DONE_HOURS와 같은 기본값)
MAX_TEXT = 8000


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
    """보드 목록의 바뀐 항목만 SSE로 민다. snapshot(fresh)는 board-server가 넘기는 함수다(fresh=False면 캐시로 빨리).
    구독자가 있을 때만 돈다: 상주 세션·권한 훅이 poke()하면 캐시로 바로 비교하고, poke가 끊이지 않아도
    interval마다 한 번은 새로 모은다(다른 터미널 세션·하네스 카드 변화가 묻히지 않게). 새로 모으기는 따로 돌려
    캐시만 데우고, 비교·전송은 언제나 캐시로 한 lock 안에서 한다 — 느린 모으기가 알림을 막지 않고,
    먼저 모은 낡은 목록이 나중 기준을 덮어 되살아나지도 않게."""

    def __init__(self, hub, snapshot, interval=5.0):
        self.hub, self.snapshot, self.interval = hub, snapshot, interval
        self._wake = threading.Event()
        self._last = None
        self._fresh_at = 0.0
        self._refreshing = False
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
            self._wake.wait(max(0.05, self._fresh_at + self.interval - time.time()))
            self._wake.clear()
            if not self.hub.count():
                self._last = None
                continue
            if time.time() - self._fresh_at >= self.interval and not self._refreshing:
                # 새로 모으기(status.sh, 수 초)는 따로 돌려 캐시만 데운다 — 그동안 들어온 알림이 그 뒤로 밀리지 않게
                self._fresh_at, self._refreshing = time.time(), True
                threading.Thread(target=self._refresh, daemon=True).start()
            try:
                with self._run:
                    self.push(self.snapshot(False))
            except Exception:
                pass

    def _refresh(self):
        try:
            self.snapshot(True)
        except Exception:
            pass
        finally:
            self._refreshing = False
            self.poke()

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
                self.push(self.snapshot(False))


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
        for sid, rec in (self._load() or {}).items():
            if isinstance(rec, dict) and isinstance(rec.get("cwd"), str):
                s = Session(sid, rec["cwd"], rec.get("name"), rec.get("title") or sid[:8])
                s.at = rec.get("at") or s.at
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
        with self._lock:
            data = {s.sid: {"cwd": s.cwd, "name": s.name, "title": s.title, "at": s.at} for s in self._sessions.values()}
        with self._save_lock:  # 읽기 스레드·요청·종료 처리가 동시에 저장해도 임시 파일이 엇갈리지 않게
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

    def _write(self, s, text):
        line = json.dumps({"type": "user", "message": {"role": "user", "content": text}}, ensure_ascii=False)
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
        for raw in proc.stdout:
            try:
                ev = json.loads(raw)
            except ValueError:
                continue
            if not isinstance(ev, dict) or s.proc is not proc:  # 다시 띄운 뒤 남은 이전 프로세스 출력은 버린다
                continue
            t = ev.get("type")
            changed = False
            if t == "control_cancel_request":  # Claude가 거둔 요청은 붙잡은 목록에서도 뺀다
                gone = [k for k, p in s.pending.items() if p["rid"] == ev.get("request_id")]
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
            elif t == "system" and ev.get("subtype") == "init" and s.state == "idle":
                s.state, changed = "busy", True
            if changed:
                s.at = utc()
                self.notify()
        proc.wait()
        if s.proc is proc:
            s.state, s.pending, s.at = "ended", {}, utc()
            self._save()
            self.notify()

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
                err = self._spawn(s, ["--resume", s.sid])  # 끝난 세션(보드 재시작 등): 같은 id로 다시 쥔다
                if err:
                    return {"ok": False, "message": err}
            if not self._write(s, text):
                return {"ok": False, "message": "세션에 쓰지 못함 — 세션이 끝났을 수 있음"}
        s.state, s.at = "busy", utc()
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
        self.notify()
        return {"ok": ok, "message": message if ok else "세션에 쓰지 못함 — 세션이 끝났을 수 있음"}

    def end(self, item_id):
        """세션을 끝낸다: stdin을 닫으면 Claude가 붙잡힌 요청을 실패로 끝내고 종료한다. 대화 기록은 지우지 않는다."""
        s = self._get(item_id)
        if not s:
            return {"ok": False, "message": "보드가 쥔 세션이 아님"}
        if s.proc and s.proc.poll() is None:
            with s.wlock:
                try:
                    s.proc.stdin.close()
                except OSError:
                    pass
        return {"ok": True, "message": f"세션을 끝냄 — 대화 기록은 남음(claude --resume {s.sid})"}

    def shutdown(self, grace=3.0):
        """보드가 꺼질 때: 쥔 세션의 stdin을 닫아 끝내고(대화 기록은 남는다), grace 안에 안 끝나면 SIGTERM.
        board.sh stop이 5초 기다리므로 그보다 짧게 둔다. 작업 중이던 턴은 끊기지만 다음에 보내면 같은 id로 이어 쥔다."""
        live = [s for s in self._all() if s.proc and s.proc.poll() is None]
        for s in live:
            self.end("res|" + s.sid)
        end = time.time() + grace
        for s in live:
            try:
                s.proc.wait(timeout=max(0.1, end - time.time()))
            except subprocess.TimeoutExpired:
                s.proc.terminate()
        self._save()

    # ---- 목록 ----
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


def sse_lines(event, data):
    """SSE 한 건. data는 한 줄 JSON이라 줄바꿈이 섞이지 않는다."""
    return f"event: {event}\ndata: {json.dumps(data, ensure_ascii=False)}\n\n".encode()


_RES_ID = re.compile(r"res\|[0-9a-f-]{36}")


def is_resident_id(item_id):
    return isinstance(item_id, str) and bool(_RES_ID.fullmatch(item_id))
