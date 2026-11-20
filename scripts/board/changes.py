"""버전 바뀜 안내 (#439). 자동 업데이트로 플러그인 버전이 올라도 새 기능·동작 변경·업데이트 후 해야 할 일을 놓치지 않게 한다.

- 확인한 버전: 사용자 데이터 board/version-seen.json {"seen": "0.86.0", "prev": "0.85.0"}. 보드(하네스 안내)와 세션 시작 안내
  (setup.sh notify → 이 파일의 hint)가 같은 값을 본다 — 그래서 브라우저 localStorage가 아니다. prev는 마지막 확인 직전의 값으로,
  확인한 뒤에도 "최근 업데이트"를 다시 펼쳐 볼 범위다.
- 상태가 없으면(첫 설치, 이 기능이 생기기 전부터 쓰던 사람) 현재 버전으로 조용히 기록한다. 둘을 가를 확실한 근거가 없고,
  첫 설치에 수십 개 버전의 변경을 쏟아내는 것보다 이 기능이 처음 깔린 한 번을 건너뛰는 편이 낫다. 다음 업데이트부터 보인다.
- 출처: 플러그인과 함께 배포되는 CHANGELOG.md. 확인한 버전 초과 ~ 현재 버전 이하의 절을 모두 합친다(건너뛴 버전 포함, Unreleased 제외).
  버전은 숫자 튜플로 견준다(0.9.1 < 0.10.0). 현재 버전은 .claude-plugin/plugin.json(없으면 .codex-plugin) — release.json과 같다.
- 항목: "- **제목** — 본문"이면 굵은 제목과 나머지 본문, 굵은 제목이 없으면 첫 문장이 제목이고 본문은 전문이다. 들여쓴 줄은 같은 항목이다.
- HM_PLUGIN_ROOT는 테스트가 CHANGELOG·plugin.json fixture를 가리킬 때 쓴다.
"""
import json, os, re, sys, threading

DIR = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(DIR, "..", ".."))
# 소제목 → 묶음. 화면은 이 순서로 보인다. 목록에 없는 소제목(실측·왜·한계 같은 옛 절)은 기타.
BUCKETS = (("todo", "업데이트 후 해야 할 일"), ("feature", "새 기능"), ("change", "동작 변경"), ("fix", "버그 수정"), ("other", "기타"))
HEADINGS = {"업데이트 후 해야 할 일": "todo", "새 기능": "feature", "새 설정 (선택)": "feature",
            "동작 변경": "change", "개선": "change", "달라진 점": "change", "달라진 진입점": "change", "보안": "change",
            "버그 수정": "fix", "수정": "fix"}
VERSION_HEAD = re.compile(r"^## v(\d+\.\d+\.\d+)\b")
ISSUES_ONLY = re.compile(r"^\(#\d+(?:,\s*#\d+)*\)$")


def plugin_root():
    return os.environ.get("HM_PLUGIN_ROOT") or ROOT


def data_dir():
    return os.environ.get("HARNESS_METRICS_DIR") or os.path.expanduser("~/.ai-harness")


def vtuple(v):
    m = re.fullmatch(r"v?(\d+)\.(\d+)\.(\d+)", str(v or "").strip())
    return tuple(int(x) for x in m.groups()) if m else None


def current_version(root=None):
    root = root or plugin_root()
    for rel in (".claude-plugin/plugin.json", ".codex-plugin/plugin.json"):
        try:
            with open(os.path.join(root, rel), encoding="utf-8") as f:
                v = json.load(f).get("version")
        except (OSError, ValueError, AttributeError):
            continue
        if vtuple(v):
            return v
    return None


def _plain(s):
    return re.sub(r"\*\*|`", "", s).strip()


