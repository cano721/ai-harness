"""하네스 동작 항목의 PR이 지금 어떤 상태인지(열림·병합·거절) 호스트에서 읽어 둔다.

status.sh는 실행 기록만 보므로 사람이 병합한 PR도 계속 "draft PR 검토"로 남는다.
호스트 조회는 느리니 뒤에서 돌리고, status()는 캐시만 본다. 끝난 PR(병합·거절)은 다시 묻지 않는다.
PR 주소 없이 멈춘 러너 카드(#605)는 작업 브랜치의 PR을, release 런은 origin의 릴리스 태그를 같은 캐시로 판정한다.
원격 주소는 상태 파일에 두지 않고(자격이 섞일 수 있다) 카드 저장소의 remote.origin.url에서 그때 읽는다.
"""
import json, os, re, subprocess, threading, time, urllib.parse

BB = re.compile(r"^https://bitbucket\.org/([\w.-]+)/([\w.-]+)/pull-requests/(\d+)")
GH = re.compile(r"^https://github\.com/([\w.-]+)/([\w.-]+)/pull/(\d+)")
BB_REMOTE = re.compile(r"bitbucket\.org[:/]([\w.-]+)/([\w.-]+?)(?:\.git)?/?$")
GH_REMOTE = re.compile(r"github\.com[:/]")
SHARED = ("main", "master", "develop", "trunk")  # 여러 작업이 거치는 브랜치라 그 PR로 한 런의 끝을 판정하지 않는다
PENDING = ("OPEN", "NONE", "UNTAGGED")  # 아직 끝나지 않았거나 없는 상태 — OPEN_TTL마다 다시 묻는다
OPEN_TTL = 300
# url 또는 "branch\t<cwd>\t<branch>"·"tag\t<cwd>\t<tag>" -> {"state": OPEN|MERGED|DECLINED|SUPERSEDED|CLOSED|NONE|TAGGED|UNTAGGED, "at": t[, "url": PR]}
_cache = {}
_want = set()
_lock = threading.Lock()
_wake = threading.Event()


def _bitbucket_get(url):
    user, token = os.environ.get("ATLASSIAN_USER"), os.environ.get("BITBUCKET_API_TOKEN")
    if not (user and token):
        return None
    esc = lambda x: x.replace("\\", "\\\\").replace('"', '\\"')
    r = subprocess.run(["curl", "-sS", "--fail", "--max-time", "20", "-K", "-", url],
                       input=f'user = "{esc(user)}:{esc(token)}"\n', capture_output=True, text=True, timeout=30)
    return json.loads(r.stdout) if r.returncode == 0 else None


def _bitbucket(ws, repo, n):
    d = _bitbucket_get(f"https://api.bitbucket.org/2.0/repositories/{ws}/{repo}/pullrequests/{n}")
    return d.get("state") if d is not None else None


def _github(owner, repo, n):
    r = subprocess.run(["gh", "pr", "view", n, "-R", f"{owner}/{repo}", "--json", "state", "-q", ".state"],
                       capture_output=True, text=True, timeout=30)
    return r.stdout.strip() or None if r.returncode == 0 else None


def _verdict(prs):
    """같은 head 브랜치의 PR 목록 [(state, url)]을 하나로 — 열린 PR이 하나라도 있으면 끝나지 않은 것으로 본다."""
    if not prs:
        return "NONE", None
    for want in ("OPEN", "MERGED"):
        hit = [u for st, u in prs if st == want]
        if hit:
            return want, hit[0]
    st, u = prs[0]
    return ("CLOSED" if st not in ("DECLINED", "SUPERSEDED") else st), u


def _branch_prs(cwd, branch):
    if not os.path.isdir(cwd):
        return None
    r = subprocess.run(["git", "-C", cwd, "config", "--get", "remote.origin.url"], capture_output=True, text=True, timeout=10)
    remote = r.stdout.strip() if r.returncode == 0 else ""
    m = BB_REMOTE.search(remote)
    if m:
        q = urllib.parse.quote(f'source.branch.name="{branch}"', safe="")
        d = _bitbucket_get(f"https://api.bitbucket.org/2.0/repositories/{m.group(1)}/{m.group(2)}/pullrequests"
                           f"?q={q}&state=OPEN&state=MERGED&state=DECLINED&state=SUPERSEDED&pagelen=50")
        if d is None:
            return None
        return _verdict([(v.get("state"), ((v.get("links") or {}).get("html") or {}).get("href"))
                         for v in d.get("values") or [] if ((v.get("source") or {}).get("branch") or {}).get("name") == branch])
    if GH_REMOTE.search(remote):
        r = subprocess.run(["gh", "pr", "list", "--head", branch, "--state", "all", "--json", "state,headRefName,url", "--limit", "20"],
                           cwd=cwd, capture_output=True, text=True, timeout=30)
        if r.returncode != 0:
            return None
        return _verdict([(v.get("state"), v.get("url")) for v in json.loads(r.stdout or "[]") if v.get("headRefName") == branch])
    return None


