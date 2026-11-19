"""하네스 안내 화면 데이터 (#432). 기능 목록은 저장소에서 읽고, 화면 문구(한국어 이름·요약·말로 부르는 예)는 guide.json에서 붙인다.

- 출처: skills/*/SKILL.md(플러그인 스킬), templates/*/SKILL.md(프로젝트에 깔리는 워크플로·규칙 스킬),
  agents/*.md(플러그인 에이전트), catalog/catalog.json(기본 스킬 카탈로그). 항목 id는 "<출처>/<이름>"이다.
- guide.json에 없는 기능은 "기타" 묶음에 원래 설명의 첫 문장으로 남고, 저장소에 없는 guide.json 항목은 빠진다.
  둘 다 coverage()가 알려 주고 tests/board.sh가 0건인지 확인한다 — 새 기능을 더하면 guide.json도 같이 고친다.
- 묶음의 "fold": true는 사람이 부르지 않고 에이전트가 알아서 쓰는 묶음이다 — 화면이 기본으로 접는다.
- 부르는 명령은 출처로 정한다: 플러그인 스킬 /ai-harness:<이름>, 카탈로그 /<이름>, 워크플로(entry) /<이름>, 그 밖은 없음.
- 카드에서 바로 실행(#442): guide.json 항목의 "run"이 실행 범위다 — global(어디서든, 기본 위치 홈), repo(보드가 아는 저장소),
  harness(하네스를 깐 저장소만). 명령이 없거나 접힌 묶음이면 실행하지 않는다. 실행할 수 없으면 blocked가 이유다:
  no_harness_repo(하네스를 깐 저장소가 없음), not_installed(기본 스킬 카탈로그 항목을 아직 설치하지 않음 — setup.sh와 같은 폴더).
  실행 자체는 보드의 기존 POST /new가 한다.
"""
import glob, json, os, re

DIR = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(DIR, "..", ".."))
GUIDE = os.path.join(DIR, "guide.json")
VIEWS = ("list", "list:harness", "list:autofix", "refs", "impact", "settings")
RUNS = ("global", "repo", "harness")


def default_skills_dir():
    return os.environ.get("HM_CLAUDE_SKILLS_DIR") or os.path.expanduser("~/.claude/skills")


def _front(path):
    meta, block = {}, None
    try:
        with open(path, encoding="utf-8") as f:
            if f.readline().strip() != "---":
                return meta
            for line in f:
                if line.strip() == "---":
                    break
                if line[:1] in (" ", "\t") or not line.strip():
                    if block:  # description: > 같은 여러 줄 값
                        meta[block] = (meta.get(block, "") + " " + line.strip()).strip()
                    continue  # 블록 값 밖의 들여쓴 줄은 metadata: 같은 하위 항목이다
                k, _, v = line.partition(":")
                k, v = k.strip(), v.strip()
                block = k if v in (">", "|", ">-", "|-") else None
                meta[k] = "" if block else v.strip("\"'")
    except OSError:
        pass
    return meta


def _first_sentence(text):
    text = " ".join((text or "").split())
    m = re.match(r"(.+?[.!?。])(\s|$)", text)
    return (m.group(1) if m else text)[:200]


def scan(root=ROOT):
    """저장소의 기능 {id: {"name", "description"}}."""
    found = {}
    for src, pattern in (("skills", "skills/*/SKILL.md"), ("templates", "templates/*/SKILL.md")):
        for f in sorted(glob.glob(os.path.join(root, pattern))):
            d = os.path.basename(os.path.dirname(f))
            m = _front(f)
            found[f"{src}/{d}"] = {"name": m.get("name") or d, "description": m.get("description", "")}
    for f in sorted(glob.glob(os.path.join(root, "agents", "*.md"))):
        m = _front(f)
        name = m.get("name") or os.path.basename(f)[:-3]
        found[f"agents/{os.path.basename(f)[:-3]}"] = {"name": name, "description": m.get("description", "")}
    try:
        with open(os.path.join(root, "catalog", "catalog.json"), encoding="utf-8") as f:
            for s in (json.load(f).get("skills") or []):
                if isinstance(s, dict) and s.get("name"):
                    found[f"catalog/{s['name']}"] = {"name": s["name"], "description": s.get("summary") or ""}
    except (OSError, ValueError):
        pass
    return found


