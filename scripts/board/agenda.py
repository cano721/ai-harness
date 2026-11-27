#!/usr/bin/env python3
"""보드 '내 일정' 화면의 소스·수집·캐시·할 일 저장(표준 라이브러리만). 보드 서버가 import하고 board.sh todo가 CLI로 부른다.

일정·답할 것·할 일은 캘린더·메신저·메일에 흩어져 있다. 보드는 이것들을 '어댑터'(명령)로 받아 한 화면에 모은다.
어댑터 계약(#492):
- 소스 선언 agenda.json: id(소문자·숫자·-), name, fetch(argv). 선택 interval_minutes(기본 15, 최소 1),
  connect·disconnect·done·reopen(argv), requires(있어야 하는 파일. ~와 $HM_DATA_DIR를 펼침),
  requires_env(#648. 있어야 하는 키 이름 — 문자열 하나 또는 배열, 대문자·숫자·_. setup.sh와 같은 순서로 찾는다: 프로세스 환경 →
  HARNESS_CLAUDE_SETTINGS(기본 ~/.claude/settings.json)의 env → <data>/secrets.env의 export KEY='…' 줄. 빈 값은 없는 것으로 본다.
  보드는 키가 있는지만 보고 값은 읽어 넘기지 않는다 — 어댑터가 같은 순서로 직접 읽는다), setup_hint(사람 말 한 줄),
  setup_prompt(#525. requires·requires_env가 채워지지 않았을 때 보드 [설정하기]가 띄우는 설정 세션에 넘길 안내. 공백을 정리해 1000자까지).
  argv의 상대 경로는 agenda.json 폴더 기준이다(그 폴더를 작업 폴더로 삼아 실행한다).
- 발견 순서: 플러그인 scripts/board/agenda/*/ → HM_CLAUDE_SKILLS_DIR/*/ → HM_CODEX_SKILLS_DIR/*/. 같은 id는 먼저 찾은
  쪽이 쓴다(기본 어댑터를 사용자 파일이 가로채지 못한다). 잘못된 선언은 그 소스만 '선언 오류'로 보인다.
- fetch는 `--since ISO --until ISO`를 덧붙여 부르고, stdout JSONL 한 줄이 항목 하나다
  {id, kind: event|reply|todo, title, start?, end?, due?, created?, from?, shared?, url?, detail?, done?, status?, status_category?}.
  잘못된 줄은 건너뛰고 센다. 소스당 500개까지.
  status(#668)는 원본의 상태 이름(40자까지), status_category는 그 분류 new|indeterminate|done(그 밖의 값은 필드만 버린다).
  화면은 status가 있으면 제목 옆 칩으로 보이고(분류가 indeterminate면 진행 색), [Jira] 출처 필터에서 진행 중/할 일로 묶는다.
  url(link도 받는다)은 http(s) 또는 허용한 앱 딥링크(#592. APP_LINK_SCHEMES — 지금은 `msteams:`)만 남긴다. 그 밖의 스킴
  (javascript:·file:·data: 등)은 url만 버리고 항목은 남긴다. 앱이 없는 사용자를 위해 웹 링크를 줄지는 어댑터가 정한다.
  due(#539)는 reply·todo의 기한: 날짜(YYYY-MM-DD) 또는 날짜·시각(ISO 8601). 읽을 수 없는 기한은 버리고 항목은 남긴다.
  created(#567)는 받은·만든 시각(ISO 8601, 읽을 수 없으면 버린다), from은 요청자(60자까지), shared는 event가 팀·공유
  캘린더 일정이면 true. 화면이 할 일을 새로 맡겨진 것·쌓인 것으로 가르고 경과일·요청자를 보이며 공유 일정을 접는 데 쓴다.
- done은 argv 뒤에 항목 id를 붙여 부른다. done이 없는 소스는 보드가 done.json에만 적고 숨긴다. event는 완료 대상이 아니다.
  reopen(#567)은 argv 뒤에 항목 id를 붙여 원본의 완료를 되돌린다. 선언한 소스만 완료 토스트·완료함에서 다시 열 수 있다.
- 선택 delete(#637, argv): 뒤에 항목 id를 붙여 원본에서 그 항목을 지운다. todo·reply만 대상이고 event는 아니다.
  실패하면 0이 아닌 종료 코드와 stderr 사유를 낸다. 선언한 소스의 할 일·답할 것에만 보드 [삭제]가 보인다.
- 일정은 실제 시각순이다: (로컬 날짜, 종일 먼저, 시각, 제목). 종일(YYYY-MM-DD)은 그날 0시, 읽을 수 없는 start는 맨 뒤.
- 선택 accounts(argv, #519): 한 소스에 계정을 여럿 잇는 어댑터. stdout JSONL 한 줄이 계정 하나 {id, name, error?}.
  선언한 소스는 연결된 뒤에도 connect를 다시 불러 계정을 더하고, 끊기는 disconnect argv 뒤에 계정 id를 붙여 그 계정만 끊는다
  (마지막 계정을 끊으면 소스 연결도 끊긴다). 계정 목록은 연결·끊기·수집 뒤에 다시 읽어 sources.json에 둔다.
- 선택 settings (#632): 사람이 보드 '연결한 곳' 카드에서 바꾸는 소스 설정. {get(argv), set(argv), fields: [{id, label,
  type: multi-select|toggle|number, options?(argv, multi-select에만 필수), min?·max?(정수, number에만), danger?(bool),
  confirm?(사람 말 확인 문구), help?}]}. 하나라도 잘못되면 그 소스만 '선언 오류'다.
  get은 stdout에 JSON 객체 하나 {필드 id: 값}(multi-select는 문자열 배열, toggle은 bool, number는 정수)을 낸다.
  options는 stdout JSONL 한 줄이 선택지 하나 {value, label}(둘 다 문자열, 잘못된 줄은 건너뜀, 필드당 200개까지)다.
  set은 표준 입력으로 모든 필드를 담은 JSON 객체 하나를 받고, 종료 코드 0이 저장 성공이다. 보드는 바꾼 필드만 받아
  get 현재값에 합쳐 넘긴다. 세 명령 모두 연결된 소스에서만, 소스 폴더에서 60초 한도로 부른다.
  자유 입력은 없다: multi-select 값은 options 목록 안에서만, number는 min~max 정수만 받고 나머지는 거부한다.
  danger 필드는 현재값과 비교해 켜기(toggle false→true)·항목 추가(multi-select)·값 바꾸기(number)일 때 요청에
  confirm:true가 없으면 set을 부르지 않고 거부한다(화면이 확인 대화를 띄운다). 끄기·빼기만 있는 변경은 바로 저장한다.
데이터는 <data>/board/agenda/ 아래(sources.json·cache/<id>.json·done.json·todos.json·brief.json·completed.json, 모두 600)에 둔다.
완료함(#567) completed.json은 최근 7일 완료(직접 적은 할 일·보드에만 숨긴 항목·어댑터 done)의 출처·id·제목·url·시각만
남기고 본문(detail)은 남기지 않는다. 7일이 지난 줄은 읽고 쓸 때 지우고, 다시 열면 그 줄을 지운다.
아침 요약(#539): 스킬의 정기 작업이 `board.sh brief set`으로 요약 글을 남기면 화면 맨 위에 보이고, `board.sh agenda summary`는
그 요약을 만들 재료(오늘 일정·답할 것·기한순 할 일)를 JSON으로 낸다.
메일·채팅·일정 본문은 이 폴더에만 있고 harvest·지표 수집 대상(events/)에 쓰지 않는다.
설정 세션 지시문(setup_prompt())은 서버가 만든다: 소스 선언의 setup_prompt를 고정 머리말·꼬리말(비밀 값은 대화로 받지 않음)로
감싼다. 없으면 None — 화면은 setup_hint만 펼친다. 플러그인 구글 소스는 공용 클라이언트(#519)로 준비물이 없어 설정 세션이 없다.
"""
import fcntl, glob, json, os, re, secrets, signal, subprocess, sys, threading, time
from datetime import datetime, timedelta, timezone

