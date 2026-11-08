#!/usr/bin/env python3
"""Harness Board 로컬 서버 (표준 라이브러리만 사용). Orca 없이 동작한다. 띄우고 끄는 것은 board.sh가 한다.

GET  /?t=TOKEN                   보드 화면
GET  /status.json?t=...          status.sh 결과(작업 = claude agents, 하네스 = ~/.ai-harness)
GET  /transcript?t&id&offset     세션 대화를 offset 이후만 읽어 돌려줌(파일 tail)
POST /action  {t, id, action}    미리 정한 작업만 실행. send는 {text}
POST /new     {t, cwd, prompt}   claude --bg 새 세션
GET  /impact?t=...               하네스 효과: 저장소별 impact.sh compare 캐시 + 판정(계산은 뒤에서, 하루 한 번)
POST /impact/refresh {t, repo}   그 저장소를 다시 계산하도록 줄 세움
GET  /impact/report?t&repo       그 저장소의 오프라인 리포트(impact.sh render)를 만들어 보여 줌
GET  /autofix?t=...              자동 수정: 준비 상태(describe, 요청 없음)·에러별 진행·최근 실행·내 설정. 외부 API는 부르지 않음
GET  /autofix/log?t&name         autofix 실행 로그(~/.ai-harness/autofix/logs/ 안 파일 이름만)
POST /autofix/check {t, repo}    monitor-fetch.sh check(외부 API) — 버튼으로만, 결과 캐시
POST /autofix/candidates {t, repo}  autofix-auto.sh candidates(외부 API) — 버튼으로만, 결과 캐시
POST /autofix/configure {t, ...} autofix-auto.sh configure로만 개인 설정을 씀. 주기를 바꾸면 schedule.sh install-autofix·status
POST /autofix/setup {t, repo}    그 저장소에서 /ai-harness:autofix setup 세션을 띄움(보드는 monitor 파일을 쓰지 않음)

브라우저에서 명령 문자열은 받지 않는다. 항목 id로 status를 다시 찾아 서버가 인자를 만든다.
127.0.0.1에만 묶고, 실행마다 새 URL 토큰·Origin·Host(DNS rebinding)를 검사한다. 권한 훅 엔드포인트는 별도 토큰을 쓴다.
상태 파일은 플러그인 경로가 아니라 $HARNESS_METRICS_DIR/board/에 둔다 — 플러그인이 업데이트돼도 그대로 이어 쓴다.
"""
import atexit, json, os, re, secrets, shutil, signal, subprocess, sys, threading, time, unicodedata, webbrowser
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import groups
import autofix as hautofix  # noqa: E402
import impact as himpact  # noqa: E402
import prstate  # noqa: E402
import settings as hsettings  # noqa: E402

DIR = os.path.dirname(os.path.abspath(__file__))
TOKEN = secrets.token_urlsafe(24)
HOST, PORT = "127.0.0.1", int(os.environ.get("BOARD_PORT", "8765"))
DATA = os.environ.get("HARNESS_METRICS_DIR") or os.path.expanduser("~/.ai-harness")
LOG = os.environ.get("BOARD_ACTION_LOG") or os.path.join(DATA, "board", "actions.jsonl")
INITIAL_BYTES = 1536 * 1024
HOOK_TOKEN = secrets.token_urlsafe(24)
HOOK_CONF = os.path.join(DATA, "board", "server.json")  # 권한 훅이 보드를 찾는 곳. 서버가 꺼지면 지운다
PERM_WAIT = int(os.environ.get("BOARD_PERMISSION_WAIT", "3500"))  # 훅 timeout(3600)보다 조금 짧게
# 붙잡고 있어도 터미널 창은 그대로 떠 있으므로 길게 둔다. 브라우저는 뒤에 있는 탭의 타이머를 1분 단위로 늦추기 때문에
# 짧게 잡으면 사용자가 보드를 열어 둔 채로도 요청이 풀려 버린다(허용을 눌러도 '이미 처리됨').
VIEWER_GONE = int(os.environ.get("BOARD_VIEWER_GONE", "1800"))
_cache = {"at": 0.0, "data": None}
_viewer = {"at": time.time()}  # 막 켜졌을 때 다시 연결해 온 요청을 바로 돌려보내지 않게
_perms = {}  # id -> {info, event, decision}
_lock = threading.Lock()


def utc():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def log(entry):
    os.makedirs(os.path.dirname(LOG), exist_ok=True)
    with open(LOG, "a", encoding="utf-8") as f:
        f.write(json.dumps({"at": utc(), **entry}, ensure_ascii=False) + "\n")


def jira_base():
    """Jira 주소: BOARD_JIRA_URL·JIRA_BASE_URL 환경변수, 없으면 사용자 규칙 파일·설치된 jira 스킬 문서에 적힌 atlassian 주소.
    어디에도 없으면 링크 없이 키만 보인다. 코드에 조직 주소를 두지 않는다."""
    for key in ("BOARD_JIRA_URL", "JIRA_BASE_URL"):
        url = os.environ.get(key)
        if url and re.fullmatch(r"https://[\w.-]+(:\d+)?/?", url):
            return url.rstrip("/")
    for path in (os.path.join(DATA, "skills", "jira.md"), os.path.expanduser("~/.claude/skills/jira/SKILL.md")):
        try:
            with open(path, encoding="utf-8") as f:
                m = re.search(r"https://[a-z0-9-]+\.atlassian\.net", f.read())
        except OSError:
            continue
        if m:
            return m.group(0)
    return None


JIRA = jira_base()


