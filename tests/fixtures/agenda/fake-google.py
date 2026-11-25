#!/usr/bin/env python3
"""테스트용 가짜 구글 OAuth·캘린더 서버. 실제 구글은 부르지 않는다.

usage: fake-google.py <state-dir> <port>
  GET  /auth          동의 화면 대신: 받은 질의를 auth.json에 적고 code+state로 redirect_uri에 돌려보낸다.
                      로그인하는 계정은 <state>/next-account(없으면 me@example.com)다
  POST /token         authorization_code는 sha256(code_verifier)==code_challenge일 때만 토큰을 준다(PKCE 확인).
                      me@example.com은 fake-access-SECRET-1, 그 밖의 계정은 fake-access-SECRET-<로컬파트>-1을 준다.
                      refresh_token은 <state>/refresh-fail(모든 계정) 또는 refresh-fail-<계정>이 있으면 400.
                      부를 때마다 token-calls에 grant_type을 적는다
  GET  /calendar/v3/users/me/calendarList   계정마다: 공유 팀 캘린더(선택)·숨긴 캘린더, 그 계정의 기본 캘린더(primary).
                      me@example.com의 기본 캘린더는 선택하지 않았고, 다른 계정은 선택했다
  GET  /calendar/v3/calendars/<id>/events   캘린더마다 일정 1건(Bearer fake-access-*가 아니면 401)
  POST /revoke        revoke-calls에 적는다
"""
import base64, hashlib, json, os, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, unquote, urlencode, urlparse

STATE = sys.argv[1]
PORT = int(sys.argv[2])
os.makedirs(STATE, exist_ok=True)
CHALLENGES = {}
DEFAULT = "me@example.com"


def local(account):
    return account.split("@", 1)[0]


def account_of(token):
    """fake-access-SECRET-1 / fake-access-SECRET-work-1 → 계정."""
    rest = token.split("SECRET-", 1)[1] if "SECRET-" in token else ""
    name = rest.rsplit("-", 1)[0] if "-" in rest else ""
    return name + "@example.com" if name else DEFAULT


def tokens(account, n):
    tag = "" if account == DEFAULT else local(account) + "-"
    return "fake-access-SECRET-%s%d" % (tag, n), "fake-refresh-SECRET-%s1" % tag


def append(name, line):
    with open(os.path.join(STATE, name), "a", encoding="utf-8") as f:
        f.write(line + "\n")


class H(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def _json(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _form(self):
        n = int(self.headers.get("Content-Length") or 0)
        return {k: v[0] for k, v in parse_qs(self.rfile.read(n).decode()).items()}

    def do_GET(self):
        u = urlparse(self.path)
        q = {k: v[0] for k, v in parse_qs(u.query).items()}
        if u.path == "/auth":
            with open(os.path.join(STATE, "auth.json"), "w", encoding="utf-8") as f:
                json.dump(q, f)
            code = "code-%d" % (len(CHALLENGES) + 1)
            try:
                with open(os.path.join(STATE, "next-account"), encoding="utf-8") as f:
                    who = f.read().strip() or DEFAULT
            except OSError:
                who = DEFAULT
            CHALLENGES[code] = (q.get("code_challenge"), who)
            self.send_response(302)
            self.send_header("Location", q["redirect_uri"] + "/?" + urlencode({"code": code, "state": q.get("state", "")}))
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        auth = self.headers.get("Authorization") or ""
        if not auth.startswith("Bearer fake-access-"):
            return self._json(401, {"error": "unauthorized"})
        who = account_of(auth[len("Bearer "):])
        if u.path == "/calendar/v3/users/me/calendarList":
            return self._json(200, {"items": [{"id": "team@example.com", "summary": "팀 캘린더", "selected": True},
                                              {"id": "other@example.com", "summary": "숨긴 캘린더"},
                                              {"id": who, "summary": local(who), "primary": True,
                                               "selected": who != DEFAULT}]})
        if u.path.startswith("/calendar/v3/calendars/") and u.path.endswith("/events"):
            cid = unquote(u.path[len("/calendar/v3/calendars/"):-len("/events")])
            append("events-calls", json.dumps({"calendar": cid, **q}))
            return self._json(200, {"items": [
                {"id": "ev1", "summary": "주간 회의", "status": "confirmed", "htmlLink": "https://calendar.example.com/ev1",
                 "start": {"dateTime": q.get("timeMin")}, "end": {"dateTime": q.get("timeMin")}},
                {"id": "ev2", "summary": "취소된 회의", "status": "cancelled", "start": {"date": "2026-01-01"}}]})
        self._json(404, {"error": "not_found"})

    def do_POST(self):
        u = urlparse(self.path)
        f = self._form()
        if u.path == "/revoke":
            append("revoke-calls", "revoke")
            return self._json(200, {})
        if u.path != "/token":
            return self._json(404, {"error": "not_found"})
        append("token-calls", f.get("grant_type", ""))
        if f.get("grant_type") == "authorization_code":
            want, who = CHALLENGES.get(f.get("code")) or (None, DEFAULT)
            got = base64.urlsafe_b64encode(hashlib.sha256(f.get("code_verifier", "").encode()).digest()).decode().rstrip("=")
            if not want or got != want or not f.get("client_secret"):
                append("token-calls", "pkce-mismatch")
                return self._json(400, {"error": "invalid_grant"})
            append("token-calls", "pkce-ok client=" + f.get("client_id", ""))
            access, refresh = tokens(who, 1)
            return self._json(200, {"access_token": access, "refresh_token": refresh, "expires_in": 3600, "token_type": "Bearer"})
        if f.get("grant_type") == "refresh_token":
            who = account_of(f.get("refresh_token", "").replace("refresh", "access"))
            if os.path.exists(os.path.join(STATE, "refresh-fail")) or os.path.exists(os.path.join(STATE, "refresh-fail-" + who)):
                return self._json(400, {"error": "invalid_grant"})
            return self._json(200, {"access_token": tokens(who, 2)[0], "expires_in": 3600, "token_type": "Bearer"})
        self._json(400, {"error": "unsupported_grant_type"})


HTTPServer(("127.0.0.1", PORT), H).serve_forever()
