"""하네스 보드 '자동 수정' 화면 데이터 (#278). 판정·상태 전이는 scripts/autofix-auto.sh가 하고, 여기서는 읽어서 모으기만 한다.

- 준비 상태는 monitor-fetch.sh describe(요청 없음, 자격증명 값 미출력)로 본다. 30초 캐시.
- 접근 확인(monitor-fetch.sh check)과 후보 조회(autofix-auto.sh candidates)는 모니터링 도구 API를 부르므로 버튼으로만 돌리고,
  결과를 $HARNESS_METRICS_DIR/board/autofix/에 둔다. 화면을 열거나 새로 고쳐도 다시 부르지 않는다.
- 진행·이력은 autofix-auto.sh status·runs, 개인 설정은 autofix-auto.sh configure(인자 없음 = 현재 값)를 그대로 쓴다.
- 쓰기는 autofix-auto.sh configure만 거친다(값 검증·원자적 쓰기의 단일 작성자). 주기를 바꾸면 schedule.sh install-autofix·status를
  돌린다(sweep 전용 에이전트만, 등록 즉시 실행 없음).
- 보드는 수정 실행(sweep·run)을 시작하지 않고 PR을 병합하지 않으며 monitor 설정 파일을 쓰지 않는다.
"""
import json, os, subprocess, threading, time
from datetime import datetime, timezone

DIR = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.normpath(os.path.join(DIR, ".."))
AUTOFIX_SH = os.environ.get("BOARD_AUTOFIX_SH") or os.path.join(SCRIPTS, "autofix-auto.sh")
MONITOR_SH = os.environ.get("BOARD_MONITOR_FETCH_SH") or os.path.join(SCRIPTS, "monitor-fetch.sh")
SCHEDULE_SH = os.environ.get("BOARD_SCHEDULE_SH") or os.path.join(SCRIPTS, "schedule.sh")
RECENT_RUNS = 20
RUNS_WINDOW = 100000  # 비용 합계·마지막 실행을 볼 이벤트 수. runs.jsonl은 이벤트 몇 줄씩만 늘어 사실상 전체다
READY_TTL = 30
CHECK_LABEL = {0: "접근됨", 3: "요청 실패", 4: "자격증명·설정 오류", 5: "설정 없음"}
CANDIDATE_KEYS = ("signature", "title", "count", "reason", "link", "provider")
RUN_KEYS = ("at", "event", "project", "signature", "reason", "outcome", "artifact", "duration_s", "cost_usd", "exit_code", "next")
CONFIG_FLAGS = (("add_repo", "--add-repo"), ("remove_repo", "--remove-repo"), ("interval_minutes", "--interval-minutes"),
                ("daily_max", "--daily-max"), ("max_attempts", "--max-attempts"), ("budget_usd", "--budget-usd"))


def _utc():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _run(script, args, timeout, env=None):
    try:
        out = subprocess.run(["bash", script, *args], capture_output=True, text=True, timeout=timeout,
                             env={**os.environ, **(env or {})})
    except subprocess.TimeoutExpired:
        return "timeout", "", f"{timeout}초 안에 끝나지 않아 멈춤"
    return out.returncode, out.stdout, out.stderr


def _lines(text):
    out = []
    for line in (text or "").splitlines():
        try:
            v = json.loads(line)
        except ValueError:
            continue
        if isinstance(v, dict):
            out.append(v)
    return out


def _last_line(*texts):
    for t in texts:
        lines = [l.strip() for l in (t or "").splitlines() if l.strip()]
        if lines:
            return lines[-1][:300]
    return ""


def stage(sig):
    """화면의 단계: 수정 중 → 수정 PR → 배포 대기(병합됨) → 관찰 중 → 해결/재발/포기. 그 밖의 상태는 이름 그대로."""
    st = sig.get("status")
    if st == "attempting":
        return "fixing"
    if st == "pr_open":
        return "pr"
    if st == "verifying":
        return "observing" if sig.get("deployed_at") else "deploy_wait"
    return st or "unknown"


