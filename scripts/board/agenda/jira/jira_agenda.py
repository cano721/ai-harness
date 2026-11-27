#!/usr/bin/env python3
"""Jira 기본 어댑터(표준 라이브러리만) — 보드 '내 일정'의 agenda.json 계약을 따른다(#492, #632, #648, #662).

  fetch [--since ISO --until ISO]  나에게 배정된 미완료 이슈를 kind:todo JSONL로 낸다(기간 인자는 받고 무시한다).
                                   JQL: assignee = currentUser() AND statusCategory != Done ORDER BY duedate ASC, updated DESC.
                                   GET /rest/api/3/search/jql을 nextPageToken으로 넘기며 500개에서 멈춘다.
                                   먼저 GET /rest/api/3/field로 스프린트 필드(schema.custom이 gh-sprint인 첫 customfield_N)를
                                   찾아 search fields에 더한다. 조회가 실패하거나 필드가 없으면 더하지 않고 그대로 수집한다.
  settings-get                     저장한 설정 {projects: [KEY…], watching: bool}을 JSON 객체로 낸다(없으면 기본값).
  settings-set                     표준 입력 JSON 객체를 검사해 저장한다. 프로젝트 키가 아니거나 타입이 틀리면 거부(종료 코드 2).
  projects                         설정 선택지: GET /rest/api/3/project/search를 넘기며 200개까지 {value, label} JSONL.

설정은 watching이면 담당 조건을 (assignee = currentUser() OR watcher = currentUser())로 넓히고, projects가 있으면
AND project in ("A","B")를 더한다. 키는 저장할 때와 JQL을 만들 때 모두 ^[A-Z][A-Z0-9_]*$로 검사한다(손으로 고친 파일 대비).
값은 $HM_DATA_DIR/board/agenda/jira-settings.json(600)에 둔다.

기한: duedate가 있으면 그 값. 없으면 스프린트 필드에서 state가 active이고 endDate를 읽을 수 있는 스프린트 중 가장 이른
종료 시각(정규화한 ISO, 예: 2026-12-05T09:00:00Z)을 due로 쓰고 detail에 '스프린트 <이름> 종료'를 붙인다.
closed·future 스프린트나 dict가 아닌 구형 문자열 표현은 보지 않는다.

키 JIRA_BASE_URL·ATLASSIAN_USER·ATLASSIAN_API_TOKEN은 setup.sh와 같은 순서로 찾는다: 프로세스 환경 → HARNESS_CLAUDE_SETTINGS
(기본 ~/.claude/settings.json)의 env → $HM_DATA_DIR/secrets.env의 export KEY='…' 줄(source하지 않는다). 빈 값은 없는 것으로 본다.
python3 -I는 이 폴더를 import 경로에 넣지 않으므로 보드(agenda.py)의 같은 해석을 가져오지 않고 여기 따로 둔다.
토큰은 Basic 인증 Authorization 헤더로만 보낸다. 명령 인자·stdout·stderr·파일에 남기지 않고, 다른 호스트로 넘어가는
리다이렉트는 따르지 않는다(헤더가 따라가지 않게). 쓰기 요청은 하지 않는다 — 보드 [완료]는 보드에서만 숨긴다.
"""
import base64, json, os, re, sys, threading
from datetime import datetime, timezone
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, urlparse
from urllib.request import HTTPRedirectHandler, Request, build_opener