DIR = os.path.dirname(os.path.abspath(__file__))
BUILTIN_DIR = os.path.join(DIR, "agenda")
KINDS = ("event", "reply", "todo")
KIND_ALIAS = {"message": "reply"}  # 이슈 초안의 이름도 받는다
ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,39}$")
ENV_KEY_RE = re.compile(r"^[A-Z][A-Z0-9_]*$")
# 내 일정 url로 여는 앱 딥링크 스킴(#592). template.html·BoardLauncher.swift의 목록과 같아야 한다(tests/board-agenda.sh가 비교).
APP_LINK_SCHEMES = ("msteams",)
LINK_RE = re.compile(r"^(?:https?://|(?i:%s):\S)" % "|".join(map(re.escape, APP_LINK_SCHEMES)))  # 앱 스킴만 대소문자 무시
TODO_ID = "todo"
MAX_ITEMS = 500
SETUP_PROMPT_MAX = 1000
FROM_MAX = 60
STATUS_MAX = 40
STATUS_CATEGORIES = ("new", "indeterminate", "done")
COMPLETED_DAYS = 7
BRIEF_MAX = 4000
DEFAULT_INTERVAL = 15
# 테스트 전용 시간 한도(사용자 설정 아님) — 실패 격리 테스트가 시간 초과를 몇 초 안에 보게 한다.
FETCH_TIMEOUT = float(os.environ.get("BOARD_AGENDA_FETCH_TIMEOUT") or 60)
CONNECT_TIMEOUT = 300
ACTION_TIMEOUT = 60
WAIT_ON_READ = 1.5  # 화면이 읽을 때 막 시작한 수집을 기다리는 최대 시간. 느린 소스는 다음 읽기에 보인다
SETTING_TYPES = ("multi-select", "toggle", "number")
MAX_OPTIONS = 200


