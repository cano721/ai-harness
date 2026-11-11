#!/usr/bin/env python3
"""디자인 토큰의 색 대비를 계산으로 검사한다 (WCAG 2.2 상대 휘도 공식).

독립 디자인 리뷰에서 다크 테마의 채운 버튼 대비 1.74:1, 경계 대비 1.25:1 이 나왔다 — 눈으로 고른 색은
테마 하나에서만 맞기 쉽다. 그래서 규칙 문서가 쓰는 전경/배경 쌍을 contrast-pairs.tsv 에 적어 두고,
tokens.css 의 라이트·다크 값으로 전부 계산해 기준에 못 미치면 실패한다.

사용: design-contrast.py <tokens.css> <contrast-pairs.tsv> [--md]
종료 코드: 0 전부 통과, 1 기준 미달 또는 토큰 정의 오류, 2 사용법 오류.
표준 라이브러리만 쓴다.
"""
import re
import sys

DECL = re.compile(r"^\s*(--[a-z0-9-]+):\s*(.+?);\s*$")
VAR = re.compile(r"^var\((--[a-z0-9-]+)\)$")
HEX = re.compile(r"^#[0-9a-fA-F]{6}$")


def parse_tokens(path):
    """블록별 선언을 읽는다: light(:root), dark_media(@media … dark), dark_attr([data-theme="dark"])."""
    blocks = {"light": {}, "dark_media": {}, "dark_attr": {}}
    current = None
    in_dark_media = False
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            stripped = line.strip()
            if stripped.startswith("@media") and "prefers-color-scheme: dark" in stripped:
                in_dark_media = True
                continue
            if stripped.endswith("{"):
                if in_dark_media:
                    current = "dark_media"
                elif 'data-theme="dark"' in stripped:
                    current = "dark_attr"
                elif stripped.startswith(":root"):
                    current = "light"
                else:
                    current = None
                continue
            if stripped == "}":
                if current is None and in_dark_media:
                    in_dark_media = False
                current = None
                continue
            match = DECL.match(line)
            if match and current:
                blocks[current][match.group(1)] = match.group(2).strip()
    return blocks


def resolve(name, table, seen=()):
    if name in seen:
        raise ValueError("순환 참조: " + " → ".join(seen + (name,)))
    if name not in table:
        raise ValueError("정의되지 않은 토큰: " + name)
    value = table[name]
    ref = VAR.match(value)
    if ref:
        return resolve(ref.group(1), table, seen + (name,))
    return value


def luminance(hex_color):
    channels = [int(hex_color[i:i + 2], 16) / 255 for i in (1, 3, 5)]
    linear = [c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4 for c in channels]
    return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]


def contrast(first, second):
    high, low = sorted((luminance(first), luminance(second)), reverse=True)
    return (high + 0.05) / (low + 0.05)


def read_pairs(path):
    pairs = []
    with open(path, encoding="utf-8") as handle:
        for number, line in enumerate(handle, 1):
            line = line.rstrip("\n")
            if not line.strip() or line.startswith("#"):
                continue
            cells = line.split("\t")
            if len(cells) < 4:
                raise ValueError("%s:%d 열이 4개(전경, 배경, 최소 대비, 용도)여야 한다" % (path, number))
            pairs.append((cells[0], cells[1], float(cells[2]), cells[3]))
    return pairs


def main(argv):
    args = [a for a in argv[1:] if a != "--md"]
    markdown = "--md" in argv[1:]
    if len(args) != 2:
        sys.stderr.write("usage: design-contrast.py <tokens.css> <contrast-pairs.tsv> [--md]\n")
        return 2
    blocks = parse_tokens(args[0])
    problems = []
    if blocks["dark_media"] != blocks["dark_attr"]:
        names = sorted(set(blocks["dark_media"].items()) ^ set(blocks["dark_attr"].items()))
        problems.append("다크 블록 두 개(@media, [data-theme=\"dark\"])가 다르다: "
                        + ", ".join(sorted({name for name, _ in names})))
    missing = sorted(n for n in blocks["light"] if n.startswith("--color-") and n not in blocks["dark_attr"])
    if missing:
        problems.append("다크 값이 없는 색 토큰: " + ", ".join(missing))
    themes = {"light": blocks["light"], "dark": dict(blocks["light"], **blocks["dark_attr"])}

    rows = []
    try:
        pairs = read_pairs(args[1])
    except (OSError, ValueError) as error:
        sys.stderr.write("%s\n" % error)
        return 1
    for theme in ("light", "dark"):
        table = themes[theme]
        for fg_name, bg_name, minimum, use in pairs:
            try:
                fg, bg = resolve(fg_name, table), resolve(bg_name, table)
            except ValueError as error:
                problems.append("%s: %s" % (theme, error))
                continue
            if not (HEX.match(fg) and HEX.match(bg)):
                problems.append("%s: %s / %s 는 #rrggbb 로 풀려야 계산할 수 있다" % (theme, fg_name, bg_name))
                continue
            ratio = contrast(fg, bg)
            # 표시는 내림해서 보여 준다 — 4.496 이 4.50 으로 보이며 통과처럼 읽히지 않게.
            shown = int(ratio * 100) / 100
            passed = ratio >= minimum
            rows.append((theme, fg_name, bg_name, shown, minimum, passed, use))
            if not passed:
                problems.append("%s: %s on %s = %.2f:1 (기준 %s:1) — %s"
                                % (theme, fg_name, bg_name, shown, ("%g" % minimum), use))

    if markdown:
        print("| 테마 | 전경 | 배경 | 대비 | 기준 | 결과 | 용도 |")
        print("|---|---|---|---|---|---|---|")
        for theme, fg_name, bg_name, shown, minimum, passed, use in rows:
            print("| %s | `%s` | `%s` | %.2f:1 | %g:1 | %s | %s |"
                  % (theme, fg_name, bg_name, shown, minimum, "통과" if passed else "미달", use))
    else:
        for theme, fg_name, bg_name, shown, minimum, passed, use in rows:
            print("%s\t%s\t%s\t%.2f\t%g\t%s\t%s"
                  % (theme, fg_name, bg_name, shown, minimum, "ok" if passed else "FAIL", use))
    worst = {}
    for theme, _, _, shown, minimum, _, _ in rows:
        key = (theme, minimum)
        worst[key] = min(worst.get(key, shown), shown)
    for (theme, minimum), value in sorted(worst.items()):
        line = "%s: 기준 %g:1 쌍의 최저 대비 %.2f:1" % (theme, minimum, value)
        print(("\n" + line) if markdown else "# " + line)
    if problems:
        for problem in problems:
            sys.stderr.write("FAIL %s\n" % problem)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
