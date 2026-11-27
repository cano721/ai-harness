#!/usr/bin/env bash
# 회귀 테스트 — 문서 링크·앵커: README.md·CONTRIBUTING.md·docs/**/*.md의 상대 링크가 실제 파일과
# <a id>·heading 앵커에 닿는지(tests/docs-links.py), README 슬림화(#688)의 크기 상한과 옮긴 절 앵커 배치.
# --changed가 경로로 고르도록 대상 문서를 적는다: docs/skills.md docs/workflows.md docs/automation.md docs/board.md
# docs/guards-and-data.md docs/configuration.md docs/design-system.md docs/privacy.md docs/design/workflow-contract.md
# 실행: bash tests/run.sh docs-links
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DL_CHECK=(python3 -I "$ROOT/tests/docs-links.py")

# 검사기 자체: 없는 파일·없는 앵커만 줄 번호와 함께 보고하고, 코드 블록·인라인 코드·외부 URL은 보지 않는다.
DL_FX="$TEST_TMP/links"
mkdir -p "$DL_FX/sub"
cat >"$DL_FX/sub/b.md" <<'EOF'
# B 문서

<a id="kept"></a>

## 같은 제목

## 같은 제목

## `코드` 제목_둘
EOF
cat >"$DL_FX/a.md" <<'EOF'
# A 문서

[있는 파일](sub/b.md) [디렉토리](sub)
[a id 앵커](sub/b.md#kept) [중복 heading](sub/b.md#같은-제목-1) [코드 heading](sub/b.md#코드-제목_둘)
[자기 앵커](#a-문서) [외부](https://example.com/none.md#x) [메일](mailto:a@example.com)
[없는 파일](sub/none.md)
`[인라인 코드](nowhere.md)`

```markdown
[코드 블록](nowhere.md#x)
```

[없는 앵커](sub/b.md#gone)
EOF
DL_OUT="$("${DL_CHECK[@]}" "$DL_FX/a.md" "$DL_FX/sub/b.md" 2>&1)" && fail "broken links make the checker exit 1"
assert_eq "$DL_FX/a.md:6: sub/none.md -> missing file
$DL_FX/a.md:13: sub/b.md#gone -> missing anchor" "$DL_OUT" "only the two broken links are reported with file:line"
sed -i.bak -e 's|sub/none.md|sub/b.md|' -e 's|sub/b.md#gone|sub/b.md#같은-제목|' "$DL_FX/a.md"
"${DL_CHECK[@]}" "$DL_FX/a.md" "$DL_FX/sub/b.md" >/dev/null || fail "fixed links make the checker exit 0"
pass "docs-links checker reports missing files and anchors only"

# 저장소 문서의 상대 링크와 앵커가 모두 닿는다.
DL_FILES=("$ROOT/README.md" "$ROOT/CONTRIBUTING.md")
while IFS= read -r f; do DL_FILES+=("$f"); done <<<"$(find "$ROOT/docs" -name '*.md' | sort)"
DL_OUT="$("${DL_CHECK[@]}" "${DL_FILES[@]}" 2>&1)" || fail "repository docs have broken links: $DL_OUT"
pass "README, CONTRIBUTING and docs links resolve"

# README 크기 상한(#688): 2026-11-27 merge-base README 158173바이트의 1/4(floor).
DL_README_MAX=39543
DL_README_SIZE="$(wc -c <"$ROOT/README.md" | tr -d ' ')"
[ "$DL_README_SIZE" -le "$DL_README_MAX" ] || fail "README.md is $DL_README_SIZE bytes, over $DL_README_MAX"
pass "README stays within a quarter of its pre-#688 size"

# README에 남는 절과 옮긴 절의 앵커 배치(#688): 옮긴 앵커는 지정한 docs 파일에 정확히 한 번, README에는 없다.
DL_README="$(<"$ROOT/README.md")"
for a in overview skills quick-start updates repository; do
  assert_contains "$DL_README" "<a id=\"$a\"></a>" "README keeps the $a anchor"
done
assert_contains "$DL_README" "flowchart LR" "README keeps the overview mermaid"
for pair in skills:skill-catalog skills:design-skills \
  workflows:project-sync workflows:feature-delivery workflows:feature-driver workflows:merge-policy workflows:delivery-level \
  workflows:bug-fix workflows:investigate workflows:design-polish workflows:review \
  automation:self-learning automation:auto-apply automation:llm-digest automation:auto-harvest automation:auto-sync \
  automation:auto-merge automation:autofix board:board \
  guards-and-data:db-scan-guard guards-and-data:stale-reset-guard guards-and-data:data-retention configuration:configuration; do
  doc="${pair%%:*}"
  a="${pair#*:}"
  assert_eq "1" "$(grep -cF "<a id=\"$a\"></a>" "$ROOT/docs/$doc.md")" "docs/$doc.md has the $a anchor once"
  assert_eq "0" "$(grep -cF "<a id=\"$a\"></a>" "$ROOT/README.md")" "README no longer has the $a anchor"
done
pass "moved README anchors live in their docs files"

finish_tests
