#!/usr/bin/env python3
"""구글 캘린더 기본 어댑터(표준 라이브러리만) — 보드 '내 일정'의 agenda.json 계약을 따른다(#492, #519).

  connect          데스크톱 OAuth(루프백 + PKCE S256). 동의 URL을 브라우저로 열고 127.0.0.1 빈 포트에서 한 번만 받는다.
                   로그인한 계정(기본 캘린더 주소)으로 토큰을 남긴다. 이미 있는 계정이면 토큰을 바꾼다 — 계정 추가도 이것이다.
  fetch            연결한 모든 계정의 selected 캘린더 일정(--since ~ --until, 기본 오늘 0시부터 7일)을 kind:event JSONL로 낸다.
                   여러 계정이 같은 캘린더를 보면 한 번만 낸다. 한 계정이 실패해도 다른 계정 일정은 내고, 모두 실패해야 실패한다.
  accounts         연결한 계정 목록 JSONL {id, name, error?}. 마지막 수집에서 실패한 계정은 error에 사유를 단다.
  disconnect [id]  그 계정(없으면 모든 계정)의 로컬 토큰을 지우고 revoke를 최선 노력으로 한 번 부른다.

OAuth 클라이언트는 $HM_DATA_DIR/google-oauth-client.json(사용자가 직접 만든 것)이 있으면 그것을, 없으면 플러그인에 든
공용 데스크톱 클라이언트(client.json)를 쓴다. 데스크톱 앱의 client secret은 구글도 기밀로 보지 않는 값이고(앱에 넣어 배포하는
전제), 보호는 PKCE·state·사용자 동의가 맡는다. 중개 서버는 없다. 토큰은 $HM_DATA_DIR/board/agenda/google-accounts/<계정>.json
(600, 폴더 700)에 둔다. 예전 단일 토큰(google-token.json)은 그대로 쓰다가 처음 수집할 때 계정 주소로 옮긴다.
scope는 calendar.readonly 하나다. 토큰·client secret은 stdout·stderr에 쓰지 않는다.
"""
import base64, hashlib, json, os, re, secrets, sys, threading, time, webbrowser
from datetime import datetime, timedelta
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qs, quote, urlencode, urlparse
from urllib.request import Request, urlopen

# 테스트가 가짜 구글 서버를 넣는 자리다(사용자 설정 아님).
AUTH_URL = os.environ.get("BOARD_AGENDA_GOOGLE_AUTH_URL") or "https://accounts.google.com/o/oauth2/v2/auth"
TOKEN_URL = os.environ.get("BOARD_AGENDA_GOOGLE_TOKEN_URL") or "https://oauth2.googleapis.com/token"
API_BASE = (os.environ.get("BOARD_AGENDA_GOOGLE_API_BASE") or "https://www.googleapis.com/calendar/v3").rstrip("/")
REVOKE_URL = os.environ.get("BOARD_AGENDA_GOOGLE_REVOKE_URL") or "https://oauth2.googleapis.com/revoke"
SCOPE = "https://www.googleapis.com/auth/calendar.readonly"
CONSENT_WAIT = 290  # 보드의 connect 한도(5분)보다 조금 짧게
HTTP_TIMEOUT = 20
RECONNECT = "구글 연결이 만료됐거나 해제됐습니다. 내 일정의 '연결한 곳'에서 이 계정을 다시 연결하세요."
BUILTIN_CLIENT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "client.json")
LEGACY = "legacy"
ACCOUNT_RE = re.compile(r"^[A-Za-z0-9._%+-]{1,64}@[A-Za-z0-9.-]{1,190}\.[A-Za-z]{2,24}$")


class Fail(Exception):
    def __init__(self, message, code=1):
        super().__init__(message)
        self.code = code


def data_dir():
    return os.environ.get("HM_DATA_DIR") or os.environ.get("HARNESS_METRICS_DIR") or os.path.expanduser("~/.ai-harness")


def client_path():
    return os.path.join(data_dir(), "google-oauth-client.json")


def agenda_dir():
    return os.path.join(data_dir(), "board", "agenda")


def legacy_path():
    return os.path.join(agenda_dir(), "google-token.json")


def accounts_dir():
    return os.path.join(agenda_dir(), "google-accounts")


def account_path(account):
    return legacy_path() if account == LEGACY else os.path.join(accounts_dir(), account + ".json")


