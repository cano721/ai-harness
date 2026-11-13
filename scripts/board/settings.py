"""하네스 설정: 개인 자동화 단계(즉시)와 저장소 사실(PR).

자동화 단계(PR까지/병합까지/배포·검증까지)는 사람마다 다르므로 ~/.ai-harness/config의
HM_DELIVERY_LEVEL·HM_DELIVERY_LEVEL_REPOS에 둔다(#242). 병합 여부는 이 개인 설정만 정한다(#248). 보드가 바로 쓴다.
워크플로 승인 모드도 같은 파일의 HM_APPROVAL·HM_APPROVAL_REPOS만 정한다(#294) — manifest approval은 보지 않는다.
기준 브랜치·배포 확인·스모크 명령은 저장소 사실이라 harness.json에 있고, 보드는 직접 고치지 않는다 —
그 저장소에서 /ai-harness:harness-init 설정 변경을 돌려 draft PR로 낸다.
"""
import json, os, re, subprocess, tempfile, threading

LEVELS = ("pr", "merge", "deploy")


def _git(path, *args):
    out = subprocess.run(["git", "-C", path, *args], capture_output=True, text=True, timeout=10)
    return out.stdout.strip() if out.returncode == 0 else ""


def main_checkout(path):
    """worktree 경로여도 원본 체크아웃 경로를 돌려준다."""
    if not path or not os.path.isdir(path):
        return None
    common = _git(path, "rev-parse", "--path-format=absolute", "--git-common-dir")
    if not common:
        return None
    root = os.path.dirname(common) if common.endswith("/.git") else _git(path, "rev-parse", "--show-toplevel")
    return root or None


def discover(seed_paths):
    """하네스가 깔린 저장소: 알려진 경로(자동 실행 기록·작업 세션 cwd)의 원본 체크아웃과 그 형제 폴더."""
    roots, out = set(), set()
    for p in seed_paths:
        m = main_checkout(p)
        if m:
            roots.add(m)
    for r in list(roots):
        out.add(r)
        parent = os.path.dirname(r)
        try:
            for name in os.listdir(parent):
                out.add(os.path.join(parent, name))
        except OSError:
            pass
    return sorted(p for p in out if os.path.isfile(os.path.join(p, ".ai-harness", "harness.json")))


def level_of(m):
    gp = m.get("git_policy")
    if gp == "merge":
        verify = (m.get("merge_policy") or {}).get("verify") or []
        return "deploy" if ("deploy" in verify or "smoke" in verify) else "merge"
    if gp == "pr-only":
        return "pr"
    return gp or "none"  # direct | 미설정


def suggest(repo):
    # PR이 실제로 향하는 통합 브랜치(develop)가 있으면 그것, 없으면 원격 기본 브랜치
    base = "develop" if _git(repo, "rev-parse", "--verify", "--quiet", "refs/remotes/origin/develop") else ""
    if not base:
        head = _git(repo, "symbolic-ref", "--short", "refs/remotes/origin/HEAD")
        base = head.split("/", 1)[1] if "/" in head else ""
    for cand in ("main", "master"):
        if not base and _git(repo, "rev-parse", "--verify", "--quiet", f"refs/remotes/origin/{cand}"):
            base = cand
    merges = _git(repo, "log", "--merges", "--oneline", "-5", f"origin/{base}") if base else ""
    url = _git(repo, "remote", "get-url", "origin")
    host = "bitbucket" if "bitbucket" in url else "github" if "github" in url else "other"
    method = "merge" if merges else "squash"
    if host == "bitbucket" and method == "rebase":
        method = "squash"
    return {"base": base, "method": method, "host": host}


def read_repo(repo):
    try:
        with open(os.path.join(repo, ".ai-harness", "harness.json")) as f:
            m = json.load(f)
    except Exception as e:
        return {"repo": repo, "name": os.path.basename(repo), "error": f"harness.json을 읽지 못함: {e}"}
    return {
        "repo": repo, "name": os.path.basename(repo),
        "branch": _git(repo, "rev-parse", "--abbrev-ref", "HEAD"),
        "level": level_of(m), "git_policy": m.get("git_policy"), "merge_policy": m.get("merge_policy"),
        **repo_approval(repo, m),
        "monitor_ready": bool(m.get("monitor") and m.get("project_id")),
        "suggest": suggest(repo),
        "key": project_key(repo), "runner": runner_state(repo),
    }


LEVEL_KO = {"pr": "PR까지", "merge": "병합까지", "deploy": "배포·검증까지"}


