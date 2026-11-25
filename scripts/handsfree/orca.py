"""Orca CLI 로 세션 목록·입력·전환·화면 읽기."""
import json
import os
import re
import shutil
import subprocess

from router import squash

ORCA = shutil.which("orca") or os.path.join(
    os.environ.get("ORCA_CLI_BIN_DIR", "/Applications/Orca.app/Contents/Resources/bin"), "orca"
)
OPTION = re.compile(r"^\W*(\d+)\.\s+\S")
SELECTED = re.compile(r"❯\s*\d+\.\s")
RULE = re.compile(r"^\s*[─━═╭╮╰╯┌┐└┘]{10,}\s*$")
TITLED_RULE = re.compile(r"^\s*[─━]{10,}\s.{1,80}\s[─━]+\s*$")
DASHED = re.compile(r"^[\s╌┄┈╍-]{10,}$")
FOOTER = re.compile(r"esc to cancel|enter to (select|confirm)", re.I)


def _run(*args, timeout=15):
    return subprocess.run([ORCA] + list(args), capture_output=True, text=True, timeout=timeout)


def _nodes(node, test):
    if isinstance(node, dict):
        if test(node):
            yield node
        for value in node.values():
            yield from _nodes(value, test)
    elif isinstance(node, list):
        for value in node:
            yield from _nodes(value, test)


def sessions():
    """화면 탭 순서대로 [{handle, title, tab, active}]. 탭마다 활성 터미널 하나.
    active 는 Orca 가 앞에 띄운 탭이다. 화면이 여러 칸으로 나뉘어 앞 탭이 둘 이상이면 어느 쪽도 고르지 않는다."""
    data = json.loads(_run("terminal", "list", "--json", "--include-visual-layouts").stdout or "{}").get("result", {})
    result = []
    groups = list(_nodes(data.get("visualLayouts", []), lambda n: isinstance(n.get("tabs"), list)))
    for group in groups:
        for tab in group["tabs"]:
            terms = list(_nodes(tab.get("panes"), lambda n: n.get("type") == "terminal" and n.get("handle")))
            if not terms:
                continue
            term = next((t for t in terms if t.get("leafId") == tab.get("activeLeafId")), terms[0])
            result.append({"handle": term["handle"], "title": term.get("title", ""), "tab": tab.get("title", ""),
                           "active": len(groups) == 1 and tab.get("tabId") == group.get("activeTabId")})
    if result:
        return result
    return [
        {"handle": t["handle"], "title": t.get("title", ""), "tab": t.get("title", ""), "active": False}
        for t in data.get("terminals", [])
    ]


def label(session):
    return session["tab"] or session["title"]


def find_by_name(name, items):
    """이름이 탭·터미널 제목에 들어 있는 세션. 하나로 좁혀질 때만 돌려준다."""
    key = squash(name)
    if len(key) < 2:
        return None
    hits = [s for s in items if key in squash(s["tab"]) or key in squash(s["title"])]
    return hits[0] if len(hits) == 1 else None


def send(handle, text, enter=False):
    args = ["terminal", "send", "--terminal", handle, "--text", text, "--json"]
    if enter:
        args.append("--enter")
    proc = _run(*args)
    return proc.returncode == 0 and '"accepted": true' in proc.stdout


def switch(handle):
    return _run("terminal", "switch", "--terminal", handle).returncode == 0


def screen(handle):
    """렌더링된 화면 글자. 읽지 못했으면 None — 창이 없다고 단정하면 안 되므로 빈 문자열과 구분한다."""
    try:
        proc = _run("terminal", "read", "--terminal", handle, "--screen", "--limit", "80")
    except (subprocess.TimeoutExpired, OSError):
        return None
    head, sep, body = proc.stdout.partition("\n\n")
    if proc.returncode != 0 or not sep or not re.search(r"^source: screen$", head, flags=re.M):
        return None
    return body


def dialog(screen_text):
    """승인 창·선택지가 떠 있으면 {"text", "options": {번호: 문구}, "selected": 번호}, 없으면 None.

    고른 줄(❯ 1.)만 보면 대화 내용에 찍힌 같은 글자에 속는다. 창 맨 아래 안내 줄까지 있어야 창으로 본다.
    """
    lines = (screen_text or "").splitlines()
    footers = [i for i, line in enumerate(lines) if FOOTER.search(line)]
    if not footers:
        return None
    end = footers[-1]
    if any(line.strip() for line in lines[end + 1:]):
        return None
    start = end
    while start > 0 and end - start < 60 and not RULE.match(lines[start - 1]):
        start -= 1
    raw = [line for line in lines[start:end] if line.strip() and not DASHED.match(line)]
    block = [re.sub(r"[│┃❯]", " ", line).strip() for line in raw]
    picked = next((i for i in range(len(raw) - 1, -1, -1) if SELECTED.search(raw[i])), None)
    if picked is None:
        return None
    # 미리보기 안의 번호 목록을 선택지로 착각하지 않게, 고른 줄에서 위로 올라가며 가장 가까운 1번을 찾는다.
    first = next((i for i in range(picked, -1, -1)
                  if OPTION.match(block[i]) and OPTION.match(block[i]).group(1) == "1"), None)
    if first is None:
        return None
    options, number = {}, None
    for line in block[first:]:
        m = OPTION.match(line)
        if m:
            number = int(m.group(1))
            options[number] = line
        elif number is not None:
            options[number] += " " + line
    # 미리보기(파일 내용·diff)는 길어서 제목과 질문, 선택지만 읽는다.
    head = block[:min(3, first)]
    question = block[max(len(head), first - 1):first]
    return {"text": " / ".join(head + question + block[first:])[:700], "full": " ".join(block)[:4000],
            "ask": " · ".join(head + question)[:200],
            "options": options,
            "selected": int(OPTION.match(block[picked]).group(1)) if OPTION.match(block[picked]) else None}


def input_ready(screen_text):
    """Claude Code 입력 칸(구분선 / ❯ / 구분선)이 화면 맨 아래에 보이면 True.

    승인 창을 못 알아본 화면에 글자와 엔터를 보내면 엔터가 승인으로 먹는다. 그래서 "창이 없다"가 아니라
    "입력 칸이 보인다"를 확인한 뒤에만 보낸다. 모르는 모양이면 보내지 않는 쪽으로 틀린다.
    """
    lines = (screen_text or "").splitlines()[-20:]
    # 세션에 이름을 붙이면 윗 구분선 끝에 제목이 들어간다("──── 결제 작업 ─").
    rules = [i for i, line in enumerate(lines) if RULE.match(line) or TITLED_RULE.match(line)]
    if len(rules) < 2:
        return False
    top, bottom = rules[-2], rules[-1]
    inside = [line for line in lines[top + 1:bottom] if line.strip()]
    below = [line for line in lines[bottom + 1:] if line.strip()]
    return bool(inside) and inside[0].lstrip().startswith("❯") and len(below) <= 5


def state_of(screen_text):
    if screen_text is None:
        return "확인 불가"
    if dialog(screen_text):
        return "승인 대기"
    tail = "\n".join(screen_text.splitlines()[-25:])
    return "작업 중" if "esc to interrupt" in tail else "대기"