def load_client():
    """사용자가 직접 만든 클라이언트가 있으면 그것, 없으면 플러그인에 든 공용 클라이언트."""
    own = os.path.exists(client_path())
    try:
        with open(client_path() if own else BUILTIN_CLIENT, encoding="utf-8") as f:
            d = json.load(f)
    except OSError:
        raise Fail("OAuth 클라이언트 파일을 읽지 못했습니다." + (" 파일 권한을 확인하세요." if own else " 플러그인을 다시 설치하세요."), 2)
    except ValueError:
        raise Fail("OAuth 클라이언트 파일이 올바른 JSON이 아닙니다." + (" 구글 클라우드에서 받은 파일을 그대로 두세요." if own else ""), 2)
    c = d.get("installed") if isinstance(d, dict) else None
    if not isinstance(c, dict) or not c.get("client_id") or not c.get("client_secret"):
        raise Fail("OAuth 클라이언트 파일이 '데스크톱 앱' 형식이 아닙니다." + (" 데스크톱 앱 클라이언트를 만들어 받으세요." if own else ""), 2)
    return c["client_id"], c["client_secret"]


def write_private(path, data):
    folder = os.path.dirname(path)
    os.makedirs(folder, mode=0o700, exist_ok=True)
    os.chmod(folder, 0o700)
    tmp = f"{path}.tmp.{os.getpid()}"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(data, f)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def post_form(url, fields):
    req = Request(url, data=urlencode(fields).encode(), headers={"Content-Type": "application/x-www-form-urlencoded"})
    with urlopen(req, timeout=HTTP_TIMEOUT) as r:
        return json.loads(r.read().decode() or "{}")


def make_token(resp, old=None):
    if not isinstance(resp, dict) or not resp.get("access_token"):
        raise Fail("구글이 토큰을 주지 않았습니다. 다시 연결하세요.")
    return {
        "access_token": resp["access_token"],
        "refresh_token": resp.get("refresh_token") or (old or {}).get("refresh_token"),
        "expires_at": int(time.time()) + int(resp.get("expires_in") or 3600),
        "token_type": resp.get("token_type") or "Bearer",
        "scope": resp.get("scope") or SCOPE,
    }


def write_if_present(path, data):
    """이미 있는 토큰 파일만 고쳐 쓴다 — 수집 중에 그 계정을 끊었으면 되살리지 않는다."""
    if os.path.exists(path):
        write_private(path, data)


def read_token(path):
    try:
        with open(path, encoding="utf-8") as f:
            tok = json.load(f)
    except (OSError, ValueError):
        return None
    return tok if isinstance(tok, dict) else None


def list_accounts():
    """연결한 계정 [(id, 토큰 파일)]. 계정 파일은 주소 순, 예전 단일 토큰은 맨 뒤."""
    out = []
    try:
        names = sorted(os.listdir(accounts_dir()))
    except OSError:
        names = []
    for name in names:
        account = name[:-5] if name.endswith(".json") else ""
        if ACCOUNT_RE.match(account):
            out.append((account, account_path(account)))
    if os.path.exists(legacy_path()):
        out.append((LEGACY, legacy_path()))
    return out


# ---- connect ----
def pkce_pair():
    verifier = secrets.token_urlsafe(64)
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).decode().rstrip("=")
    return verifier, challenge