KEYS = ("JIRA_BASE_URL", "ATLASSIAN_USER", "ATLASSIAN_API_TOKEN")
PROJECT_RE = re.compile(r"^[A-Z][A-Z0-9_]*$")
FIELDS = "summary,status,priority,project,duedate,created,reporter"
MAX_ITEMS = 500
MAX_PROJECTS = 200
PAGE = 100
HTTP_TIMEOUT = 20
DEFAULTS = {"projects": [], "watching": False}
CREATED_RE = re.compile(r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(?:\.\d+)?(Z|[+-]\d{2}:?\d{2})?$")
SETUP = "/ai-harness:setup"
SPRINT_SCHEMA = "com.pyxis.greenhopper.jira:gh-sprint"
CUSTOM_FIELD_RE = re.compile(r"^customfield_\d+$")


class Fail(Exception):
    def __init__(self, message, code=1):
        super().__init__(message)
        self.code = code


def data_dir():
    return os.environ.get("HM_DATA_DIR") or os.environ.get("HARNESS_METRICS_DIR") or os.path.expanduser("~/.ai-harness")


def settings_path():
    return os.path.join(data_dir(), "board", "agenda", "jira-settings.json")


def _read_json(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def resolve(key):
    """프로세스 환경 → Claude settings.json env → secrets.env. 없으면 None."""
    if os.environ.get(key):
        return os.environ[key]
    settings = _read_json(os.environ.get("HARNESS_CLAUDE_SETTINGS") or os.path.expanduser("~/.claude/settings.json"))
    env = settings.get("env") if isinstance(settings, dict) else None
    if isinstance(env, dict) and isinstance(env.get(key), str) and env[key]:
        return env[key]
    try:
        with open(os.path.join(data_dir(), "secrets.env"), encoding="utf-8") as f:
            for line in f.read().splitlines():
                m = re.match(r"^export %s='(.*)'$" % re.escape(key), line)
                if m:
                    return m.group(1).replace("'\\''", "'") or None
    except (OSError, UnicodeDecodeError):
        pass
    return None


class _NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None  # 3xx는 HTTPError로 — Authorization이 다른 곳으로 따라가지 않게


class Jira:
    def __init__(self):
        values = {k: resolve(k) for k in KEYS}
        missing = [k for k in KEYS if not values[k]]
        if missing:
            raise Fail(f"Jira 설정 필요: {'·'.join(missing)}이(가) 없습니다. {SETUP}으로 Jira 키를 넣으세요.", 2)
        self.base = values["JIRA_BASE_URL"].strip().rstrip("/")
        u = urlparse(self.base)
        if u.scheme not in ("http", "https") or not u.netloc:
            raise Fail(f"Jira 설정 필요: JIRA_BASE_URL이 http(s) 주소가 아닙니다. {SETUP}으로 다시 넣으세요.", 2)
        raw = f"{values['ATLASSIAN_USER']}:{values['ATLASSIAN_API_TOKEN']}".encode()
        self._auth = "Basic " + base64.b64encode(raw).decode()
        self._open = build_opener(_NoRedirect).open

    def get(self, path, params, want=dict):
        query = f"?{urlencode(params)}" if params else ""
        req = Request(f"{self.base}{path}{query}", headers={"Authorization": self._auth, "Accept": "application/json"})
        try:
            with self._open(req, timeout=HTTP_TIMEOUT) as r:
                body = r.read()
        except HTTPError as e:
            if e.code in (401, 403):
                raise Fail(f"Jira 인증이 거부됐습니다(HTTP {e.code}). ATLASSIAN_USER·ATLASSIAN_API_TOKEN과 프로젝트 권한을 확인하세요({SETUP}).")
            raise Fail(f"Jira 요청 실패: HTTP {e.code}")
        except (URLError, OSError) as e:
            why = getattr(e, "reason", None) or e
            raise Fail(f"Jira에 연결하지 못했습니다({getattr(why, 'strerror', None) or why})")
        try:
            data = json.loads(body.decode("utf-8"))
        except (UnicodeDecodeError, ValueError):
            raise Fail("Jira 응답을 읽지 못했습니다(JSON이 아님)")
        if not isinstance(data, want):
            raise Fail("Jira 응답을 읽지 못했습니다(%s이 아님)" % ("배열" if want is list else "객체"))
        return data


# ---- 설정 ----
def clean_settings(raw):
    """저장 형식 검사. 맞으면 정리한 값, 아니면 Fail(2)."""
    if not isinstance(raw, dict):
        raise Fail("설정은 JSON 객체여야 합니다.", 2)
    unknown = [k for k in raw if k not in DEFAULTS]
    if unknown:
        raise Fail(f"모르는 설정입니다: {', '.join(map(str, unknown))[:100]}", 2)
    projects = raw.get("projects", [])
    if not isinstance(projects, list) or not all(isinstance(p, str) and PROJECT_RE.match(p) for p in projects):
        raise Fail("projects는 Jira 프로젝트 키(대문자·숫자·_) 목록이어야 합니다.", 2)
    watching = raw.get("watching", False)
    if not isinstance(watching, bool):
        raise Fail("watching은 true 또는 false여야 합니다.", 2)
    return {"projects": list(dict.fromkeys(projects)), "watching": watching}


def load_settings():
    """저장값(손으로 고쳐 틀린 값은 빼고). 파일이 없거나 읽을 수 없으면 기본값."""
    raw = _read_json(settings_path())
    if not isinstance(raw, dict):
        return dict(DEFAULTS)
    projects = raw.get("projects")
    return {"projects": list(dict.fromkeys(p for p in projects if isinstance(p, str) and PROJECT_RE.match(p)))
            if isinstance(projects, list) else [],
            "watching": raw.get("watching") is True}


def save_settings(values):
    path = settings_path()
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    tmp = f"{path}.tmp.{os.getpid()}.{threading.get_ident()}"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(values, f, ensure_ascii=False)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def build_jql(settings):
    who = "(assignee = currentUser() OR watcher = currentUser())" if settings["watching"] else "assignee = currentUser()"
    jql = f"{who} AND statusCategory != Done"
    keys = [p for p in settings["projects"] if PROJECT_RE.match(p)]
    if keys:
        jql += " AND project in (" + ",".join(f'"{k}"' for k in keys) + ")"
    return jql + " ORDER BY duedate ASC, updated DESC"


# ---- 수집 ----
def _name(v, key):
    return v.get(key).strip() if isinstance(v, dict) and isinstance(v.get(key), str) and v[key].strip() else ""


def normalize_created(value):
    """2026-11-20T10:15:30.000+0900 → 2026-11-20T10:15:30+09:00 (macOS python 3.9의 fromisoformat이 +0900을 못 읽는다)."""
    m = CREATED_RE.match(value.strip()) if isinstance(value, str) else None
    if not m:
        return None
    tz = m.group(2) or ""
    if tz and tz != "Z" and ":" not in tz:
        tz = tz[:3] + ":" + tz[3:]
    return m.group(1) + tz


def sprint_field(jira):
    """필드 목록에서 gh-sprint 필드 id. 조회 실패·없음이면 None — 기한만 비우고 수집은 계속한다."""
    try:
        fields = jira.get("/rest/api/3/field", {}, want=list)
    except Fail:
        return None
    for f in fields:
        schema = f.get("schema") if isinstance(f, dict) else None
        if isinstance(schema, dict) and schema.get("custom") == SPRINT_SCHEMA:
            fid = f.get("id")
            return fid if isinstance(fid, str) and CUSTOM_FIELD_RE.match(fid) else None
    return None


def _instant(iso):
    try:
        t = datetime.fromisoformat(iso.replace("Z", "+00:00"))
    except ValueError:
        return None
    return t if t.tzinfo else t.replace(tzinfo=timezone.utc)


def sprint_due(value):
    """가장 이른 활성 스프린트의 (정규화한 endDate, 이름). 없으면 None."""
    best = None
    for s in value if isinstance(value, list) else []:
        if not isinstance(s, dict) or s.get("state") != "active":
            continue
        end = normalize_created(s.get("endDate"))
        at = _instant(end) if end else None
        if at and (best is None or at < best[0]):
            best = (at, end, _name(s, "name"))
    return best[1:] if best else None


def to_item(issue, base, sprint_id=None):
    key = issue.get("key") if isinstance(issue, dict) else None
    if not isinstance(key, str) or not key.strip():
        return None
    f = issue.get("fields") if isinstance(issue.get("fields"), dict) else {}
    summary = f.get("summary") if isinstance(f.get("summary"), str) else ""
    item = {"id": key, "kind": "todo", "title": f"{key} {summary}".strip(), "url": f"{base}/browse/{key}"}
    sprint = None
    if isinstance(f.get("duedate"), str) and f["duedate"]:
        item["due"] = f["duedate"]
    elif sprint_id:
        sprint = sprint_due(f.get(sprint_id))
        if sprint:
            item["due"] = sprint[0]
    created = normalize_created(f.get("created"))
    if created:
        item["created"] = created
    reporter = _name(f.get("reporter"), "displayName")
    if reporter:
        item["from"] = reporter
    parts = [_name(f.get("status"), "name"), _name(f.get("priority"), "name"), _name(f.get("project"), "name")]
    if sprint:
        parts.append(f"스프린트 {sprint[1]} 종료" if sprint[1] else "스프린트 종료")
    detail = " · ".join(x for x in parts if x)
    if detail:
        item["detail"] = detail
    return item


def cmd_fetch():
    jira = Jira()
    jql = build_jql(load_settings())
    sprint_id = sprint_field(jira)
    fields = f"{FIELDS},{sprint_id}" if sprint_id else FIELDS
    count, token = 0, None
    while count < MAX_ITEMS:
        params = {"jql": jql, "fields": fields, "maxResults": PAGE}
        if token:
            params["nextPageToken"] = token
        data = jira.get("/rest/api/3/search/jql", params)
        for issue in data.get("issues") or []:
            item = to_item(issue, jira.base, sprint_id)
            if item and count < MAX_ITEMS:
                print(json.dumps(item, ensure_ascii=False))
                count += 1
        token = data.get("nextPageToken")
        if not isinstance(token, str) or not token or data.get("isLast") is True:
            break


def cmd_projects():
    jira = Jira()
    start, count = 0, 0
    while count < MAX_PROJECTS:
        data = jira.get("/rest/api/3/project/search", {"maxResults": PAGE, "startAt": start})
        values = data.get("values") if isinstance(data.get("values"), list) else []
        for p in values:
            key = p.get("key") if isinstance(p, dict) else None
            if isinstance(key, str) and PROJECT_RE.match(key) and count < MAX_PROJECTS:
                print(json.dumps({"value": key, "label": f"{key} {_name(p, 'name')}".strip()}, ensure_ascii=False))
                count += 1
        start += len(values)
        if not values or data.get("isLast") is not False:
            break


def cmd_settings_get():
    print(json.dumps(load_settings(), ensure_ascii=False))


def cmd_settings_set():
    try:
        raw = json.loads(sys.stdin.read() or "")
    except ValueError:
        raise Fail("설정은 JSON 객체여야 합니다.", 2)
    save_settings(clean_settings(raw))


COMMANDS = {"fetch": cmd_fetch, "projects": cmd_projects, "settings-get": cmd_settings_get, "settings-set": cmd_settings_set}


def main(argv):
    if len(argv) < 2 or argv[1] not in COMMANDS:
        print("usage: jira_agenda.py fetch [--since ISO --until ISO]|projects|settings-get|settings-set", file=sys.stderr)
        return 2
    try:
        COMMANDS[argv[1]]()
    except Fail as e:
        print(str(e), file=sys.stderr)
        return e.code
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
