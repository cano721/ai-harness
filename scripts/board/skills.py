"""보드 '하네스 설정 > 스킬'(#494): 카탈로그·디자인 스킬의 설치·토큰·연결 상태와 setup 세션 요청.

- 상태 판정의 원본은 scripts/setup.sh 하나다. `setup.sh list`·`setup.sh design list`를 불러 그대로 쓴다 — 설치 판정
  (absent·current·outdated·modified·foreign)과 키를 찾는 순서가 setup 스킬과 같고, 키 값은 원래 출력되지 않는다.
  스킬 폴더도 setup.sh 규칙(HM_CLAUDE_SKILLS_DIR·HM_CODEX_SKILLS_DIR)을 따른다. 결과는 짧게 캐시하고 세션이 끝나면 비운다.
- 카탈로그 스킬은 missing(미설치) · no_token(설치됨·필수 키 없음) · unverified(키는 있는데 연결 확인 없음·실패) ·
  verified(마지막 연결 확인 성공) 중 하나. 연결 확인(`setup.sh check`)은 외부 API라 버튼을 눌렀을 때만 부르고
  결과는 {ok, at, error}만 board/skill-checks.json에 남긴다(as·hint는 응답에만).
- 디자인 스킬은 토큰이 없어 installed · missing · builtin(내장) · superseded(내장으로 대체된 예전 사본) ·
  unavailable(설치 불가: 이 도구엔 없음·원본 미고정) 중 하나.
- setup 세션의 지시문은 서버가 카탈로그 이름과 고정 문구로만 만든다. 브라우저가 보낸 문자열은 넣지 않는다.
  비밀 값은 대화로 받지 않고 별도 터미널의 `setup.sh set`(숨김 입력)으로 안내한다(setup SKILL 5-4).
- 띄운 세션은 board/skill-sessions.json에 {"<kind>:<name>": {sid, action, name, at}}로 남기고, 보드가 세션 상태를 붙인다.
  내 일정 소스의 [설정하기] 세션(#525)도 같은 파일에 "agenda:<소스 id>"로 남는다 — 검사·지시문은 보드 서버가 agenda.py로 만들고
  (kind agenda는 KINDS·validate를 거치지 않는다), 기록·끝난 세션 지우기만 여기를 같이 쓴다.
"""
import json, os, re, subprocess, threading, time
from datetime import datetime, timezone

DIR = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(DIR, "..", ".."))
SETUP = os.path.join(ROOT, "scripts", "setup.sh")
KINDS = ("catalog", "design")
ACTIONS = ("install", "setup", "remove")
ACTION_LABEL = {"install": "설치", "setup": "설정", "remove": "제거"}
INSTALLED = ("current", "outdated", "modified", "foreign")
LIST_TTL = float(os.environ.get("BOARD_SKILLS_TTL", "30"))
NAME_RE = re.compile(r"[a-z0-9][a-z0-9-]{0,63}")
STATUS_RE = re.compile(r"[a-z]{1,20}")


def utc():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def catalog_state(row, check):
    """setup.sh list 한 줄 → missing | no_token | unverified | verified (env가 없는 스킬은 installed)."""
    st = row.get("status") or {}
    if not any(st.get(t) in INSTALLED for t in ("claude", "codex")):
        return "missing"
    env = row.get("env") or []
    if any(e.get("required") and not e.get("found") for e in env):
        return "no_token"
    if not env:
        return "installed"
    return "verified" if check and check.get("ok") else "unverified"


def design_state(row):
    """setup.sh design list 한 줄 → installed | superseded | missing | builtin | unavailable."""
    vals = [(row.get("status") or {}).get(t) for t in ("claude", "codex")]
    if any(v in INSTALLED for v in vals):
        return "installed"
    if "superseded" in vals:
        return "superseded"
    if "absent" in vals:
        return "missing"
    if "builtin" in vals:
        return "builtin"
    return "unavailable"


