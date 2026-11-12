#!/usr/bin/env python3
"""보드 화면 미리보기 서버 — 가짜 데이터만 쓴다(디자인 검토·스크린샷용). 실제 보드 서버(scripts/board/board-server.py)와 같은
경로·응답 모양을 흉내 내고, 쓰기 요청은 아무것도 바꾸지 않고 성공만 돌려준다.

    python3 -I tests/fixtures/board-preview/serve.py [--port 8765]
    → http://127.0.0.1:8765/?t=demo            기본(할 일·진행·대기·결과가 다 있는 상태)
      ?t=empty   할 일·작업이 하나도 없음      ?t=slow   첫 응답이 3초 늦음(로딩 뼈대)
      ?t=error   상태를 읽지 못함(오류)        &theme=light|dark  테마 고정

데이터는 전부 지어낸 예시다(acme/* 저장소, 가짜 에러). 실제 사용자 데이터를 여기에 넣지 않는다.
"""
import json, os, sys, time
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."))
TEMPLATE = os.path.join(ROOT, "scripts", "board", "template.html")


def ago(minutes):
    return (datetime.now(timezone.utc) - timedelta(minutes=minutes)).strftime("%Y-%m-%dT%H:%M:%SZ")


def status(scenario):
    items = []
    if scenario != "empty":
        items = [
            # 지금 할 일: 권한 요청 · 답 대기 · 자동 수정 사람 판단 · PR 검토
            {"id": "w1", "section": "work", "kind": "agent", "project": "shop", "state": "needs_human", "status": "waiting", "live": True,
             "at": ago(2), "title": "배송비 계산을 지역별 요금표로 바꾸기", "actions": ["view"],
             "detail": "요청: 배송비를 지역별 요금표에서 읽게 바꿔줘\n— 스테이징 배포 스크립트를 실행하려고 합니다.",
             "permission": {"pid": "p1", "tool": "Bash", "input": "scripts/deploy.sh --env staging"}, "cwd": "/work/acme/shop"},
            {"id": "w2", "section": "work", "kind": "bg", "project": "billing-api", "state": "needs_human", "status": "waiting", "live": True,
             "at": ago(9), "title": "환불 금액 반올림 규칙 정하기", "actions": ["view", "send"],
             "detail": "요청: 부분 환불 금액이 1원씩 어긋나는 문제 확인\n— 반올림을 **은행가 방식**으로 할지 사사오입으로 할지 정해 주세요.", "cwd": "/work/acme/billing-api"},
            {"id": "af1", "section": "autofix", "kind": "autofix", "project": "shop", "state": "needs_human", "status": "skipped",
             "outcome": "left_for_user", "at": ago(35), "signature": "datadog:5b1c0d2e9f8a7b6c",
             "title": "2026-11-10 09:14:15.264 ERROR trace_id:4af2c9e1b7d84a0f9c3e span_id:2694346509131183652 - CartController:88: 장바구니 합계 계산에 실패했습니다. cartSn: 1042",
             "detail": "할인 쿠폰이 두 개 겹치면 합계가 음수가 됩니다. 쿠폰 정책을 먼저 정해야 해서 무인 실행은 고치지 않고 넘겼습니다.",
             "stage": "skipped", "stage_label": "건너뜀 · 사람 판단 필요", "count": 41, "attempts": 1, "regressions": 0,
             "monitor_link": "https://example.com/monitor/5b1c", "log_name": "20261110T091500Z-shop.log", "repo": "/work/acme/shop",
             "actions": ["open_agent"], "session_id": "w5"},
            {"id": "af2", "section": "autofix", "kind": "autofix", "project": "billing-api", "state": "needs_human", "status": "pr_open",
             "at": ago(55), "signature": "sentry:4410293", "title": "TimeoutError: upstream did not respond within 30000ms",
             "detail": "결제 승인 호출에 재시도와 타임아웃을 넣었습니다. 재현 테스트가 들어 있습니다.",
             "stage": "pr", "stage_label": "PR 검토 대기", "count": 12, "attempts": 1, "regressions": 0,
             "link": "https://example.com/acme/billing-api/pull/132", "monitor_link": "https://example.com/monitor/4410293",
             "repo": "/work/acme/billing-api", "actions": ["open_agent"]},
            {"id": "h1", "section": "harness", "kind": "harvest", "project": "docs", "state": "needs_human", "at": ago(120),
             "title": "개선 — draft PR 검토", "detail": "설치 안내에서 자주 틀리던 경로 규칙 2개를 AGENTS.md에 더했습니다.",
             "link": "https://example.com/acme/docs/pull/77", "actions": ["open_agent"], "repo": "/work/acme/docs"},
            # 진행 중
            {"id": "w3", "section": "work", "kind": "bg", "project": "search", "state": "running", "status": "busy", "live": True,
             "at": ago(1), "title": "검색어 자동완성 지연 줄이기", "actions": ["view"],
             "detail": "요청: 자동완성 응답을 200ms 안으로\n— 캐시 키를 바꾸고 테스트 12개 중 9개 통과. 남은 3개를 고치는 중입니다.",
             "subagents": {"total": 3, "active": 1}, "cwd": "/work/acme/search"},
            {"id": "af3", "section": "autofix", "kind": "autofix", "project": "shop", "state": "running", "status": "verifying",
             "at": ago(240), "signature": "sentry:4410001", "title": "로그인 직후 프로필 사진이 안 보임",
             "stage": "observing", "stage_label": "배포됨 · 재발 관찰 중", "count": 7, "attempts": 1, "regressions": 0,
             "verify_until": ago(-1440), "link": "https://example.com/acme/shop/pull/129", "repo": "/work/acme/shop", "actions": []},
            {"id": "h2", "section": "harness", "kind": "sync", "project": "shop", "state": "running", "at": ago(4), "title": "실행 중 (claude)", "actions": []},
            # 대기 · 막힘
            *[{"id": f"q{i}", "section": "harness", "kind": "harvest", "project": p, "state": "queued", "at": ago(60 * i),
               "title": f"harvest 대기 (세션 {n}개)", "detail": "근거: sessions", "actions": ["harvest_now"]}
              for i, (p, n) in enumerate([("shop", 12), ("billing-api", 8), ("search", 5), ("docs", 3)], 1)],
            *[{"id": f"b{i}", "section": "harness", "kind": "schedule", "project": p, "state": "blocked", "at": ago(30 * i),
               "title": "지난 동기화 PR 상태를 확인할 수 없어 멈춤", "reason": "sync_pr_status_unknown", "detail": "최근 2일 2회 건너뜀", "actions": []}
              for i, p in enumerate(["shop", "billing-api", "search"], 1)],
            {"id": "b9", "section": "harness", "kind": "schedule", "project": "스케줄", "state": "blocked", "at": ago(15),
             "title": "정기 실행 LLM 단계 건너뜀", "detail": "열린 세션이 계속 활동 중이라 정기 실행의 LLM 단계(세션 정리·자동 개선·동기화)를 미뤘습니다.", "actions": []},
            # 읽지 않은 결과
            *[{"id": f"r{i}", "section": "work", "kind": "bg", "project": p, "state": "review", "status": "idle", "live": False,
               "at": ago(90 + 20 * i), "title": t, "actions": ["view", "send", "cleanup"],
               "detail": f"세션 종료됨\n— {d}", "refs": {"prs": [f"https://example.com/acme/{p}/pull/{120 + i}"], "issues": []}}
              for i, (p, t, d) in enumerate([("shop", "주문 목록 정렬 고치기", "정렬 기준을 주문일 내림차순으로 고쳤습니다."),
                                             ("docs", "API 문서 예제 갱신", "예제 6개를 새 응답 형식으로 바꿨습니다."),
                                             ("search", "색인 재구축 스크립트 정리", "중복 단계를 지웠습니다.")], 1)],
            # 쉬는 중 · 완료
            {"id": "w5", "section": "work", "kind": "bg", "project": "shop", "state": "idle", "status": "idle", "live": True, "at": ago(30),
             "title": "shop 장바구니 합계 계산에 실패했습니다", "actions": ["view", "send"], "autofix_id": "af1",
             "detail": "요청: 자동 수정이 사람에게 넘긴 운영 에러를 이어서 본다.\n— 쿠폰 두 개가 겹칠 때 할인 순서를 정해야 합니다."},
            *[{"id": f"d{i}", "section": "harness", "kind": k, "project": p, "state": "done", "at": ago(600 * i),
               "title": t, "link": None, "actions": []}
              for i, (k, p, t) in enumerate([("sync", "docs", "PR 생성 (improved)"), ("harvest", "search", "변경 없음"),
                                             ("rule", "shop", "규칙 2개 적용"), ("sync", "billing-api", "변경 없음")], 1)],
            {"id": "af4", "section": "autofix", "kind": "autofix", "project": "search", "state": "done", "status": "resolved", "at": ago(2880),
             "signature": "sentry:4409000", "title": "검색어에 이모지를 넣으면 500 오류", "stage": "resolved", "stage_label": "해결",
             "count": 19, "attempts": 1, "regressions": 0, "link": "https://example.com/acme/search/pull/131", "actions": []},
        ]
    return {"generated_at": ago(0), "window_days": 7, "items": items, "jira_base": None}