def utc():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _epoch(iso):
    try:
        return datetime.strptime(iso, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp()
    except (TypeError, ValueError):
        return 0.0


DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")


def parse_due(value):
    """기한 문자열 → (정규화한 문자열, 비교용 epoch). 날짜만이면 그날 끝(이 PC 시간대)으로 본다. 못 읽으면 (None, None)."""
    if not isinstance(value, str) or not value.strip() or len(value.strip()) > 40:
        return None, None
    v = value.strip()
    try:
        if DATE_RE.match(v):
            d = datetime.strptime(v, "%Y-%m-%d")
            return v, d.replace(hour=23, minute=59, second=59).astimezone().timestamp()
        d = datetime.fromisoformat(v[:-1] + "+00:00" if v.endswith("Z") else v)
    except ValueError:
        return None, None
    return v, (d if d.tzinfo else d.astimezone()).timestamp()


def parse_when(value):
    """일정 start 같은 시각 → epoch. 날짜만이면 그날 0시(이 PC 시간대), 시간대 없는 시각은 이 PC 시간대. 못 읽으면 None."""
    if not isinstance(value, str) or not value.strip() or len(value.strip()) > 40:
        return None
    v = value.strip()
    try:
        if DATE_RE.match(v):
            return datetime.strptime(v, "%Y-%m-%d").astimezone().timestamp()
        d = datetime.fromisoformat(v[:-1] + "+00:00" if v.endswith("Z") else v)
    except ValueError:
        return None
    return (d if d.tzinfo else d.astimezone()).timestamp()


def event_key(it):
    """(로컬 날짜, 종일 먼저, 시각, 제목). 소스·계정·오프셋이 섞여도 실제 시각순이다. 읽을 수 없는 start는 맨 뒤."""
    ts = parse_when(it.get("start"))
    if ts is None:
        return (1, "", 0, 0.0, it.get("title") or "")
    day = datetime.fromtimestamp(ts).astimezone().strftime("%Y-%m-%d")
    return (0, day, 0 if DATE_RE.match(it["start"].strip()) else 1, ts, it.get("title") or "")


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


def secrets_value(path, key):
    """secrets.env에서 setup.sh가 쓴 `export KEY='값'` 줄만 읽는다(source하지 않음, '\\'' 이스케이프를 푼다). 없으면 None."""
    try:
        with open(path, encoding="utf-8") as f:
            lines = f.read().splitlines()
    except (OSError, UnicodeDecodeError):
        return None
    m = next((m for m in (re.match(r"^export %s='(.*)'$" % re.escape(key), x) for x in lines) if m), None)
    return m.group(1).replace("'\\''", "'") if m else None


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


def _int(v):
    return isinstance(v, int) and not isinstance(v, bool)


def _parse_settings(s):
    """settings 선언(#632) → (정리한 선언, 오류). 오류 문구는 parse_declaration과 같은 '<키>는 … 여야 합니다.' 꼴."""
    if not isinstance(s, dict):
        return None, "settings는 get·set·fields를 가진 객체여야 합니다."
    for k in ("get", "set"):
        if not _argv(s.get(k)):
            return None, f"settings.{k}는 명령(문자열 배열)이어야 합니다."
    raw = s.get("fields")
    if not isinstance(raw, list) or not raw:
        return None, "settings.fields는 비어 있지 않은 배열이어야 합니다."
    fields, ids = [], set()
    for i, f in enumerate(raw):
        key = f"settings.fields[{i}]"
        if not isinstance(f, dict):
            return None, f"{key}는 객체여야 합니다."
        fid, ftype = f.get("id"), f.get("type")
        if not isinstance(fid, str) or not ID_RE.match(fid):
            return None, f"{key}.id는 소문자·숫자·- 로 된 이름이어야 합니다."
        if fid in ids:
            return None, f"{key}.id는 다른 필드와 달라야 합니다('{fid}'가 겹칩니다)."
        ids.add(fid)
        if not isinstance(f.get("label"), str) or not f["label"].strip():
            return None, f"{key}.label은 빈 문자열이 아니어야 합니다."
        if ftype not in SETTING_TYPES:
            return None, f"{key}.type은 multi-select·toggle·number 중 하나여야 합니다."
        if ftype == "multi-select" and not _argv(f.get("options")):
            return None, f"{key}.options는 multi-select 필드에 꼭 있는 명령(문자열 배열)이어야 합니다."
        if ftype != "multi-select" and "options" in f:
            return None, f"{key}.options는 multi-select 필드에만 쓰여야 합니다."
        for k in ("min", "max"):
            if k in f and ftype != "number":
                return None, f"{key}.{k}은 number 필드에만 쓰여야 합니다."
            if k in f and not _int(f[k]):
                return None, f"{key}.{k}은 정수여야 합니다."
        if _int(f.get("min")) and _int(f.get("max")) and f["min"] > f["max"]:
            return None, f"{key}.min은 max보다 크지 않아야 합니다."
        if "danger" in f and not isinstance(f["danger"], bool):
            return None, f"{key}.danger는 true 또는 false여야 합니다."
        for k in ("confirm", "help"):
            if f.get(k) is not None and not isinstance(f[k], str):
                return None, f"{key}.{k}는 문자열이어야 합니다."
        fields.append({
            "id": fid, "label": _short(f["label"], 60), "type": ftype, "options": f.get("options"),
            "min": f.get("min"), "max": f.get("max"), "danger": f.get("danger") is True,
            "confirm": _short(f["confirm"], 300) if (f.get("confirm") or "").strip() else None,
            "help": _short(f["help"], 300) if (f.get("help") or "").strip() else None,
        })
    return {"get": s["get"], "set": s["set"], "fields": fields}, None


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
    for k in ("connect", "disconnect", "done", "reopen", "delete", "accounts"):
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
    req_env = d.get("requires_env", [])
    if isinstance(req_env, str):
        req_env = [req_env]
    if not isinstance(req_env, list) or ("requires_env" in d and not req_env) or \
            not all(isinstance(x, str) and ENV_KEY_RE.match(x) for x in req_env):
        return None, "requires_env는 키 이름(대문자·숫자·_, 문자열 또는 비어 있지 않은 문자열 배열)이어야 합니다."
    hint = d.get("setup_hint")
    if hint is not None and not isinstance(hint, str):
        return None, "setup_hint는 문자열이어야 합니다."
    prompt = d.get("setup_prompt")
    if prompt is not None and not isinstance(prompt, str):
        return None, "setup_prompt는 문자열이어야 합니다."
    settings = None
    if "settings" in d:
        settings, err = _parse_settings(d["settings"])
        if err:
            return None, err
    return {
        "id": d["id"], "name": _short(d["name"], 60), "folder": os.path.dirname(os.path.abspath(path)),
        "fetch": d["fetch"], "connect": d.get("connect"), "disconnect": d.get("disconnect"), "done": d.get("done"),
        "reopen": d.get("reopen"), "delete": d.get("delete"), "accounts": d.get("accounts"),
        "interval": interval, "requires": req, "requires_env": req_env, "setup_hint": _short(hint, 300) if hint else None,
        "setup_prompt": _short(prompt, SETUP_PROMPT_MAX) if prompt and prompt.strip() else None,
        "settings": settings,
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
    due, _ = parse_due(raw.get("due"))
    if due and kind != "event":
        item["due"] = due
    created, _ = parse_due(raw.get("created"))
    if created:
        item["created"] = created
    if isinstance(raw.get("from"), str) and raw["from"].strip():
        item["from"] = _short(raw["from"], FROM_MAX)
    if isinstance(raw.get("status"), str) and raw["status"].strip():
        item["status"] = _short(raw["status"], STATUS_MAX)
    if raw.get("status_category") in STATUS_CATEGORIES:
        item["status_category"] = raw["status_category"]
    if kind == "event" and raw.get("shared") is True:
        item["shared"] = True
    url = raw.get("url") if isinstance(raw.get("url"), str) else raw.get("link")
    if isinstance(url, str) and LINK_RE.match(url):
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
        self.brief_path = os.path.join(self.dir, "brief.json")
        self.completed_path = os.path.join(self.dir, "completed.json")
        self.warn = warn or (lambda m: print(m, file=sys.stderr, flush=True))
        self._warned = set()
        self.lock = threading.Lock()
        self.fetching = {}  # id -> Thread
        self.refetch = set()  # 수집 중에 다시 모아야 할 일이 생긴 소스(계정을 끊음 등)
        self.connecting = {}  # id -> 시작 시각
        self.connect_error = {}  # id -> 사람 말 오류(연결 실패)
        self.settings_lock = threading.Lock()  # 설정 저장(get → 합치기 → set)이 서로 끼어들어 값을 잃지 않게

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
        """채워지지 않은 준비물: 없는 requires 파일 + 찾지 못한 requires_env 키 이름(값은 다루지 않는다)."""
        out = [p for p in src["requires"] if not os.path.exists(self._expand(p))]
        keys = src.get("requires_env") or []
        if keys:
            out += [k for k in keys if not self._has_env(k)]
        return out

    def _has_env(self, key):
        """setup.sh resolve_value와 같은 순서: 프로세스 환경 → Claude settings.json env → secrets.env(빈 값 제외)."""
        if os.environ.get(key):
            return True
        path = os.environ.get("HARNESS_CLAUDE_SETTINGS") or os.path.expanduser("~/.claude/settings.json")
        settings = _read_json(path, {})
        env = settings.get("env") if isinstance(settings, dict) else None
        if isinstance(env, dict) and isinstance(env.get(key), str) and env[key]:
            return True
        return bool(secrets_value(os.path.join(self.data, "secrets.env"), key))

    def setup_prompt(self, src):
        """[설정하기] 세션 지시문. 브라우저 문자열은 받지 않고 소스 선언·고정 문구로만 만든다. 없으면 None."""
        if src.get("invalid"):
            return None
        if not src.get("setup_prompt"):
            return None
        return "\n".join([
            f"보드 '내 일정 > 연결한 곳'에서 일정 소스 {src['id']}의 [설정하기]로 띄운 세션입니다. 아래는 그 소스를 제공한 스킬의 안내입니다.",
            "",
            src["setup_prompt"],
            "",
            "비밀 값(토큰·키·client secret)은 대화로 받지 않고, 사용자가 직접 파일·별도 터미널에 둡니다. 다른 스킬·소스는 바꾸지 않습니다. "
            "끝나면 결과를 짧게 요약합니다. 보드는 세션이 끝나면 상태를 다시 읽습니다.",
        ])

    def _env(self):
        env = dict(os.environ)
        env["HM_DATA_DIR"] = self.data
        env["HARNESS_METRICS_DIR"] = self.data
        return env

    def _run(self, src, argv, extra, timeout, stdin_text=None):
        """어댑터 명령 하나. stdin_text를 주면 표준 입력으로 넘긴다(없으면 DEVNULL).
        반환 (종료 코드 또는 None(시간 초과·실행 못 함), stdout, 사람 말 오류)."""
        argv = list(argv)
        first = os.path.join(src["folder"], argv[0])
        if not os.path.isabs(argv[0]) and os.path.exists(first):
            argv[0] = first
        try:  # 자기 프로세스 그룹으로 띄워, 시간 초과면 손자 프로세스까지 끈다(파이프를 쥔 손자가 기다림을 늘리지 않게)
            p = subprocess.Popen(argv + list(extra), cwd=src["folder"], env=self._env(),
                                 stdin=subprocess.DEVNULL if stdin_text is None else subprocess.PIPE,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)
        except OSError as e:
            return None, "", f"명령을 실행하지 못했습니다({e.strerror or e})."
        try:
            out, err = p.communicate(input=stdin_text, timeout=timeout)
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

    # ---- 완료함(#567) ----
    def _completed_rows(self):
        d = _read_json(self.completed_path, {})
        rows = d.get("items") if isinstance(d, dict) else None
        return [r for r in rows or [] if isinstance(r, dict) and isinstance(r.get("source"), str) and isinstance(r.get("id"), str)]

    def _completed_update(self, change=None):
        """잠근 채 읽고 7일 지난 줄을 지운 뒤 change(rows)로 고친다. 바뀐 게 있을 때만 쓴다. 반환: 남은 줄."""
        with _FileLock(self.completed_path):
            rows = self._completed_rows()
            cutoff = time.time() - COMPLETED_DAYS * 86400
            kept = [r for r in rows if _epoch(r.get("done_at")) >= cutoff]
            if change:
                kept = change(kept)
            if kept != rows or (change and not os.path.exists(self.completed_path)):
                _write_private(self.completed_path, {"items": kept})
            return kept

    def _completed_add(self, source, source_name, item):
        row = {"source": source, "source_name": source_name, "id": item["id"], "kind": item.get("kind") or "todo",
               "title": item.get("title") or "", "done_at": utc()}
        if item.get("url"):
            row["url"] = item["url"]
        self._completed_update(lambda rows: [r for r in rows if (r["source"], r["id"]) != (source, item["id"])] + [row])

    def _completed_remove(self, source, item_id):
        self._completed_update(lambda rows: [r for r in rows if (r["source"], r["id"]) != (source, item_id)])

    def completed(self, sources=None):
        """최근 7일 완료, 최신순. can_reopen: 할 일·보드 숨김은 늘, 어댑터는 소스가 지금 reopen을 선언했을 때만."""
        by_id = {s["id"]: s for s in (sources if sources is not None else self.sources()) if not s.get("invalid")}
        hidden = self._done_local()
        out = []
        for r in sorted(self._completed_update(), key=lambda r: _epoch(r.get("done_at")), reverse=True):
            src = by_id.get(r["source"])
            local = r["source"] == TODO_ID or r["id"] in (hidden.get(r["source"]) or {})
            out.append(dict(r, can_reopen=bool(local or (src and src.get("reopen")))))
        return out

    # ---- 화면용 상태 ----
    def state(self, wait=WAIT_ON_READ):
        self.refresh_due(wait)
        local_done = self._done_local()
        connected = self._connected()
        sources, items = [], {k: [] for k in KINDS}
        declared = self.sources()
        for src in declared:
            if src.get("invalid"):
                sources.append({"id": src["id"], "name": src["name"], "state": "error", "connected": False,
                                "invalid": True, "error": "선언 오류: " + src["invalid"], "fetched_at": None, "setup_hint": None,
                                "setup_session": False, "settings": False})
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
                            "connect_error": self.connect_error.get(sid), "setup_session": bool(self.setup_prompt(src)),
                            "settings": bool(src["settings"]), "can_delete": bool(src["delete"])})
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
                row = {"source": TODO_ID, "source_name": "할 일", "id": t["id"], "kind": "todo",
                       "title": t["title"], "start": t.get("created_at"), "local": True}
                if t.get("created_at"):
                    row["created"] = t["created_at"]
                if parse_due(t.get("due"))[0]:
                    row["due"] = t["due"]
                items["todo"].append(row)
        items["event"].sort(key=event_key)
        for k in ("reply", "todo"):  # 기한 있는 것이 먼저(이른 순), 기한 없는 것은 원래 순서
            items[k].sort(key=lambda i: parse_due(i.get("due"))[1] or float("inf"))
        res = {"ok": True, "now": utc(), "sources": sources, "items": items,
               "todo_total": len(todos), "window": dict(zip(("since", "until"), window())),
               "completed": self.completed(declared)}
        brief = self.brief()
        if brief:
            res["brief"] = brief
        return res

    def summary(self, wait=10.0):
        """아침 요약 재료: 오늘 일정, 답할 것, 기한순 할 일(지난 것 표시). 본문은 요약에만 쓰고 기록에 남기지 않는다."""
        st = self.state(wait=wait)
        now, today = time.time(), datetime.now().astimezone().strftime("%Y-%m-%d")
        pick = ("source", "source_name", "id", "title", "start", "end", "due", "detail", "url")

        def row(it):
            r = {k: it[k] for k in pick if k in it}
            ts = parse_due(it.get("due"))[1]
            if ts:
                r["overdue"] = ts < now
            return r

        events = [row(e) for e in st["items"]["event"] if (e.get("start") or "")[:10] <= today]
        todos = [row(t) for t in st["items"]["todo"]]
        return {"ok": True, "now": st["now"], "today": today, "events_today": events,
                "replies": [row(r) for r in st["items"]["reply"]], "todos": todos,
                "counts": {"events_today": len(events), "replies": len(st["items"]["reply"]), "todos": len(todos),
                           "overdue": sum(1 for t in todos if t.get("overdue"))},
                "sources": [{"id": s["id"], "name": s["name"], "state": s["state"], "error": s.get("error")}
                            for s in st["sources"] if s.get("connected") or s.get("invalid")]}

    # ---- 아침 요약 글 ----
    def brief(self):
        d = _read_json(self.brief_path, {})
        if not isinstance(d, dict) or not isinstance(d.get("text"), str) or not d["text"].strip():
            return None
        return {"text": d["text"], "source": d.get("source") or "", "at": d.get("at")}

    def brief_set(self, text, source=""):
        text = (text or "").replace("\r\n", "\n").strip()[:BRIEF_MAX]
        if not text:
            return False
        with _FileLock(self.brief_path):
            _write_private(self.brief_path, {"text": text, "source": _short(source or "", 60), "at": utc()})
        return True

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

    def refresh_all(self):
        """머리 [지금 가져오기](#663): 연결된 모든 소스를 주기와 상관없이 한꺼번에 다시 모은다.

        소스마다 스레드를 함께 띄우고 같은 마감까지 기다린다 — 하나씩 refresh를 부르면 N×시간 초과까지 늘어진다.
        이미 수집 중인 소스는 그 스레드를 기다리지 않고 건너뛴다(그 결과는 다음 읽기에 보인다). 진행 여부는 서버만 정확히 안다.
        돌려주는 세 번째 값은 기록용 소스 id 목록이다(이름·제목은 기록에 남기지 않는다).
        """
        targets = [s for s in self.sources()
                   if not s.get("invalid") and s["id"] not in self.connecting
                   and self.is_connected(s["id"]) and not self.missing(s)]
        if not targets:
            return 409, {"ok": False, "message": "연결된 곳이 없습니다."}, {}
        with self.lock:
            busy_ids = {s["id"] for s in targets
                        if self.fetching.get(s["id"]) and self.fetching[s["id"]].is_alive()}
        skipped = [s for s in targets if s["id"] in busy_ids]
        run = [s for s in targets if s["id"] not in busy_ids]
        threads = [self._start_fetch(s) for s in run]
        deadline = time.time() + FETCH_TIMEOUT + 5
        for t in threads:
            t.join(max(0.0, deadline - time.time()))
        refreshed, failed = [], []
        for s in run:
            err = self.cache(s["id"]).get("error")
            if err:
                failed.append({"source": s["id"], "name": s["name"], "error": err})
            else:
                refreshed.append(s)
        parts = []
        if refreshed:
            parts.append(f"{len(refreshed)}곳에서 새로 가져왔습니다.")
        parts += [f"{f['name']}에서 가져오지 못했습니다. {f['error']}" for f in failed]
        parts += [f"{s['name']}은(는) 이미 가져오는 중이라 건너뛰었습니다." for s in skipped]
        res = {"ok": not failed, "refreshed": [s["name"] for s in refreshed], "skipped": [s["name"] for s in skipped],
               "failed": failed, "message": " ".join(parts)}
        ids = {"refreshed": [s["id"] for s in refreshed], "skipped": [s["id"] for s in skipped],
               "failed": [f["source"] for f in failed]}
        return 200, res, ids

    def done(self, source_id, item_id):
        if not isinstance(item_id, str) or not item_id:
            return 400, {"ok": False, "message": "완료할 항목이 없습니다."}
        if source_id == TODO_ID:
            ok = self.todo_done(item_id)
            return (200, {"ok": True, "message": "할 일을 완료로 표시했습니다.", "undo": True}) if ok else (404, {"ok": False, "message": "그 할 일을 찾지 못했습니다."})
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
            self._completed_add(source_id, src["name"], item)
            if src["reopen"]:
                return 200, {"ok": True, "message": f"{src['name']}에 완료로 표시했습니다.", "undo": True}
            return 200, {"ok": True, "message": f"{src['name']}에 완료로 표시했습니다. 되돌리려면 원본에서 다시 여세요.", "undo": False}
        with _FileLock(self.done_path):
            d = self._done_local()
            d.setdefault(source_id, {})[item_id] = utc()
            _write_private(self.done_path, d)
        self._completed_add(source_id, src["name"], item)
        return 200, {"ok": True, "message": "완료로 표시했습니다. 이 보드에서만 숨깁니다.", "undo": True}

    def reopen(self, source_id, item_id):
        """완료를 되돌린다(#539·#567). 직접 적은 할 일·보드에만 숨긴 항목, reopen을 선언한 어댑터의 done 항목."""
        if not isinstance(item_id, str) or not item_id:
            return 400, {"ok": False, "message": "되돌릴 항목이 없습니다."}
        if source_id == TODO_ID:
            with _FileLock(self.todos_path):
                items = self._todos()
                hit = next((t for t in items if t["id"] == item_id and t.get("done_at")), None)
                if hit:
                    hit["done_at"] = None
                    _write_private(self.todos_path, {"items": items})
            if hit:
                self._completed_remove(TODO_ID, item_id)
            return (200, {"ok": True, "message": "할 일을 다시 열었습니다."}) if hit else \
                (404, {"ok": False, "message": "되돌릴 할 일을 찾지 못했습니다."})
        with _FileLock(self.done_path):
            d = self._done_local()
            hidden = d.get(source_id) if isinstance(d.get(source_id), dict) else {}
            was_hidden = item_id in hidden
            if was_hidden:
                hidden.pop(item_id)
                _write_private(self.done_path, d)
        if was_hidden:
            self._completed_remove(source_id, item_id)
            return 200, {"ok": True, "message": "다시 목록에 올렸습니다."}
        return self._reopen_adapter(source_id, item_id)

    def _reopen_adapter(self, source_id, item_id):
        src = self.find(source_id)
        if not src or not src["reopen"]:
            return 409, {"ok": False, "message": "원본에 완료로 알린 항목은 여기서 되돌릴 수 없습니다. 원본에서 다시 여세요."}
        c = self.cache(source_id)
        cached = next((i for i in c.get("items") or [] if i.get("id") == item_id), None)
        known = any((r["source"], r["id"]) == (source_id, item_id) for r in self._completed_rows())
        if not known and not (cached and cached.get("done")):
            return 404, {"ok": False, "message": "되돌릴 항목을 찾지 못했습니다."}
        code, _out, err = self._run(src, src["reopen"], [item_id], ACTION_TIMEOUT)
        if code != 0:
            return 200, {"ok": False, "message": f"{src['name']}에서 다시 열지 못했습니다. " + err}
        if cached and cached.get("done") and self.is_connected(source_id):
            cached.pop("done", None)
            _write_private(self.cache_path(source_id), c)
        self._completed_remove(source_id, item_id)
        if self.is_connected(source_id) and not self.missing(src):
            self._start_fetch(src, again=True)
        return 200, {"ok": True, "message": f"{src['name']}에서 다시 열었습니다."}

    def delete(self, source_id, item_id):
        """항목을 지운다(#637). 직접 적은 할 일은 todos.json에서, delete를 선언한 어댑터는 그 argv로 원본에서. 완료함에서도 뺀다."""
        if not isinstance(item_id, str) or not item_id:
            return 400, {"ok": False, "message": "지울 항목이 없습니다."}
        if source_id == TODO_ID:
            return (200, {"ok": True, "message": "할 일을 지웠습니다."}) if self.todo_delete(item_id) else \
                (404, {"ok": False, "message": "그 할 일을 찾지 못했습니다."})
        src = self.find(source_id)
        if not src or src.get("invalid"):
            return 404, {"ok": False, "message": "등록된 일정 소스가 아닙니다."}
        c = self.cache(source_id)
        item = next((i for i in c.get("items") or [] if i.get("id") == item_id), None)
        if not item:
            return 404, {"ok": False, "message": "그 항목을 찾지 못했습니다. 화면을 새로 고친 뒤 다시 시도하세요."}
        if item["kind"] == "event":
            return 400, {"ok": False, "message": "일정은 여기서 지우지 않습니다."}
        if not src["delete"]:
            return 409, {"ok": False, "message": f"{src['name']}은(는) 보드에서 지울 수 없습니다. 원본에서 지우세요."}
        code, _out, err = self._run(src, src["delete"], [item_id], ACTION_TIMEOUT)
        if code != 0:
            return 200, {"ok": False, "message": f"{src['name']}에서 지우지 못했습니다. " + err}
        if self.is_connected(source_id):
            c["items"] = [i for i in c.get("items") or [] if i.get("id") != item_id]
            _write_private(self.cache_path(source_id), c)
        self._completed_remove(source_id, item_id)
        if self.is_connected(source_id) and not self.missing(src):
            self._start_fetch(src, again=True)
        return 200, {"ok": True, "message": f"{src['name']}에서 지웠습니다."}

    # ---- 소스 설정(#632) ----
    def _settings_source(self, source_id):
        """설정을 읽고 쓸 수 있는 소스. 반환 (소스, None) 또는 (None, (코드, 응답))."""
        src = self.find(source_id) if isinstance(source_id, str) else None
        if not src:
            return None, (404, {"ok": False, "message": "등록된 일정 소스가 아닙니다."})
        if not src["settings"]:
            return None, (404, {"ok": False, "message": f"{src['name']}은(는) 보드에서 바꿀 설정을 선언하지 않았습니다."})
        if not self.is_connected(source_id) or self.missing(src):
            return None, (409, {"ok": False, "message": f"{src['name']}에 연결돼 있지 않습니다. 먼저 연결한 뒤 설정을 바꾸세요."})
        return src, None

    @staticmethod
    def _setting_value(field, v):
        """get이 낸 값 하나를 필드 타입에 맞춘다. 맞지 않으면 빈 값(빈 목록·false·null)."""
        if field["type"] == "multi-select":
            return list(dict.fromkeys(x for x in v if isinstance(x, str))) if isinstance(v, list) else []
        if field["type"] == "toggle":
            return v is True
        return v if _int(v) else None

    def _settings_current(self, src):
        """get → {필드 id: 값}. 반환 (값, 사람 말 오류)."""
        code, out, err = self._run(src, src["settings"]["get"], [], ACTION_TIMEOUT)
        if code != 0:
            return None, f"{src['name']}의 현재 설정을 읽지 못했습니다. " + err
        try:
            raw = json.loads(out or "")
        except ValueError:
            raw = None
        if not isinstance(raw, dict):
            return None, f"{src['name']}의 현재 설정을 읽지 못했습니다. get 명령이 JSON 객체를 내지 않았습니다."
        return {f["id"]: self._setting_value(f, raw.get(f["id"])) for f in src["settings"]["fields"]}, None

    def _settings_options(self, src, field):
        """options → [{value, label}]. 반환 (선택지, 사람 말 오류)."""
        code, out, err = self._run(src, field["options"], [], ACTION_TIMEOUT)
        if code != 0:
            return None, f"{field['label']} 선택지를 읽지 못했습니다. " + err
        rows, seen = [], set()
        for line in (out or "").splitlines():
            try:
                raw = json.loads(line)
            except ValueError:
                continue
            if not isinstance(raw, dict):
                continue
            value, label = raw.get("value"), raw.get("label")
            if not isinstance(value, str) or not value or len(value) > 200 or value in seen or not isinstance(label, str):
                continue
            seen.add(value)
            rows.append({"value": value, "label": _short(label, 120) or value})
            if len(rows) >= MAX_OPTIONS:
                break
        return rows, None

    def settings_read(self, source_id):
        """설정 폼: 필드 선언·선택지·현재값. get·options가 실패하면 ok:false와 사유."""
        src, refused = self._settings_source(source_id)
        if refused:
            return refused
        values, err = self._settings_current(src)
        if err:
            return 200, {"ok": False, "message": err}
        fields = []
        for f in src["settings"]["fields"]:
            row = {k: f[k] for k in ("id", "label", "type", "min", "max", "danger", "confirm", "help")}
            row["options"] = []
            if f["type"] == "multi-select":
                row["options"], err = self._settings_options(src, f)
                if err:
                    return 200, {"ok": False, "message": err}
            fields.append(row)
        return 200, {"ok": True, "fields": fields, "values": values}

    @staticmethod
    def _setting_check(field, v):
        """요청 값 하나를 검사한다(선택지 목록은 따로). 반환 (정리한 값, 사람 말 오류)."""
        label = field["label"]
        if field["type"] == "toggle":
            return (v, None) if isinstance(v, bool) else (None, f"{label}은(는) 켜기·끄기(true/false)로만 바꿉니다.")
        if field["type"] == "multi-select":
            if not isinstance(v, list) or not all(isinstance(x, str) for x in v):
                return None, f"{label}은(는) 목록에서 고른 항목들로만 바꿉니다."
            return list(dict.fromkeys(v)), None
        lo, hi = field["min"], field["max"]
        if not _int(v) or (lo is not None and v < lo) or (hi is not None and v > hi):
            span = f" {lo if lo is not None else ''}~{hi if hi is not None else ''} 사이" if lo is not None or hi is not None else ""
            return None, f"{label}은(는){span} 정수로만 바꿉니다."
        return v, None

    def settings_save(self, source_id, values, confirm=False):
        """바꿀 필드만 받아 검사하고, 위험한 변경은 confirm을 요구한 뒤, get 현재값에 합친 전체 객체를 set 표준 입력으로 넘긴다."""
        src, refused = self._settings_source(source_id)
        if refused:
            return refused
        if not isinstance(values, dict) or not values:
            return 400, {"ok": False, "message": "바꿀 설정 값(values)을 필드 id와 값의 객체로 보내야 합니다."}
        by_id = {f["id"]: f for f in src["settings"]["fields"]}
        unknown = [k for k in values if k not in by_id]
        if unknown:
            return 400, {"ok": False, "message": f"{src['name']}에 없는 설정입니다: {_short(', '.join(unknown), 100)}"}
        wanted = {}
        for fid, v in values.items():
            wanted[fid], err = self._setting_check(by_id[fid], v)
            if err:
                return 400, {"ok": False, "message": err}
        with self.settings_lock:
            for fid, v in wanted.items():
                f = by_id[fid]
                if f["type"] != "multi-select":
                    continue
                opts, err = self._settings_options(src, f)
                if err:
                    return 200, {"ok": False, "message": err}
                allowed = {o["value"] for o in opts}
                outside = [x for x in v if x not in allowed]
                if outside:
                    return 400, {"ok": False, "message": f"{f['label']}의 목록에 없는 항목입니다: {_short(', '.join(outside), 100)}"}
            current, err = self._settings_current(src)
            if err:
                return 200, {"ok": False, "message": err}
            risky = []
            for fid, v in wanted.items():
                f, cur = by_id[fid], current[fid]
                if not f["danger"]:
                    continue
                if (f["type"] == "toggle" and v and not cur) or (f["type"] == "number" and v != cur) or \
                        (f["type"] == "multi-select" and set(v) - set(cur)):
                    risky.append(fid)
            if risky and confirm is not True:
                return 409, {"ok": False, "needs_confirm": True, "fields": risky,
                             "message": "위험한 설정을 켜거나 더하는 변경입니다. 확인한 뒤 다시 저장하세요: "
                                        + ", ".join(by_id[x]["label"] for x in risky)}
            merged = dict(current, **wanted)
            code, _out, err = self._run(src, src["settings"]["set"], [], ACTION_TIMEOUT,
                                        stdin_text=json.dumps(merged, ensure_ascii=False))
        if code != 0:
            return 200, {"ok": False, "message": f"{src['name']} 설정을 저장하지 못했습니다. " + err}
        return 200, {"ok": True, "message": f"{src['name']} 설정을 저장했습니다."}

    # ---- 할 일 ----
    def _todos(self):
        d = _read_json(self.todos_path, {})
        items = d.get("items") if isinstance(d, dict) else None
        return [t for t in items or [] if isinstance(t, dict) and isinstance(t.get("id"), str) and isinstance(t.get("title"), str)]

    def todo_add(self, text, due=None):
        title = _short(text or "", 300)
        if not title:
            return None
        if due:
            due = parse_due(due)[0]
            if not due:
                return None
        with _FileLock(self.todos_path):
            items = self._todos()
            ids = {t["id"] for t in items}
            tid = secrets.token_hex(4)
            while tid in ids:
                tid = secrets.token_hex(4)
            row = {"id": tid, "title": title, "created_at": utc(), "done_at": None}
            if due:
                row["due"] = due
            items.append(row)
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
        self._completed_add(TODO_ID, "할 일", dict(hit, kind="todo"))
        return True

    def todo_delete(self, tid):
        """열린 할 일이든 끝낸 할 일이든 지우고 완료함에서도 뺀다(#637)."""
        with _FileLock(self.todos_path):
            items = self._todos()
            left = [t for t in items if t["id"] != tid]
            if len(left) == len(items):
                return False
            _write_private(self.todos_path, {"items": left})
        self._completed_remove(TODO_ID, tid)
        return True

    def todo_list(self, include_done=False):
        return [t for t in self._todos() if include_done or not t.get("done_at")]