def status(max_age=3):
    with _lock:
        if _cache["data"] is None or time.time() - _cache["at"] > max_age:
            out = subprocess.run(["bash", os.path.join(DIR, "status.sh")], capture_output=True, text=True, timeout=90)
            data = json.loads(out.stdout)
            try:
                groups.annotate(data["items"], os.path.join(DATA, "board", "links.json"))
            except Exception as e:  # 묶음은 덤 — 실패해도 보드는 그대로 보인다
                print("groups:", e, file=sys.stderr, flush=True)
            for i in data["items"]:  # Orca 터미널에 떠 있는 대화형 세션은 그 터미널로 입력을 보낼 수 있다
                if (i.get("section") == "work" and i.get("kind") == "agent" and i.get("orca_handle")
                        and i.get("status") != "waiting" and "send" not in i.get("actions", [])):
                    i["actions"] = i.get("actions", []) + ["send"]
            data["items"] = classify_work(data["items"])
            prstate.apply(data["items"])
            daily = hsettings.user_config().get("HM_HARVEST_AUTO_DAILY_MAX") or ""
            for i in data["items"]:  # 상한을 올린 뒤에도 지난 이틀의 건너뜀 기록이 남아 '막힘'으로 보이지 않게
                if i.get("kind") == "schedule" and i.get("state") == "blocked" and i.get("title") == "하루 실행 상한 도달" \
                        and daily.isdigit() and int(daily) >= 1000:
                    i["state"], i["title"] = "done", "하루 실행 상한 도달(지난 기록) → 지금은 제한 없음"
            data["jira_base"] = JIRA
            _cache["data"] = data
            _cache["at"] = time.time()
        return _cache["data"]


def find_item(item_id, fresh=False):
    if fresh:
        _cache["data"] = None
    return next((i for i in status()["items"] if i.get("id") == item_id), None)


# ---- 읽음 표시 · 정리(숨김) ----
SEEN = os.path.join(DATA, "board", "seen.json")  # sid -> 내가 마지막으로 본 시점의 활동 시각(item.at)
HIDDEN = os.path.join(DATA, "board", "hidden.json")  # sid -> 정리한 시각. 대화 기록 파일은 지우지 않는다(harvest가 쓴다)
_marks_lock = threading.Lock()


def _load(path):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return None


def _save(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f)
    os.replace(tmp, path)


def mark_seen(items):
    with _marks_lock:
        seen = _load(SEEN) or {}
        changed = False
        for i in items:
            if i.get("sid") and i.get("at") and seen.get(i["sid"]) != i["at"]:
                seen[i["sid"]], changed = i["at"], True
        if changed:
            _save(SEEN, seen)
        for i in items:  # 캐시도 바로 반영 → 다음 새로고침을 기다리지 않음
            if i.get("state") == "review":
                i["state"] = "idle"


def classify_work(items):
    """끝난 세션을 '결과 확인'(아직 안 봄)과 '쉬는 중'(봤음·종료)으로 나누고, 정리한 세션은 뺀다."""
    with _marks_lock:
        seen = _load(SEEN)
        first = seen is None  # 처음 켰을 때는 지금 끝나 있는 것을 모두 읽음으로 — 처음부터 쌓이면 소음
        seen = seen or {}
        hidden = _load(HIDDEN) or {}
        out, unhide = [], False
        for i in items:
            if i.get("section") != "work" or not i.get("sid"):
                if i.get("section") == "work" and i.get("state") == "done":
                    i["state"] = "idle"  # 워크플로 실행기 등 세션이 아닌 작업: 끝난 것은 쉬는 중
                out.append(i)
                continue
            sid = i["sid"]
            if sid in hidden:
                if not i.get("live"):
                    continue
                hidden.pop(sid)  # 다시 살아난 세션은 다시 보인다
                unhide = True
            if i.get("state") == "done":
                if first:
                    seen[sid] = i.get("at")
                if (not i.get("live") and i.get("kind") == "agent") or (seen.get(sid) and seen[sid] >= (i.get("at") or "")):
                    i["state"] = "idle"
                else:
                    i["state"] = "review"
            if can_close(i) or not i.get("live"):
                i["actions"] = i.get("actions", []) + ["cleanup"]
            out.append(i)
        if first:
            _save(SEEN, seen)
        if unhide:
            _save(HIDDEN, hidden)
        return out


def _git(path, *args):
    out = subprocess.run(["git", "-C", path, *args], capture_output=True, text=True, timeout=15)
    return out.returncode, out.stdout.strip()


def can_close(item):
    """살아 있어도 쉬는 세션(응답을 끝내고 입력을 기다림)은 닫고 정리할 수 있다. 작업 중·질문 중은 안 됨."""
    if not item.get("live") or item.get("status") != "idle" or item.get("state") not in ("idle", "review"):
        return False
    return item.get("kind") == "bg" or bool(item.get("orca_handle"))


def end_session(item):
    """세션을 끝낸다: bg는 claude stop, 대화형은 그 Orca 터미널을 닫는다. 대화 기록은 남아서 나중에 --resume 가능."""
    if item.get("kind") == "bg":
        claude(["stop", item["short_id"]], item["cwd"], timeout=30)
    else:
        handle = item.get("orca_handle") or ""
        if not re.fullmatch(r"term_[0-9a-f-]{36}", handle):
            return False
        subprocess.run(["orca", "terminal", "close", "--terminal", handle, "--json"], capture_output=True, text=True, timeout=20)
    return wait_stopped(item, 15)


