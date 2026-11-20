"""하네스 보드 '자동 수정' 화면 데이터 (#278). 판정·상태 전이는 scripts/autofix-auto.sh가 하고, 여기서는 읽어서 모으기만 한다.

- 준비 상태는 monitor-fetch.sh describe(요청 없음, 자격증명 값 미출력)로 본다. 30초 캐시.
- 접근 확인(monitor-fetch.sh check)·후보 조회(autofix-auto.sh candidates)·원문 조회(monitor-fetch.sh detail)는 모니터링 도구 API를
  부르므로 버튼으로만 돌리고,
  결과를 $HARNESS_METRICS_DIR/board/autofix/에 둔다. 화면을 열거나 새로 고쳐도 다시 부르지 않는다.
- 진행·이력은 autofix-auto.sh status·runs, 개인 설정은 autofix-auto.sh configure(인자 없음 = 현재 값)를 그대로 쓴다.
- 쓰기는 autofix-auto.sh configure만 거친다(값 검증·원자적 쓰기의 단일 작성자). 주기를 바꾸면 schedule.sh install-autofix·status를
  돌린다(sweep 전용 에이전트만, 등록 즉시 실행 없음).
- 설정 폼(#450): 최근 에러 조회(monitor-fetch.sh discover)는 버튼으로만 부르고 결과를 캐시한다. 저장은 캐시한 줄 가운데
  고른 것만으로 monitor를 만들어 monitor-fetch.sh save(검증·원자적 쓰기의 단일 작성자)에 넘긴다 — 보드가 파일을 직접 쓰지 않고,
  화면이 보낸 query·이름을 그대로 쓰지 않는다. 쓰는 곳은 개인 로컬 파일뿐이다.
- 보드는 수정 실행(sweep·run)을 시작하지 않고 PR을 병합하지 않는다.
"""
import glob, json, os, re, subprocess, threading, time
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
CANDIDATE_KEYS = ("signature", "title", "culprit", "count", "first_seen", "last_seen", "reason", "link", "provider", "meta")
DETAIL_MAX = 8000  # 펼친 줄에 보일 원문(스택·샘플) 길이 상한
RUN_KEYS = ("at", "event", "project", "signature", "reason", "outcome", "artifact", "duration_s", "cost_usd", "exit_code", "next")
DISCOVER_HOURS = (24, 168)
DISCOVER_MAX = 400  # 조직 전체 조회라 저장소 서비스가 상위 몇십 줄 밖에 있을 수 있다. 화면은 검색칸으로 좁힌다
DD_SITES = ("datadoghq.com", "us3.datadoghq.com", "us5.datadoghq.com", "datadoghq.eu", "ap1.datadoghq.com", "ap2.datadoghq.com", "ddog-gov.com")
SLUG_RE = re.compile(r"^[A-Za-z0-9._-]+$")
DD_BARE_RE = re.compile(r"^[A-Za-z0-9._/-]+$")
MONITOR_INT_KEYS = ("min_events", "window_hours", "grace_hours", "quiet_hours")
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


def _dd_term(key, value):
    """monitor-fetch.sh DD_TERM과 같은 표기: 공백·특수문자가 있으면 따옴표로 감싼다."""
    return f"{key}:{value}" if DD_BARE_RE.match(value) else f"{key}:{json.dumps(value, ensure_ascii=False)}"