class Store:
    def __init__(self, data):
        self.data = data
        self.dir = os.path.join(data, "board", "autofix")
        self.logs = os.path.join(data, "autofix", "logs")
        self._lock = threading.Lock()
        self._ready = {}  # repo -> (at, describe)

    def _file(self, name):
        return os.path.join(self.dir, name)

    def _load(self, name):
        try:
            with open(self._file(name), encoding="utf-8") as f:
                v = json.load(f)
            return v if isinstance(v, dict) else {}
        except Exception:
            return {}

    def _put(self, name, key, value):
        with self._lock:
            cur = self._load(name)
            cur[key] = value
            os.makedirs(self.dir, exist_ok=True)
            tmp = f"{self._file(name)}.tmp.{os.getpid()}.{threading.get_ident()}"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(cur, f, ensure_ascii=False)
            os.replace(tmp, self._file(name))

    # ---- 읽기 ----
    def readiness(self, repo):
        hit = self._ready.get(repo)
        if hit and time.time() - hit[0] < READY_TTL:
            return hit[1]
        rc, out, err = _run(MONITOR_SH, ["describe", "--root", repo], 30)
        rows = _lines(out)
        res = rows[-1] if rc == 0 and rows else {"source": "unknown", "provider": "", "summary": "", "credentials": "unknown",
                                                 "code": None, "problem": _last_line(err) or "준비 상태를 읽지 못함"}
        self._ready[repo] = (time.time(), res)
        return res

    def config(self):
        rc, out, err = _run(AUTOFIX_SH, ["configure"], 30)
        rows = _lines(out)
        return rows[-1] if rc == 0 and rows else {"error": _last_line(err) or "설정을 읽지 못함"}

    def view(self, repos, key_of):
        """repos: 하네스 저장소 경로 목록, key_of: 경로 → project_id."""
        cfg = self.config()
        targets = set(cfg.get("repos") or [])
        _, out, _ = _run(AUTOFIX_SH, ["status"], 30)
        sigs = _lines(out)
        _, out, _ = _run(AUTOFIX_SH, ["runs", "--limit", str(RUNS_WINDOW)], 30)
        events = _lines(out)
        last_run = {}
        for e in events:
            if e.get("event") == "finished":
                last_run[(e.get("project"), e.get("signature"))] = {k: e.get(k) for k in ("at", "outcome", "reason", "cost_usd", "duration_s", "artifact")}
        titles = {(s.get("project"), s.get("signature")): s.get("title") for s in sigs}
        by_project = {}
        for s in sigs:
            s = {**s, "stage": stage(s), "last_run": last_run.get((s.get("project"), s.get("signature")))}
            by_project.setdefault(s.get("project"), []).append(s)
        for lst in by_project.values():
            lst.sort(key=lambda s: s.get("updated_at") or "", reverse=True)
        checks, cands = self._load("checks.json"), self._load("candidates.json")
        rows, seen = [], set()
        for repo in repos:
            pid = key_of(repo)
            seen.add(pid)
            rows.append({"repo": repo, "name": os.path.basename(repo), "project": pid, "ready": self.readiness(repo),
                         "targeted": pid in targets, "signatures": by_project.get(pid, []),
                         "check": checks.get(repo), "candidates": cands.get(repo)})
        for pid, lst in by_project.items():  # 상태는 있는데 이 맥에서 저장소를 찾지 못한 프로젝트
            if pid not in seen:
                rows.append({"repo": None, "name": pid, "project": pid, "ready": None, "targeted": pid in targets,
                             "signatures": lst, "check": None, "candidates": None})
        today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
        started = sum(1 for e in events if e.get("event") == "started" and str(e.get("at") or "").startswith(today))
        cost = sum(e["cost_usd"] for e in events if e.get("event") == "finished" and isinstance(e.get("cost_usd"), (int, float)))
        recent = []
        for e in reversed(events[-RECENT_RUNS:]):
            r = {k: e.get(k) for k in RUN_KEYS if e.get(k) is not None}
            r["title"] = titles.get((e.get("project"), e.get("signature")))
            log = os.path.basename(str(e.get("log") or ""))
            if log and os.path.isfile(os.path.join(self.logs, log)):
                r["log"] = log
            recent.append(r)
        return {"ok": True, "config": cfg, "repos": rows, "runs": recent, "cost_usd": round(cost, 4),
                "today": {"started": started, "daily_max": cfg.get("daily_max")}}

    def log_path(self, name):
        """실행 로그는 autofix 로그 디렉토리 안 파일 이름으로만 연다."""
        if not isinstance(name, str) or not name.endswith(".log") or os.path.basename(name) != name or name.startswith("."):
            return None
        path = os.path.join(self.logs, name)
        real = os.path.realpath(path)
        return real if real.startswith(os.path.realpath(self.logs) + os.sep) and os.path.isfile(real) else None

    # ---- 버튼 ----
    def check(self, repo):
        rc, out, err = _run(MONITOR_SH, ["check", "--root", repo], 90)
        code = rc if isinstance(rc, int) else None
        res = {"at": _utc(), "code": code, "label": CHECK_LABEL.get(code, "확인 실패"),
               "message": _last_line(out) if code == 0 else _last_line(err, out)}
        self._ready.pop(repo, None)
        self._put("checks.json", repo, res)
        return res

    def candidates(self, repo, project):
        rc, out, err = _run(AUTOFIX_SH, ["candidates", "--project", project, "--root", repo], 180)
        if rc != 0:
            res = {"at": _utc(), "items": [], "error": _last_line(err, out) or f"후보 조회 실패(exit {rc})"}
        else:
            res = {"at": _utc(), "items": [{k: c.get(k) for k in CANDIDATE_KEYS} for c in _lines(out)][:30], "error": None}
        self._put("candidates.json", repo, res)
        return res

    def configure(self, req):
        args = []
        if "auto" in req:
            if not isinstance(req["auto"], bool):
                return {"ok": False, "message": "무인 실행은 켬/끔만"}
            args += ["--auto", "1" if req["auto"] else "0"]
        for key, flag in CONFIG_FLAGS:
            if key not in req:
                continue
            v = req[key]
            if isinstance(v, bool) or not isinstance(v, (str, int, float)) or v is None:
                return {"ok": False, "message": f"{key} 값이 올바르지 않음"}
            args += [flag, str(v)]
        if not args:
            return {"ok": False, "message": "바꿀 값이 없음"}
        rc, out, err = _run(AUTOFIX_SH, ["configure", *args], 30)
        rows = _lines(out)
        if rc != 0 or not rows:
            return {"ok": False, "message": _last_line(err, out) or f"설정을 쓰지 못함(exit {rc})"}
        res = {"ok": True, "message": "내 설정에 저장함 — 다음 sweep부터 적용", "config": rows[-1]}
        if "interval_minutes" in req:
            interval = rows[-1].get("interval_minutes")
            env = {"HM_AUTOFIX_INTERVAL_MINUTES": str(interval) if interval else ""}
            # install-autofix: sweep 전용 에이전트만, 등록 즉시 실행 없이(보드가 수정 실행을 시작하지 않게). backfill은 건드리지 않는다.
            irc, iout, ierr = _run(SCHEDULE_SH, ["install-autofix"], 60, env)
            _, sout, _ = _run(SCHEDULE_SH, ["status"], 30, env)
            status = _lines(sout)
            res["schedule"] = {"install_rc": irc, "install": ((iout or "") + (ierr or "")).strip()[-600:],
                               "status": status[-1] if status else None}
            if irc != 0:
                res["message"] = "내 설정에 저장함 — 정기 실행 등록은 아래 안내를 확인"
        return res