def worktree_check(item):
    """정리해도 되는 worktree인지. 메인 체크아웃·변경 있음·원격에 없는 커밋·다른 살아 있는 세션이 쓰는 경우는 지우지 않는다."""
    cwd = item.get("cwd")
    if not cwd or not os.path.isdir(cwd):
        return {"path": cwd, "removable": False, "reason": "폴더가 이미 없음"}
    rc, top = _git(cwd, "rev-parse", "--show-toplevel")
    if rc != 0:
        return {"path": cwd, "removable": False, "reason": "git 저장소가 아님"}
    _, gdir = _git(top, "rev-parse", "--absolute-git-dir")
    _, common = _git(top, "rev-parse", "--path-format=absolute", "--git-common-dir")
    info = {"path": top, "removable": False}
    _, info["branch"] = _git(top, "rev-parse", "--abbrev-ref", "HEAD")
    if os.path.realpath(gdir) == os.path.realpath(common):
        info["reason"] = "worktree가 아니라 원본 저장소라 지우지 않음"
        return info
    _, dirty = _git(top, "status", "--porcelain")
    if dirty:
        info["dirty"] = dirty.splitlines()[:10]
        info["reason"] = f"커밋 안 한 변경 {len(dirty.splitlines())}개"
        return info
    rc, ahead = _git(top, "log", "--oneline", "HEAD", "--not", "--remotes")
    if rc == 0 and ahead:
        info["unpushed"] = len(ahead.splitlines())
        info["reason"] = f"원격에 올리지 않은 커밋 {info['unpushed']}개"
        return info
    others = [i.get("title") for i in (_cache["data"] or {}).get("items", [])
              if i.get("section") == "work" and i.get("live") and i.get("sid") != item.get("sid")
              and (i.get("cwd", "") + "/").startswith(top + "/")]
    if others:
        info["reason"] = "아직 이 폴더에서 돌고 있는 세션: " + ", ".join(others[:3])
        return info
    info["removable"] = True
    return info


def cleanup(item, with_worktree):
    if item.get("live") and not can_close(item):
        return {"ok": False, "message": "작업 중이거나 답을 기다리는 세션은 정리하지 않음"}
    msg, wt = [], None
    if with_worktree:  # 세션을 닫기 전에 먼저 확인 — 지울 수 없으면 세션도 그대로 둔다
        wt = worktree_check(item)
        if not wt["removable"]:
            return {"ok": False, "message": "worktree를 지우지 않음 — " + wt.get("reason", "")}
    if item.get("live"):
        if not end_session(item):
            return {"ok": False, "message": "세션을 끝내지 못함 — 터미널에서 직접 닫아 주세요"}
        msg.append("세션 종료")
    if with_worktree:
        if shutil.which("orca"):
            out = subprocess.run(["orca", "worktree", "rm", "--worktree", "path:" + wt["path"], "--json"],
                                 capture_output=True, text=True, timeout=60)
            try:
                ok = json.loads(out.stdout or "{}").get("ok")
            except Exception:
                ok = False
        else:
            ok = False
        if not ok:  # Orca가 모르는 worktree거나 Orca가 없으면 git으로(강제 없이)
            _, common = _git(wt["path"], "rev-parse", "--path-format=absolute", "--git-common-dir")
            out = subprocess.run(["git", "-C", os.path.dirname(common), "worktree", "remove", wt["path"]],
                                 capture_output=True, text=True, timeout=60)
            if out.returncode != 0:
                return {"ok": False, "message": "worktree 삭제 실패: " + (out.stderr or out.stdout)[-200:]}
        msg.append(f"worktree 삭제({wt.get('branch')})")
    with _marks_lock:
        hidden = _load(HIDDEN) or {}
        hidden[item["sid"]] = utc()
        _save(HIDDEN, hidden)
    _cache["data"] = None
    return {"ok": True, "message": "정리함" + (" — " + ", ".join(msg) if msg else " — 보드에서 숨김(대화 기록은 남음)")}


# ---- 하네스 설정(자동화 수준) ----
CHANGES = os.path.join(DATA, "board", "settings-changes.json")  # repo -> {sid, level, at}


def harness_repos():
    seeds = set(known_repos())
    for i in (_cache["data"] or {}).get("items", []):
        if i.get("cwd"):
            seeds.add(i["cwd"])
    return hsettings.discover(seeds)


_protect = {}  # repo -> {at, base, result}
IMPACT = himpact.Store(DATA)


def impact_state():
    repos = harness_repos()
    IMPACT.ensure(repos)
    return {"ok": True, "today": datetime.now().strftime("%Y-%m-%d"),
            "repos": [IMPACT.repo_state(r, os.path.basename(r)) for r in repos]}


def impact_refresh(repo):
    if repo not in harness_repos():
        return {"ok": False, "message": "하네스 저장소 목록에 없는 경로"}
    queued = IMPACT.refresh(repo)
    return {"ok": True, "message": "다시 계산을 시작함 — 저장소에 따라 수십 초 걸림" if queued else "이미 계산 중"}


AUTOFIX = hautofix.Store(DATA)


def autofix_key(repo):
    """autofix-auto.sh(project_id_for_cwd)와 같은 키: 폴더 이름에서 온 한글(NFD)도 NFC로 맞춘다."""
    return unicodedata.normalize("NFC", hsettings.project_key(repo))


def autofix_state():
    return AUTOFIX.view(harness_repos(), autofix_key)


def autofix_button(kind, repo):
    if repo not in harness_repos():
        return {"ok": False, "message": "하네스 저장소 목록에 없는 경로"}
    if kind == "check":
        res = AUTOFIX.check(repo)
        return {"ok": True, "message": f"접근 확인: {res['label']}", "check": res}
    res = AUTOFIX.candidates(repo, autofix_key(repo))
    msg = res["error"] or f"후보 {len(res['items'])}건"
    return {"ok": not res["error"], "message": msg, "candidates": res}


def autofix_setup(repo):
    if repo not in harness_repos():
        return {"ok": False, "message": "하네스 저장소 목록에 없는 경로"}
    res = new_bg(repo, "/ai-harness:autofix setup", name=f"자동 수정 설정: {os.path.basename(repo)}")
    if res["ok"]:
        res["message"] = "자동 수정 설정 세션을 띄움 — 작업 화면에서 질문에 답하세요"
    return res


