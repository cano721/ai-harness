"""작업 세션 묶음: 어떤 세션이 어떤 세션을 띄웠는지 찾아 item에 group을 붙인다.

근거는 추측이 아니라 기록된 사실만 쓴다.
1. Orca 오케스트레이션 Run: coordinator 터미널 → worker 터미널 (Orca가 있을 때만)
2. 부모 대화 기록의 띄우기 명령 결과: `orca terminal create|agent launch|worktree create`가 돌려준 터미널 ID,
   `claude --bg`가 돌려준 `backgrounded · <id>`
터미널 ID ↔ 세션은 살아 있는 claude 프로세스의 ORCA_TERMINAL_HANDLE로 짝짓고, 끝난 뒤에도 쓰도록 저장한다.
"""
import glob, json, os, re, shutil, subprocess, threading, time

HANDLE = re.compile(r"term_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
BG = re.compile(r"backgrounded · ([0-9a-f]{8})")
SPAWN = re.compile(r"orca\s+(terminal\s+create|agent\s+launch|worktree\s+create)|claude\b[^\n|;&]*--bg")
PR = re.compile(r"https://(?:bitbucket\.org/[\w.-]+/[\w.-]+/pull-requests|github\.com/[\w.-]+/[\w.-]+/pull)/\d+")
ISSUE = re.compile(r"\b([A-Z][A-Z0-9]{1,9})-(\d{1,6})\b")
SCAN_VERSION = 2
_lock = threading.Lock()
_orca = {"at": 0.0, "runs": {}, "workers": []}


class Store:
    def __init__(self, path):
        self.path = path
        try:
            self.data = json.load(open(path))
        except Exception:
            self.data = {}
        self.data.setdefault("handles", {})  # handle -> sid
        self.data.setdefault("verified", {})  # "sid|id" -> True | 확인한 파일 크기
        self.data.setdefault("scan", {})  # transcript -> {offset, pending, handles, bg}

    def save(self):
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        tmp = self.path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(self.data, f)
        os.replace(tmp, self.path)


def _handles_of(pids):
    """살아 있는 프로세스 환경변수에서 Orca 터미널 ID를 읽는다."""
    if not pids:
        return {}
    out = subprocess.run(["ps", "eww", "-o", "pid=,command=", "-p", ",".join(map(str, pids))],
                         capture_output=True, text=True, timeout=5).stdout
    found = {}
    for line in out.splitlines():
        pid, _, rest = line.strip().partition(" ")
        m = re.search(r"ORCA_TERMINAL_HANDLE=(term_[0-9a-f-]{36})", rest)
        if m and pid.isdigit():
            found[int(pid)] = m.group(1)
    return found


def _scan_transcript(path, st):
    """부모 대화 기록에서 '띄우기 명령의 결과'로 받은 터미널 ID·bg ID만 뽑는다(새로 붙은 부분만)."""
    size = os.path.getsize(path)
    if st.get("offset", 0) > size or st.get("v") != SCAN_VERSION:
        st.clear()
        st["v"] = SCAN_VERSION
    if st.get("offset", 0) == size:
        return
    with open(path, "rb") as f:
        f.seek(st.get("offset", 0))
        chunk = f.read(size - st.get("offset", 0))
    chunk = chunk[: chunk.rfind(b"\n") + 1]
    pending = set(st.get("pending", []))
    handles, bgs = set(st.get("handles", [])), set(st.get("bg", []))
    prs, keys, seq = st.get("prs", {}), st.get("keys", {}), st.get("seq", 0)
    for line in chunk.decode("utf-8", "replace").splitlines():
        if '"type":"user"' not in line and '"type":"assistant"' not in line:
            continue
        try:
            r = json.loads(line)
        except Exception:
            continue
        if r.get("isSidechain"):
            continue
        content = (r.get("message") or {}).get("content")
        # PR·이슈 바로가기: 사람 요청·에이전트 답·도구 결과(PR 만든 출력)에서. 시스템 주입문(isMeta)은 제외
        if not r.get("isMeta"):
            texts = []
            if isinstance(content, str):
                texts.append(("user" if r.get("type") == "user" else "agent", content))
            elif isinstance(content, list):
                for c in content:
                    if not isinstance(c, dict):
                        continue
                    if c.get("type") == "text":
                        texts.append(("user" if r.get("type") == "user" else "agent", c.get("text", "")))
                    elif c.get("type") == "tool_result":
                        t = c.get("content")
                        texts.append(("tool", t if isinstance(t, str) else json.dumps(t, ensure_ascii=False)))
            for who, t in texts:
                if who == "user" and t.lstrip().startswith(("<", "Base directory", "Caveat:", "This session is being continued")):
                    continue
                for url in PR.findall(t):
                    seq += 1
                    prs[url] = seq
                if who == "tool":
                    continue
                for m in ISSUE.finditer(t):
                    k = f"{m.group(1)}-{m.group(2)}"
                    seq += 1
                    e = keys.setdefault(k, {"n": 0, "seq": 0, "user": False})
                    e["n"] += 1
                    e["seq"] = seq
                    e["user"] = e["user"] or who == "user"
        if not isinstance(content, list):
            continue
        for c in content:
            if not isinstance(c, dict):
                continue
            if c.get("type") == "tool_use" and c.get("name") == "Bash" and SPAWN.search(str((c.get("input") or {}).get("command", ""))):
                pending.add(c.get("id"))
            elif c.get("type") == "tool_result" and c.get("tool_use_id") in pending:
                pending.discard(c.get("tool_use_id"))
                text = c.get("content")
                text = text if isinstance(text, str) else json.dumps(text, ensure_ascii=False)
                handles.update(HANDLE.findall(text))
                bgs.update(BG.findall(text))
    if len(prs) > 30:
        prs = dict(sorted(prs.items(), key=lambda x: x[1])[-30:])
    if len(keys) > 60:
        keys = dict(sorted(keys.items(), key=lambda x: x[1]["seq"])[-60:])
    st.update(offset=st.get("offset", 0) + len(chunk), pending=sorted(pending)[-50:], handles=sorted(handles), bg=sorted(bgs),
              prs=prs, keys=keys, seq=seq)


def _mentions(store, item, token):
    """세션 대화에 이 task/run ID가 실제로 나오는지. 같은 터미널에서 나중에 띄운 다른 세션을 잘못 묶지 않으려고."""
    path = item.get("transcript")
    if not token or not path or not os.path.isfile(path):
        return False
    key = f"{item['sid']}|{token}"
    size = os.path.getsize(path)
    seen = store.data["verified"].get(key)
    if seen is True or seen == size:
        return seen is True
    with open(path, "rb") as f:
        ok = token.encode() in f.read()
    store.data["verified"][key] = True if ok else size
    return ok


def _orca_state():
    if not shutil.which("orca") or time.time() - _orca["at"] < 20:
        return _orca
    def call(*args):
        out = subprocess.run(["orca", "orchestration", *args, "--json"], capture_output=True, text=True, timeout=8)
        res = json.loads(out.stdout)
        return res.get("result") or {} if res.get("ok") else {}
    try:
        runs = {r["id"]: r for r in call("run-list").get("runs", [])}
        workers, cursor = [], None
        for _ in range(3):
            page = call("worker-list", "--limit", "100", *(["--cursor", cursor] if cursor else []))
            workers += page.get("workers", [])
            cursor = (page.get("page") or {}).get("nextCursor")
            if not cursor:
                break
        _orca.update(at=time.time(), runs=runs, workers=workers)
    except Exception:
        _orca["at"] = time.time()
    return _orca


def annotate(items, store_path):
    """work 항목에 group={id,title,role,source}와 subagents={total,active}를 붙인다. items를 제자리에서 바꾼다."""
    work = [i for i in items if i.get("section") == "work" and i.get("sid")]
    if not work:
        return
    with _lock:
        store = Store(store_path)
        live = {i["pid"]: i["sid"] for i in work if i.get("pid")}
        fresh = _handles_of(list(live))
        for pid, h in fresh.items():
            store.data["handles"][h] = live[pid]
        for i in work:  # 지금 이 프로세스가 붙어 있는 터미널(입력 보내기에 쓴다). 저장된 짝이 아니라 방금 읽은 값만
            if i.get("pid") in fresh:
                i["orca_handle"] = fresh[i["pid"]]
        handles = store.data["handles"]
        by_sid = {i["sid"]: i for i in work}
        by_short = {i.get("short_id"): i["sid"] for i in work}

        groups, member = {}, {}  # gid -> {title, coord, source}; sid -> gid
        orca = _orca_state()
        for w in orca["workers"]:
            run = orca["runs"].get(w.get("runId"))
            sid = handles.get(w.get("agentTerminalHandle"))
            if not run or sid not in by_sid or not _mentions(store, by_sid[sid], w.get("taskId")):
                continue
            gid = "orca|" + run["id"]
            coord = handles.get(run.get("coordinator_handle"))
            if coord not in by_sid or not _mentions(store, by_sid[coord], run["id"]):
                coord = None
            groups.setdefault(gid, {"title": run.get("objective") or run["id"], "coord": coord, "source": "orca"})
            member[sid] = gid
        for parent in work:
            path = parent.get("transcript")
            if not path or not os.path.isfile(path):
                continue
            st = store.data["scan"].setdefault(path, {})
            try:
                _scan_transcript(path, st)
            except OSError:
                continue
            kids = [handles.get(h) for h in st.get("handles", [])] + [by_short.get(b) for b in st.get("bg", [])]
            for kid in kids:
                if kid in by_sid and kid != parent["sid"] and kid not in member:
                    gid = "spawn|" + parent["sid"]
                    groups.setdefault(gid, {"title": parent.get("title"), "coord": parent["sid"], "source": "spawn"})
                    member[kid] = gid
        # 이슈 키 접두어는 사람이 직접 입력한 적 있는 것만 인정(UTF-8, SHA-256 같은 오탐 제외)
        prefixes = {p.strip() for p in os.environ.get("BOARD_JIRA_PROJECTS", "").split(",") if p.strip()}
        for st in store.data["scan"].values():
            prefixes |= {k.split("-")[0] for k, e in st.get("keys", {}).items() if e.get("user")}
        for i in work:
            st = store.data["scan"].get(i.get("transcript") or "", {})
            prs = [u for u, _ in sorted(st.get("prs", {}).items(), key=lambda x: -x[1])][:3]
            keys = [k for k, e in sorted(st.get("keys", {}).items(), key=lambda x: (-x[1]["user"], -x[1]["seq"]))
                    if k.split("-")[0] in prefixes][:3]
            if prs or keys:
                i["refs"] = {"prs": prs, "issues": keys}
        live_paths = {i.get("transcript") for i in work}
        store.data["scan"] = {p: s for p, s in store.data["scan"].items() if p in live_paths}
        store.data["verified"] = {k: v for k, v in store.data["verified"].items() if k.split("|")[0] in by_sid}
        store.save()

    for gid, g in groups.items():
        coord = g["coord"]
        if coord in by_sid and coord not in member:
            member[coord] = gid
    for sid, gid in member.items():
        g = groups[gid]
        by_sid[sid]["group"] = {"id": gid, "title": g["title"], "source": g["source"],
                                "role": "coord" if sid == g["coord"] else "member"}
    now = time.time()
    for i in work:
        path = i.get("transcript")
        if not path:
            continue
        subs = glob.glob(os.path.join(path[: -len(".jsonl")], "subagents", "*.jsonl"))
        if subs:
            i["subagents"] = {"total": len(subs), "active": sum(1 for s in subs if now - os.path.getmtime(s) < 90)}
