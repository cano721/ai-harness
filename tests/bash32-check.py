"""macOS 기본 bash 3.2가 잘못 펼치는 따옴표 패턴을 찾는다.

bash 3.2는 큰따옴표로 감싼 명령 치환 "...$(...)" 이 명령 인자일 때, 그 안의 큰따옴표 문자열에 든
쉼표 있는 중괄호 {a, b} 를 중괄호 확장으로 펼친다(bash 4+ 와 CI 의 ubuntu bash 5 는 펼치지 않는다).
  echo "$(node -e "f({ a: 1, b: 2 })")"   → node 가 f( a: 1) 와 f( b: 2 ) 를 따로 받는다
변수 대입(x="$(...)")과 [[ ]] 안, 작은따옴표 문자열은 안전하다.
고치는 법: 안쪽 문자열을 먼저 변수에 담거나(js='...') 작은따옴표로 쓰고 환경변수로 넘긴다.

사용: python3 -I tests/bash32-check.py FILE...   (찾으면 FILE:줄 을 찍고 1로 끝난다)
"""
import re
import sys

HEREDOC = re.compile(r"<<-?[ \t]*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")
ASSIGN_BEFORE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?\+?=$")


def scan(text):
    """경고할 줄 번호 목록."""
    hits = []
    stack = []  # 'dq' | 'cmd' | 'param' — 각 항목은 (kind, safe_context)
    pending_heredocs = []
    i, n, line = 0, len(text), 1
    brace = None  # (줄, 쉼표 봤나) — 위험한 큰따옴표 안의 { 위치

    def top():
        return stack[-1][0] if stack else "top"

    def risky_dq():
        # 안쪽 dq 가 cmd 안에 있고, 그 cmd 가 명령 인자로 쓰인 바깥 dq 안에 있을 때
        kinds = [k for k, _ in stack]
        for j in range(len(kinds) - 1, 1, -1):
            if kinds[j] == "dq" and kinds[j - 1] == "cmd" and kinds[j - 2] == "dq" and not stack[j - 2][1]:
                return True
        return False

    def line_start(pos):
        return text.rfind("\n", 0, pos) + 1

    while i < n:
        c = text[i]
        state = top()
        if c == "\\":
            line += text.startswith("\n", i + 1)
            i += 2
            continue
        if c == "\n":
            line += 1
            i += 1
            if pending_heredocs and state in ("top", "cmd"):
                for delim, strip in pending_heredocs:
                    while i < n:
                        end = text.find("\n", i)
                        end = n if end < 0 else end
                        body = text[i:end]
                        i = end + 1
                        line += 1
                        if (body.lstrip("\t") if strip else body) == delim:
                            break
                pending_heredocs = []
            continue
        if state in ("top", "cmd"):
            if c == "#" and (i == 0 or text[i - 1] in " \t\n;(|&"):
                end = text.find("\n", i)
                i = n if end < 0 else end
                continue
            if c == "'":
                end = text.find("'", i + 1)
                end = n if end < 0 else end
                line += text.count("\n", i, end)
                i = end + 1
                continue
            if text.startswith("$'", i):
                j = i + 2
                while j < n and text[j] != "'":
                    j += 2 if text[j] == "\\" else 1
                line += text.count("\n", i, j)
                i = j + 1
                continue
            if c == "<" and text.startswith("<<", i) and not text.startswith("<<<", i):
                m = HEREDOC.match(text, i)
                if m:
                    pending_heredocs.append((m.group(2), text.startswith("<<-", i)))
                    i = m.end()
                    continue
            if c == '"':
                before = text[line_start(i):i]
                safe = bool(ASSIGN_BEFORE.search(before.split()[-1] if before.split() else "")) or "[[" in before
                stack.append(("dq", safe))
                i += 1
                continue
            if text.startswith("$(", i):
                stack.append(("cmd", False))
                i += 2
                continue
            if c == "(" and state == "cmd":
                stack.append(("cmd", False))
                i += 1
                continue
            if c == ")" and state == "cmd":
                stack.pop()
                i += 1
                continue
            if text.startswith("${", i):
                stack.append(("param", False))
                i += 2
                continue
            i += 1
            continue
        if state == "param":
            if c == "{":
                stack.append(("param", False))
            elif c == "}":
                stack.pop()
            elif c == "\n":
                line += 1
            i += 1
            continue
        # dq
        if c == '"':
            stack.pop()
            brace = None
            i += 1
            continue
        if text.startswith("$(", i):
            stack.append(("cmd", False))
            brace = None
            i += 2
            continue
        if text.startswith("${", i):
            stack.append(("param", False))
            i += 2
            continue
        if c == "{" and risky_dq():
            brace = (line, False)
        elif c == "," and brace:
            brace = (brace[0], True)
        elif c == "}" and brace:
            if brace[1]:
                hits.append(brace[0])
            brace = None
        i += 1
    return hits


def main(paths):
    rc = 0
    for path in paths:
        with open(path, encoding="utf-8", errors="replace") as f:
            for ln in sorted(set(scan(f.read()))):
                print(f"{path}:{ln}: bash 3.2가 \"$(... \"{{a, b}}\" ...)\" 안 중괄호를 펼친다 — 안쪽 문자열을 변수·작은따옴표로 옮긴다")
                rc = 1
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