def settings_state():
    changes = _load(CHANGES) or {}
    by_sid = {i.get("sid"): i for i in (_cache["data"] or {}).get("items", []) if i.get("sid")}
    cfg = hsettings.user_config()
    rows = []
    for repo in harness_repos():
        row = hsettings.read_repo(repo)
        if row.get("error"):
            rows.append(row)
            continue
        row["mine"] = hsettings.repo_levels(cfg).get(row["key"])
        row["effective"] = hsettings.effective(row, cfg)
        p = _protect.get(repo)
        if p and time.time() - p["at"] < 600:
            row["protection"] = {**p["result"], "base": p["base"]}
        ch = changes.get(repo)
        if ch:
            it = by_sid.get(ch["sid"])
            row["change"] = {**ch, "item_id": it.get("id") if it else None, "state": it.get("state") if it else "gone",
                             "prs": (it.get("refs") or {}).get("prs", []) if it else []}
        rows.append(row)
    return {"ok": True, "repos": rows, "config": hsettings.CONFIG,
            "personal": {k: cfg.get(k) for k in hsettings.PERSONAL_KEYS}}


def check_protection(repo):
    if repo not in harness_repos():
        return {"ok": False, "message": "하네스 저장소 목록에 없는 경로"}
    row = hsettings.read_repo(repo)
    base = (row.get("merge_policy") or {}).get("base") or row["suggest"]["base"]
    try:
        res = hsettings.protection(repo, base)
    except Exception as e:
        res = {"error": str(e)[:200]}
    _protect[repo] = {"at": time.time(), "base": base, "result": res}
    return {"ok": True, "protection": {**res, "base": base}}


def set_harness_stage(req):
    err = hsettings.set_harness(req)
    if err:
        return {"ok": False, "message": err}
    return {"ok": True, "message": "내 설정에 저장함 — 다음 자동 실행부터 적용"}


def set_personal_level(req):
    err = hsettings.set_personal(req, harness_repos())
    if err:
        return {"ok": False, "message": err}
    return {"ok": True, "message": "내 설정에 저장함 — 다음 러너 실행부터 적용"}


def request_facts_change(req):
    repos = harness_repos()
    change, err = hsettings.validate_facts(req, repos)
    if err:
        return {"ok": False, "message": err}
    row = hsettings.read_repo(change["repo"])
    name = f"하네스 설정: {os.path.basename(change['repo'])} 저장소 사실"
    res = new_bg(change["repo"], hsettings.prompt_for_facts(change, row), name=name)
    if not res["ok"]:
        return res
    sid = None
    try:  # 방금 띄운 세션 찾기(이름으로)
        agents = json.loads(claude(["agents", "--json", "--all"], change["repo"], timeout=15).stdout)
        sid = next((a["sessionId"] for a in sorted(agents, key=lambda a: -(a.get("startedAt") or 0)) if a.get("name") == name), None)
    except Exception:
        pass
    with _marks_lock:
        changes = _load(CHANGES) or {}
        changes[change["repo"]] = {"sid": sid, "facts": change["facts"], "at": utc()}
        _save(CHANGES, changes)
    _cache["data"] = None
    return {"ok": True, "message": "저장소 사실 변경 세션을 띄움 — draft PR을 병합해야 반영됨"}


# ---- 대화(transcript) ----
SKIP_PREFIX = ("<command", "<local-command", "<system", "Base directory for this skill", "Caveat:", "<task-notification", "This session is being continued")


def _text(content):
    if isinstance(content, str):
        return content
    return "\n".join(c.get("text", "") for c in content if isinstance(c, dict) and c.get("type") == "text")


def _tool_label(c):
    inp = c.get("input") or {}
    hint = inp.get("description") or inp.get("file_path") or inp.get("command") or inp.get("pattern") or inp.get("prompt") or ""
    hint = " ".join(str(hint).split())
    return f"{c.get('name', 'tool')}" + (f" · {hint[:120]}" if hint else "")


def parse_lines(lines):
    out = []
    for line in lines:
        try:
            r = json.loads(line)
        except Exception:
            continue
        typ, msg, ts = r.get("type"), r.get("message") or {}, r.get("timestamp")
        if r.get("isSidechain"):
            continue
        if typ == "user" and not r.get("isMeta"):
            content = msg.get("content")
            if isinstance(content, list) and any(isinstance(c, dict) and c.get("type") == "tool_result" for c in content):
                continue
            text = _text(content or "").strip()
            cmd = re.search(r"<command-name>(.*?)</command-name>", text)
            if cmd:  # 슬래시 명령·스킬 호출은 "/name args"로 보여 준다
                args = re.search(r"<command-args>(.*?)</command-args>", text, re.S)
                text = (cmd.group(1).strip() + " " + (args.group(1).strip() if args else "")).strip()
            if text and not text.startswith(SKIP_PREFIX):
                out.append({"role": "user", "text": text, "ts": ts})
        elif typ == "assistant":
            for c in msg.get("content") or []:
                if not isinstance(c, dict):
                    continue
                if c.get("type") == "text" and c.get("text", "").strip():
                    out.append({"role": "assistant", "text": c["text"].strip(), "ts": ts})
                elif c.get("type") == "tool_use":
                    out.append({"role": "tool", "text": _tool_label(c), "ts": ts})
    return out


def pending_question(path):
    """답을 기다리는 AskUserQuestion(이후 tool_result·사람 입력이 없는 마지막 질문)."""
    size = os.path.getsize(path)
    with open(path, "rb") as f:
        f.seek(max(0, size - 512 * 1024))
        lines = f.read().decode("utf-8", "replace").splitlines()
    pending = None
    for line in lines:
        try:
            r = json.loads(line)
        except Exception:
            continue
        if r.get("isSidechain"):
            continue
        content = (r.get("message") or {}).get("content")
        if r.get("type") == "assistant" and isinstance(content, list):
            for c in content:
                if isinstance(c, dict) and c.get("type") == "tool_use" and c.get("name") == "AskUserQuestion":
                    pending = (c.get("input") or {}).get("questions")
        elif r.get("type") == "user" and pending and not r.get("isMeta"):
            pending = None
    return pending


PAGE_MESSAGES = 120


