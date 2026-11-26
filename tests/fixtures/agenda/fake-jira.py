#!/usr/bin/env python3
"""테스트용 가짜 Jira Cloud 서버(#648). 실제 Jira는 부르지 않는다.

usage: fake-jira.py <state-dir> <port>
  상태 폴더의 파일(요청마다 다시 읽는다):
    issues.json     search/jql이 돌려줄 이슈 배열(Jira 응답의 issues[] 모양 {key, fields}). 없으면 빈 배열
    projects.json   project/search가 돌려줄 프로젝트 배열 [{key, name}]. 없으면 ACME·OPS 두 개
    page_size       한 페이지 최대 개수(없으면 50). 요청 maxResults와 작은 쪽을 쓴다
    status          있으면 그 HTTP 코드로 모든 요청에 실패한다
    expected-auth   Authorization 헤더 기대값. 요청마다 일치 여부를 requests.log에 적는다
  requests.log      요청마다 JSON 한 줄 {method, path, query(디코드한 값), auth_ok}
  GET /rest/api/3/search/jql       nextPageToken(시작 위치)으로 페이지를 나누고 isLast·nextPageToken을 돌려준다
  GET /rest/api/3/project/search   startAt·maxResults로 나눈 values·isLast
  그 밖의 메서드는 적기만 하고 405 — 어댑터가 쓰기 요청을 하지 않는지 본다.
"""
import json, os, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlparse

STATE = sys.argv[1]
PORT = int(sys.argv[2])
os.makedirs(STATE, exist_ok=True)
DEFAULT_PROJECTS = [{"key": "ACME", "name": "Acme 프로젝트"}, {"key": "OPS", "name": "운영"}]


def read(name, default):
    try:
        with open(os.path.join(STATE, name), encoding="utf-8") as f:
            text = f.read()
    except OSError:
        return default
    try:
        return json.loads(text)
    except ValueError:
        return text.strip() or default


class H(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def _json(self, code, body):
        data = json.dumps(body, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _record(self):
        u = urlparse(self.path)
        q = {k: v[0] for k, v in parse_qs(u.query).items()}
        expected = read("expected-auth", None)
        row = {"method": self.command, "path": u.path, "query": q,
               "auth_ok": expected is not None and self.headers.get("Authorization") == str(expected)}
        with open(os.path.join(STATE, "requests.log"), "a", encoding="utf-8") as f:
            f.write(json.dumps(row, ensure_ascii=False) + "\n")
        return u, q

    def do_GET(self):
        u, q = self._record()
        if u.path == "/":
            return self._json(200, {"ok": True})
        status = read("status", None)
        if status:
            return self._json(int(status), {"errorMessages": ["forced"]})
        size = int(read("page_size", 50))
        want = min(size, int(q.get("maxResults") or size))
        if u.path == "/rest/api/3/search/jql":
            issues = read("issues.json", [])
            start = int(q.get("nextPageToken") or 0)
            page = issues[start:start + want]
            end = start + len(page)
            body = {"issues": page, "isLast": end >= len(issues)}
            if end < len(issues):
                body["nextPageToken"] = str(end)
            return self._json(200, body)
        if u.path == "/rest/api/3/project/search":
            projects = read("projects.json", DEFAULT_PROJECTS)
            start = int(q.get("startAt") or 0)
            page = projects[start:start + want]
            return self._json(200, {"values": page, "startAt": start, "maxResults": want, "total": len(projects),
                                    "isLast": start + len(page) >= len(projects)})
        return self._json(404, {"errorMessages": ["not found"]})

    def _write(self):
        self._record()
        self._json(405, {"errorMessages": ["read-only fake"]})

    do_POST = do_PUT = do_DELETE = _write


HTTPServer(("127.0.0.1", PORT), H).serve_forever()
