#!/usr/bin/env python3
"""구글 캘린더 기본 어댑터(표준 라이브러리만) — 보드 '내 일정'의 agenda.json 계약을 따른다(#492).

  connect     데스크톱 OAuth(루프백 + PKCE S256). 동의 URL을 브라우저로 열고 127.0.0.1 빈 포트에서 한 번만 받는다.
  fetch       selected 캘린더의 일정(--since ~ --until, 기본 오늘 0시부터 7일)을 kind:event JSONL로 낸다.
  disconnect  로컬 토큰을 지우고 revoke를 최선 노력으로 한 번 부른다.

OAuth 클라이언트는 사용자가 직접 만든 것($HM_DATA_DIR/google-oauth-client.json, 구글이 내려주는 installed 형식)만 쓴다.
저장소에는 client id·secret이 없고 중개 서버도 없다. 토큰은 $HM_DATA_DIR/board/agenda/google-token.json(600)에 둔다.
scope는 calendar.readonly 하나다. 토큰·client secret은 stdout·stderr에 쓰지 않는다.
"""
import base64, hashlib, json, os, secrets, sys, threading, time, webbrowser
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
RECONNECT = "구글 연결이 만료됐거나 해제됐습니다. 내 일정의 '연결한 곳'에서 끊은 뒤 다시 연결하세요."


class Fail(Exception):
    def __init__(self, message, code=1):
        super().__init__(message)
        self.code = code


def data_dir():
    return os.environ.get("HM_DATA_DIR") or os.environ.get("HARNESS_METRICS_DIR") or os.path.expanduser("~/.ai-harness")


def client_path():
    return os.path.join(data_dir(), "google-oauth-client.json")


def token_path():
    return os.path.join(data_dir(), "board", "agenda", "google-token.json")


def load_client():
    try:
        with open(client_path(), encoding="utf-8") as f:
            d = json.load(f)
    except OSError:
        raise Fail("OAuth 클라이언트 파일이 없습니다. /ai-harness:setup의 구글 캘린더 안내대로 만들어 두세요.", 2)
    except ValueError:
        raise Fail("OAuth 클라이언트 파일이 올바른 JSON이 아닙니다. 구글 클라우드에서 받은 파일을 그대로 두세요.", 2)
    c = d.get("installed") if isinstance(d, dict) else None
    if not isinstance(c, dict) or not c.get("client_id") or not c.get("client_secret"):
        raise Fail("OAuth 클라이언트 파일이 '데스크톱 앱' 형식이 아닙니다. 데스크톱 앱 클라이언트를 만들어 받으세요.", 2)
    return c["client_id"], c["client_secret"]


def write_private(path, data):
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
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


def save_token(resp, old=None):
    if not isinstance(resp, dict) or not resp.get("access_token"):
        raise Fail("구글이 토큰을 주지 않았습니다. 다시 연결하세요.")
    tok = {
        "access_token": resp["access_token"],
        "refresh_token": resp.get("refresh_token") or (old or {}).get("refresh_token"),
        "expires_at": int(time.time()) + int(resp.get("expires_in") or 3600),
        "token_type": resp.get("token_type") or "Bearer",
        "scope": resp.get("scope") or SCOPE,
    }
    write_private(token_path(), tok)
    return tok


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
        "access_type": "offline", "prompt": "consent",
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
    save_token(resp)


# ---- fetch ----
def load_token():
    try:
        with open(token_path(), encoding="utf-8") as f:
            tok = json.load(f)
    except (OSError, ValueError):
        raise Fail("구글 캘린더에 연결돼 있지 않습니다. 내 일정의 '연결한 곳'에서 연결하세요.", 3)
    if not isinstance(tok, dict) or not tok.get("access_token"):
        raise Fail(RECONNECT, 3)
    return tok


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
    return save_token(resp, tok)


class Api:
    def __init__(self):
        self.tok = load_token()
        if int(self.tok.get("expires_at") or 0) <= time.time() + 60:
            self.tok = refresh(self.tok)

    def get(self, path, params, retried=False):
        url = API_BASE + path + "?" + urlencode(params)
        req = Request(url, headers={"Authorization": "Bearer " + self.tok["access_token"]})
        try:
            with urlopen(req, timeout=HTTP_TIMEOUT) as r:
                return json.loads(r.read().decode() or "{}")
        except HTTPError as e:
            if e.code == 401 and not retried:
                self.tok = refresh(self.tok)
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


def _when(v):
    if not isinstance(v, dict):
        return None
    return v.get("dateTime") or v.get("date")


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
    api = Api()
    out = []
    for cal in api.pages("/users/me/calendarList", {"minAccessRole": "reader"}):
        if not cal.get("selected") or not cal.get("id"):
            continue
        cid = cal["id"]
        for ev in api.pages(f"/calendars/{quote(cid, safe='')}/events",
                            {"timeMin": since, "timeMax": until, "singleEvents": "true", "orderBy": "startTime", "maxResults": "250"}):
            if ev.get("status") == "cancelled" or not ev.get("id"):
                continue
            item = {"id": f"{cid}:{ev['id']}", "kind": "event", "title": ev.get("summary") or "(제목 없음)",
                    "start": _when(ev.get("start")), "end": _when(ev.get("end")),
                    "detail": cal.get("summaryOverride") or cal.get("summary") or ""}
            if isinstance(ev.get("htmlLink"), str):
                item["url"] = ev["htmlLink"]
            out.append(json.dumps({k: v for k, v in item.items() if v}, ensure_ascii=False))
    if out:
        sys.stdout.write("\n".join(out) + "\n")


# ---- disconnect ----
def disconnect():
    try:
        with open(token_path(), encoding="utf-8") as f:
            tok = json.load(f)
    except (OSError, ValueError):
        tok = None
    try:
        os.remove(token_path())
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
        elif cmd == "disconnect":
            disconnect()
        else:
            print("usage: google_calendar.py connect|fetch [--since ISO --until ISO]|disconnect", file=sys.stderr)
            return 2
    except Fail as e:
        print(str(e), file=sys.stderr)
        return e.code
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