def _window(path, lo, hi, limit=PAGE_MESSAGES):
    """[lo, hi) 구간의 완결된 줄만 읽어 마지막 limit개 메시지와, 그 첫 메시지가 나온 줄의 시작 위치(start)를 돌려준다."""
    with open(path, "rb") as f:
        f.seek(lo)
        chunk = f.read(hi - lo)
    if lo > 0:  # 잘린 첫 줄은 버린다
        cut = chunk.find(b"\n") + 1
        lo, chunk = lo + cut, chunk[cut:]
    chunk = chunk[: chunk.rfind(b"\n") + 1]
    rows, pos = [], lo
    for raw in chunk.split(b"\n")[:-1]:
        msgs = parse_lines([raw.decode("utf-8", "replace")])
        if msgs:
            rows.append((pos, msgs))
        pos += len(raw) + 1
    kept, count = [], 0
    for off, msgs in reversed(rows):
        if count >= limit:
            break
        kept.append((off, msgs))
        count += len(msgs)
    kept.reverse()
    start = kept[0][0] if kept else lo
    return start, lo + len(chunk), [m for _, msgs in kept for m in msgs]


def read_older(item, before):
    """위로 올렸을 때: before(줄 시작 위치) 앞의 메시지 한 페이지."""
    path = item.get("transcript")
    if not path or not os.path.isfile(path):
        return {"ok": False, "message": "대화 기록 파일이 없음"}
    before = max(0, min(before, os.path.getsize(path)))
    start, _, msgs = _window(path, max(0, before - INITIAL_BYTES), before)
    if not msgs and start > 0:  # 이 구간에 보일 메시지가 없으면 시작 위치만 앞으로 옮겨 다음 요청이 더 앞을 읽게
        start = max(0, before - INITIAL_BYTES)
    return {"ok": True, "start": start, "messages": msgs}


def read_transcript(item, offset):
    path = item.get("transcript")
    if not path or not os.path.isfile(path):
        return {"ok": False, "message": "대화 기록 파일이 없음"}
    size = os.path.getsize(path)
    initial = not (0 < offset <= size)
    if initial:
        start, end, msgs = _window(path, max(0, size - INITIAL_BYTES), size)
        return {"ok": True, "offset": end, "start": start, "reset": True, "messages": msgs,
                "status": item.get("status"), "live": item.get("live"),
                "question": pending_question(path) if item.get("status") == "waiting" else None}
    base = offset
    with open(path, "rb") as f:
        f.seek(base)
        chunk = f.read(size - base)
    if initial and base > 0:  # 잘린 첫 줄은 버린다
        cut = chunk.find(b"\n") + 1
        base, chunk = base + cut, chunk[cut:]
    complete = chunk[: chunk.rfind(b"\n") + 1]  # 쓰는 중인 마지막 줄은 다음 번에 읽는다
    return {"ok": True, "offset": base + len(complete), "reset": initial,
            "messages": parse_lines(complete.decode("utf-8", "replace").splitlines()),
            "status": item.get("status"), "live": item.get("live"),
            "question": pending_question(path) if item.get("status") == "waiting" else None}


# ---- 권한 질문(PermissionRequest 훅) ----
def _perm_summary(tool, inp):
    if not isinstance(inp, dict):
        return str(inp)[:2000]
    if tool == "Bash":
        return str(inp.get("command", ""))[:2000]
    if inp.get("file_path"):
        return str(inp["file_path"])
    return json.dumps(inp, ensure_ascii=False)[:2000]


def hold_permission(req):
    """훅 요청을 붙잡고 보드에서 허용/거부할 때까지 기다린다. 보는 사람이 없으면 바로 터미널로 넘긴다."""
    if time.time() - _viewer["at"] > VIEWER_GONE or req.get("tool_name") == "AskUserQuestion":
        return {}
    pid = secrets.token_hex(8)
    ev = threading.Event()
    tool = req.get("tool_name") or "?"
    _perms[pid] = {"info": {"pid": pid, "sid": req.get("session_id"), "cwd": req.get("cwd"), "tool": tool,
                            "input": _perm_summary(tool, req.get("tool_input")), "at": utc()},
                   "event": ev, "decision": None}
    tpath = req.get("transcript_path")
    start = os.path.getsize(tpath) if isinstance(tpath, str) and os.path.isfile(tpath) else None
    end = time.time() + PERM_WAIT
    try:
        while time.time() < end and not ev.is_set():
            ev.wait(1)
            if time.time() - _viewer["at"] > VIEWER_GONE or answered_elsewhere(tpath, start):
                break
        return {"behavior": _perms[pid]["decision"]} if _perms[pid]["decision"] else {}
    finally:
        _perms.pop(pid, None)


def answered_elsewhere(tpath, start):
    """터미널에서 먼저 답하면 Claude는 훅을 끝내지 않는다. 대화 기록에 도구 결과가 붙으면 끝난 것으로 본다."""
    if start is None:
        return False
    try:
        with open(tpath, "rb") as f:
            f.seek(start)
            return b'"tool_result"' in f.read(4 << 20)
    except OSError:
        return False


def decide_permission(pid, decision):
    p = _perms.get(pid)
    if not p or decision not in ("allow", "deny"):
        log({"action": "permission", "decision": decision, "ok": False, "message": "gone"})
        return {"ok": False, "message": "보드가 이 요청을 더 이상 붙잡고 있지 않음 — 터미널 창에서 답해 주세요"}
    p["decision"] = decision
    p["event"].set()
    log({"action": "permission", "tool": p["info"]["tool"], "decision": decision})
    return {"ok": True, "message": "허용함 — 세션이 이어서 진행" if decision == "allow" else "거부함"}


