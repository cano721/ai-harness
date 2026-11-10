"""하네스 보드 '자동 수정' 화면 데이터 (#278). 판정·상태 전이는 scripts/autofix-auto.sh가 하고, 여기서는 읽어서 모으기만 한다.

- 준비 상태는 monitor-fetch.sh describe(요청 없음, 자격증명 값 미출력)로 본다. 30초 캐시.
- 접근 확인(monitor-fetch.sh check)과 후보 조회(autofix-auto.sh candidates)는 모니터링 도구 API를 부르므로 버튼으로만 돌리고,
  결과를 $HARNESS_METRICS_DIR/board/autofix/에 둔다. 화면을 열거나 새로 고쳐도 다시 부르지 않는다.
- 진행·이력은 autofix-auto.sh status·runs, 개인 설정은 autofix-auto.sh configure(인자 없음 = 현재 값)를 그대로 쓴다.
- 쓰기는 autofix-auto.sh configure만 거친다(값 검증·원자적 쓰기의 단일 작성자). 주기를 바꾸면 schedule.sh install-autofix·status를
  돌린다(sweep 전용 에이전트만, 등록 즉시 실행 없음).
- 보드는 수정 실행(sweep·run)을 시작하지 않고 PR을 병합하지 않으며 monitor 설정 파일을 쓰지 않는다.
"""
import glob, json, os, subprocess, threading, time
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


def _child_env(extra=None):
    """autofix 설정(HM_AUTOFIX_*)은 자식이 ~/.ai-harness/config에서 다시 읽는다. 서버 환경에 남은 값을 넘기면 config에서
    지운 키가 되살아난다(config를 읽어도 지운 키는 덮어쓰지 못한다). board.sh도 config에서 온 키를 빼고 띄우지만, 다른 방법으로
    띄운 서버에서도 같게 여기서 한 번 더 뺀다."""
    env = {k: v for k, v in os.environ.items() if not k.startswith("HM_AUTOFIX_")}
    env.update(extra or {})
    return env


def _run(script, args, timeout, env=None):
    try:
        out = subprocess.run(["bash", script, *args], capture_output=True, text=True, timeout=timeout,
                             env=_child_env(env))
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


STAGE_KO = {"fixing": "수정 중", "pr": "PR 검토 대기", "deploy_wait": "병합됨 · 배포 대기", "observing": "배포됨 · 재발 관찰 중",
            "resolved": "해결", "regressed": "재발 · 다음 sweep이 다시 고침", "gave_up": "포기 · 사람에게 넘김",
            "skipped": "건너뜀", "declined": "PR 닫힘", "failed": "실행 실패"}
OUTCOME_KO = {"left_for_user": "사람 판단 필요", "not_code_bug": "코드 버그 아님", "not_reproducible": "재현 불가",
              "no_result": "결과 없음", "deploy_unobserved": "배포 확인 못 함"}


def board_state(sig):
    """통합 목록의 열: 사람이 할 일(넘김·포기·실패·PR 검토) → needs_human, 자동으로 진행 중 → running,
    다음 sweep이 다시 고칠 것 → queued, 끝난 것(해결·PR 닫힘·코드 버그 아님 등으로 건너뜀) → done."""
    st = sig.get("status")
    if st in ("gave_up", "failed", "pr_open") or (st == "skipped" and sig.get("outcome") == "left_for_user"):
        return "needs_human"
    if st in ("attempting", "verifying"):
        return "running"
    if st == "regressed":
        return "queued"
    return "done"


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
        self._out = {}  # 명령 -> (파일 지문, 출력)

    def _fingerprint(self):
        """status·runs 출력이 기대는 파일(실행 기록·상태 파일)의 크기·수정 시각. 바뀌지 않았으면 다시 돌리지 않는다 —
        sweep마다 건너뜀 기록이 쌓여 runs.jsonl이 커져도 보드가 몇 초마다 전체를 다시 훑지 않게."""
        af = os.path.join(self.data, "autofix")
        parts = []
        for p in [os.path.join(af, "runs.jsonl")] + sorted(glob.glob(os.path.join(af, "*", "state.json"))):
            try:
                st = os.stat(p)
                parts.append((p, st.st_size, st.st_mtime_ns))
            except OSError:
                parts.append((p, None, None))
        return tuple(parts)

    def _cached(self, args):
        fp, key = self._fingerprint(), " ".join(args)
        hit = self._out.get(key)
        if hit and hit[0] == fp:
            return hit[1]
        rc, out, _ = _run(AUTOFIX_SH, args, 30)
        if rc == 0:  # 실패(시간 초과 등)는 남기지 않는다 — 파일이 바뀔 때까지 빈 화면에 머물지 않게
            self._out[key] = (fp, out)
        return out

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
        out = self._cached(["status"])
        sigs = _lines(out)
        out = self._cached(["runs", "--limit", str(RUNS_WINDOW)])
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
            if pid and pid not in seen:  # project가 없는 기록은 어느 저장소에도 붙일 수 없어 뺀다
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

    def items(self, repos_fn, key_of, ttl=10):
        """보드 통합 목록에 넣을 에러 시그니처 카드. status(상태 파일 + 상태 파일을 잃은 프로젝트의 실행 기록 복구)를 그대로 옮긴다.
        repos_fn은 저장소 찾기(git 호출)라 캐시가 지났을 때만 부른다."""
        hit = getattr(self, "_items", None)
        if hit and time.time() - hit[0] < ttl:
            return [dict(i) for i in hit[1]]
        out = self._cached(["status"])
        sigs = _lines(out)
        repo_of = {}
        for r in (repos_fn() if sigs else []):  # 자동 수정을 쓰지 않으면 저장소 찾기(git 호출)를 하지 않는다
            repo_of.setdefault(key_of(r), r)
        res = []
        for s in sigs:
            sig, project = s.get("signature") or "", s.get("project") or ""
            if not sig or not project:  # 어느 저장소·에러인지 모르는 기록은 카드로 만들지 않는다
                continue
            st, stg = board_state(s), stage(s)
            word = STAGE_KO.get(stg, stg)
            if s.get("status") == "skipped" and s.get("outcome"):
                word = f"건너뜀 · {OUTCOME_KO.get(s['outcome'], s['outcome'])}"
            if s.get("status") == "gave_up" and s.get("outcome") == "deploy_unobserved":
                word = "포기 · 배포 확인 못 함"
            if s.get("status") == "failed" and s.get("last_reason"):
                word = f"실행 실패 · {s['last_reason']}"
            log = os.path.basename(str(s.get("last_log") or ""))
            pr = s.get("pr") if str(s.get("pr") or "").startswith("https://") else None
            item = {"id": f"autofix:{project}:{sig}", "section": "autofix", "kind": "autofix", "project": project,
                    "state": st, "at": s.get("updated_at") or s.get("first_detected_at"), "title": s.get("title") or sig,
                    "detail": s.get("summary"), "link": pr, "signature": sig, "stage": stg, "stage_label": word,
                    "count": s.get("count"), "attempts": s.get("attempts"), "regressions": s.get("regressions"),
                    "verify_until": s.get("verify_until"), "recovered": s.get("recovered"),
                    "monitor_link": s.get("link") if str(s.get("link") or "").startswith("https://") else None,
                    "log_name": log if log and self.log_path(log) else None,
                    "repo": repo_of.get(project), "actions": []}
            if st == "needs_human" and item["repo"]:
                item["actions"] = ["open_agent"]
            res.append(item)
        self._items = (time.time(), res)
        return [dict(i) for i in res]

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