def _load(guide_path):
    try:
        with open(guide_path, encoding="utf-8") as f:
            groups = json.load(f).get("groups")
    except (OSError, ValueError, AttributeError):
        return []
    out = []
    for g in groups if isinstance(groups, list) else []:
        if isinstance(g, dict):
            items = g.get("items")
            out.append({**g, "items": [i for i in items if isinstance(i, dict)] if isinstance(items, list) else []})
    return out


def coverage(root=ROOT, guide_path=GUIDE):
    found = scan(root)
    listed = [i.get("id") for g in _load(guide_path) for i in (g.get("items") or [])]
    return {"unlisted": sorted(set(found) - set(listed)), "stale": sorted(set(listed) - set(found))}


def _cmd(item_id, name, entry):
    src = item_id.split("/", 1)[0]
    if src == "skills":
        return f"/ai-harness:{name}"
    if src == "catalog" or (src == "templates" and entry):
        return f"/{name}"
    return None


def _run(item_id, name, cmd, run, fold, harness, skills):
    """(run, runnable, blocked). harness가 None이면 하네스 저장소 수를 모르는 것으로 보고 막지 않는다."""
    run = run if run in RUNS and cmd and not fold else None
    if not run:
        return None, False, None
    if run == "harness" and harness is not None and not harness:
        return run, False, "no_harness_repo"
    if item_id.startswith("catalog/") and not os.path.isfile(os.path.join(skills, name, "SKILL.md")):
        return run, False, "not_installed"
    return run, True, None


def state(root=ROOT, guide_path=GUIDE, harness=None, repos=None, skills_dir=None):
    """harness: 하네스를 깐 저장소 목록, repos: 보드가 아는 저장소 목록(보드 서버가 넘긴다)."""
    skills = skills_dir or default_skills_dir()
    found = scan(root)
    groups, seen = [], set()
    for g in _load(guide_path):
        items = []
        for i in g.get("items") or []:
            iid = i.get("id")
            if iid not in found or iid in seen:
                continue
            seen.add(iid)
            name = found[iid]["name"]
            view = i.get("view") if i.get("view") in VIEWS else None
            cmd = _cmd(iid, name, i.get("entry"))
            run, runnable, blocked = _run(iid, name, cmd, i.get("run"), g.get("fold") is True, harness, skills)
            items.append({"id": iid, "name": name, "title": i.get("title") or name, "summary": i.get("summary") or "",
                          "ask": i.get("ask") or "", "cmd": cmd, "view": view,
                          "run": run, "runnable": runnable, "blocked": blocked})
        if items:
            groups.append({"key": g.get("key") or "", "label": g.get("label") or "", "desc": g.get("desc") or "",
                           "fold": g.get("fold") is True, "items": items})
    rest = [k for k in found if k not in seen]
    if rest:
        groups.append({"key": "other", "label": "기타", "desc": "안내 문구가 아직 없는 기능입니다. 설명은 원문 첫 문장입니다.", "fold": False,
                       "items": [{"id": k, "name": found[k]["name"], "title": found[k]["name"],
                                  "summary": _first_sentence(found[k]["description"]), "ask": "",
                                  "cmd": _cmd(k, found[k]["name"], False), "view": None,
                                  "run": None, "runnable": False, "blocked": None} for k in rest]})
    harness = sorted(set(harness or []))
    return {"ok": True, "groups": groups,
            "launch": {"home": os.path.expanduser("~"), "harness": harness, "repos": sorted(set(repos or []) | set(harness))}}
