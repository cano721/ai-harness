#!/usr/bin/env python3
"""테스트용 가짜 구글 OAuth·캘린더 서버. 실제 구글은 부르지 않는다.

usage: fake-google.py <state-dir> <port>
  GET  /auth          동의 화면 대신: 받은 질의를 auth.json에 적고 code+state로 redirect_uri에 돌려보낸다
  POST /token         authorization_code는 sha256(code_verifier)==code_challenge일 때만 토큰을 준다(PKCE 확인).
                      refresh_token은 <state>/refresh-fail이 있으면 400. 부를 때마다 token-calls에 grant_type을 적는다
  GET  /calendar/v3/users/me/calendarList   선택한 캘린더 1개, 선택하지 않은 캘린더 1개
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
            CHALLENGES[code] = q.get("code_challenge")
            self.send_response(302)
            self.send_header("Location", q["redirect_uri"] + "/?" + urlencode({"code": code, "state": q.get("state", "")}))
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if not (self.headers.get("Authorization") or "").startswith("Bearer fake-access-"):
            return self._json(401, {"error": "unauthorized"})
        if u.path == "/calendar/v3/users/me/calendarList":
            return self._json(200, {"items": [{"id": "team@example.com", "summary": "팀 캘린더", "selected": True},
                                              {"id": "other@example.com", "summary": "숨긴 캘린더"}]})
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
            want = CHALLENGES.get(f.get("code"))
            got = base64.urlsafe_b64encode(hashlib.sha256(f.get("code_verifier", "").encode()).digest()).decode().rstrip("=")
            if not want or got != want or not f.get("client_secret"):
                append("token-calls", "pkce-mismatch")
                return self._json(400, {"error": "invalid_grant"})
            append("token-calls", "pkce-ok")
            return self._json(200, {"access_token": "fake-access-SECRET-1", "refresh_token": "fake-refresh-SECRET-1",
                                    "expires_in": 3600, "token_type": "Bearer"})
        if f.get("grant_type") == "refresh_token":
            if os.path.exists(os.path.join(STATE, "refresh-fail")):
                return self._json(400, {"error": "invalid_grant"})
            return self._json(200, {"access_token": "fake-access-SECRET-2", "expires_in": 3600, "token_type": "Bearer"})
        self._json(400, {"error": "unsupported_grant_type"})


HTTPServer(("127.0.0.1", PORT), H).serve_forever()