# ---- 개인 설정(~/.ai-harness/config) ----
CONFIG = os.path.join(os.environ.get("HARNESS_METRICS_DIR") or os.path.expanduser("~/.ai-harness"), "config")
PERSONAL_KEYS = ("HM_DELIVERY_LEVEL", "HM_DELIVERY_LEVEL_REPOS", "HM_MERGE_REQUIRE", "HM_MERGE_MIN_APPROVALS", "HM_MERGE_METHOD",
                 "HM_APPROVAL", "HM_APPROVAL_REPOS",
                 "HM_HARVEST_AUTO", "HM_SYNC_AUTO", "HM_HARVEST_AUTO_MERGE", "HM_SYNC_AUTO_MERGE",
                 "HM_HARVEST_AUTO_DAILY_MAX", "HM_SYNC_AUTO_DAILY_MAX")
DAILY_DEFAULT = {"harvest": 2, "sync": 6}  # harvest-auto.sh 기본값
UNLIMITED = 1000  # harvest-auto.sh에 '무제한' 값이 없어 사실상 닿지 않는 수로 둔다(batch당 1회·동시 1개·실행당 비용 상한은 그대로)
HARNESS_STAGES = ("off", "run", "merge")  # 끔 / 자동 실행(draft PR까지) / 자동 실행 + 자동 병합
_LINE = re.compile(r"^\s*(?:export\s+)?([A-Z0-9_]+)=(.*)$")
_cfg_lock = threading.Lock()


def _value(raw):
    m = re.match(r'^"([^"]*)"', raw) or re.match(r"^'([^']*)'", raw)
    return m.group(1) if m else raw.split()[0] if raw.split() else ""


def user_config():
    """러너 user_config와 같은 규칙: 파일의 마지막 줄, 없으면 같은 이름의 환경변수. 셸로 실행하지 않는다."""
    out = {}
    try:
        with open(CONFIG) as f:
            for line in f:
                m = _LINE.match(line.rstrip("\n"))
                if m and m.group(1) in PERSONAL_KEYS:
                    out[m.group(1)] = _value(m.group(2))
    except OSError:
        pass
    for k in PERSONAL_KEYS:
        if k not in out and os.environ.get(k):
            out[k] = os.environ[k]
    return out


def write_user_config(updates):
    """updates의 키만 바꾼다(None·빈 값은 줄 삭제). 다른 줄·주석·권한은 그대로 두고 원자적으로 바꿔 쓴다."""
    with _cfg_lock:
        try:
            with open(CONFIG) as f:
                lines = f.read().splitlines()
            mode = os.stat(CONFIG).st_mode & 0o777
        except FileNotFoundError:
            lines, mode = [], 0o600
        keep = [l for l in lines if not ((m := _LINE.match(l)) and m.group(1) in updates)]
        keep += [f'{k}="{v}"' for k, v in updates.items() if v]
        os.makedirs(os.path.dirname(CONFIG), exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(CONFIG), prefix=".config.")
        with os.fdopen(fd, "w") as f:
            f.write("\n".join(keep) + "\n")
        os.chmod(tmp, mode)
        os.replace(tmp, CONFIG)


def repo_map(cfg, key):
    """러너 repository_setting과 같은 규칙: "<project_id>=<값>"(쉼표·공백 구분), 같은 키는 마지막 값."""
    out = {}
    for e in re.split(r"[,\s]+", cfg.get(key, "")):
        if "=" in e:
            k, v = e.split("=", 1)
            out[k] = v
    return out


def repo_levels(cfg):
    return repo_map(cfg, "HM_DELIVERY_LEVEL_REPOS")


APPROVALS = ("human", "auto")


def approval_of(key, cfg):
    """러너 approval_mode와 같은 순서: HM_APPROVAL_REPOS(이 저장소) > HM_APPROVAL > human. manifest approval은 보지 않는다(#294).
    source: repo | default(내 기본) | none(설정 없음). 값이 human·auto가 아니면 러너는 시작하지 않으므로 그대로 보여 준다."""
    mine = repo_map(cfg, "HM_APPROVAL_REPOS").get(key) or None
    if mine:
        return {"approval": mine, "approval_source": "repo", "approval_mine": mine}
    if cfg.get("HM_APPROVAL"):
        return {"approval": cfg["HM_APPROVAL"], "approval_source": "default", "approval_mine": None}
    return {"approval": "human", "approval_source": "none", "approval_mine": None}


