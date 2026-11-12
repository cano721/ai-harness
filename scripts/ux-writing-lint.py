#!/usr/bin/env python3
"""UX 라이팅 규칙 문서(.ai-harness/docs/ux-writing.md)로 화면 문구를 결정적으로 검사한다.

스크립트는 기계가 틀리지 않는 것만 본다: 용어집·금지 표현의 문자열 일치와, 문서가 정한 종결 어미
(해요체/합니다체)와 다른 문장. 버튼이 동작을 드러내는지, 사용자 관점인지 같은 맥락 판단은
ux-writing-audit 스킬의 LLM 검토 몫이다(#293). 같은 입력이면 같은 결과를 낸다.

  check   --text TEXT | --file PATH | --diff [BASE] | --diff-file PATH   위반 표 출력
  extract [PATH...]                                                      기존 문구 실측(빌더용)

종료 코드: 0 위반 없음, 1 위반 있음, 2 잘못된 인자, 3 규칙 문서 없음(미채점).
"""
import argparse
import json
import os
import re
import subprocess
import sys

DEFAULT_DOC = ".ai-harness/docs/ux-writing.md"
HANGUL = re.compile(r"[가-힣]")
LETTER = re.compile(r"[A-Za-z가-힣]")
QUOTED = re.compile(r"\"((?:[^\"\\]|\\.)*)\"|'((?:[^'\\]|\\.)*)'|`([^`]*)`")
JSX_TEXT = re.compile(r">([^<>{}]*[A-Za-z가-힣][^<>{}]*)<")
SENTENCE_SPLIT = re.compile(r"(?<=[.!?。])\s+|\n")
TRAILING = re.compile(r"[\s.!?…~:;,)\]\"'”’>]+$")
FORMAL_END = re.compile(r"(니다|니까)$")
POLITE_END = re.compile(r"(요|죠)$")
# '요'로 끝나지만 종결 어미가 아닌 명사
NOT_ENDING_YO = {"필요", "중요", "주요", "개요", "수요", "소요", "강요", "요요", "불필요", "기요"}
STYLE_ALIASES = {
    "해요체": "polite", "polite": "polite",
    "합니다체": "formal", "formal": "formal",
}
TEXT_EXTS = {"", ".md", ".txt", ".markdown"}
HASH_COMMENT_EXTS = {".py", ".sh", ".rb", ".yml", ".yaml", ".toml", ".properties", ".conf"}
UI_EXTS = {
    ".tsx", ".jsx", ".ts", ".js", ".vue", ".svelte", ".html", ".htm", ".json", ".yml", ".yaml",
    ".properties", ".strings", ".xml", ".kt", ".java", ".swift", ".dart", ".erb", ".jinja",
    ".j2", ".hbs", ".php", ".jsp", ".ftl", ".mustache", ".arb", ".po",
}
SKIP_DIRS = ("node_modules/", "dist/", "build/", ".next/", "vendor/", "coverage/", ".git/")
SKIP_PARTS = ("test", "spec", "__tests__", "fixture", "mock", "stories")


def section_key(title):
    title = re.sub(r"\(.*?\)", "", title).strip().lower()
    return title


