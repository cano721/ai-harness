"""하네스 효과 화면 데이터 (#256). 집계와 판정은 scripts/impact.sh·impact-evidence.jq가 하고, 여기서는 돌리고 보관만 한다.

- impact.sh compare는 저장소마다 수십 초 걸릴 수 있어 요청 경로에서 돌리지 않는다. 뒤의 작업 스레드 하나가 한 번에
  한 저장소씩 돌리고, 결과를 $HARNESS_METRICS_DIR/board/impact/<저장소>/<날짜>.json에 둔다.
- 오늘 결과가 없으면 화면을 열 때 뒤에서 다시 계산한다(하루 한 번). "다시 계산"은 오늘 결과가 있어도 새로 돌린다.
- 실패(설치일 모름 exit 3 등)는 이유와 함께 그날 하루 기억한다. 같은 날 자동으로 다시 돌리지 않는다.
- 판정은 impact.sh view가 /harness-impact가 보관한 마지막 매칭으로 낸다. 보드는 판정 규칙을 갖지 않는다.
"""
import hashlib, json, os, re, subprocess, threading, time
from datetime import date, datetime, timezone

DIR = os.path.dirname(os.path.abspath(__file__))
IMPACT_SH = os.environ.get("BOARD_IMPACT_SH") or os.path.join(DIR, "..", "impact.sh")
TIMEOUT = int(os.environ.get("BOARD_IMPACT_TIMEOUT", "900"))
KEEP_DAYS = 7
WEEKS = 12
_DAY = re.compile(r"^\d{4}-\d{2}-\d{2}\.json$")