def _flags(row):
    """도구별 보조 표시: 최신이 아님·고친 사본·직접 둔 폴더·대체됨."""
    return [{"tool": t, "status": s} for t, s in sorted((row.get("status") or {}).items())
            if s in ("outdated", "modified", "foreign", "superseded")]


class Store:
    def __init__(self, data, setup=None):
        self.dir = os.path.join(data, "board")
        self.checks_path = os.path.join(self.dir, "skill-checks.json")
        self.sessions_path = os.path.join(self.dir, "skill-sessions.json")
        self.setup = setup or os.environ.get("BOARD_SETUP_SH") or SETUP
        self.lock = threading.Lock()
        self.cache = {"at": 0.0, "catalog": None, "design": None, "error": None}

    # ---- 파일 ----
    def _load(self, path):
        try:
            with open(path, encoding="utf-8") as f:
                d = json.load(f)
            return d if isinstance(d, dict) else {}
        except (OSError, ValueError):
            return {}

    def _save(self, path, data):
        os.makedirs(self.dir, exist_ok=True)
        tmp = f"{path}.tmp.{os.getpid()}"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False)
        os.replace(tmp, path)

    # ---- setup.sh ----
    def _run(self, args, timeout):
        return subprocess.run(["bash", self.setup] + args, capture_output=True, text=True, timeout=timeout)

    def _lines(self, args):
        out = self._run(args, 60)
        if out.returncode != 0:
            raise RuntimeError((out.stderr.strip().splitlines() or [f"종료 코드 {out.returncode}"])[-1][:200])
        return [json.loads(l) for l in out.stdout.splitlines() if l.strip()]

    def invalidate(self):
        with self.lock:
            self.cache["at"] = 0.0

    def lists(self, force=False):
        """(catalog 줄, design 줄, 오류). 둘 다 setup.sh 출력 그대로. LIST_TTL초 캐시."""
        with self.lock:
            if force or self.cache["catalog"] is None or time.time() - self.cache["at"] > LIST_TTL:
                try:
                    cat, des = self._lines(["list"]), self._lines(["design", "list"])
                    self.cache.update(at=time.time(), catalog=cat, design=des, error=None)
                except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as e:
                    self.cache.update(at=time.time(), catalog=None, design=None,
                                      error=f"setup.sh가 스킬 상태를 읽지 못했습니다({str(e)[:200]})")
            return self.cache["catalog"], self.cache["design"], self.cache["error"]

    # ---- 화면 데이터 ----
    def view(self, sessions=None):
        """sessions: {"<kind>:<name>": {state, item_id, action, at}} — 보드가 작업 목록에서 붙인 진행 중 세션."""
        sessions = sessions or {}
        cat, des, err = self.lists()
        if err:
            return {"ok": False, "message": err}
        checks = self._load(self.checks_path)
        catalog = []
        for r in cat:
            name = r.get("name")
            check = checks.get(name) if isinstance(checks.get(name), dict) else None
            state = catalog_state(r, check)
            env = r.get("env") or []
            catalog.append({
                "name": name, "summary": r.get("summary") or "", "state": state, "status": r.get("status") or {},
                "flags": _flags(r), "has_env": bool(env),
                "missing": [(e.get("keys") or ["?"])[0] for e in env if e.get("required") and not e.get("found")],
                "check": {k: check.get(k) for k in ("ok", "at", "error") if k in check} if check and state in ("verified", "unverified") else None,
                "session": sessions.get(f"catalog:{name}"),
            })
        design = []
        for r in des:
            name = r.get("name")
            design.append({
                "name": name, "summary": r.get("summary") or "", "bundle": r.get("bundle"), "state": design_state(r),
                "status": r.get("status") or {}, "flags": _flags(r), "builtin": r.get("builtin"), "note": r.get("note"),
                "conflict": r.get("conflict"), "session": sessions.get(f"design:{name}"),
            })
        return {"ok": True, "catalog": catalog, "design": design}

    def _row(self, kind, name):
        cat, des, err = self.lists()
        if err:
            return None, err
        rows = cat if kind == "catalog" else des
        return next((r for r in rows if r.get("name") == name), None), None

    # ---- 연결 확인 ----
    def check(self, name):
        if not isinstance(name, str) or not NAME_RE.fullmatch(name):
            return {"ok": False, "message": "카탈로그에 없는 스킬"}
        row, err = self._row("catalog", name)
        if err:
            return {"ok": False, "message": err}
        if not row:
            return {"ok": False, "message": "카탈로그에 없는 스킬"}
        if not row.get("env"):
            return {"ok": False, "message": "연결 정보가 없는 스킬이라 확인할 것이 없습니다."}
        try:
            out = self._run(["check", name], 90)
            res = json.loads((out.stdout.strip().splitlines() or ["{}"])[-1])
        except (OSError, ValueError, subprocess.TimeoutExpired) as e:
            res = {"ok": False, "error": f"확인을 마치지 못함({str(e)[:120]})"}
        ok = res.get("ok") is True
        missing = ", ".join(str(k) for k in res.get("missing") or [])
        error = None if ok else str(res.get("error") or (f"필수 키 없음: {missing}" if missing else "원인 모름"))[:200]
        rec = {"ok": ok, "at": utc()}
        if error:
            rec["error"] = error
        with self.lock:
            checks = self._load(self.checks_path)
            checks[name] = rec
            self._save(self.checks_path, checks)
        out = {"ok": True, "check": rec, "message": f"{name} 연결을 확인했습니다." if ok else f"{name} 연결 확인에 실패했습니다: {error}"}
        if ok and res.get("as"):
            out["as"] = str(res["as"])[:200]
        if not ok and res.get("hint"):
            out["hint"] = str(res["hint"])[:300]
        return out

    # ---- 세션 ----
    def validate(self, kind, name, action):
        """세션 요청 검사. (row, None) 또는 (None, 사유)."""
        if kind not in KINDS:
            return None, "알 수 없는 스킬 종류"
        if action not in ACTIONS:
            return None, "알 수 없는 동작"
        if not isinstance(name, str) or not NAME_RE.fullmatch(name):
            return None, "카탈로그에 없는 스킬"
        row, err = self._row(kind, name)
        if err:
            return None, err
        if not row:
            return None, "카탈로그에 없는 스킬"
        if kind == "catalog":
            state = catalog_state(row, None)
            if action == "install" and state != "missing":
                return None, "이미 설치된 스킬입니다."
            if action == "setup" and (state == "missing" or not row.get("env")):
                return None, "설치했고 연결 정보가 있는 스킬만 설정할 수 있습니다."
            if action == "remove" and state == "missing":
                return None, "설치되지 않은 스킬은 제거할 수 없습니다."
        else:
            state = design_state(row)
            if action == "setup":
                return None, "디자인 스킬에는 설정할 연결 정보가 없습니다."
            if action == "install" and state != "missing":
                return None, "설치할 수 없는 항목입니다(이미 설치·내장·설치 불가)."
            if action == "remove" and state not in ("installed", "superseded"):
                return None, "설치된 항목만 제거할 수 있습니다."
        return row, None

    def session_name(self, action, name):
        return f"하네스 설정: 스킬 {ACTION_LABEL[action]} {name}"

    def prompt(self, kind, name, action, row):
        """서버가 만드는 setup 세션 지시문. name·상태 값은 카탈로그·setup.sh 출력에서 온 것만 쓴다."""
        st = row.get("status") or {}
        now = ", ".join(f"{t}={s}" for t, s in sorted(st.items()) if t in ("claude", "codex") and STATUS_RE.fullmatch(str(s)))
        setup = SETUP
        what = "카탈로그 스킬" if kind == "catalog" else "디자인 스킬"
        lines = [
            f"/ai-harness:setup 보드 '하네스 설정 > 스킬'에서 {what} {name}의 [{ACTION_LABEL[action]}]을 눌러 띄운 세션입니다.",
            f"전체 셋업이 아니라 아래 단계만 {name} 하나에 적용합니다. 다른 스킬은 설치·제거·갱신하지 않고, 마무리(setup.sh done)·사용자 규칙·자동화 옵션 단계는 건너뜁니다.",
            f"지금 상태(setup.sh {'list' if kind == 'catalog' else 'design list'}): {now or '모름'}",
        ]
        if kind == "catalog" and action == "install":
            lines += [
                "- 단계: '3. 설치·제거'의 설치.",
                "- 설치할 도구(claude·codex·both)는 '2. 고르기' 2번 규칙대로 사용자에게 묻습니다.",
                f"- 실행: {setup} install --tool <도구> {name}",
                "- 설치 뒤 필수 키가 비어 있으면 알리고, 사용자가 원하면 '5. 접속 정보'와 '6. 연결 확인'을 이 스킬에만 이어서 적용합니다.",
            ]
        elif kind == "catalog" and action == "setup":
            lines += [
                "- 단계: '5. 접속 정보 — 발급·저장·연결 확인'과 '6. 연결 확인'.",
                "- 저장할 도구(claude·codex·both)는 '2. 고르기' 2번 규칙대로 사용자에게 묻습니다.",
                f"- 연결 확인: {setup} check {name}",
            ]
        elif kind == "catalog":
            lines += [
                "- 단계: '3. 설치·제거'의 제거.",
                "- 지우기 전에 어느 도구에서 지울지와 제거 여부를 사용자에게 다시 확인합니다. 확인받지 않으면 지우지 않습니다.",
                f"- 실행: {setup} remove --tool <도구> {name}",
            ]
        elif action == "install":
            lines += [
                "- 단계: '디자인 스킬 (design)' 4번의 설치.",
                "- 설치할 도구(claude·codex·both)는 '2. 고르기' 2번 규칙대로 사용자에게 묻습니다. 실행하는 것·네트워크(review)를 먼저 보여 줍니다.",
                f"- 실행: {setup} design install --tool <도구> {name}",
            ]
        else:
            lines += [
                "- 단계: '디자인 스킬 (design)' 4번의 제거.",
                "- 지우기 전에 어느 도구에서 지울지와 제거 여부를 사용자에게 다시 확인합니다. 확인받지 않으면 지우지 않습니다.",
                f"- 실행: {setup} design remove --tool <도구> {name}",
            ]
        lines += [
            "- foreign(직접 둔 폴더)·modified(고친 사본)는 사용자가 명시하지 않으면 바꾸거나 지우지 않습니다(--replace·--force 금지).",
            "- 비밀 값(토큰·키)은 대화로 받지 않습니다. 사용자가 별도 터미널에서 "
            f"`{setup} set --tool <도구> <KEY>`(숨김 입력)를 실행하게 안내하고, 끝났다고 답하면 다음으로 갑니다. 이 세션의 Bash로 대신 실행하지 않습니다.",
            "- 끝나면 결과를 짧게 요약합니다. 보드는 세션이 끝나면 상태를 다시 읽습니다.",
        ]
        return "\n".join(lines)

    def record_session(self, kind, name, action, sid, label):
        with self.lock:
            recs = self._load(self.sessions_path)
            recs[f"{kind}:{name}"] = {"sid": sid, "action": action, "name": label, "at": time.time()}
            self._save(self.sessions_path, recs)

    def sessions(self):
        return {k: v for k, v in self._load(self.sessions_path).items() if isinstance(v, dict)}

    def end_sessions(self, keys):
        """끝난 세션 기록을 지우고, 그 스킬의 연결 확인 기록(키가 바뀌었을 수 있음)과 상태 캐시를 비운다."""
        if not keys:
            return
        with self.lock:
            recs = self._load(self.sessions_path)
            checks = self._load(self.checks_path)
            for k in keys:
                recs.pop(k, None)
                kind, _, name = k.partition(":")
                if kind == "catalog":
                    checks.pop(name, None)
            self._save(self.sessions_path, recs)
            self._save(self.checks_path, checks)
            self.cache["at"] = 0.0