def parse_doc(path):
    """규칙 문서에서 기계가 읽는 항목만 뽑는다: 금지어 → 표준어, 종결 어미."""
    sections = {}
    current = None
    with open(path, encoding="utf-8") as fh:
        for raw in fh:
            line = raw.rstrip("\n")
            m = re.match(r"^##\s+(.+?)\s*$", line)
            if m and not line.startswith("###"):
                current = section_key(m.group(1))
                sections.setdefault(current, [])
                continue
            if current is not None:
                sections[current].append(line)

    def pick(*names):
        for name in names:
            if name in sections:
                return sections[name]
        return []

    terms = []
    rows = [l for l in pick("용어집", "glossary") if l.strip().startswith("|")]
    if rows:
        header = [c.strip().lower() for c in rows[0].strip().strip("|").split("|")]
        pref_i = next((i for i, c in enumerate(header) if c in ("표준어", "preferred")), None)
        forb_i = next((i for i, c in enumerate(header) if c in ("금지어", "forbidden")), None)
        if pref_i is not None and forb_i is not None:
            for row in rows[1:]:
                cells = [c.strip() for c in row.strip().strip("|").split("|")]
                if len(cells) <= max(pref_i, forb_i) or set(cells[0]) <= set("-: "):
                    continue
                for bad in re.split(r"[,、·/]", cells[forb_i]):
                    bad = bad.strip().strip("`")
                    if bad:
                        terms.append((bad, cells[pref_i].strip("`"), "용어집"))
    for line in pick("금지 표현", "금지어", "prohibited terms", "prohibited"):
        m = re.match(r"^\s*[-*]\s+(.+?)\s*$", line)
        if not m or m.group(1).startswith("<!--"):
            continue
        parts = re.split(r"\s*(?:→|->)\s*", m.group(1), maxsplit=1)
        bad = parts[0].strip().strip("`")
        if bad:
            terms.append((bad, parts[1].strip().strip("`") if len(parts) > 1 else "", "금지 표현"))

    style = None
    for line in pick("문체", "language and style", "style"):
        m = re.match(r"^\s*[-*]\s*(종결\s*어미|sentence\s*ending)\s*:\s*([^<\s]+)", line, re.I)
        if m:
            style = STYLE_ALIASES.get(m.group(2).strip().lower())
    return {"terms": terms, "style": style}


# 개발자만 보는 문자열: 로그·예외·단언. 사용자 화면 문구가 아니다.
DEV_ONLY = re.compile(r"\b(console|logger|log|Log|warn|debug)\s*[.(]|\bthrow\b|\bassert\w*\s*\(|\bnew\s+\w*Error\s*\(")
# 상수·클래스 이름(FOO_BAR, FooBar_Baz)이 들어간 조각은 개발자 설명이다.
IDENTIFIER = re.compile(r"\b[A-Z][A-Z0-9]+_[A-Z0-9_]+\b|\b[a-z]+[A-Z]\w*\s*[:=(]")


def is_comment(stripped, ext):
    if stripped.startswith(("//", "/*", "*", "<!--", "{/*")):
        return True
    return stripped.startswith("#") and ext in HASH_COMMENT_EXTS


def segments(line, ext):
    """한 줄에서 사람이 읽는 문구 조각만 꺼낸다. 식별자·경로·키는 버린다."""
    stripped = line.strip()
    if not stripped or is_comment(stripped, ext):
        return []
    if ext not in TEXT_EXTS and DEV_ONLY.search(stripped):
        return []
    if ext in TEXT_EXTS:
        return [stripped]
    found = []
    for m in QUOTED.finditer(line):
        found.append(next(g for g in m.groups() if g is not None))
    found.extend(m.group(1) for m in JSX_TEXT.finditer(line))
    out = []
    for seg in found:
        seg = seg.strip()
        if not LETTER.search(seg):
            continue
        if not HANGUL.search(seg) and " " not in seg:
            continue  # 영문 한 단어는 키·클래스명·경로일 가능성이 높다
        if IDENTIFIER.search(seg):
            continue
        out.append(seg)
    return out


def sentence_style(sentence):
    tail = TRAILING.sub("", sentence)
    if not HANGUL.search(tail[-1:] if tail else ""):
        return None
    if FORMAL_END.search(tail):
        return "formal"
    if POLITE_END.search(tail):
        last_word = tail.split()[-1] if tail.split() else tail
        if last_word in NOT_ENDING_YO:
            return None
        return "polite"
    return None


JOSA_PAIRS = (("을", "를"), ("이", "가"), ("은", "는"), ("과", "와"), ("이랑", "랑"), ("으로", "로"))


def has_batchim(word):
    ch = word[-1:] if word else ""
    return bool(ch) and "가" <= ch <= "힣" and (ord(ch) - 0xAC00) % 28 != 0