def _item(lines, version):
    text = "\n".join(lines).strip()
    m = re.match(r"\*\*(.+?)\*\*\s*(?:—|–|-|:)?\s*", text, re.S)
    if m:
        return {"title": _plain(m.group(1)), "body": text[m.end():].strip(), "version": version}
    first = re.match(r"(.+?[.!?。])(\s+|$)", text, re.S)
    title, body = (first.group(1), text[first.end():].strip()) if first else (text, "")
    if ISSUES_ONLY.match(body):
        title, body = f"{title} {body}", ""
    # 굵은 제목이 없으면 제목(첫 문장)이 줄에서 잘릴 수 있으므로 펼친 곳에는 전문을 둔다. 한 문장뿐이면 펼칠 것이 없다.
    return {"title": _plain(" ".join(title.split())), "body": text if body else "", "version": version}


def parse(text):
    """CHANGELOG 본문 → [{"version", "items": [(묶음, 항목)]}] (파일 순서 = 최신부터). Unreleased·머리말은 건너뛴다."""
    versions, cur, bucket, item, fence = [], None, "other", None, False

    def flush():
        nonlocal item
        if cur is not None and item:
            cur["items"].append((bucket, _item(item, cur["version"])))
        item = None

    for line in text.splitlines():
        if line.strip().startswith("```"):
            fence = not fence  # 코드 블록은 앞 항목의 본문이다(울타리 줄 자체는 버린다)
            continue
        if fence:
            if cur is not None and item is not None and line.strip():
                item.append(line.strip())
            continue
        if line.startswith("## "):
            flush()
            m = VERSION_HEAD.match(line)
            cur = {"version": m.group(1), "items": []} if m else None
            if cur:
                versions.append(cur)
            bucket = "other"
            continue
        if cur is None:
            continue
        if re.match(r"#{3,6} ", line):
            flush()
            bucket = HEADINGS.get(line.lstrip("#").strip(), "other")
        elif line.startswith("- "):
            flush()
            item = [line[2:]]
        elif not line.strip():
            continue  # 빈 줄은 항목을 끊지 않는다(들여쓴 이어지는 문단·코드 블록)
        elif line[:1] in (" ", "\t") and item is not None:
            item.append(line.strip())
        else:
            flush()
            item = [line.strip()]  # 목록 기호 없는 옛 절의 문단은 문단 하나가 항목이다
    flush()
    return versions


def _read_changelog(root):
    try:
        with open(os.path.join(root, "CHANGELOG.md"), encoding="utf-8") as f:
            return parse(f.read())
    except OSError:
        return []


def _range(versions, lo, hi):
    """lo 초과 hi 이하 버전들을 합친 {versions, groups, counts}. lo가 None이면 hi 하나."""
    lo_t, hi_t = vtuple(lo) if lo else None, vtuple(hi)
    picked = [v for v in versions if vtuple(v["version"]) <= hi_t and (lo_t is None and vtuple(v["version"]) == hi_t or lo_t is not None and vtuple(v["version"]) > lo_t)]
    picked.sort(key=lambda v: vtuple(v["version"]), reverse=True)
    groups = []
    for key, label in BUCKETS:
        items = [it for v in picked for b, it in v["items"] if b == key]
        if items:
            groups.append({"key": key, "label": label, "items": items})
    todo = sum(len(g["items"]) for g in groups if g["key"] == "todo")
    return {"versions": [v["version"] for v in picked], "groups": groups,
            "counts": {"todo": todo, "total": sum(len(g["items"]) for g in groups)}}


def _state_path(data):
    return os.path.join(data, "board", "version-seen.json")


def read_seen(data=None):
    try:
        with open(_state_path(data or data_dir()), encoding="utf-8") as f:
            st = json.load(f)
    except (OSError, ValueError):
        return None
    return st if isinstance(st, dict) and vtuple(st.get("seen")) else None


def _write(data, st):
    path = _state_path(data)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = f"{path}.tmp.{os.getpid()}.{threading.get_ident()}"  # 보드 서버는 요청마다 스레드다
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(st, f)
    os.replace(tmp, path)  # 보드와 세션 시작 안내가 따로 쓴다 — 반쯤 쓴 파일을 읽지 않게