def repo_approval(repo, manifest):
    """이 저장소 러너가 실제로 쓸 승인 모드. #294 이전 러너(HM_APPROVAL을 모름)는 아직 manifest approval을 읽으므로
    동기화 전까지는 그 값을 출처 legacy로 보인다 — 개인 설정으로 계산하면 auto 저장소가 사람 확인으로 잘못 보인다."""
    personal = approval_of(project_key(repo), user_config())
    if runner_approval(repo) == "old":
        return {**personal, "approval": manifest.get("approval") or "human", "approval_source": "legacy"}
    return personal


def set_approval(req, known):
    """{scope: "default"} 또는 {scope: "repo", repo}, mode: human|auto|"" (""=설정 지움)."""
    mode = req.get("mode") or ""
    if mode and mode not in APPROVALS:
        return "알 수 없는 승인 모드"
    if req.get("scope") == "default":
        write_user_config({"HM_APPROVAL": mode})
        return None
    if req.get("repo") not in known:
        return "하네스 저장소 목록에 없는 경로"
    key = project_key(req["repo"])
    if not re.fullmatch(r"[\w.-]+", key):
        return f"이 저장소의 project_id({key})는 설정 키로 쓸 수 없음"
    modes = repo_map(user_config(), "HM_APPROVAL_REPOS")
    modes.pop(key, None)
    if mode:
        modes[key] = mode
    write_user_config({"HM_APPROVAL_REPOS": ",".join(f"{k}={v}" for k, v in modes.items())})
    return None


def set_harness(req):
    """하네스 동작(자동 harvest·sync)의 내 설정: kind harvest|sync, stage off|run|merge."""
    kind, stage = req.get("kind"), req.get("stage")
    if kind not in ("harvest", "sync"):
        return "알 수 없는 값"
    k = kind.upper()
    if "daily_max" in req:  # 하루 실행 상한(전체 저장소 합계)
        n = req["daily_max"]
        if not isinstance(n, int) or not (1 <= n <= 30 or n == UNLIMITED):
            return "하루 상한은 1~30 또는 제한 없음"
        write_user_config({f"HM_{k}_AUTO_DAILY_MAX": "" if n == DAILY_DEFAULT[kind] else str(n)})
        return None
    if stage not in HARNESS_STAGES:
        return "알 수 없는 값"
    write_user_config({f"HM_{k}_AUTO": "1" if stage != "off" else "", f"HM_{k}_AUTO_MERGE": "1" if stage == "merge" else ""})
    return None


def set_personal(req, known):
    """{scope: "default"} 또는 {scope: "repo", repo}, level: pr|merge|deploy|"" (""=설정 지움)."""
    level = req.get("level") or ""
    if level and level not in LEVELS:
        return "알 수 없는 단계"
    cfg = user_config()
    if req.get("scope") == "default":
        write_user_config({"HM_DELIVERY_LEVEL": level})
        return None
    if req.get("repo") not in known:
        return "하네스 저장소 목록에 없는 경로"
    key = project_key(req["repo"])
    if not re.fullmatch(r"[\w.-]+", key):
        return f"이 저장소의 project_id({key})는 설정 키로 쓸 수 없음"
    levels = repo_levels(cfg)
    levels.pop(key, None)
    if level:
        levels[key] = level
    write_user_config({"HM_DELIVERY_LEVEL_REPOS": ",".join(f"{k}={v}" for k, v in levels.items())})
    return None


def project_key(repo):
    """러너 project_key와 같은 순서: harness.json project_id → origin 저장소 이름 → 원본 체크아웃 폴더 이름."""
    try:
        pid = json.load(open(os.path.join(repo, ".ai-harness", "harness.json"))).get("project_id")
        if pid:
            return pid
    except Exception:
        pass
    url = _git(repo, "remote", "get-url", "origin").rstrip("/")
    name = re.sub(r"\.git$", "", url.rsplit("/", 1)[-1].rsplit(":", 1)[-1]) if url else ""
    return name or os.path.basename(main_checkout(repo) or repo)


def runner_state(repo):
    p = os.path.join(repo, ".ai-harness", "workflows", "workflow-driver.sh")
    if not os.path.isfile(p):
        return "none"
    with open(p, errors="replace") as f:
        return "personal" if "HM_DELIVERY_LEVEL" in f.read() else "old"


def runner_approval(repo):
    """러너가 개인 승인 모드(HM_APPROVAL)를 읽는지: personal | old(manifest approval을 읽음) | none."""
    p = os.path.join(repo, ".ai-harness", "workflows", "workflow-driver.sh")
    if not os.path.isfile(p):
        return "none"
    with open(p, errors="replace") as f:
        return "personal" if "HM_APPROVAL" in f.read() else "old"