def _release_tag(cwd, tag):
    if not os.path.isdir(cwd):
        return None
    r = subprocess.run(["git", "-C", cwd, "ls-remote", "--tags", "--refs", "origin", f"refs/tags/{tag}"],
                       capture_output=True, text=True, timeout=30, env={**os.environ, "GIT_TERMINAL_PROMPT": "0"})
    if r.returncode != 0:
        return None
    return ("TAGGED" if r.stdout.strip() else "UNTAGGED"), None


def _resolve(key):
    """키 하나를 (상태, 근거 PR 주소)로 읽는다. 읽지 못하면 None — 캐시하지 않고 카드를 그대로 둔다."""
    kind, _, rest = key.partition("\t")
    if kind in ("branch", "tag") and rest:
        cwd, _, ref = rest.partition("\t")
        return (_branch_prs if kind == "branch" else _release_tag)(cwd, ref)
    m = BB.match(key)
    if m:
        return _bitbucket(*m.groups()), None
    m = GH.match(key)
    if m:
        return _github(*m.groups()), None
    return None


def _fetch(key):
    try:
        got = _resolve(key)
    except (OSError, ValueError, subprocess.SubprocessError):
        return None
    return got[0] if got else None


def _ref_key(i):
    """PR 주소가 없는 러너 카드의 판정 키. release 런은 태그로만, 그 밖은 공용이 아닌 작업 브랜치로만 판정한다."""
    cwd = i.get("cwd") or ""
    if not cwd:
        return None
    if i.get("workflow") == "release":
        tag = i.get("release_tag")
        return f"tag\t{cwd}\t{tag}" if tag else None
    b = i.get("branch")
    return f"branch\t{cwd}\t{b}" if b and b not in SHARED else None


def _worker():
    while True:
        _wake.wait(60)
        _wake.clear()
        with _lock:
            todo = list(_want)
        for url in todo:
            try:
                got = _resolve(url)
            except Exception:
                got = None
            with _lock:
                if got and got[0]:
                    _cache[url] = {"state": got[0], "at": time.time(), "url": got[1]}
                _want.discard(url)


threading.Thread(target=_worker, daemon=True).start()


def apply(items):
    """사람 확인을 기다리는 하네스 항목과 멈춘 러너 카드 중 PR이 이미 끝난 것은 done으로 내린다."""
    now, ask = time.time(), False
    for i in items:
        url = i.get("link") or ""
        work = i.get("section") == "work"
        runner = work and i.get("kind") == "runner" and i.get("state") in ("needs_human", "blocked")
        other = not work and i.get("state") == "needs_human"
        key = url if BB.match(url) or GH.match(url) else (_ref_key(i) if runner else None)
        if not (runner or other) or not key:
            continue
        if i.get("section") == "autofix" and i.get("stage") != "pr":  # 포기·실패 카드의 지난 PR은 상태를 바꾸는 근거가 아니다
            continue
        with _lock:
            c = _cache.get(key)
            if not c or (c["state"] in PENDING and now - c["at"] > OPEN_TTL):
                _want.add(key)
                ask = True
        if c and c["state"] not in PENDING:
            if key != url and c.get("url"):  # 브랜치로 찾은 PR을 근거로 연다
                i["link"] = c["url"]
            if c["state"] == "TAGGED":
                done = None
                i["title"] = f"{i.get('title') or ''} → 릴리스 태그 {i.get('release_tag')} 있음"
            else:
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
            if done:
                i["title"] = f"{i.get('title') or ''} → PR {done}"
            if runner:  # 끝난 런에 이어 가기·승인 명령과 '중단됨' 배지가 남지 않게
                i["cmd"] = None
                i.pop("stall", None)
    if ask:
        _wake.set()