REPOS = ["/work/acme/shop", "/work/acme/billing-api", "/work/acme/search", "/work/acme/docs"]


def settings():
    def repo(path, mine=None, level="pr", notes=None, protection=None, change=None):
        name = os.path.basename(path)
        eff = mine or None
        row = {"repo": path, "name": name, "key": name, "branch": "main", "level": level, "git_policy": "pr-only",
               "merge_policy": {"base": "main"}, "suggest": {"base": "main"}, "runner": "personal", "mine": mine,
               "effective": {"level": eff or "pr", "source": "repo" if mine else "default", "notes": notes or []}}
        if protection:
            row["protection"] = protection
        if change:
            row["change"] = change
        return row
    return {"ok": True, "config": "~/.ai-harness/config", "personal": {"HM_DELIVERY_LEVEL": "pr", "HM_HARVEST_AUTO": "1", "HM_SYNC_AUTO": "1",
            "HM_SYNC_AUTO_MERGE": "1", "HM_HARVEST_AUTO_DAILY_MAX": "5"},
            "repos": [repo(REPOS[0], mine="merge", protection={"approvals": 1, "checks": 2, "base": "main"}),
                      repo(REPOS[1], mine="deploy", notes=["저장소에 배포 확인·스모크 명령이 없어 병합까지만 함 — 아래에서 저장소 사실을 추가할 수 있음"],
                           protection={"approvals": 0, "checks": 1, "base": "main"}),
                      repo(REPOS[2]), repo(REPOS[3])]}


