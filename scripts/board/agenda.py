#!/usr/bin/env python3
"""보드 '내 일정' 화면의 소스·수집·캐시·할 일 저장(표준 라이브러리만). 보드 서버가 import하고 board.sh todo가 CLI로 부른다.

일정·답할 것·할 일은 캘린더·메신저·메일에 흩어져 있다. 보드는 이것들을 '어댑터'(명령)로 받아 한 화면에 모은다.
어댑터 계약(#492):
- 소스 선언 agenda.json: id(소문자·숫자·-), name, fetch(argv). 선택 interval_minutes(기본 15, 최소 1),
  connect·disconnect·done(argv), requires(있어야 하는 파일. ~와 $HM_DATA_DIR를 펼침), setup_hint(사람 말 한 줄).
  argv의 상대 경로는 agenda.json 폴더 기준이다(그 폴더를 작업 폴더로 삼아 실행한다).
- 발견 순서: 플러그인 scripts/board/agenda/*/ → HM_CLAUDE_SKILLS_DIR/*/ → HM_CODEX_SKILLS_DIR/*/. 같은 id는 먼저 찾은
  쪽이 쓴다(기본 어댑터를 사용자 파일이 가로채지 못한다). 잘못된 선언은 그 소스만 '선언 오류'로 보인다.
- fetch는 `--since ISO --until ISO`를 덧붙여 부르고, stdout JSONL 한 줄이 항목 하나다
  {id, kind: event|reply|todo, title, start?, end?, url?, detail?, done?}. 잘못된 줄은 건너뛰고 센다. 소스당 500개까지.
- done은 argv 뒤에 항목 id를 붙여 부른다. done이 없는 소스는 보드가 done.json에만 적고 숨긴다. event는 완료 대상이 아니다.
- 선택 accounts(argv, #519): 한 소스에 계정을 여럿 잇는 어댑터. stdout JSONL 한 줄이 계정 하나 {id, name, error?}.
  선언한 소스는 연결된 뒤에도 connect를 다시 불러 계정을 더하고, 끊기는 disconnect argv 뒤에 계정 id를 붙여 그 계정만 끊는다
  (마지막 계정을 끊으면 소스 연결도 끊긴다). 계정 목록은 연결·끊기·수집 뒤에 다시 읽어 sources.json에 둔다.
데이터는 <data>/board/agenda/ 아래(sources.json·cache/<id>.json·done.json·todos.json, 모두 600)에 둔다.
메일·채팅·일정 본문은 이 폴더에만 있고 harvest·지표 수집 대상(events/)에 쓰지 않는다.
"""
import fcntl, glob, json, os, re, secrets, signal, subprocess, sys, threading, time
from datetime import datetime, timedelta, timezone

DIR = os.path.dirname(os.path.abspath(__file__))
BUILTIN_DIR = os.path.join(DIR, "agenda")
KINDS = ("event", "reply", "todo")
KIND_ALIAS = {"message": "reply"}  # 이슈 초안의 이름도 받는다
ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,39}$")
TODO_ID = "todo"
MAX_ITEMS = 500
DEFAULT_INTERVAL = 15
# 테스트 전용 시간 한도(사용자 설정 아님) — 실패 격리 테스트가 시간 초과를 몇 초 안에 보게 한다.
FETCH_TIMEOUT = float(os.environ.get("BOARD_AGENDA_FETCH_TIMEOUT") or 60)
CONNECT_TIMEOUT = 300
ACTION_TIMEOUT = 60
WAIT_ON_READ = 1.5  # 화면이 읽을 때 막 시작한 수집을 기다리는 최대 시간. 느린 소스는 다음 읽기에 보인다