def status_with_permissions():
    data = status()
    pend = [p["info"] for p in list(_perms.values())]
    if not pend:
        return data
    items = list(data["items"])
    for info in pend:
        i = next((n for n, it in enumerate(items) if it.get("sid") == info["sid"]), None)
        if i is None:
            items.append({"section": "work", "kind": "agent", "state": "needs_human", "project": os.path.basename(info["cwd"] or "?"),
                          "at": info["at"], "title": (info["sid"] or "?")[:8], "detail": "", "id": "perm|" + info["pid"],
                          "actions": [], "permission": info})
        else:
            items[i] = {**items[i], "state": "needs_human", "permission": info}
    return {**data, "items": items}


def write_hook_conf(url):
    """board.sh·권한 훅이 이 서버를 찾는 곳. token은 훅 전용, url은 브라우저 토큰이 든 주소라 0600으로만 쓴다."""
    os.makedirs(os.path.dirname(HOOK_CONF), exist_ok=True)
    tmp = HOOK_CONF + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump({"port": PORT, "token": HOOK_TOKEN, "pid": os.getpid(), "url": url}, f)
    os.replace(tmp, HOOK_CONF)
    atexit.register(remove_hook_conf)


def remove_hook_conf():
    """내가 쓴 server.json만 지운다 — 그 사이 다른 서버가 덮어썼으면 남긴다."""
    conf = _load(HOOK_CONF)
    if isinstance(conf, dict) and conf.get("pid") == os.getpid():
        try:
            os.remove(HOOK_CONF)
        except OSError:
            pass


# ---- 세션 작업 ----
def claude(args, cwd, timeout=60):
    env = {**os.environ}
    env.pop("CLAUDECODE", None)
    return subprocess.run(["claude", *args], cwd=cwd, capture_output=True, text=True, timeout=timeout, env=env)


def send_to_terminal(item, text):
    """대화형 세션: 그 세션이 떠 있는 Orca 터미널에 붙여넣고 Enter. 작업 중이면 Claude가 다음 입력으로 받아 둔다."""
    handle = item.get("orca_handle") or ""
    if not re.fullmatch(r"term_[0-9a-f-]{36}", handle):
        return {"ok": False, "message": "이 세션의 터미널을 찾지 못함"}
    if item.get("status") == "waiting":
        return {"ok": False, "message": "권한·질문 창이 떠 있음 — 그 창에 잘못 입력될 수 있어 보내지 않음"}
    try:
        out = subprocess.run(["orca", "terminal", "send", "--terminal", handle, "--text", text, "--enter", "--json"],
                             capture_output=True, text=True, timeout=20)
        res = json.loads(out.stdout or "{}")
    except Exception as e:
        return {"ok": False, "message": f"Orca로 보내지 못함: {e}"}
    if res.get("ok"):
        return {"ok": True, "message": "터미널에 입력함" + (" — 작업이 끝나면 이어서 처리" if item.get("status") == "busy" else "")}
    return {"ok": False, "message": "Orca로 보내지 못함: " + json.dumps(res.get("error") or res, ensure_ascii=False)[:240]}


def send_to_bg(item, text):
    """bg 세션에 이어서 지시한다. 실행 중이면 멈춘 뒤 같은 ID로 깨운다(옵션을 넘기면 복사본이 생기므로 넘기지 않는다)."""
    if not isinstance(text, str) or not text.strip() or len(text) > 8000:
        return {"ok": False, "message": "보낼 내용이 비었거나 너무 김(8000자 이하)"}
    if item.get("kind") == "agent":
        return send_to_terminal(item, text)
    if item.get("status") == "busy":
        return {"ok": False, "message": "작업 중인 세션 — 끝난 뒤 보내세요"}
    if item.get("live"):
        claude(["stop", item["short_id"]], item["cwd"], timeout=30)
        if not wait_stopped(item):  # 덜 멈춘 채 깨우면 복사본이 생긴다
            return {"ok": False, "message": "세션이 멈추지 않음 — 잠시 뒤 다시 보내세요"}
    out = claude(["--bg", "--resume", item["sid"], text], item["cwd"])
    msg = (out.stdout + out.stderr).strip()
    if out.returncode == 0 and "copy" not in msg:
        return {"ok": True, "message": "보냄 — 세션이 이어서 작업함"}
    return {"ok": False, "message": "보내지 못함: " + msg[-240:]}


def wait_stopped(item, seconds=20):
    end = time.time() + seconds
    while time.time() < end:
        try:
            agents = json.loads(claude(["agents", "--json", "--all"], item["cwd"], timeout=15).stdout)
            a = next((x for x in agents if x.get("sessionId") == item["sid"]), None)
            if a is None or a.get("pid") is None:
                return True
        except Exception:
            pass
        time.sleep(0.5)
    return False


# ---- 슬래시 명령·스킬 목록(자동완성) ----
def _front(path):
    meta = {}
    try:
        with open(path, encoding="utf-8") as f:
            if f.readline().strip() != "---":
                return meta
            block = None
            for line in f:
                if line.strip() == "---":
                    break
                if block and line[:1] in (" ", "\t"):  # description: > 같은 여러 줄 값
                    meta[block] = (meta.get(block, "") + " " + line.strip()).strip()
                    continue
                block = None
                k, _, v = line.partition(":")
                k, v = k.strip(), v.strip()
                if k in ("name", "description") and v:
                    if v in ("|", ">", "|-", ">-"):
                        block, meta[k] = k, ""
                    else:
                        meta[k] = v.strip("'\"")
    except OSError:
        pass
    return meta


def _scan(root, prefix, out):
    sk = os.path.join(root, "skills")
    if os.path.isdir(sk):
        for d in sorted(os.listdir(sk)):
            f = os.path.join(sk, d, "SKILL.md")
            if os.path.isfile(f):
                m = _front(f)
                out.setdefault("/" + prefix + (m.get("name") or d), m.get("description", "")[:160])
    cm = os.path.join(root, "commands")
    if os.path.isdir(cm):
        for f in sorted(os.listdir(cm)):
            if f.endswith(".md"):
                out.setdefault("/" + prefix + f[:-3], _front(os.path.join(cm, f)).get("description", "")[:160])