def fix_josa(word, josa):
    """바꾼 낱말 뒤 조사를 받침에 맞춘다(공고을 → 공고를)."""
    for with_b, without_b in JOSA_PAIRS:
        if josa in (with_b, without_b):
            if with_b == "으로" and word and (ord(word[-1]) - 0xAC00) % 28 == 8:
                return "로"  # ㄹ 받침은 '로'
            return with_b if has_batchim(word) else without_b
    return josa


def replace_term(seg, bad, good):
    pattern = re.compile(re.escape(bad) + r"(?:(으로|이랑|을|를|이|가|은|는|과|와|랑|로)(?![가-힣]))?", re.I)
    return pattern.sub(lambda m: good + (fix_josa(good, m.group(1)) if m.group(1) else ""), seg)


def check_segment(seg, rules):
    found = []
    low = seg.lower()
    for bad, good, origin in rules["terms"]:
        if bad.lower() in low:
            fix = replace_term(seg, bad, good) if good else ""
            rule = f"{origin}: '{bad}'" + (f" → '{good}'" if good else " 사용 금지")
            found.append((fix, rule))
    want = rules["style"]
    if want:
        for sentence in SENTENCE_SPLIT.split(seg):
            got = sentence_style(sentence.strip())
            if got and got != want:
                name = "해요체" if want == "polite" else "합니다체"
                found.append(("", f"종결 어미: {name}로 통일 ('{TRAILING.sub('', sentence.strip())[-6:]}')"))
    return found


def iter_lines(args, root):
    """(위치, 확장자, 줄) 을 낸다. diff는 추가된 줄만 새 파일 기준 줄번호로."""
    if args.text is not None:
        for i, line in enumerate(args.text.splitlines(), 1):
            yield f"text:{i}", "", line
        return
    if args.file:
        path = args.file if os.path.isabs(args.file) else os.path.join(root, args.file)
        ext = os.path.splitext(path)[1].lower()
        rel = os.path.relpath(path, root)
        with open(path, encoding="utf-8", errors="replace") as fh:
            for i, line in enumerate(fh, 1):
                yield f"{rel}:{i}", ext, line.rstrip("\n")
        return
    if args.diff_file:
        with open(args.diff_file, encoding="utf-8", errors="replace") as fh:
            diff = fh.read()
    else:
        cmd = ["git", "-C", root, "diff", "--no-ext-diff", "--no-color", "--unified=0"]
        if args.diff:
            cmd.append(args.diff)
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
        if res.returncode != 0:
            sys.stderr.write(res.stderr)
            sys.exit(2)
        diff = res.stdout
    path, lineno = "", 0
    for line in diff.splitlines():
        if line.startswith("+++ "):
            path = line[4:].strip()
            path = path[2:] if path.startswith("b/") else path
            continue
        m = re.match(r"^@@ -\S+ \+(\d+)", line)
        if m:
            lineno = int(m.group(1))
            continue
        if line.startswith("+") and path and path != "/dev/null":
            yield f"{path}:{lineno}", os.path.splitext(path)[1].lower(), line[1:]
            lineno += 1


def cell(text):
    return text.replace("|", "\\|").replace("\n", " ") or "—"


def cmd_check(args):
    root = os.path.abspath(args.root)
    doc = args.doc if os.path.isabs(args.doc) else os.path.join(root, args.doc)
    if not os.path.isfile(doc):
        msg = f"미채점: UX 라이팅 규칙 문서가 없습니다 ({os.path.relpath(doc, root)}). /ux-writing-builder로 먼저 만드세요."
        print(json.dumps({"scored": False, "reason": msg}, ensure_ascii=False) if args.json else msg)
        return 3
    rules = parse_doc(doc)
    findings = []
    for where, ext, line in iter_lines(args, root):
        for seg in segments(line, ext):
            for fix, rule in check_segment(seg, rules):
                findings.append({"where": where, "text": seg, "fix": fix, "rule": rule})
    if args.json:
        print(json.dumps({"scored": True, "rules": {"terms": len(rules["terms"]), "style": rules["style"]},
                          "findings": findings}, ensure_ascii=False, indent=2))
    else:
        print("| 위치 | 원문 | 수정안 | 위반 규칙 |")
        print("|---|---|---|---|")
        for f in findings:
            print(f"| {cell(f['where'])} | {cell(f['text'])} | {cell(f['fix'])} | {cell(f['rule'])} |")
        style = {"polite": "해요체", "formal": "합니다체"}.get(rules["style"], "지정 안 함")
        print(f"\n결정적 위반 {len(findings)}건 (용어 규칙 {len(rules['terms'])}개, 종결 어미 {style})")
    return 1 if findings else 0