def _utc():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _read(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return None


def _write(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = f"{path}.tmp.{os.getpid()}.{threading.get_ident()}"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False)
    os.replace(tmp, path)


def _tail(text, n=300):
    text = (text or "").strip()
    return text[-n:]


def _author(repo):
    """재작업 비율은 내 PR만 센다(impact.sh compare --author). 이메일이 없으면 재작업은 빠진다."""
    try:
        out = subprocess.run(["git", "-C", repo, "config", "user.email"], capture_output=True, text=True, timeout=10)
    except Exception:
        return ""
    return out.stdout.strip() if out.returncode == 0 else ""


def failure_reason(code, stderr):
    if code == 3:
        return ("설치일을 찾지 못함 — .ai-harness/harness.json의 initialized도, AGENTS.md 커밋도 없습니다. "
                "그 저장소에서 /ai-harness:harness-impact --at YYYY-MM-DD 로 설치일을 정하면 리포트는 볼 수 있습니다.")
    if code == "timeout":
        return f"{TIMEOUT}초 안에 끝나지 않아 멈춤"
    return f"impact.sh compare 실패(exit {code})" + (f": {_tail(stderr)}" if _tail(stderr) else "")


class Store:
    def __init__(self, data_dir):
        self.data = data_dir
        self.root = os.path.join(data_dir, "board", "impact")
        self.lock = threading.Lock()
        self.queue = []  # repo 경로, 들어온 순서대로
        self.running = {}  # repo -> 시작 시각(ISO)
        self.worker = None
        self.views = {}  # cache 경로 -> (mtime, 읽은 시각, view)

    # ---- 경로 ----
    def repo_dir(self, repo):
        real = os.path.realpath(repo)
        name = re.sub(r"[^A-Za-z0-9._-]", "_", os.path.basename(real))[:40] or "repo"
        return os.path.join(self.root, f"{name}-{hashlib.sha1(real.encode()).hexdigest()[:10]}")

    def latest(self, repo):
        d = self.repo_dir(repo)
        try:
            days = sorted(n for n in os.listdir(d) if _DAY.match(n))
        except OSError:
            return None
        return os.path.join(d, days[-1]) if days else None

    def failed(self, repo):
        f = _read(os.path.join(self.repo_dir(repo), "failed.json"))
        return f if isinstance(f, dict) else None

    # ---- 계산 ----
    def ensure(self, repos):
        """오늘 결과도, 오늘 실패도 없는 저장소를 뒤에서 계산하도록 줄 세운다. 기다리지 않는다."""
        today = date.today().isoformat()
        for repo in repos:
            latest = self.latest(repo)
            fail = self.failed(repo)
            if latest and os.path.basename(latest) == f"{today}.json":
                continue
            if fail and fail.get("day") == today:
                continue
            self._enqueue(repo)

    def refresh(self, repo):
        try:
            os.remove(os.path.join(self.repo_dir(repo), "failed.json"))
        except OSError:
            pass
        return self._enqueue(repo)

    def _enqueue(self, repo):
        with self.lock:
            if repo in self.running or repo in self.queue:
                return False
            self.queue.append(repo)
            if not self.worker or not self.worker.is_alive():
                self.worker = threading.Thread(target=self._work, daemon=True)
                self.worker.start()
            return True

    def _work(self):
        while True:
            with self.lock:
                if not self.queue:
                    self.worker = None
                    return
                repo = self.queue.pop(0)
                self.running[repo] = _utc()
            try:
                self._compute(repo)
            except Exception as e:  # 한 저장소의 실패가 줄 전체를 멈추지 않게
                self._fail(repo, "error", str(e))
            finally:
                with self.lock:
                    self.running.pop(repo, None)

    def _compute(self, repo):
        args = ["bash", IMPACT_SH, "compare", "--root", repo]
        author = _author(repo)
        if author:
            args += ["--author", author]
        env = {**os.environ, "HARNESS_METRICS_DIR": self.data}
        try:
            out = subprocess.run(args, capture_output=True, text=True, timeout=TIMEOUT, env=env, cwd=repo, stdin=subprocess.DEVNULL)
        except subprocess.TimeoutExpired:
            return self._fail(repo, "timeout", "")
        if out.returncode != 0:
            return self._fail(repo, out.returncode, out.stderr)
        try:
            data = json.loads(out.stdout)
            assert isinstance(data, dict)
        except Exception:
            return self._fail(repo, "json", "compare 출력이 JSON 객체가 아님")
        today = date.today().isoformat()
        d = self.repo_dir(repo)
        _write(os.path.join(d, f"{today}.json"), {"repo": repo, "computed_at": _utc(), "data": data})
        try:
            os.remove(os.path.join(d, "failed.json"))
        except OSError:
            pass
        for old in sorted(n for n in os.listdir(d) if _DAY.match(n))[:-KEEP_DAYS]:
            try:
                os.remove(os.path.join(d, old))
            except OSError:
                pass

    def _fail(self, repo, code, stderr):
        _write(os.path.join(self.repo_dir(repo), "failed.json"),
               {"day": date.today().isoformat(), "at": _utc(), "code": code, "reason": failure_reason(code, stderr)})

    # ---- 화면 데이터 ----
    def _view(self, cache_path):
        """impact.sh view: 보관된 매칭으로 판정을 붙인 compare JSON. 캐시가 같으면 1분 동안 다시 부르지 않는다."""
        mtime = os.path.getmtime(cache_path)
        hit = self.views.get(cache_path)
        if hit and hit[0] == mtime and time.time() - hit[1] < 60:
            return hit[2]
        cached = _read(cache_path) or {}
        tmp = f"{cache_path}.view.{os.getpid()}.{threading.get_ident()}"
        try:
            _write(tmp, cached.get("data") or {})
            out = subprocess.run(["bash", IMPACT_SH, "view", "--data", tmp], capture_output=True, text=True, timeout=60,
                                 env={**os.environ, "HARNESS_METRICS_DIR": self.data}, stdin=subprocess.DEVNULL)
        finally:
            try:
                os.remove(tmp)
            except OSError:
                pass
        if out.returncode != 0:
            raise RuntimeError(_tail(out.stderr) or f"impact.sh view exit {out.returncode}")
        view = {"computed_at": cached.get("computed_at"), "data": json.loads(out.stdout)}
        self.views[cache_path] = (mtime, time.time(), view)
        return view

    def repo_state(self, repo, name):
        with self.lock:
            running = self.running.get(repo)
            queued = repo in self.queue
        latest = self.latest(repo)
        fail = self.failed(repo)
        row = {"repo": repo, "name": name, "running_since": running, "queued": queued,
               "cache_day": os.path.basename(latest)[:-5] if latest else None,
               "stale": bool(latest) and os.path.basename(latest) != f"{date.today().isoformat()}.json",
               "error": fail}
        row["state"] = "running" if running else "queued" if queued else "failed" if fail else "ready" if latest else "none"
        if latest:
            try:
                v = self._view(latest)
                row["computed_at"] = v["computed_at"]
                row.update(shape(v["data"]))
            except Exception as e:
                row["view_error"] = str(e)[:300]
        return row

    def report(self, repo):
        """그 저장소의 오프라인 리포트(impact.sh render)를 만들고 경로를 돌려준다. 보관된 매칭이 있으면 함께 싣는다."""
        latest = self.latest(repo)
        if not latest:
            return None, "아직 계산한 결과가 없음"
        cached = _read(latest) or {}
        data = cached.get("data") or {}
        tmp = f"{latest}.render.{os.getpid()}.{threading.get_ident()}"
        env = {**os.environ, "HARNESS_METRICS_DIR": self.data}
        try:
            _write(tmp, data)
            args = ["bash", IMPACT_SH, "render", "--data", tmp]
            hl = (self._view(latest)["data"].get("highlights") or {}).get("file")
            if hl and os.path.isfile(hl):
                args += ["--highlights", hl]
            out = subprocess.run(args, capture_output=True, text=True, timeout=120, env=env, stdin=subprocess.DEVNULL)
        finally:
            try:
                os.remove(tmp)
            except OSError:
                pass
        path = out.stdout.strip().splitlines()[-1] if out.returncode == 0 and out.stdout.strip() else ""
        if not path or not os.path.isfile(path):
            return None, _tail(out.stderr) or "리포트를 만들지 못함"
        return path, None


PERIOD_KEYS = ("since", "until", "sessions", "digested_sessions", "corrections", "corrections_per_session",
               "missing_context", "missing_context_per_session", "guard_blocks")
WEEK_KEYS = ("week", "after_install", "sessions", "digested_sessions", "corrections_per_session",
             "missing_context_per_session", "guard_blocks")
RESULT_KEYS = ("verdict", "label", "note", "before_hits", "after_hits", "window_hits", "baseline", "observed", "as_of",
               "unjudged", "after_truncated", "before_examples", "after_examples")


def _pick(d, keys):
    d = d if isinstance(d, dict) else {}
    return {k: d.get(k) for k in keys}


def _rework(side):
    if not isinstance(side, dict):
        return None
    return {"ratio": side.get("rework_ratio"), "prs": side.get("settled_prs")}


def shape(v):
    """impact.sh view 결과 → 화면에 필요한 것만. 후보·교정 목록 같은 큰 배열은 싣지 않는다."""
    periods = v.get("periods") or {}
    rework = v.get("rework") if isinstance(v.get("rework"), dict) else None
    imps = []
    for x in reversed(v.get("improvements") or []):  # 최신순
        before = x.get("before") or {}
        imps.append({
            "id": x.get("id"), "date": x.get("date"), "summary": x.get("summary"), "expected": x.get("expected"),
            "artifact": x.get("artifact"), "change": x.get("change") or "add",
            "basis": before.get("basis"), "before_observed": before.get("observed"),
            "window_observed": (before.get("window") or {}).get("observed"),
            "observed_now": (x.get("after") or {}).get("observed"),
            "result": _pick(x.get("result"), RESULT_KEYS),
        })
    return {
        "project": v.get("project"), "today": v.get("today"),
        "installed": v.get("installed"), "window_days": v.get("window_days"),
        "before": _pick(periods.get("before"), PERIOD_KEYS), "after": _pick(periods.get("after"), PERIOD_KEYS),
        "rework": {"before": _rework(rework.get("before")), "after": _rework(rework.get("after"))} if rework else None,
        "weekly": [_pick(w, WEEK_KEYS) for w in (v.get("weekly") or [])][-WEEKS:],
        "warnings": v.get("warnings") or [],
        # 비교 가능성·추세·저장소 상태는 impact.sh view(impact-assess.jq)가 정한 값을 그대로 싣는다(#260).
        "assessment": v.get("assessment") if isinstance(v.get("assessment"), dict) else None,
        "improvements": imps,
        "matched_through": (v.get("highlights") or {}).get("matched_through"),
    }