def list_commands(cwd):
    home = os.path.expanduser("~/.claude")
    out = {}
    if isinstance(cwd, str) and os.path.isabs(cwd) and os.path.isdir(cwd):
        _scan(os.path.join(cwd, ".claude"), "", out)
    _scan(home, "", out)
    try:
        enabled = json.load(open(os.path.join(home, "settings.json"))).get("enabledPlugins", {})
    except Exception:
        enabled = {}
    try:
        plugins = json.load(open(os.path.join(home, "plugins", "installed_plugins.json"))).get("plugins", {})
    except Exception:
        plugins = {}
    for key, installs in plugins.items():
        if enabled.get(key) is False or not installs:
            continue
        _scan(installs[-1].get("installPath", ""), key.split("@")[0] + ":", out)
    return [{"name": k, "description": v} for k, v in sorted(out.items())]


def new_bg(cwd, prompt, name=None):
    if not isinstance(cwd, str) or not os.path.isabs(cwd) or not os.path.isdir(cwd):
        return {"ok": False, "message": "작업 경로가 없거나 절대 경로가 아님"}
    if not isinstance(prompt, str) or not prompt.strip() or len(prompt) > 8000:
        return {"ok": False, "message": "첫 지시가 비었거나 너무 김"}
    args = ["--bg"] + (["--name", name[:80]] if name else []) + [prompt]
    out = claude(args, cwd)
    msg = (out.stdout + out.stderr).strip()
    if out.returncode == 0 and "backgrounded" in msg:
        _cache["data"] = None
        return {"ok": True, "message": "새 세션을 띄움 — 작업 화면에 곧 나타남"}
    return {"ok": False, "message": msg[-300:] or "세션을 띄우지 못함"}


def prompt_for(item):
    link = item.get("link")
    if item["kind"] == "sync" and item.get("result") == "left_for_user":
        return "/ai-harness:harness-init --sync --apply"
    if item["kind"] == "sync" and link:
        return (f"ai-harness 자동 sync가 일부만 적용한 draft PR {link} 를 검토해줘. "
                "바뀐 것과 남긴 항목을 요약하고, 남은 항목을 이 저장소에서 이어서 적용할지 내게 물어봐.")
    if link:
        return (f"ai-harness 자동 개선 draft PR {link} 를 검토해줘. "
                "근거·바뀐 규칙을 요약하고 병합해도 될지 의견을 줘. 병합은 내가 한다.")
    return f"ai-harness 보드에서 넘어왔다: {item['title']}. 상황을 확인하고 내가 결정할 것을 정리해줘."


def known_repos():
    repos = set()
    try:
        with open(os.path.join(DATA, "harvest-auto", "runs.jsonl"), encoding="utf-8") as f:
            for line in f:
                try:
                    r = json.loads(line)
                except Exception:
                    continue
                if r.get("repo") and os.path.isdir(r["repo"]):
                    repos.add(r["repo"])
    except OSError:
        pass
    for i in (_cache["data"] or {}).get("items", []):
        if i.get("section") == "work" and i.get("cwd") and os.path.isdir(i["cwd"]):
            repos.add(i["cwd"])
    return sorted(repos)