TODO_USAGE = """usage: board.sh todo add [--due YYYY-MM-DD[THH:MM]] <내용...>   할 일을 적고 새 id를 출력한다
       board.sh todo list [--all]        열린 할 일을 'id<TAB>내용'으로 (--all은 끝낸 것도, 셋째 칸에 완료 시각)
       board.sh todo done <id>           할 일을 완료로 표시한다
       board.sh todo delete <id>         할 일을 지운다(끝낸 것도, 완료함에서도 뺀다)"""


def _cli_todo(args, data_dir):
    def usage():
        print(TODO_USAGE, file=sys.stderr)
        return 2

    if not args:
        return usage()
    store = Store(data_dir)
    cmd, rest = args[0], args[1:]
    if cmd == "add":
        due = None
        if rest[:1] == ["--due"]:
            if len(rest) < 2 or not parse_due(rest[1])[0]:
                print("board: --due는 YYYY-MM-DD 또는 YYYY-MM-DDTHH:MM 형식이어야 합니다", file=sys.stderr)
                return 2
            due, rest = rest[1], rest[2:]
        tid = store.todo_add(" ".join(rest), due)
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
    if cmd == "delete":
        if len(rest) != 1 or not rest[0]:
            return usage()
        if not store.todo_delete(rest[0]):
            print(f"board: 할 일 중에 id {rest[0]} 없음", file=sys.stderr)
            return 1
        return 0
    return usage()