def connect():
    client_id, client_secret = load_client()
    verifier, challenge = pkce_pair()
    state = secrets.token_urlsafe(24)
    got = {}

    class Loopback(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            q = parse_qs(urlparse(self.path).query)
            if "code" not in q and "error" not in q:  # 파비콘 같은 다른 요청은 무시하고 계속 기다린다
                self.send_response(404)
                self.end_headers()
                return
            got.update({k: v[0] for k, v in q.items()})
            ok = "code" in q and secrets.compare_digest(q.get("state", [""])[0], state)
            body = ("구글 캘린더를 연결했습니다. 이 창을 닫고 보드로 돌아가세요." if ok else
                    "연결하지 못했습니다. 보드에서 다시 [연결]을 누르세요.").encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    srv = HTTPServer(("127.0.0.1", 0), Loopback)
    redirect = f"http://127.0.0.1:{srv.server_address[1]}"
    url = AUTH_URL + "?" + urlencode({
        "client_id": client_id, "redirect_uri": redirect, "response_type": "code", "scope": SCOPE,
        "code_challenge": challenge, "code_challenge_method": "S256", "state": state,
        # 계정을 더할 때 이미 로그인한 계정으로 바로 넘어가지 않게 계정 고르기를 띄운다.
        "access_type": "offline", "prompt": "select_account consent",
    })
    if os.environ.get("BOARD_NO_BROWSER") == "1":
        print(url, file=sys.stderr, flush=True)
    else:
        threading.Thread(target=webbrowser.open, args=(url,), daemon=True).start()
    deadline = time.time() + CONSENT_WAIT
    try:
        while not got and time.time() < deadline:
            srv.timeout = max(0.1, min(1.0, deadline - time.time()))
            srv.handle_request()
    finally:
        srv.server_close()
    if not got:
        raise Fail("브라우저에서 허용을 마치지 않아 연결하지 못했습니다. 다시 [연결]을 누르세요.")
    if got.get("error"):
        raise Fail("구글에서 허용하지 않아 연결하지 못했습니다.")
    if not secrets.compare_digest(got.get("state", ""), state):
        raise Fail("응답의 확인 값(state)이 맞지 않아 연결을 거부했습니다. 다시 [연결]을 누르세요.")
    try:
        resp = post_form(TOKEN_URL, {"code": got["code"], "client_id": client_id, "client_secret": client_secret,
                                     "redirect_uri": redirect, "grant_type": "authorization_code", "code_verifier": verifier})
    except HTTPError as e:
        raise Fail(f"구글이 토큰 발급을 거절했습니다(HTTP {e.code}). 다시 [연결]을 누르세요.")
    except (URLError, OSError, ValueError) as e:
        raise Fail(f"구글에 닿지 못해 연결하지 못했습니다({getattr(e, 'reason', e)}).")
    api = Api(make_token(resp))
    write_private(account_path(api.primary()), api.tok)


# ---- fetch ----
def refresh(tok):
    if not tok.get("refresh_token"):
        raise Fail(RECONNECT, 3)
    client_id, client_secret = load_client()
    try:
        resp = post_form(TOKEN_URL, {"grant_type": "refresh_token", "refresh_token": tok["refresh_token"],
                                     "client_id": client_id, "client_secret": client_secret})
    except HTTPError:
        raise Fail(RECONNECT, 3)
    except (URLError, OSError, ValueError) as e:
        raise Fail(f"구글에 닿지 못했습니다({getattr(e, 'reason', e)}). 네트워크를 확인하세요.")
    return make_token(resp, tok)


class Api:
    """토큰 하나로 부르는 캘린더 API. path가 있으면 갱신한 토큰을 그 파일에 다시 쓴다."""

    def __init__(self, tok, path=None):
        if not isinstance(tok, dict) or not tok.get("access_token"):
            raise Fail(RECONNECT, 3)
        self.tok, self.path = {k: v for k, v in tok.items() if k != "error"}, path
        if int(self.tok.get("expires_at") or 0) <= time.time() + 60:
            self._refresh()

    def _refresh(self):
        self.tok = refresh(self.tok)
        if self.path:
            write_if_present(self.path, self.tok)

    def get(self, path, params, retried=False):
        url = API_BASE + path + "?" + urlencode(params)
        req = Request(url, headers={"Authorization": "Bearer " + self.tok["access_token"]})
        try:
            with urlopen(req, timeout=HTTP_TIMEOUT) as r:
                return json.loads(r.read().decode() or "{}")
        except HTTPError as e:
            if e.code == 401 and not retried:
                self._refresh()
                return self.get(path, params, retried=True)
            if e.code in (401, 403):
                raise Fail(RECONNECT, 3)
            raise Fail(f"구글 캘린더가 요청을 거절했습니다(HTTP {e.code}).")
        except (URLError, OSError, ValueError) as e:
            raise Fail(f"구글 캘린더에 닿지 못했습니다({getattr(e, 'reason', e)}). 네트워크를 확인하세요.")

    def pages(self, path, params, limit=10):
        token = None
        for _ in range(limit):
            d = self.get(path, dict(params, **({"pageToken": token} if token else {})))
            yield from d.get("items") or []
            token = d.get("nextPageToken")
            if not token:
                return

    def primary(self):
        """로그인한 계정 = 기본 캘린더의 주소(calendar.readonly 안에서 알 수 있는 계정 식별자)."""
        for cal in self.pages("/users/me/calendarList", {"minAccessRole": "owner"}):
            if cal.get("primary") and isinstance(cal.get("id"), str) and ACCOUNT_RE.match(cal["id"]):
                return cal["id"]
        raise Fail("구글 계정의 기본 캘린더를 찾지 못해 연결하지 못했습니다. 다시 연결하세요.")


def _when(v):
    if not isinstance(v, dict):
        return None
    return v.get("dateTime") or v.get("date")


def _migrate_legacy(api):
    """예전 단일 토큰을 계정 주소 파일로 옮긴다. 같은 계정 파일이 이미 있으면 예전 것만 지운다."""
    account = api.primary()
    target = account_path(account)
    if not os.path.exists(target):
        write_private(target, api.tok)
    os.remove(legacy_path())
    api.path = target


def fetch(args):
    since = until = None
    i = 0
    while i < len(args):
        if args[i] in ("--since", "--until") and i + 1 < len(args):
            if args[i] == "--since":
                since = args[i + 1]
            else:
                until = args[i + 1]
            i += 2
        else:
            i += 1
    if not since or not until:
        start = datetime.now().astimezone().replace(hour=0, minute=0, second=0, microsecond=0)
        since, until = since or start.isoformat(), until or (start + timedelta(days=7)).isoformat()
    accounts = list_accounts()
    if not accounts:
        raise Fail("구글 캘린더에 연결돼 있지 않습니다. 내 일정의 '연결한 곳'에서 연결하세요.", 3)
    out, seen, failures, ok = [], set(), [], 0
    for account, path in accounts:
        tok = read_token(path)
        api = None
        try:
            api = Api(tok, path)
            if account == LEGACY:
                _migrate_legacy(api)
            rows = []
            for cal in api.pages("/users/me/calendarList", {"minAccessRole": "reader"}):
                if not cal.get("selected") or not cal.get("id"):
                    continue
                cid = cal["id"]
                for ev in api.pages(f"/calendars/{quote(cid, safe='')}/events",
                                    {"timeMin": since, "timeMax": until, "singleEvents": "true", "orderBy": "startTime",
                                     "maxResults": "250"}):
                    if ev.get("status") == "cancelled" or not ev.get("id"):
                        continue
                    item = {"id": f"{cid}:{ev['id']}", "kind": "event", "title": ev.get("summary") or "(제목 없음)",
                            "start": _when(ev.get("start")), "end": _when(ev.get("end")),
                            "detail": cal.get("summaryOverride") or cal.get("summary") or ""}
                    if isinstance(ev.get("htmlLink"), str):
                        item["url"] = ev["htmlLink"]
                    rows.append(item)
        except Fail as e:
            failures.append(e)
            # 계정 목록이 그 계정의 실패를 보이게 남긴다. 이번에 갱신·이전한 토큰이 있으면 그것을 기준으로.
            where, base = (api.path, api.tok) if api and api.path else (path, tok)
            if base:
                write_if_present(where, dict(base, error=str(e)))
            continue
        ok += 1
        if api.path and (read_token(api.path) or {}).get("error"):
            write_if_present(api.path, api.tok)
        for item in rows:
            if item["id"] in seen:
                continue
            seen.add(item["id"])
            out.append(json.dumps({k: v for k, v in item.items() if v}, ensure_ascii=False))
    if not ok:
        raise failures[0]
    if out:
        sys.stdout.write("\n".join(out) + "\n")


def accounts():
    for account, path in list_accounts():
        row = {"id": account, "name": "구글 계정" if account == LEGACY else account}
        err = (read_token(path) or {}).get("error")
        if isinstance(err, str) and err:
            row["error"] = err
        print(json.dumps(row, ensure_ascii=False, separators=(",", ":")))


# ---- disconnect ----
def disconnect(args):
    known = list_accounts()
    if args:
        want = args[0]
        known = [(a, p) for a, p in known if a == want]
        if not known:
            raise Fail("연결된 구글 계정이 아닙니다.", 2)
    for _account, path in known:
        tok = read_token(path)
        try:
            os.remove(path)
        except OSError:
            pass
        value = isinstance(tok, dict) and (tok.get("refresh_token") or tok.get("access_token"))
        if value:
            try:  # 구글 쪽 권한 철회는 최선 노력 — 네트워크가 없어도 끊기는 성공한다
                post_form(REVOKE_URL, {"token": value})
            except Exception:
                pass


def main(argv):
    cmd = argv[1] if len(argv) > 1 else ""
    try:
        if cmd == "connect":
            connect()
        elif cmd == "fetch":
            fetch(argv[2:])
        elif cmd == "accounts":
            accounts()
        elif cmd == "disconnect":
            disconnect(argv[2:])
        else:
            print("usage: google_calendar.py connect|fetch [--since ISO --until ISO]|accounts|disconnect [account]", file=sys.stderr)
            return 2
    except Fail as e:
        print(str(e), file=sys.stderr)
        return e.code
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