def _seen(root, data):
    """(확인 상태, 현재 버전). 상태가 없거나 깨졌으면 현재 버전으로 기록한다."""
    cur = current_version(root)
    st = read_seen(data)
    if st is None and cur:
        st = {"seen": cur}
        try:
            _write(data, st)
        except OSError:
            pass
    return st, cur


def state(root=None, data=None):
    """하네스 안내 맨 위 패널 데이터. unseen이면 from(확인한 버전) → to(현재)의 묶음, 아니면 recent(마지막으로 확인한 범위)."""
    root, data = root or plugin_root(), data or data_dir()
    st, cur = _seen(root, data)
    if not cur:
        return {"ok": True, "current": None, "seen": None, "unseen": False, "recent": None}
    versions = _read_changelog(root)
    seen = st["seen"]
    out = {"ok": True, "current": cur, "seen": seen, "unseen": vtuple(cur) > vtuple(seen)}
    if out["unseen"]:
        out.update({"from": seen, "to": cur, **_range(versions, seen, cur)})
        return out
    top = min((cur, seen), key=vtuple)
    prev = st.get("prev") if vtuple(st.get("prev")) and vtuple(st.get("prev")) < vtuple(top) else None
    if prev is None:  # 확인한 범위를 모르면 그 버전 절 하나, from은 바로 앞 버전
        older = sorted((v["version"] for v in versions if vtuple(v["version"]) < vtuple(top)), key=vtuple)
        recent = {"from": older[-1] if older else None, "to": top, **_range(versions, None, top)}
    else:
        recent = {"from": prev, "to": top, **_range(versions, prev, top)}
    out["recent"] = recent if recent["groups"] else None
    return out


def confirm(to, root=None, data=None):
    """확인한 버전을 to로 올린다. to는 화면이 보여 준 버전 — 페이지를 연 뒤 또 오른 버전까지 확인한 것으로 치지 않는다."""
    root, data = root or plugin_root(), data or data_dir()
    st, cur = _seen(root, data)
    if not vtuple(to) or not cur or vtuple(to) > vtuple(cur):
        return {"ok": False, "message": "확인할 수 없는 버전입니다. 화면을 새로 고친 뒤 다시 확인하세요."}
    if st and vtuple(to) <= vtuple(st["seen"]):
        return {"ok": False, "message": f"이미 v{st['seen']}까지 확인했습니다."}
    new = {"seen": to, "prev": st["seen"]} if st else {"seen": to}
    try:
        _write(data, new)
    except OSError as e:
        return {"ok": False, "message": f"확인한 버전을 기록하지 못했습니다({e.strerror or e}). 데이터 폴더에 쓸 수 있는지 확인한 뒤 다시 누르세요."}
    return {"ok": True, "message": f"v{to}까지 확인했습니다.", "seen": to}


def hint(root=None, data=None):
    """세션 시작 안내용 요약 {from, to, todo}. 올라간 것이 없거나 상태가 없었으면(지금 기록) None."""
    root, data = root or plugin_root(), data or data_dir()
    had = read_seen(data) is not None
    st, cur = _seen(root, data)
    if not had or not cur or vtuple(cur) <= vtuple(st["seen"]):
        return None
    r = _range(_read_changelog(root), st["seen"], cur)
    return {"from": st["seen"], "to": cur, "todo": r["counts"]["todo"]}


if __name__ == "__main__":
    # setup.sh notify가 부른다: python3 changes.py hint [플러그인 루트] [데이터 폴더]
    if len(sys.argv) >= 2 and sys.argv[1] == "hint":
        h = hint(sys.argv[2] if len(sys.argv) > 2 else None, sys.argv[3] if len(sys.argv) > 3 else None)
        if h:
            print(json.dumps(h))
        sys.exit(0)
    print("usage: changes.py hint [plugin root] [data dir]", file=sys.stderr)
    sys.exit(2)