def impact():
    def series(vals):
        return [{"week": f"W{40 + i}", "value": v, "n": 0 if v is None else 4} for i, v in enumerate(vals)]
    good = {"name": "shop", "repo": REPOS[0], "project": "shop", "state": "done", "computed_at": ago(200), "cache_day": "2026-11-10",
            "installed": {"date": "2026-09-01"}, "window_days": 30, "matched_through": "2026-11-09",
            "assessment": {"status": {"key": "effective", "good": [{"by": "improvement", "n": 2}, {"by": "trend", "metric": "corrections_per_session"}], "bad": [], "gaps": []},
                           "trends": {"corrections_per_session": {"verdict": "down", "series": series([0.9, 0.8, None, 0.6, 0.5, 0.4]), "first": 0.85, "last": 0.45, "weeks": 5, "digested": 24},
                                      "missing_context_per_session": {"verdict": "flat", "series": series([0.3, 0.3, 0.2, 0.3, 0.3, 0.3]), "first": 0.3, "last": 0.3, "weeks": 6, "digested": 26}},
                           "metrics": {"corrections_per_session": {"comparable": False, "reason": "no_baseline_digests"},
                                       "missing_context_per_session": {"comparable": False, "reason": "no_baseline_digests"},
                                       "guard_blocks": {"after": 3}, "rework": {"comparable": False, "reason": "few_prs", "before_n": 4, "after_n": 6}}},
            "improvements": [
                {"date": "2026-10-02", "change": "add", "summary": "테스트를 고치기 전에 실패를 먼저 확인한다. 실패 확인 없이 고친 사례가 세 번 있었다.",
                 "expected": "고친 뒤에야 테스트가 틀렸다는 지적이 줄어든다", "artifact": "https://example.com/acme/shop/pull/101",
                 "result": {"verdict": "gone", "after_hits": 0, "observed": 14, "baseline": "batch", "before_hits": 3}, "before_observed": 9, "basis": "batch"},
                {"date": "2026-10-20", "change": "add", "summary": "마이그레이션 파일 이름은 날짜로 시작한다.",
                 "result": {"verdict": "reduced", "after_hits": 1, "observed": 11, "baseline": "window", "window_hits": 4}, "window_observed": 12},
                {"date": "2026-11-01", "change": "remove", "summary": "쓰이지 않던 배포 체크리스트 규칙을 지웠다.", "result": {"verdict": "hold"}, "observed_now": 3}]}
    bad = {"name": "billing-api", "repo": REPOS[1], "project": "billing-api", "state": "done", "computed_at": ago(300), "cache_day": "2026-11-10",
           "installed": {"date": "2026-09-15"}, "window_days": 30,
           "assessment": {"status": {"key": "attention", "good": [], "bad": [{"by": "improvement", "n": 1}], "gaps": []},
                          "trends": {"corrections_per_session": {"verdict": "insufficient", "series": [], "weeks": 2, "digested": 6}},
                          "metrics": {"corrections_per_session": {"comparable": False, "reason": "few_digests"},
                                      "guard_blocks": {"after": 0}, "rework": {"comparable": False, "reason": "no_rework"}}},
           "improvements": [{"date": "2026-10-11", "change": "add", "summary": "금액 계산은 정수(원)로만 한다.",
                             "result": {"verdict": "recurred", "after_hits": 3, "observed": 8, "baseline": "batch", "before_hits": 2}, "before_observed": 6, "basis": "batch"}]}
    poor = [{"name": n, "repo": r, "project": n, "state": "done", "computed_at": ago(400), "cache_day": "2026-11-10", "installed": {"date": "2026-10-20"},
             "window_days": 30, "assessment": {"status": {"key": k, "good": [], "bad": [], "gaps": [{"why": w}]}, "metrics": {}, "trends": {}}, "improvements": []}
            for n, r, k, w in [("search", REPOS[2], "insufficient", "few_recent_digests"), ("docs", REPOS[3], "no_sessions", "no_recent_sessions")]]
    return {"ok": True, "repos": [good, bad, *poor]}