def run_action(item, action, req):
    if action not in item.get("actions", []):
        return {"ok": False, "message": "이 항목에서 허용하지 않는 작업"}
    if action == "send":
        return send_to_bg(item, req.get("text"))
    if action == "cleanup":
        res = cleanup(item, bool(req.get("worktree")))
        return res
    if action == "open_agent":
        return new_bg(item["repo"], prompt_for(item), name=f"{item['project']} {item['title']}")
    if action == "harvest_now":
        out = subprocess.run(["bash", os.path.join(DIR, "board-actions.sh"), "harvest-now", item["project"]],
                             capture_output=True, text=True, timeout=120)
        try:
            return json.loads(out.stdout.strip().splitlines()[-1])
        except Exception:
            return {"ok": False, "message": (out.stderr or out.stdout)[-300:] or "실행 결과 없음"}
    return {"ok": False, "message": "알 수 없는 작업"}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def _send(self, code, body, ctype="application/json; charset=utf-8"):
        data = (json.dumps(body, ensure_ascii=False) if isinstance(body, (dict, list)) else body).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def _token_ok(self, given):
        return isinstance(given, str) and secrets.compare_digest(given, TOKEN)

    def _host_ok(self):  # DNS rebinding 방어: 다른 도메인 이름으로 들어온 요청은 거절
        return self.headers.get("Host", "") in (f"{HOST}:{PORT}", f"localhost:{PORT}")

    def do_GET(self):
        if not self._host_ok():
            return self._send(403, {"error": "host"})
        u = urlparse(self.path)
        q = parse_qs(u.query)
        if not self._token_ok(q.get("t", [None])[0]):
            return self._send(403, {"error": "token"})
        if u.path == "/":
            html = open(os.path.join(DIR, "template.html"), encoding="utf-8").read()
            return self._send(200, html.replace("__DATA__", "null"), "text/html; charset=utf-8")
        if u.path == "/status.json":
            _viewer["at"] = time.time()
            return self._send(200, status_with_permissions())
        if u.path == "/commands":
            return self._send(200, list_commands(q.get("cwd", [None])[0]))
        if u.path == "/cleanup-preview":
            item = find_item(q.get("id", [None])[0])
            if not item or "cleanup" not in item.get("actions", []):
                return self._send(404, {"ok": False, "message": "정리할 수 있는 세션이 아님"})
            return self._send(200, {"ok": True, "worktree": worktree_check(item)})
        if u.path == "/settings":
            return self._send(200, settings_state())
        if u.path == "/repos":
            return self._send(200, known_repos())
        if u.path == "/impact":
            return self._send(200, impact_state())
        if u.path == "/autofix":
            return self._send(200, autofix_state())
        if u.path == "/autofix/log":
            path = AUTOFIX.log_path(q.get("name", [None])[0])
            if not path:
                return self._send(404, {"ok": False, "message": "autofix 실행 로그가 아님"})
            with open(path, encoding="utf-8", errors="replace") as f:
                return self._send(200, f.read()[-INITIAL_BYTES:], "text/plain; charset=utf-8")
        if u.path == "/impact/report":
            repo = q.get("repo", [None])[0]
            if repo not in harness_repos():
                return self._send(404, {"ok": False, "message": "하네스 저장소 목록에 없는 경로"})
            path, err = IMPACT.report(repo)
            if not path:
                return self._send(409, {"ok": False, "message": err})
            with open(path, encoding="utf-8") as f:
                return self._send(200, f.read(), "text/html; charset=utf-8")
        if u.path == "/transcript":
            cached = (_cache["data"] or {}).get("items")
            iid = q.get("id", [None])[0]
            item = next((i for i in cached if i.get("id") == iid), None) if cached else find_item(iid)
            if not item or item.get("section") != "work":
                return self._send(404, {"ok": False, "message": "대화를 볼 수 있는 작업이 아님"})
            try:
                offset = int(q.get("offset", ["0"])[0])
                before = int(q.get("before", ["-1"])[0])
            except ValueError:
                offset, before = 0, -1
            if before < 0 and item.get("state") in ("review", "idle"):
                mark_seen([item])
            return self._send(200, read_older(item, before) if before >= 0 else read_transcript(item, offset))
        self._send(404, {"error": "not found"})

    def do_POST(self):
        if not self._host_ok():
            return self._send(403, {"error": "host"})
        path = urlparse(self.path).path
        if path == "/hook/permission":  # 브라우저가 아니라 훅 스크립트가 부른다(별도 토큰)
            given = self.headers.get("X-Board-Hook", "")
            if not secrets.compare_digest(given, HOOK_TOKEN):
                return self._send(403, {"error": "token"})
            try:
                req = json.loads(self.rfile.read(min(int(self.headers.get("Content-Length", 0)), 1 << 20)))
            except Exception:
                return self._send(400, {"error": "json"})
            return self._send(200, hold_permission(req))
        if self.headers.get("Origin", "") not in (f"http://{HOST}:{PORT}", f"http://localhost:{PORT}"):
            return self._send(403, {"error": "origin"})
        try:
            req = json.loads(self.rfile.read(min(int(self.headers.get("Content-Length", 0)), 32768)))
        except Exception:
            return self._send(400, {"error": "json"})
        if not self._token_ok(req.get("t")):
            return self._send(403, {"error": "token"})
        if path == "/settings/harness":
            res = set_harness_stage(req)
            log({"action": "harness_stage", "kind": req.get("kind"), "stage": req.get("stage"), **res})
            return self._send(200, res)
        if path == "/settings/personal":
            res = set_personal_level(req)
            log({"action": "personal_level", "scope": req.get("scope"), "repo": req.get("repo"), "level": req.get("level"), **res})
            return self._send(200, res)
        if path == "/settings/protection":
            return self._send(200, check_protection(req.get("repo")))
        if path == "/settings":
            res = request_facts_change(req)
            log({"action": "settings_facts", "repo": req.get("repo"), **res})
            return self._send(200, res)
        if path in ("/autofix/check", "/autofix/candidates"):
            kind = path.rsplit("/", 1)[1]
            res = autofix_button(kind, req.get("repo"))
            log({"action": f"autofix_{kind}", "repo": req.get("repo"), "ok": res["ok"], "message": res["message"]})
            return self._send(200, res)
        if path == "/autofix/configure":
            res = AUTOFIX.configure({k: v for k, v in req.items() if k != "t"})
            log({"action": "autofix_configure", "keys": sorted(k for k in req if k != "t"), "ok": res["ok"], "message": res["message"]})
            return self._send(200, res)
        if path == "/autofix/setup":
            res = autofix_setup(req.get("repo"))
            log({"action": "autofix_setup", "repo": req.get("repo"), **res})
            return self._send(200, res)
        if path == "/impact/refresh":
            res = impact_refresh(req.get("repo"))
            log({"action": "impact_refresh", "repo": req.get("repo"), **res})
            return self._send(200, res)
        if path == "/seen":
            ids = set(req.get("ids") or [])
            mark_seen([i for i in status()["items"] if i.get("id") in ids])
            return self._send(200, {"ok": True})
        if path == "/permission":
            return self._send(200, decide_permission(req.get("pid"), req.get("decision")))
        if path == "/new":
            res = new_bg(req.get("cwd"), req.get("prompt"), req.get("name"))
            log({"action": "new", "cwd": req.get("cwd"), "chars": len(req.get("prompt") or ""), **res})
            return self._send(200, res)
        if path != "/action":
            return self._send(404, {"error": "not found"})
        item = find_item(req.get("id"), fresh=True)
        res = {"ok": False, "message": "항목이 이미 바뀌었음 — 다시 시도"} if item is None else run_action(item, req.get("action"), req)
        _cache["data"] = None
        log({"id": req.get("id"), "action": req.get("action"), "chars": len(req.get("text") or ""), **res})
        self._send(200, res)


if __name__ == "__main__":
    try:
        srv = ThreadingHTTPServer((HOST, PORT), Handler)
    except OSError as e:
        print(f"board: {HOST}:{PORT}에 묶지 못함 — {e.strerror or e}", file=sys.stderr, flush=True)
        sys.exit(3)
    srv.daemon_threads = True
    url = f"http://{HOST}:{PORT}/?t={TOKEN}"
    write_hook_conf(url)
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    signal.signal(signal.SIGHUP, signal.SIG_IGN)
    if sys.stdout.isatty():  # board.sh가 띄우면 주소는 server.json(0600)으로만 전한다 — 로그에 토큰을 남기지 않는다
        print(url, flush=True)
    if "--no-open" not in sys.argv:
        webbrowser.open(url)
    srv.serve_forever()