def ui_files(root, paths):
    if paths:
        res = subprocess.run(["git", "-C", root, "ls-files", "--", *paths], capture_output=True, text=True, timeout=60)
    else:
        res = subprocess.run(["git", "-C", root, "ls-files"], capture_output=True, text=True, timeout=60)
    for rel in res.stdout.splitlines():
        low = rel.lower()
        if os.path.splitext(low)[1] not in UI_EXTS or any(d in low for d in SKIP_DIRS):
            continue
        if any(p in part for part in low.split("/") for p in SKIP_PARTS):
            continue
        yield rel


def cmd_extract(args):
    """빌더가 근거로 쓰는 기존 문구 실측: 종결 어미 분포와 문구 목록(위치 포함)."""
    root = os.path.abspath(args.root)
    counts = {"polite": [], "formal": []}
    items = []
    for rel in ui_files(root, args.paths):
        ext = os.path.splitext(rel)[1].lower()
        try:
            with open(os.path.join(root, rel), encoding="utf-8", errors="replace") as fh:
                lines = fh.read().splitlines()
        except OSError:
            continue
        for i, line in enumerate(lines, 1):
            for seg in segments(line, ext):
                if not HANGUL.search(seg):
                    continue
                where = f"{rel}:{i}"
                items.append({"where": where, "text": seg})
                for sentence in SENTENCE_SPLIT.split(seg):
                    style = sentence_style(sentence.strip())
                    if style:
                        counts[style].append({"where": where, "text": seg})
    if args.json:
        print(json.dumps({"segments": len(items), "polite": len(counts["polite"]), "formal": len(counts["formal"]),
                          "items": items[: args.limit]}, ensure_ascii=False, indent=2))
        return 0
    print(f"한글 문구 {len(items)}개 · 해요체 문장 {len(counts['polite'])} · 합니다체 문장 {len(counts['formal'])}")
    for key, name in (("polite", "해요체"), ("formal", "합니다체")):
        for ex in counts[key][:5]:
            print(f"  {name} 예: {ex['where']}  {ex['text']}")
    print()
    for it in items[: args.limit]:
        print(f"{it['where']}\t{it['text']}")
    if len(items) > args.limit:
        print(f"... {len(items) - args.limit}개 더 (--limit로 늘림)")
    return 0


def main(argv):
    parser = argparse.ArgumentParser(prog="ux-writing-lint.py", description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="cmd")
    chk = sub.add_parser("check", help="규칙 문서로 문구 검사")
    chk.add_argument("--root", default=".")
    chk.add_argument("--doc", default=DEFAULT_DOC)
    chk.add_argument("--json", action="store_true")
    src = chk.add_mutually_exclusive_group(required=True)
    src.add_argument("--text")
    src.add_argument("--file")
    src.add_argument("--diff", nargs="?", const="", metavar="BASE")
    src.add_argument("--diff-file")
    ext = sub.add_parser("extract", help="기존 문구 실측")
    ext.add_argument("--root", default=".")
    ext.add_argument("--limit", type=int, default=300)
    ext.add_argument("--json", action="store_true")
    ext.add_argument("paths", nargs="*")
    try:
        args = parser.parse_args(argv)
    except SystemExit as exc:
        return 2 if exc.code else 0
    if args.cmd == "check":
        return cmd_check(args)
    if args.cmd == "extract":
        return cmd_extract(args)
    parser.print_usage(sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