def datadog_query(rows):
    """고른 service·env 줄로 query를 만든다. 한 줄이면 discover가 준 query, env가 같으면 service만 OR로 묶고,
    env가 섞이면 줄마다 (service env)를 OR로 묶는다 — 고르지 않은 조합(api의 staging 등)이 끼지 않게."""
    if len(rows) == 1:
        return rows[0]["query"]
    envs = {r["env"] for r in rows}
    if len(envs) == 1:
        env = next(iter(envs))
        services = " OR ".join(_dd_term("service", r["service"]) for r in rows)
        return " ".join([f"({services})"] + ([_dd_term("env", env)] if env else []) + ["status:error"])
    clauses = " OR ".join("(" + " ".join([_dd_term("service", r["service"])] + ([_dd_term("env", r["env"])] if r["env"] else [])) + ")"
                          for r in rows)
    return f"({clauses}) status:error"


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
        checks, cands, details = self._load("checks.json"), self._load("candidates.json"), self._load("details.json")
        rows, seen = [], set()
        for repo in repos:
            pid = key_of(repo)
            seen.add(pid)
            rows.append({"repo": repo, "name": os.path.basename(repo), "project": pid, "ready": self.readiness(repo),
                         "targeted": pid in targets, "signatures": by_project.get(pid, []),
                         "check": checks.get(repo), "candidates": cands.get(repo),
                         "details": {k.split("\u0000", 1)[1]: v for k, v in details.items() if k.startswith(repo + "\u0000")}})
        for pid, lst in by_project.items():  # 상태는 있는데 이 맥에서 저장소를 찾지 못한 프로젝트
            if pid and pid not in seen:  # project가 없는 기록은 어느 저장소에도 붙일 수 없어 뺀다
                rows.append({"repo": None, "name": pid, "project": pid, "ready": None, "targeted": pid in targets,
                             "signatures": lst, "check": None, "candidates": None, "details": {}})
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
        cand_title = {}  # 상태 파일에 제목이 없는 시그니처(수동 track·복구)는 마지막 후보 조회의 제목을 빌린다
        for r, c in self._load("candidates.json").items():
            for it in (c or {}).get("items") or []:
                if it.get("signature") and it.get("title"):
                    cand_title.setdefault(it["signature"], it["title"])
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
                    "state": st, "at": s.get("updated_at") or s.get("first_detected_at"),
                    "title": s.get("title") or cand_title.get(sig) or sig, "status": s.get("status"), "outcome": s.get("outcome"),
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

    def detail(self, repo, project, signature):
        """에러 하나의 원문(스택·샘플). 조회 정보(meta)는 마지막 후보 조회나 상태 파일에서 찾는다. 비밀값은 monitor-fetch.sh가 가린다."""
        meta = next((c.get("meta") for c in (self._load("candidates.json").get(repo) or {}).get("items") or []
                     if c.get("signature") == signature), None)
        if not isinstance(meta, dict):
            meta = next((s.get("meta") for s in _lines(self._cached(["status"]))
                         if s.get("project") == project and s.get("signature") == signature), None)
        if not isinstance(meta, dict):
            res = {"at": _utc(), "detail": None, "error": "이 에러를 다시 찾을 조회 정보가 없습니다. 후보를 다시 조회한 뒤 열어 보세요."}
        else:
            rc, out, err = _run(MONITOR_SH, ["detail", "--root", repo, "--meta", json.dumps(meta, separators=(",", ":"))], 90)
            rows = _lines(out)
            if rc == 0 and rows:
                text = json.dumps(rows[-1], ensure_ascii=False)
                res = {"at": _utc(), "detail": rows[-1] if len(text) <= DETAIL_MAX else {"truncated": text[:DETAIL_MAX]}, "error": None}
            else:
                res = {"at": _utc(), "detail": None, "error": _last_line(err, out) or f"원문을 불러오지 못함(exit {rc})"}
        self._put("details.json", f"{repo}\u0000{signature}", res)
        return res

    # ---- 설정 폼 ----
    @staticmethod
    def _discover_key(provider, site=None, org=None):
        return f"{provider}|{site or org or ''}"

    def discover(self, req):
        provider, hours = req.get("provider"), req.get("hours", 24)
        site, org = req.get("site") or None, req.get("org") or None
        if provider not in ("datadog", "sentry"):
            return {"ok": False, "message": "datadog·sentry만 조회합니다"}
        if hours not in DISCOVER_HOURS:
            return {"ok": False, "message": "조회 기간은 24시간·7일만"}
        args = ["discover", "--provider", provider, "--hours", str(hours)]
        if provider == "datadog":
            org = None
            if site is not None and site not in DD_SITES:
                return {"ok": False, "message": "지원하지 않는 Datadog 사이트"}
            if site:
                args += ["--site", site]
        else:
            site = None
            if org is not None and not (isinstance(org, str) and SLUG_RE.match(org)):
                return {"ok": False, "message": "Sentry 조직 이름이 올바르지 않음"}
            if org:
                args += ["--org", org]
        rc, out, err = _run(MONITOR_SH, args, 90)
        if rc != 0:
            msg = _last_line(err, out) or f"최근 에러를 불러오지 못함(exit {rc})"
            if rc == 4:
                msg += " — 자격증명은 /ai-harness:setup에서 저장합니다."
            res = {"at": _utc(), "hours": hours, "items": [], "error": msg}
        else:
            if provider == "datadog":
                keys = ("service", "env", "count", "query")
            elif org:
                keys = ("project", "environment", "events", "issues")
            else:
                keys = ("org", "name")
            items = [{k: r.get(k) for k in keys} for r in _lines(out)][:DISCOVER_MAX]
            for it in items:
                for k in keys:
                    if k in ("count", "events", "issues"):
                        it[k] = it[k] if isinstance(it[k], int) else 0
                    elif not isinstance(it[k], str):
                        it[k] = ""
            res = {"at": _utc(), "hours": hours, "items": items, "error": None}
        res["kind"] = "orgs" if provider == "sentry" and not org else "rows"
        self._put("discover.json", self._discover_key(provider, site, org), res)
        n = len(res["items"])
        return {"ok": not res["error"], "message": res["error"] or (f"조직 {n}곳" if res["kind"] == "orgs" else f"최근 에러 묶음 {n}개"),
                "discover": res}

    def save_monitor(self, repo, req):
        """캐시한 discover 줄 가운데 고른 것으로 monitor를 만들어 monitor-fetch.sh save에 넘긴다. 이어서 접근을 확인한다."""
        provider, picks = req.get("provider"), req.get("picks")
        site, org = req.get("site") or None, req.get("org") or None
        if provider not in ("datadog", "sentry"):
            return {"ok": False, "message": "datadog·sentry만 저장합니다"}
        if not isinstance(picks, list) or not picks or not all(isinstance(p, dict) for p in picks):
            return {"ok": False, "message": "최근 에러 표에서 하나 이상 고르세요"}
        cached = self._load("discover.json").get(self._discover_key(provider, site if provider == "datadog" else None,
                                                                    org if provider == "sentry" else None)) or {}
        rows = cached.get("items") if cached.get("kind") == "rows" else None
        if not rows:
            return {"ok": False, "message": "최근 에러를 먼저 불러오세요"}
        if provider == "datadog":
            if site is not None and site not in DD_SITES:
                return {"ok": False, "message": "지원하지 않는 Datadog 사이트"}
            chosen = []
            for p in picks:
                hit = next((r for r in rows if r.get("service") == p.get("service") and r.get("env") == p.get("env")), None)
                if not hit:
                    return {"ok": False, "message": "고른 줄이 마지막 조회 결과에 없습니다. 다시 불러온 뒤 고르세요."}
                if hit not in chosen:
                    chosen.append(hit)
            monitor = {"provider": "datadog", "query": datadog_query(chosen)}
            if site and site != "datadoghq.com":
                monitor["site"] = site
        else:
            if len(picks) != 1:
                return {"ok": False, "message": "Sentry는 프로젝트·환경 한 줄만 고릅니다"}
            p = picks[0]
            hit = next((r for r in rows if r.get("project") == p.get("project") and r.get("environment") == p.get("environment")), None)
            if not hit:
                return {"ok": False, "message": "고른 줄이 마지막 조회 결과에 없습니다. 다시 불러온 뒤 고르세요."}
            monitor = {"provider": "sentry", "org": org, "project": hit["project"]}
            if hit["environment"]:
                monitor["environment"] = hit["environment"]
        opts = req.get("options") or {}
        if not isinstance(opts, dict):
            return {"ok": False, "message": "추가 설정이 올바르지 않음"}
        for k, v in opts.items():
            if k in MONITOR_INT_KEYS and isinstance(v, int) and not isinstance(v, bool) and 0 <= v <= 100000:
                monitor[k] = v
            elif k == "deploy_branch" and isinstance(v, str) and v.strip():
                monitor[k] = v.strip()
            elif not (k == "deploy_branch" and v in ("", None)):
                return {"ok": False, "message": f"{k} 값이 올바르지 않음"}
        rc, out, err = _run(MONITOR_SH, ["save", "--root", repo, "--monitor", json.dumps(monitor, ensure_ascii=False)], 30)
        rows = _lines(out)
        if rc != 0 or not rows:
            return {"ok": False, "message": _last_line(err, out) or f"설정을 저장하지 못함(exit {rc})", "monitor": monitor}
        check = self.check(repo)
        msg = "개인 설정에 저장함 — 접근 확인됨" if check.get("code") == 0 else \
            f"개인 설정에 저장함 — 접근 확인은 실패({check['label']}). 연결 행의 안내를 확인하세요"
        return {"ok": True, "message": msg, "monitor": rows[-1].get("monitor"), "check": check}

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