def effective(row, cfg):
    """이 저장소에서 러너가 쓸 단계와 출처, 그리고 주의할 점."""
    personal = repo_levels(cfg).get(row["key"]) or cfg.get("HM_DELIVERY_LEVEL")
    src = "repo" if repo_levels(cfg).get(row["key"]) else "default" if personal else "team"
    notes = []
    if personal and row["runner"] != "personal":
        notes.append(("이 저장소에는 워크플로 러너가 아직 없어" if row["runner"] == "none" else "이 저장소의 러너가 옛 버전이라")
                     + f" 고른 단계({LEVEL_KO[personal]})는 하네스를 동기화한 뒤부터 적용되고, 그 전에는 저장소 설정을 따릅니다.")
        personal, src = None, "team"
    level = personal or ("pr" if row["level"] in LEVELS else None)
    gp = row.get("git_policy")
    if gp == "merge":  # 러너는 예전 git_policy:"merge"를 pr-only로 읽는다(#248)
        notes.append("저장소 하네스 설정의 예전 병합 설정은 더 이상 쓰이지 않아 PR까지로 읽힙니다. 하네스를 동기화하면 정리를 제안합니다.")
    if personal and personal != "pr" and gp not in ("pr-only", "merge"):
        notes.append("저장소가 PR을 만들지 않는 설정이라 병합할 PR이 없습니다.")
    mp = row.get("merge_policy") or {}
    if level == "deploy" and src != "team" and not (mp.get("deploy_check_cmd") or mp.get("smoke_cmd")):
        notes.append("저장소에 배포 확인·스모크 명령이 없어 병합까지만 합니다. 저장소 사실 고치기로 더할 수 있습니다.")
    return {"level": level, "source": src, "notes": notes}


# ---- 호스트 브랜치 보호(개인 단계의 병합 안전장치) ----
def protection(repo, base):
    """러너 branch_protection과 같은 판정: {approvals, checks} 또는 {error}."""
    url = _git(repo, "remote", "get-url", "origin")
    if not re.fullmatch(r"[\w./-]{1,100}", base or ""):
        return {"error": "기준 브랜치를 모름"}
    m = re.search(r"github\.com[:/]([\w.-]+/[\w.-]+?)(?:\.git)?/?$", url)
    if m:
        slug, approvals, checks, unreadable = m.group(1), 0, 0, []
        r = subprocess.run(["gh", "api", f"repos/{slug}/rules/branches/{base}"], capture_output=True, text=True, timeout=20, cwd=repo)
        if r.returncode == 0:
            rules = json.loads(r.stdout or "[]")
            approvals = max([x.get("parameters", {}).get("required_approving_review_count", 0) for x in rules if x.get("type") == "pull_request"] or [0])
            checks = sum(len(x.get("parameters", {}).get("required_status_checks", [])) for x in rules if x.get("type") == "required_status_checks")
        else:
            unreadable.append("규칙 세트: " + r.stderr.strip()[:150])
        r = subprocess.run(["gh", "api", f"repos/{slug}/branches/{base}/protection"], capture_output=True, text=True, timeout=20, cwd=repo)
        if r.returncode == 0:
            p = json.loads(r.stdout)
            approvals = max(approvals, (p.get("required_pull_request_reviews") or {}).get("required_approving_review_count", 0))
            rc = p.get("required_status_checks") or {}
            checks = max(checks, len(rc.get("checks") or rc.get("contexts") or []))
        elif "Branch not protected" not in r.stderr + r.stdout:
            unreadable.append("브랜치 보호: " + (r.stderr.strip() or r.stdout.strip())[:150])
        if approvals == 0 and unreadable:
            return {"error": "; ".join(unreadable)}
        return {"approvals": approvals, "checks": checks}
    m = re.search(r"bitbucket\.org[:/]([\w.-]+/[\w.-]+?)(?:\.git)?/?$", url)
    if m:
        user, token = os.environ.get("ATLASSIAN_USER"), os.environ.get("BITBUCKET_API_TOKEN")
        if not (user and token):
            return {"error": "ATLASSIAN_USER·BITBUCKET_API_TOKEN이 보드 환경에 없음"}
        def bb(path):
            esc = lambda x: x.replace("\\", "\\\\").replace('"', '\\"')
            r = subprocess.run(["curl", "-sS", "--fail", "--max-time", "30", "-K", "-", f"https://api.bitbucket.org/2.0/repositories/{m.group(1)}/{path}"],
                               input=f'user = "{esc(user)}:{esc(token)}"\n', capture_output=True, text=True, timeout=40)
            if r.returncode:
                raise RuntimeError(r.stderr.strip()[:150] or "요청 실패")
            return json.loads(r.stdout)
        try:
            rules = bb("branch-restrictions?pagelen=100").get("values", [])
        except Exception as e:
            return {"error": f"branch restrictions(관리자 권한 필요): {e}"}
        model = None
        if any(x.get("branch_match_kind") == "branching_model" for x in rules):
            try:
                model = bb("branching-model")
            except Exception:
                model = None
        import fnmatch
        approvals = checks = 0
        for x in rules:
            kind = x.get("kind")
            if kind not in ("require_approvals_to_merge", "require_default_reviewer_approvals_to_merge", "require_passing_builds_to_merge"):
                continue
            if (x.get("branch_match_kind") or "glob") == "glob":
                applies = fnmatch.fnmatchcase(base, x.get("pattern") or "")
            elif model:
                t = x.get("branch_type")
                name = ((model.get("development") or {}).get("branch") or {}).get("name") if t == "development" else \
                    ((model.get("production") or {}).get("branch") or {}).get("name") if t == "production" and (model.get("production") or {}).get("enabled") is not False else None
                applies = name == base
            else:
                applies = False
            if applies:
                if kind == "require_passing_builds_to_merge":
                    checks = max(checks, x.get("value") or 0)
                else:
                    approvals = max(approvals, x.get("value") or 0)
        return {"approvals": approvals, "checks": checks}
    return {"error": "GitHub·Bitbucket이 아닌 원격"}