BRIEF_USAGE = """usage: board.sh brief set [--source <이름>] < 글   아침 요약 글을 보드 '내 일정' 맨 위에 남긴다(앞의 것을 바꾼다)
       board.sh brief show                       남긴 요약 글을 출력한다
       board.sh agenda summary                   오늘 일정·답할 것·기한순 할 일을 JSON으로 낸다(아침 요약 재료)"""


def _cli_brief(args, data_dir):
    store = Store(data_dir)
    if args[:1] == ["show"] and len(args) == 1:
        b = store.brief()
        if b:
            print(b["text"])
        return 0
    if args[:1] == ["set"] and (len(args) == 1 or (len(args) == 3 and args[1] == "--source")):
        if not store.brief_set(sys.stdin.read(), args[2] if len(args) == 3 else ""):
            print("board: 요약 글이 비어 있습니다", file=sys.stderr)
            return 2
        return 0
    print(BRIEF_USAGE, file=sys.stderr)
    return 2


def main(argv):
    data_dir = os.environ.get("HARNESS_METRICS_DIR") or os.environ.get("HM_DATA_DIR") or os.path.expanduser("~/.ai-harness")
    if len(argv) >= 2 and argv[1] == "todo":
        return _cli_todo(argv[2:], data_dir)
    if len(argv) >= 2 and argv[1] == "brief":
        return _cli_brief(argv[2:], data_dir)
    if argv[1:] == ["agenda", "summary"]:
        print(json.dumps(Store(data_dir).summary(), ensure_ascii=False))
        return 0
    print("usage: agenda.py todo|brief|agenda summary ...", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