def autofix():
    cands = {"at": ago(20), "error": None, "items": [
        {"signature": "datadog:9d8e7f6a5b4c3d2e", "provider": "datadog", "reason": "new", "count": 150, "culprit": "shop-api",
         "first_seen": ago(600), "last_seen": ago(3), "link": None, "meta": {"hash": "9d8e7f6a5b4c3d2e"},
         "title": "2026-11-10 10:59:41.802 ERROR trace_id:4af2c9e1b7d84a0f span_id:8142421225783121316 - OrderPreviewService:102: 주문 미리보기 첨부파일 복사에 실패했습니다. orderSn: 536"},
        {"signature": "datadog:1a2b3c4d5e6f7a8b", "provider": "datadog", "reason": "new", "count": 73, "culprit": "shop-api",
         "first_seen": ago(900), "last_seen": ago(40), "link": None, "meta": {"hash": "1a2b3c4d5e6f7a8b"},
         "title": "2026-11-10 08:42:50.538 ERROR trace_id:*** span_id:4895040075721877131 - RestControllerAdvice:203: \t오류 : StaleObjectStateException [Row was updated or deleted by another transaction]"},
        {"signature": "datadog:5b1c0d2e9f8a7b6c", "provider": "datadog", "reason": "new", "count": 41, "culprit": "shop-api",
         "first_seen": ago(2000), "last_seen": ago(50), "link": None, "meta": {"hash": "5b1c0d2e9f8a7b6c"},
         "title": "2026-11-10 09:14:15.264 ERROR trace_id:4af2c9e1b7d84a0f9c3e span_id:2694346509131183652 - CartController:88: 장바구니 합계 계산에 실패했습니다. cartSn: 1042"},
        {"signature": "datadog:0f0e0d0c0b0a0908", "provider": "datadog", "reason": "regressed", "count": 16, "culprit": "shop-worker",
         "first_seen": ago(5000), "last_seen": ago(70), "link": None, "meta": {"hash": "0f0e0d0c0b0a0908"},
         "title": "order_sync_failed"}]}
    detail = {"at": ago(5), "error": None, "detail": {"message": "주문 미리보기 첨부파일 복사에 실패했습니다. orderSn: <n>", "kind": "IllegalStateException",
              "service": "shop-api", "date": ago(3), "stack": "java.lang.IllegalStateException: copy failed\n  at acme.shop.order.OrderPreviewService.copy(OrderPreviewService.java)\n  at acme.shop.order.OrderPreviewController.preview(OrderPreviewController.java)"}}
    sig = lambda **k: {"project": "shop", "updated_at": ago(35), **k}
    repos = [
        {"repo": REPOS[0], "name": "shop", "project": "shop", "targeted": True, "check": {"at": ago(60), "code": 0, "label": "접근됨", "message": "ok datadog"},
         "ready": {"source": "local", "provider": "datadog", "summary": "service:shop-api env:prod", "credentials": "present", "code": 0},
         "signatures": [sig(signature="datadog:5b1c0d2e9f8a7b6c", status="skipped", stage="skipped", outcome="left_for_user"),
                        sig(signature="sentry:4410001", status="verifying", stage="observing", updated_at=ago(240))],
         "candidates": cands, "details": {"datadog:9d8e7f6a5b4c3d2e": detail}},
        {"repo": REPOS[1], "name": "billing-api", "project": "billing-api", "targeted": True, "check": None,
         "ready": {"source": "manifest", "provider": "sentry", "summary": "project billing-api", "credentials": "missing", "code": 4,
                   "problem": "Sentry 토큰이 없습니다. /ai-harness:setup에서 토큰을 저장하세요."},
         "signatures": [sig(project="billing-api", signature="sentry:4410293", status="pr_open", stage="pr", updated_at=ago(55))], "candidates": None, "details": {}},
        {"repo": REPOS[2], "name": "search", "project": "search", "targeted": False, "check": None,
         "ready": {"source": "local", "provider": "sentry", "summary": "project search", "credentials": "present", "code": 0}, "signatures": [], "candidates": None, "details": {}},
        {"repo": REPOS[3], "name": "docs", "project": "docs", "targeted": False, "check": None,
         "ready": {"source": "none", "provider": "", "summary": "", "credentials": "not_needed", "code": 5}, "signatures": [], "candidates": None, "details": {}},
    ]
    runs = [{"at": ago(35), "event": "finished", "project": "shop", "signature": "datadog:5b1c0d2e9f8a7b6c", "outcome": "left_for_user", "duration_s": 420, "cost_usd": 1.8},
            {"at": ago(80), "event": "skipped", "project": "shop", "reason": "daily_max"},
            {"at": ago(100), "event": "verify_error", "project": "search", "signature": "sentry:4409000"}]
    cfg = {"auto": True, "repos": ["shop", "billing-api"], "interval_minutes": 30, "daily_max": 3, "daily_unlimited": False,
           "max_attempts": 2, "budget_usd": 10}
    return {"ok": True, "config": cfg, "repos": repos, "runs": runs, "cost_usd": 12.4, "today": {"started": 1, "daily_max": 3}}


