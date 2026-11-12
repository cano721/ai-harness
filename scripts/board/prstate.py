"""하네스 동작 항목의 PR이 지금 어떤 상태인지(열림·병합·거절) 호스트에서 읽어 둔다.

status.sh는 실행 기록만 보므로 사람이 병합한 PR도 계속 "draft PR 검토"로 남는다.
호스트 조회는 느리니 뒤에서 돌리고, status()는 캐시만 본다. 끝난 PR(병합·거절)은 다시 묻지 않는다.
"""
import json, os, re, subprocess, threading, time

BB = re.compile(r"^https://bitbucket\.org/([\w.-]+)/([\w.-]+)/pull-requests/(\d+)")
GH = re.compile(r"^https://github\.com/([\w.-]+)/([\w.-]+)/pull/(\d+)")
OPEN_TTL = 300
_cache = {}  # url -> {"state": OPEN|MERGED|DECLINED|SUPERSEDED|CLOSED, "at": t}
_want = set()
_lock = threading.Lock()
_wake = threading.Event()


def _bitbucket(ws, repo, n):
    user, token = os.environ.get("ATLASSIAN_USER"), os.environ.get("BITBUCKET_API_TOKEN")
    if not (user and token):
        return None
    esc = lambda x: x.replace("\\", "\\\\").replace('"', '\\"')
    r = subprocess.run(["curl", "-sS", "--fail", "--max-time", "20", "-K", "-",
                        f"https://api.bitbucket.org/2.0/repositories/{ws}/{repo}/pullrequests/{n}"],
                       input=f'user = "{esc(user)}:{esc(token)}"\n', capture_output=True, text=True, timeout=30)
    return json.loads(r.stdout).get("state") if r.returncode == 0 else None


def _github(owner, repo, n):
    r = subprocess.run(["gh", "pr", "view", n, "-R", f"{owner}/{repo}", "--json", "state", "-q", ".state"],
                       capture_output=True, text=True, timeout=30)
    return r.stdout.strip() or None if r.returncode == 0 else None


def _fetch(url):
    m = BB.match(url)
    if m:
        return _bitbucket(*m.groups())
    m = GH.match(url)
    if m:
        return _github(*m.groups())
    return None


def _worker():
    while True:
        _wake.wait(60)
        _wake.clear()
        with _lock:
            todo = list(_want)
        for url in todo:
            try:
                st = _fetch(url)
            except Exception:
                st = None
            with _lock:
                if st:
                    _cache[url] = {"state": st, "at": time.time()}
                _want.discard(url)


threading.Thread(target=_worker, daemon=True).start()


def apply(items):
    """사람 확인을 기다리는 하네스 항목 중 PR이 이미 끝난 것은 done으로 내린다."""
    now, ask = time.time(), False
    for i in items:
        url = i.get("link") or ""
        if i.get("section") == "work" or i.get("state") != "needs_human" or not (BB.match(url) or GH.match(url)):
            continue
        if i.get("section") == "autofix" and i.get("stage") != "pr":  # 포기·실패 카드의 지난 PR은 상태를 바꾸는 근거가 아니다
            continue
        with _lock:
            c = _cache.get(url)
            if not c or (c["state"] == "OPEN" and now - c["at"] > OPEN_TTL):
                _want.add(url)
                ask = True
        if c and c["state"] != "OPEN":
            done = {"MERGED": "병합됨", "DECLINED": "거절됨", "SUPERSEDED": "대체됨", "CLOSED": "닫힘"}.get(c["state"], c["state"])
            i["actions"] = [a for a in i.get("actions", []) if a not in ("open_agent",)]
            if i.get("section") == "autofix":
                # 자동 수정 PR은 병합이 끝이 아니다 — 배포 반영·재발 관찰을 다음 검증(sweep)이 이어 한다.
                merged = c["state"] == "MERGED"
                i["state"] = "running" if merged else "done"
                i["stage"] = "deploy_wait" if merged else "declined"
                i["stage_label"] = "병합됨 · 다음 검증이 배포·재발을 확인" if merged else f"PR {done}"
                continue
            i["state"] = "done"
            i["title"] = f"{i.get('title') or ''} → PR {done}"
    if ask:
        _wake.set()