def utc():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _epoch(iso):
    try:
        return datetime.strptime(iso, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp()
    except (TypeError, ValueError):
        return 0.0


def window(now=None):
    """오늘 0시(이 PC 시간대)부터 7일."""
    now = (now or datetime.now()).astimezone()
    start = now.replace(hour=0, minute=0, second=0, microsecond=0)
    return start.isoformat(), (start + timedelta(days=7)).isoformat()


def _read_json(path, default):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def _write_private(path, data):
    """임시 파일(600)에 쓰고 바꿔 넣는다 — 읽는 쪽이 반쯤 쓴 파일을 보지 않는다."""
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    tmp = f"{path}.tmp.{os.getpid()}.{threading.get_ident()}"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


class _FileLock:
    """셸(board.sh todo)과 서버가 같은 파일을 동시에 고쳐도 깨지지 않게 하는 배타 잠금."""

    def __init__(self, path):
        self.path = path + ".lock"

    def __enter__(self):
        os.makedirs(os.path.dirname(self.path), mode=0o700, exist_ok=True)
        self.fd = os.open(self.path, os.O_RDWR | os.O_CREAT, 0o600)
        fcntl.flock(self.fd, fcntl.LOCK_EX)
        return self

    def __exit__(self, *exc):
        fcntl.flock(self.fd, fcntl.LOCK_UN)
        os.close(self.fd)


def _argv(v):
    return isinstance(v, list) and v and all(isinstance(x, str) and x for x in v)


def _short(text, limit):
    text = re.sub(r"\s+", " ", str(text)).strip()
    return text if len(text) <= limit else text[: limit - 1] + "…"


def skill_dirs():
    return [
        BUILTIN_DIR,
        os.environ.get("HM_CLAUDE_SKILLS_DIR") or os.path.expanduser("~/.claude/skills"),
        os.environ.get("HM_CODEX_SKILLS_DIR") or os.path.expanduser("~/.agents/skills"),
    ]


def parse_declaration(path):
    """agenda.json 하나를 읽어 (소스, 오류)를 돌려준다. 오류가 있으면 소스는 None."""
    try:
        with open(path, encoding="utf-8") as f:
            d = json.load(f)
    except OSError as e:
        return None, f"선언 파일을 읽지 못했습니다({e.strerror or e})."
    except ValueError:
        return None, "선언 파일이 올바른 JSON이 아닙니다."
    if not isinstance(d, dict):
        return None, "선언 파일이 JSON 객체가 아닙니다."
    if not isinstance(d.get("id"), str) or not ID_RE.match(d["id"]):
        return None, "id가 없거나 소문자·숫자·- 로 된 이름이 아닙니다."
    if not isinstance(d.get("name"), str) or not d["name"].strip():
        return None, "name이 없습니다."
    if not _argv(d.get("fetch")):
        return None, "fetch 명령(문자열 배열)이 없습니다."
    for k in ("connect", "disconnect", "done", "accounts"):
        if k in d and not _argv(d[k]):
            return None, f"{k} 명령이 문자열 배열이 아닙니다."
    if "accounts" in d and "disconnect" not in d:
        return None, "accounts를 선언하면 계정을 끊을 disconnect 명령도 있어야 합니다."
    interval = d.get("interval_minutes", DEFAULT_INTERVAL)
    if isinstance(interval, bool) or not isinstance(interval, int) or interval < 1:
        return None, "interval_minutes는 1 이상의 정수여야 합니다."
    req = d.get("requires", [])
    if isinstance(req, str):
        req = [req]
    if not isinstance(req, list) or not all(isinstance(x, str) and x for x in req):
        return None, "requires는 파일 경로(문자열 또는 문자열 배열)여야 합니다."
    hint = d.get("setup_hint")
    if hint is not None and not isinstance(hint, str):
        return None, "setup_hint는 문자열이어야 합니다."
    return {
        "id": d["id"], "name": _short(d["name"], 60), "folder": os.path.dirname(os.path.abspath(path)),
        "fetch": d["fetch"], "connect": d.get("connect"), "disconnect": d.get("disconnect"), "done": d.get("done"),
        "accounts": d.get("accounts"),
        "interval": interval, "requires": req, "setup_hint": _short(hint, 300) if hint else None,
    }, None


def discover(dirs=None, warn=None):
    """소스 선언을 찾는다. 반환: [소스 또는 {"id", "name", "invalid": 사유}] (발견 순서)."""
    seen, out = {TODO_ID}, []
    for base in dirs or skill_dirs():
        for path in sorted(glob.glob(os.path.join(base, "*", "agenda.json"))):
            folder = os.path.basename(os.path.dirname(path))
            src, err = parse_declaration(path)
            if err:
                key = f"{folder}"
                if key in seen:
                    continue
                seen.add(key)
                out.append({"id": key, "name": folder, "invalid": err, "path": path})
                continue
            if src["id"] in seen:
                if warn:
                    warn(f"agenda: 같은 id '{src['id']}'가 이미 있어 {path}를 건너뜁니다")
                continue
            seen.add(src["id"])
            out.append(src)
    return out


def _normalize(raw, source_id):
    """fetch 한 줄 → 항목. 쓸 수 없으면 None."""
    if not isinstance(raw, dict):
        return None
    iid, kind, title = raw.get("id"), raw.get("kind"), raw.get("title")
    if isinstance(iid, (int, float)) and not isinstance(iid, bool):
        iid = str(iid)
    kind = KIND_ALIAS.get(kind, kind)
    if not isinstance(iid, str) or not iid.strip() or len(iid) > 300 or kind not in KINDS:
        return None
    if not isinstance(title, str) or not title.strip():
        return None
    item = {"source": source_id, "id": iid, "kind": kind, "title": _short(title, 300)}
    for k in ("start", "end"):
        if isinstance(raw.get(k), str) and raw[k].strip():
            item[k] = raw[k].strip()[:40]
    url = raw.get("url") if isinstance(raw.get("url"), str) else raw.get("link")
    if isinstance(url, str) and re.match(r"^https?://", url):
        item["url"] = url[:2000]
    if isinstance(raw.get("detail"), str) and raw["detail"].strip():
        item["detail"] = _short(raw["detail"], 500)
    if raw.get("done") is True:
        item["done"] = True
    return item


def parse_jsonl(text, source_id):
    """stdout → (항목, 건너뛴 줄 수). 500개를 넘는 줄도 건너뛴 수에 든다."""
    items, skipped, ids = [], 0, set()
    for line in (text or "").splitlines():
        if not line.strip():
            continue
        try:
            raw = json.loads(line)
        except ValueError:
            skipped += 1
            continue
        item = _normalize(raw, source_id)
        if not item or item["id"] in ids or len(items) >= MAX_ITEMS:
            skipped += 1
            continue
        ids.add(item["id"])
        items.append(item)
    return items, skipped


def _last_line(text):
    lines = [x.strip() for x in (text or "").splitlines() if x.strip()]
    return _short(lines[-1], 200) if lines else ""


class Store:
    def __init__(self, data_dir, warn=None):
        self.data = data_dir
        self.dir = os.path.join(data_dir, "board", "agenda")
        self.sources_path = os.path.join(self.dir, "sources.json")
        self.done_path = os.path.join(self.dir, "done.json")
        self.todos_path = os.path.join(self.dir, "todos.json")
        self.warn = warn or (lambda m: print(m, file=sys.stderr, flush=True))
        self._warned = set()
        self.lock = threading.Lock()
        self.fetching = {}  # id -> Thread
        self.refetch = set()  # 수집 중에 다시 모아야 할 일이 생긴 소스(계정을 끊음 등)
        self.connecting = {}  # id -> 시작 시각
        self.connect_error = {}  # id -> 사람 말 오류(연결 실패)

    # ---- 경로·환경 ----
    def _warn_once(self, msg):
        if msg not in self._warned:
            self._warned.add(msg)
            self.warn(msg)

    def sources(self):
        return discover(warn=self._warn_once)

    def find(self, source_id):
        return next((s for s in self.sources() if s.get("id") == source_id and not s.get("invalid")), None)

    def _expand(self, path):
        path = path.replace("${HM_DATA_DIR}", self.data).replace("$HM_DATA_DIR", self.data)
        return os.path.expanduser(path)

    def missing(self, src):
        return [p for p in src["requires"] if not os.path.exists(self._expand(p))]

    def _env(self):
        env = dict(os.environ)
        env["HM_DATA_DIR"] = self.data
        env["HARNESS_METRICS_DIR"] = self.data
        return env

    def _run(self, src, argv, extra, timeout):
        """어댑터 명령 하나. 반환 (종료 코드 또는 None(시간 초과·실행 못 함), stdout, 사람 말 오류)."""
        argv = list(argv)
        first = os.path.join(src["folder"], argv[0])
        if not os.path.isabs(argv[0]) and os.path.exists(first):
            argv[0] = first
        try:  # 자기 프로세스 그룹으로 띄워, 시간 초과면 손자 프로세스까지 끈다(파이프를 쥔 손자가 기다림을 늘리지 않게)
            p = subprocess.Popen(argv + list(extra), cwd=src["folder"], env=self._env(), stdin=subprocess.DEVNULL,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)
        except OSError as e:
            return None, "", f"명령을 실행하지 못했습니다({e.strerror or e})."
        try:
            out, err = p.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(p.pid, signal.SIGKILL)
            except OSError:
                pass
            p.communicate()
            return None, "", f"{int(timeout)}초 안에 끝나지 않았습니다."
        if p.returncode != 0:
            why = _last_line(err)
            if why and why[-1] not in ".!?。…)":
                why += "."
            return p.returncode, out, f"명령이 실패했습니다(종료 코드 {p.returncode})." + (f" {why}" if why else "")
        return 0, out, ""

    # ---- 연결 상태 ----
    def _connected(self):
        d = _read_json(self.sources_path, {})
        return d if isinstance(d, dict) else {}

    def _set_connected(self, source_id, on):
        with _FileLock(self.sources_path):
            d = self._connected()
            if on:
                prev = d.get(source_id) if isinstance(d.get(source_id), dict) else {}
                d[source_id] = dict(prev, connected=True, at=prev.get("at") or utc())
            else:
                d.pop(source_id, None)
            _write_private(self.sources_path, d)

    # ---- 계정(accounts를 선언한 소스) ----
    def _read_accounts(self, src):
        """accounts 명령 → [{id, name, error?}]. 실행하지 못하면 None(이전 목록을 그대로 둔다)."""
        code, out, _err = self._run(src, src["accounts"], [], ACTION_TIMEOUT)
        if code != 0:
            return None
        rows, ids = [], set()
        for line in (out or "").splitlines():
            try:
                raw = json.loads(line)
            except ValueError:
                continue
            aid = raw.get("id") if isinstance(raw, dict) else None
            if not isinstance(aid, str) or not aid.strip() or len(aid) > 200 or aid in ids:
                continue
            ids.add(aid)
            row = {"id": aid, "name": _short(raw.get("name") if isinstance(raw.get("name"), str) and raw["name"].strip() else aid, 120)}
            if isinstance(raw.get("error"), str) and raw["error"].strip():
                row["error"] = _short(raw["error"], 300)
            rows.append(row)
            if len(rows) >= 50:
                break
        return rows

    def _sync_accounts(self, src):
        """계정 목록을 다시 읽어 sources.json에 둔다. 반환: 목록(읽지 못하면 None)."""
        if not src.get("accounts"):
            return None
        rows = self._read_accounts(src)
        if rows is None:
            return None
        with _FileLock(self.sources_path):
            d = self._connected()
            if isinstance(d.get(src["id"]), dict):
                d[src["id"]]["accounts"] = rows
                _write_private(self.sources_path, d)
        return rows

    def accounts_of(self, source_id):
        entry = self._connected().get(source_id)
        rows = entry.get("accounts") if isinstance(entry, dict) else None
        return rows if isinstance(rows, list) else []

    def is_connected(self, source_id):
        return bool((self._connected().get(source_id) or {}).get("connected"))

    # ---- 캐시 ----
    def cache_path(self, source_id):
        return os.path.join(self.dir, "cache", source_id + ".json")

    def cache(self, source_id):
        c = _read_json(self.cache_path(source_id), {})
        return c if isinstance(c, dict) else {}

    def _due(self, src):
        c = self.cache(src["id"])
        last = max(_epoch(c.get("fetched_at")), _epoch(c.get("tried_at")))
        return time.time() - last >= src["interval"] * 60

    def fetch(self, src):
        """소스 하나를 수집해 캐시에 쓴다. 실패하면 이전 항목을 그대로 두고 error만 채운다."""
        since, until = window()
        code, out, err = self._run(src, src["fetch"], ["--since", since, "--until", until], FETCH_TIMEOUT)
        prev = self.cache(src["id"])
        now = utc()
        if code == 0:
            items, skipped = parse_jsonl(out, src["id"])
            entry = {"fetched_at": now, "tried_at": now, "items": items, "error": None, "skipped": skipped}
        else:
            entry = {"fetched_at": prev.get("fetched_at"), "tried_at": now, "items": prev.get("items") or [],
                     "error": "가져오기 " + err, "skipped": prev.get("skipped", 0)}
        if self.is_connected(src["id"]):  # 수집 도중 끊었으면 캐시를 되살리지 않는다
            _write_private(self.cache_path(src["id"]), entry)
            self._sync_accounts(src)  # 수집이 남긴 계정별 실패를 목록에 비춘다
        return entry

    def _start_fetch(self, src, again=False):
        """수집 스레드를 띄운다. 이미 돌고 있으면 그것을 돌려주고, again이면 끝난 뒤 한 번 더 모으게 표시한다."""
        with self.lock:
            t = self.fetching.get(src["id"])
            if t and t.is_alive():
                if again:
                    self.refetch.add(src["id"])
                return t
            t = threading.Thread(target=self._fetch_guarded, args=(src,), daemon=True)
            self.fetching[src["id"]] = t
        t.start()
        return t

    def _fetch_guarded(self, src):
        while True:
            try:
                self.fetch(src)
            except Exception as e:  # 한 소스의 예외가 다른 소스·서버를 막지 않게
                self.warn(f"agenda: {src['id']} 수집 중 예외 — {type(e).__name__}")
            with self.lock:
                if src["id"] not in self.refetch:
                    return
                self.refetch.discard(src["id"])

    def refresh_due(self, wait=0.0):
        """연결된 소스 중 주기가 지난 것을 소스마다 자기 스레드로 수집한다. wait초까지만 기다린다."""
        started = []
        for src in self.sources():
            if src.get("invalid") or src["id"] in self.connecting or not self.is_connected(src["id"]) or self.missing(src):
                continue
            if self._due(src):
                started.append(self._start_fetch(src))
        deadline = time.time() + wait
        for t in started:
            t.join(max(0.0, deadline - time.time()))
        return len(started)

    # ---- 완료 기록 ----
    def _done_local(self):
        d = _read_json(self.done_path, {})
        return d if isinstance(d, dict) else {}

    # ---- 화면용 상태 ----
    def state(self, wait=WAIT_ON_READ):
        self.refresh_due(wait)
        local_done = self._done_local()
        connected = self._connected()
        sources, items = [], {k: [] for k in KINDS}
        for src in self.sources():
            if src.get("invalid"):
                sources.append({"id": src["id"], "name": src["name"], "state": "error", "connected": False,
                                "invalid": True, "error": "선언 오류: " + src["invalid"], "fetched_at": None, "setup_hint": None})
                continue
            sid = src["id"]
            on = bool((connected.get(sid) or {}).get("connected"))
            c = self.cache(sid) if on else {}
            fetching = bool(self.fetching.get(sid) and self.fetching[sid].is_alive())
            if self.missing(src):
                st = "needs_setup"
            elif sid in self.connecting:
                st = "connecting"
            elif on:
                st = "error" if c.get("error") else "connected"
            else:
                st = "disconnected"
            sources.append({"id": sid, "name": src["name"], "state": st, "connected": on, "fetching": fetching,
                            "fetched_at": c.get("fetched_at"), "error": c.get("error") or self.connect_error.get(sid),
                            "skipped": c.get("skipped", 0), "setup_hint": src["setup_hint"], "can_done": bool(src["done"]),
                            "multi": bool(src["accounts"]), "accounts": self.accounts_of(sid) if on else [],
                            "connect_error": self.connect_error.get(sid)})
            if not on or st == "needs_setup":
                continue
            hidden = local_done.get(sid) or {}
            for it in c.get("items") or []:
                if it.get("done") or it["id"] in hidden:
                    continue
                items[it["kind"]].append(dict(it, source_name=src["name"]))
        todos = self._todos()
        for t in todos:
            if not t.get("done_at"):
                items["todo"].append({"source": TODO_ID, "source_name": "할 일", "id": t["id"], "kind": "todo",
                                      "title": t["title"], "start": t.get("created_at"), "local": True})
        items["event"].sort(key=lambda i: (i.get("start") or "", i["title"]))
        return {"ok": True, "now": utc(), "sources": sources, "items": items,
                "todo_total": len(todos), "window": dict(zip(("since", "until"), window()))}

    # ---- 동작 ----
    def connect(self, source_id):
        src = self.find(source_id)
        if not src:
            return 404, {"ok": False, "message": "등록된 일정 소스가 아닙니다."}
        if self.missing(src):
            return 409, {"ok": False, "message": f"{src['name']} 연결에 필요한 설정이 아직 없습니다. 연결한 곳의 [설정하기] 안내를 따르세요."}
        adding = self.is_connected(source_id)
        if adding and not src["accounts"]:
            return 200, {"ok": True, "state": "connected", "message": f"{src['name']} 연결이 이미 돼 있습니다."}
        with self.lock:
            if source_id in self.connecting:
                return 200, {"ok": True, "state": "connecting", "message": f"{src['name']}에 연결하는 중입니다."}
            self.connect_error.pop(source_id, None)
            if not src["connect"]:
                self._set_connected(source_id, True)
            else:
                self.connecting[source_id] = time.time()
        if not src["connect"]:
            self._start_fetch(src)
            return 200, {"ok": True, "state": "connected", "message": f"{src['name']} 연결을 마쳤습니다."}
        threading.Thread(target=self._connect_bg, args=(src,), daemon=True).start()
        what = "계정을 더하는 중입니다" if adding else "연결하는 중입니다"
        return 200, {"ok": True, "state": "connecting", "message": f"{src['name']}에 {what}. 브라우저에서 허용을 마치면 연결됩니다."}

    def _connect_bg(self, src):
        """브라우저 동의처럼 오래 걸리는 connect는 뒤에서 돌린다(최대 5분)."""
        code = None
        try:
            code, _out, err = self._run(src, src["connect"], [], CONNECT_TIMEOUT)
            if code == 0:
                self._set_connected(src["id"], True)
                self._sync_accounts(src)
            else:
                self.connect_error[src["id"]] = "연결하지 못했습니다. " + err
        finally:
            with self.lock:
                self.connecting.pop(src["id"], None)
        if code == 0:
            self._fetch_guarded(src)

    def disconnect(self, source_id, account=None):
        src = self.find(source_id)
        if not src:
            return 404, {"ok": False, "message": "등록된 일정 소스가 아닙니다."}
        if account is not None:
            return self._disconnect_account(src, account)
        note = ""
        if src["disconnect"]:
            code, _out, err = self._run(src, src["disconnect"], [], ACTION_TIMEOUT)
            if code != 0:
                note = " 끊기 명령은 실패했습니다: " + err
        self._set_connected(source_id, False)
        self.connect_error.pop(source_id, None)
        try:
            os.remove(self.cache_path(source_id))
        except OSError:
            pass
        return 200, {"ok": True, "state": "disconnected", "message": f"{src['name']} 연결을 끊었습니다." + note}

    def _disconnect_account(self, src, account):
        """계정 하나만 끊는다. 마지막 계정이면 소스 연결도 끊는다."""
        known = self._sync_accounts(src)
        if known is None:
            known = self.accounts_of(src["id"])
        row = next((a for a in known if a["id"] == account), None) if src["accounts"] else None
        if not row:
            return 404, {"ok": False, "message": f"{src['name']}에 연결된 계정이 아닙니다."}
        if src["disconnect"]:
            code, _out, err = self._run(src, src["disconnect"], [account], ACTION_TIMEOUT)
            if code != 0:
                return 502, {"ok": False, "message": f"{row['name']} 연결을 끊지 못했습니다. " + err}
        left = self._sync_accounts(src)
        if left is None:
            left = [a for a in known if a["id"] != account]
        if not left:
            self._set_connected(src["id"], False)
            self.connect_error.pop(src["id"], None)
            try:
                os.remove(self.cache_path(src["id"]))
            except OSError:
                pass
            return 200, {"ok": True, "state": "disconnected", "message": f"{row['name']} 연결을 끊었습니다. 남은 계정이 없어 {src['name']} 연결도 끊었습니다."}
        self._start_fetch(src, again=True)  # 끊은 계정의 일정을 바로 걷어 낸다(돌던 수집은 끝난 뒤 한 번 더)
        return 200, {"ok": True, "state": "connected", "message": f"{row['name']} 연결을 끊었습니다."}

    def refresh(self, source_id):
        """사람이 [다시 가져오기]를 누르면 주기와 상관없이 그 소스 하나만 바로 다시 모은다."""
        src = self.find(source_id)
        if not src or src.get("invalid"):
            return 404, {"ok": False, "message": "등록된 일정 소스가 아닙니다."}
        if not self.is_connected(source_id) or self.missing(src):
            return 409, {"ok": False, "message": f"{src['name']}에 연결돼 있지 않습니다. 연결한 곳에서 먼저 연결하세요."}
        self._start_fetch(src).join(FETCH_TIMEOUT + 5)
        err = self.cache(source_id).get("error")
        if err:
            return 200, {"ok": False, "message": f"{src['name']}에서 또 가져오지 못했습니다. {err}"}
        return 200, {"ok": True, "message": f"{src['name']}에서 새로 가져왔습니다."}

    def done(self, source_id, item_id):
        if not isinstance(item_id, str) or not item_id:
            return 400, {"ok": False, "message": "완료할 항목이 없습니다."}
        if source_id == TODO_ID:
            ok = self.todo_done(item_id)
            return (200, {"ok": True, "message": "할 일을 완료로 표시했습니다."}) if ok else (404, {"ok": False, "message": "그 할 일을 찾지 못했습니다."})
        src = self.find(source_id)
        if not src:
            return 404, {"ok": False, "message": "등록된 일정 소스가 아닙니다."}
        c = self.cache(source_id)
        item = next((i for i in c.get("items") or [] if i.get("id") == item_id), None)
        if not item:
            return 404, {"ok": False, "message": "그 항목을 찾지 못했습니다. 화면을 새로 고친 뒤 다시 시도하세요."}
        if item["kind"] == "event":
            return 400, {"ok": False, "message": "일정은 완료로 표시하지 않습니다."}
        if src["done"]:
            code, _out, err = self._run(src, src["done"], [item_id], ACTION_TIMEOUT)
            if code != 0:
                return 200, {"ok": False, "message": f"{src['name']}에 완료를 알리지 못했습니다. " + err}
            item["done"] = True
            if self.is_connected(source_id):
                _write_private(self.cache_path(source_id), c)
            return 200, {"ok": True, "message": f"{src['name']}에 완료로 표시했습니다."}
        with _FileLock(self.done_path):
            d = self._done_local()
            d.setdefault(source_id, {})[item_id] = utc()
            _write_private(self.done_path, d)
        return 200, {"ok": True, "message": "완료로 표시했습니다. 이 보드에서만 숨깁니다."}

    # ---- 할 일 ----
    def _todos(self):
        d = _read_json(self.todos_path, {})
        items = d.get("items") if isinstance(d, dict) else None
        return [t for t in items or [] if isinstance(t, dict) and isinstance(t.get("id"), str) and isinstance(t.get("title"), str)]

    def todo_add(self, text):
        title = _short(text or "", 300)
        if not title:
            return None
        with _FileLock(self.todos_path):
            items = self._todos()
            ids = {t["id"] for t in items}
            tid = secrets.token_hex(4)
            while tid in ids:
                tid = secrets.token_hex(4)
            items.append({"id": tid, "title": title, "created_at": utc(), "done_at": None})
            _write_private(self.todos_path, {"items": items})
        return tid

    def todo_done(self, tid):
        with _FileLock(self.todos_path):
            items = self._todos()
            hit = next((t for t in items if t["id"] == tid and not t.get("done_at")), None)
            if not hit:
                return False
            hit["done_at"] = utc()
            _write_private(self.todos_path, {"items": items})
        return True

    def todo_list(self, include_done=False):
        return [t for t in self._todos() if include_done or not t.get("done_at")]


TODO_USAGE = """usage: board.sh todo add <내용...>     할 일을 적고 새 id를 출력한다
       board.sh todo list [--all]        열린 할 일을 'id<TAB>내용'으로 (--all은 끝낸 것도, 셋째 칸에 완료 시각)
       board.sh todo done <id>           할 일을 완료로 표시한다"""


def _cli_todo(args, data_dir):
    def usage():
        print(TODO_USAGE, file=sys.stderr)
        return 2

    if not args:
        return usage()
    store = Store(data_dir)
    cmd, rest = args[0], args[1:]
    if cmd == "add":
        tid = store.todo_add(" ".join(rest))
        if not tid:
            return usage()
        print(tid)
        return 0
    if cmd == "list":
        if rest not in ([], ["--all"]):
            return usage()
        for t in store.todo_list(include_done=bool(rest)):
            row = [t["id"], t["title"]] + ([t.get("done_at") or ""] if rest else [])
            print("\t".join(row))
        return 0
    if cmd == "done":
        if len(rest) != 1:
            return usage()
        if not store.todo_done(rest[0]):
            print(f"board: 열린 할 일 중에 id {rest[0]} 없음", file=sys.stderr)
            return 1
        return 0
    return usage()


def main(argv):
    data_dir = os.environ.get("HARNESS_METRICS_DIR") or os.environ.get("HM_DATA_DIR") or os.path.expanduser("~/.ai-harness")
    if len(argv) >= 2 and argv[1] == "todo":
        return _cli_todo(argv[2:], data_dir)
    print("usage: agenda.py todo <add|list|done> ...", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