# ---- 저장소 사실(기준 브랜치·배포·스모크) 변경 PR ----
def validate_facts(req, known):
    repo = req.get("repo")
    if repo not in known:
        return None, "하네스 저장소 목록에 없는 경로"
    base = str(req.get("base") or "").strip()
    if not re.fullmatch(r"[\w./-]{1,100}", base):
        return None, "기준 브랜치 이름이 올바르지 않음"
    out = {"base": base}
    for key, label in (("deploy_check_cmd", "배포 확인"), ("smoke_cmd", "스모크")):
        cmd = str(req.get(key) or "").strip()
        if "\n" in cmd or len(cmd) > 500:
            return None, f"{label} 명령은 한 줄, 500자 이하"
        out[key] = cmd
    t = req.get("deploy_timeout_minutes", 60)
    out["deploy_timeout_minutes"] = t if isinstance(t, int) and 5 <= t <= 240 else 60
    return {"repo": repo, "facts": out}, None


def prompt_for_facts(change, row):
    f = change["facts"]
    lines = [f"- base: `{f['base']}`",
             f"- deploy_check_cmd: {('`' + f['deploy_check_cmd'] + '`') if f['deploy_check_cmd'] else '없음(필드 제거)'}",
             f"- smoke_cmd: {('`' + f['smoke_cmd'] + '`') if f['smoke_cmd'] else '없음(필드 제거)'}",
             f"- deploy_timeout_minutes: {f['deploy_timeout_minutes']}"]
    return (
        "/ai-harness:harness-init 설정 변경만 한다. 3-1의 '병합에 쓸 저장소 사실'을 아래 값으로 맞춘다.\n\n"
        "목표: .ai-harness/harness.json `merge_policy`의 저장소 사실\n" + "\n".join(lines) + "\n\n"
        "- 병합 여부·조건(require·min_approvals·method)은 이제 사람마다 정하는 개인 자동화 단계(~/.ai-harness/config)라 건드리지 않는다. "
        f"git_policy도 그대로 둔다(현재 {row.get('git_policy') or '미설정'}). verify에는 명령이 있는 deploy·smoke만 남기고, 기존 monitor는 유지한다.\n"
        "- Harness Board에서 사용자가 위 값을 이미 골랐다. 다시 묻지 말고 이 diff만 적용한다. 명령이 저장소에서 실제로 돌 수 있는지(스크립트 존재, 실행 권한) 확인한다.\n"
        "- 지금 체크아웃된 브랜치와 작업 중인 변경은 건드리지 않는다. 기준 브랜치에서 새 worktree·브랜치를 만들어 작업하고 draft PR을 연다. 병합은 하지 않는다.\n"
        "- 위 값으로 진행할 수 없는 문제(명령이 저장소에 없음, 브랜치가 없음 등)가 있으면 바꾸지 말고 이유를 말한 뒤 나에게 묻는다.\n"
        "- 끝나면 PR 링크와 바뀐 줄을 짧게 보고한다."
    )