def transcript(item_id):
    msgs = [{"role": "user", "text": "배송비를 지역별 요금표에서 읽게 바꿔줘"},
            {"role": "assistant", "text": "## 확인한 것\n- 요금표는 `config/shipping.yml`에 있습니다.\n- 제주·도서 지역은 **추가 요금**이 붙습니다.\n\n```\nshipping:\n  jeju: 3000\n```\n스테이징에 올려 확인하겠습니다."},
            {"role": "tool", "text": "Bash: scripts/deploy.sh --env staging"}]
    return {"ok": True, "messages": msgs, "offset": 3, "start": 0, "reset": True,
            "question": [{"question": "반올림 방식을 고르세요", "options": [{"label": "은행가 방식", "description": "0.5는 짝수 쪽으로"}, {"label": "사사오입", "description": "0.5는 올림"}]}]
            if item_id == "w2" else None}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _json(self, code, body):
        raw = json.dumps(body, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        u = urlparse(self.path)
        q = {k: v[0] for k, v in parse_qs(u.query).items()}
        scenario = q.get("t", "demo")
        if u.path == "/":
            with open(TEMPLATE, encoding="utf-8") as f:
                html = f.read().replace("__DATA__", "null")
            raw = html.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            return self.wfile.write(raw)
        if u.path == "/status.json":
            if scenario == "slow":
                time.sleep(3)
            if scenario == "error":
                return self._json(500, {"error": "status.sh failed"})
            return self._json(200, status(scenario))
        if u.path == "/settings":
            return self._json(200, settings())
        if u.path == "/impact":
            return self._json(200, impact() if scenario != "empty" else {"ok": True, "repos": []})
        if u.path == "/autofix":
            return self._json(200, autofix())
        if u.path == "/transcript":
            return self._json(200, transcript(q.get("id")))
        if u.path in ("/commands", "/repos"):
            return self._json(200, [] if u.path == "/commands" else REPOS)
        if u.path == "/cleanup-preview":
            return self._json(200, {"worktree": {"path": "/work/acme/shop", "branch": "fix/cart-total", "removable": True}})
        return self._json(404, {"error": "not found"})

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        try:
            req = json.loads(self.rfile.read(n) or b"{}")
        except ValueError:
            req = {}
        if self.path == "/autofix/detail":
            d = autofix()["repos"][0]["details"]["datadog:9d8e7f6a5b4c3d2e"]
            return self._json(200, {"ok": True, "message": "원문을 불러옴", "detail": d})
        return self._json(200, {"ok": True, "message": f"미리보기: '{req.get('action') or self.path}' 요청을 받았습니다(아무것도 바꾸지 않음)"})


if __name__ == "__main__":
    port = int(sys.argv[sys.argv.index("--port") + 1]) if "--port" in sys.argv else 8765
    srv = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    print(f"http://127.0.0.1:{port}/?t=demo", flush=True)
    srv.serve_forever()
