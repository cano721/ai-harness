"""하네스 안내 화면 데이터 (#432). 기능 목록은 저장소에서 읽고, 화면 문구(한국어 이름·요약·말로 부르는 예)는 guide.json에서 붙인다.

- 출처: skills/*/SKILL.md(플러그인 스킬), templates/*/SKILL.md(프로젝트에 깔리는 워크플로·규칙 스킬),
  agents/*.md(플러그인 에이전트), catalog/catalog.json(기본 스킬 카탈로그). 항목 id는 "<출처>/<이름>"이다.
- guide.json에 없는 기능은 "기타" 묶음에 원래 설명의 첫 문장으로 남고, 저장소에 없는 guide.json 항목은 빠진다.
  둘 다 coverage()가 알려 주고 tests/board.sh가 0건인지 확인한다 — 새 기능을 더하면 guide.json도 같이 고친다.
- 묶음의 "fold": true는 사람이 부르지 않고 에이전트가 알아서 쓰는 묶음이다 — 화면이 기본으로 접는다.
- 부르는 명령은 출처로 정한다: 플러그인 스킬 /ai-harness:<이름>, 카탈로그 /<이름>, 워크플로(entry) /<이름>, 그 밖은 없음.
"""
import glob, json, os, re

DIR = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(DIR, "..", ".."))
GUIDE = os.path.join(DIR, "guide.json")
VIEWS = ("list", "list:harness", "list:autofix", "refs", "impact", "settings")


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


def state(root=ROOT, guide_path=GUIDE):
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
            items.append({"id": iid, "name": name, "title": i.get("title") or name, "summary": i.get("summary") or "",
                          "ask": i.get("ask") or "", "cmd": _cmd(iid, name, i.get("entry")), "view": view})
        if items:
            groups.append({"key": g.get("key") or "", "label": g.get("label") or "", "desc": g.get("desc") or "",
                           "fold": g.get("fold") is True, "items": items})
    rest = [k for k in found if k not in seen]
    if rest:
        groups.append({"key": "other", "label": "기타", "desc": "안내 문구가 아직 없는 기능입니다. 설명은 원문 첫 문장입니다.", "fold": False,
                       "items": [{"id": k, "name": found[k]["name"], "title": found[k]["name"],
                                  "summary": _first_sentence(found[k]["description"]), "ask": "",
                                  "cmd": _cmd(k, found[k]["name"], False), "view": None} for k in rest]})
    return {"ok": True, "groups": groups}
