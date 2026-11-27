"""마크다운 상대 링크·앵커 검사기 (#688).

README를 docs/ 주제별 문서로 나눈 뒤 파일 사이 링크와 앵커가 깨지지 않게 한다.
인자로 받은 .md 파일의 인라인 링크 `](path)`·`](path#anchor)`·`](#anchor)`가
실제 파일·디렉토리와 `<a id="…">` 또는 GitHub heading slug에 닿는지 본다.
펜스 코드 블록·인라인 코드 안의 링크와 외부 스킴(http·mailto 등)은 보지 않는다.
깨진 링크마다 `<파일>:<줄>: <링크> -> missing file|missing anchor`를 내고 exit 1, 없으면 exit 0.
표준 라이브러리만 쓴다(`python3 -I tests/docs-links.py <file.md>...`).
"""
import os
import re
import sys
import urllib.parse

LINK = re.compile(r"\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)")
FENCE = re.compile(r"^\s*(```|~~~)")
INLINE_CODE = re.compile(r"(`+)(?:(?!\1).)+?\1")
SCHEME = re.compile(r"^[A-Za-z][A-Za-z0-9+.-]*:")
A_ID = re.compile(r"<a\s+(?:[^>]*\s)?(?:id|name)=\"([^\"]+)\"")
HEADING = re.compile(r"^\s{0,3}#{1,6}\s+(.*?)\s*#*\s*$")


def body_lines(path):
    """펜스 코드 블록 밖의 (줄 번호, 줄)만 낸다."""
    in_fence = None
    with open(path, encoding="utf-8") as f:
        for n, line in enumerate(f, 1):
            m = FENCE.match(line)
            if m:
                if in_fence is None:
                    in_fence = m.group(1)
                elif m.group(1) == in_fence:
                    in_fence = None
                continue
            if in_fence is None:
                yield n, line.rstrip("\n")


def slug(text):
    text = re.sub(r"<[^>]+>", "", text).replace("`", "").lower()
    text = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", text)
    text = "".join(c for c in text if c.isalnum() or c in " -_")
    return text.replace(" ", "-")


_anchor_cache = {}


def anchors(path):
    if path not in _anchor_cache:
        found, seen = set(), {}
        for _, line in body_lines(path):
            found.update(A_ID.findall(line))
            m = HEADING.match(line)
            if m:
                s = slug(m.group(1))
                if s in seen:
                    seen[s] += 1
                    found.add(f"{s}-{seen[s]}")
                else:
                    seen[s] = 0
                    found.add(s)
        _anchor_cache[path] = found
    return _anchor_cache[path]


def check(path):
    errors = []
    base = os.path.dirname(path)
    for n, line in body_lines(path):
        for m in LINK.finditer(INLINE_CODE.sub("", line)):
            target = m.group(1).strip("<>")
            if SCHEME.match(target):
                continue
            file_part, _, anchor = target.partition("#")
            dest = os.path.normpath(os.path.join(base, urllib.parse.unquote(file_part))) if file_part else path
            if not os.path.exists(dest):
                errors.append(f"{path}:{n}: {target} -> missing file")
                continue
            if anchor and dest.endswith(".md") and os.path.isfile(dest):
                if urllib.parse.unquote(anchor) not in anchors(dest):
                    errors.append(f"{path}:{n}: {target} -> missing anchor")
    return errors


def main(argv):
    if not argv:
        print("usage: docs-links.py <file.md>...", file=sys.stderr)
        return 2
    errors = [e for p in argv for e in check(p)]
    for e in errors:
        print(e)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
