"""단일 HTML 화면(보드·리포트·기준 화면)과 공용 부품 CSS에서 디자인 규칙(docs/design-system.md) 중
글자로 확인할 수 있는 것만 기계적으로 검사한다. design-system.sh lint 가 부른다.

  1. 미디어 쿼리 폭은 토큰 중단점(--breakpoint-narrow 760px, --breakpoint-wide 1024px)에서 온 값만 쓴다.
     max-width 760·1023, min-width 761·1024 — 규칙 문서 `## 반응형`의 세 구간.
  2. disabled 규칙은 금지 커서(not-allowed)와 흐림 토큰(--opacity-disabled)만 쓴다(`cursor: default` 금지).
  3. 강조 면(background: var(--color-accent)) 위 글자 색은 --color-text-on-accent 다.
  4. notice('danger', …)는 실제 실패를 말할 때만 쓴다. 문구(또는 넘기는 오류 값)에 실패를 뜻하는 말이
     없으면 위반이다. 허용 목록 대신 문구로 보는 까닭: 줄 번호·건수 목록은 고칠 때마다 어긋나고,
     규칙이 묻는 것은 "그 알림이 실패를 말하는가"이기 때문이다.

usage: design-lint.py <root> <file>...   위반이 있으면 줄마다 `path:line: 내용`을 찍고 exit 1.
"""
import re
import sys

ALLOWED_MEDIA = {"max": {760, 1023}, "min": {761, 1024}}
FAILURE_WORDS = re.compile(r"실패|못했|못 했|못함|못 읽|오류|\berr\b|\.err\b|error|Error")

MEDIA_RE = re.compile(r"@media[^{]*?\((max|min)-width:\s*(\d+)px\)")
RULE_RE = re.compile(r"([^{}]+)\{([^{}]*)\}")
COMMENT_RE = re.compile(r"/\*.*?\*/", re.S)
NOT_RE = re.compile(r":not\([^()]*(?:\([^()]*\)[^()]*)*\)")
DANGER_RE = re.compile(r"""notice\(\s*['"]danger['"]\s*,(.*)""")


def line_of(text, pos):
    return text.count("\n", 0, pos) + 1


def blank_comments(text):
    # 위치(줄 번호)를 지키려고 주석을 같은 길이의 공백으로 바꾼다.
    return COMMENT_RE.sub(lambda m: re.sub(r"[^\n]", " ", m.group(0)), text)


def css_regions(path, text):
    if path.endswith(".css"):
        return [(0, text)]
    return [(m.start(1), m.group(1)) for m in re.finditer(r"<style[^>]*>(.*?)</style>", text, re.S)]


def decls(body):
    out = {}
    for part in body.split(";"):
        if ":" in part:
            k, v = part.split(":", 1)
            out[k.strip().lower()] = v.strip()
    return out


def lint_file(rel, text):
    problems = []
    for base, css in css_regions(rel, text):
        css = blank_comments(css)
        for m in MEDIA_RE.finditer(css):
            kind, px = m.group(1), int(m.group(2))
            if px not in ALLOWED_MEDIA[kind]:
                problems.append((line_of(text, base + m.start()), f"@media ({kind}-width: {px}px) — 중단점 토큰 값만 쓴다(max 760·1023, min 761·1024)"))
        for m in RULE_RE.finditer(css):
            sel = m.group(1).strip()
            if sel.startswith("@"):
                continue
            d = decls(m.group(2))
            line = line_of(text, base + m.start(1) + len(m.group(1)) - len(m.group(1).lstrip()))
            bare = NOT_RE.sub("", sel)
            if ":disabled" in bare or 'aria-disabled="true"' in bare:
                if "cursor" in d and d["cursor"] != "not-allowed":
                    problems.append((line, f"{sel} — disabled 커서는 not-allowed (지금 {d['cursor']})"))
                if "opacity" in d and d["opacity"] != "var(--opacity-disabled)":
                    problems.append((line, f"{sel} — disabled 흐림은 var(--opacity-disabled) (지금 {d['opacity']})"))
            bg = d.get("background") or d.get("background-color") or ""
            if bg == "var(--color-accent)" and "color" in d and d["color"] != "var(--color-text-on-accent)":
                problems.append((line, f"{sel} — 강조 면 위 글자는 var(--color-text-on-accent) (지금 {d['color']})"))
    if not rel.endswith(".css"):
        for i, raw in enumerate(text.splitlines(), 1):
            for m in DANGER_RE.finditer(raw):
                if not FAILURE_WORDS.search(m.group(1)):
                    problems.append((i, "notice('danger', …) — 빨강은 실제 실패에만. 실패가 아니면 info·attention"))
    return problems


def main(argv):
    if len(argv) < 3:
        print("usage: design-lint.py <root> <file>...", file=sys.stderr)
        return 2
    root, files = argv[1].rstrip("/"), argv[2:]
    bad = 0
    for rel in files:
        with open(f"{root}/{rel}", encoding="utf-8") as fh:
            text = fh.read()
        for line, msg in lint_file(rel, text):
            print(f"{rel}:{line}: {msg}")
            bad += 1
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
