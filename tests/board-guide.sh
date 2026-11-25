#!/usr/bin/env bash
# 회귀 테스트 — Harness Board 하네스 안내 화면(기능 목록·첫 단계·기능 카드 실행·버전 안내)
# 실행: bash tests/run.sh board-guide
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-board.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-board.sh"

# 하네스 안내(#432): 기능 목록은 저장소(skills·templates·agents·catalog)에서 읽고, 화면 문구는 guide.json에서 붙인다.
# 저장소의 기능과 guide.json이 어긋나면 여기서 실패한다 — 새 스킬을 더하면 guide.json에 이름·요약을 함께 적는다.
python3 -I -B -c '
import sys
sys.path.insert(0, sys.argv[1] + "/scripts/board")
import guide
root = sys.argv[1]
cov = guide.coverage(root)
assert cov == {"unlisted": [], "stale": []}, cov
st = guide.state(root)
assert st["ok"] is True
items = {i["id"]: i for g in st["groups"] for i in g["items"]}
assert all(g["label"] and g["items"] for g in st["groups"]), "every group has a label and items"
for i in items.values():
    assert i["title"] and i["summary"], i
assert items["skills/harvest"]["cmd"] == "/ai-harness:harvest", items["skills/harvest"]
assert items["templates/implement-feature"]["cmd"] == "/implement-feature"
assert items["catalog/jira"]["cmd"] == "/jira"
assert items["agents/design-reviewer"]["cmd"] is None
assert items["skills/harness-impact"]["view"] == "impact"
assert not any(g["key"] == "other" for g in st["groups"]), "nothing falls into the other group in this repository"
' "$ROOT" || fail "guide lists every harness feature from the repository with a Korean title and summary"
# 어긋남: guide.json에 없는 스킬은 "기타" 묶음에 원래 설명으로 남고, 저장소에 없는 항목은 화면에서 빠진다.
BGUIDE_ROOT="$TEST_TMP/guide-root"
mkdir -p "$BGUIDE_ROOT/skills/known" "$BGUIDE_ROOT/skills/newbie" "$BGUIDE_ROOT/catalog" "$BGUIDE_ROOT/agents"
printf -- '---\nname: known\ndescription: Known skill.\n---\n' >"$BGUIDE_ROOT/skills/known/SKILL.md"
printf -- '---\nname: newbie\ndescription: >\n  First sentence here. Second sentence.\n---\n' >"$BGUIDE_ROOT/skills/newbie/SKILL.md"
printf '{"version":1,"skills":[]}\n' >"$BGUIDE_ROOT/catalog/catalog.json"
jq -n '{groups:[{key:"start",label:"시작",desc:"설명",items:[
  {id:"skills/known",title:"알려진 스킬",summary:"요약"},
  {id:"skills/gone",title:"없어진 스킬",summary:"요약"}]}]}' >"$BGUIDE_ROOT/guide.json"
python3 -I -B -c '
import sys
sys.path.insert(0, sys.argv[1] + "/scripts/board")
import guide
root, gpath = sys.argv[2], sys.argv[2] + "/guide.json"
assert guide.coverage(root, gpath) == {"unlisted": ["skills/newbie"], "stale": ["skills/gone"]}, guide.coverage(root, gpath)
st = guide.state(root, gpath)
ids = [i["id"] for g in st["groups"] for i in g["items"]]
assert ids == ["skills/known", "skills/newbie"], ids
other = [g for g in st["groups"] if g["key"] == "other"][0]
assert other["items"][0]["title"] == "newbie" and other["items"][0]["summary"] == "First sentence here.", other
' "$ROOT" "$BGUIDE_ROOT" || fail "guide keeps an unlisted skill in the other group and drops a stale entry"
# 서버: /guide는 토큰과 Host를 확인하고 목록을 내준다. 화면은 다섯 번째 화면으로 이 목록을 그린다.
BGUIDE_DATA="$TEST_TMP/guide-data"; mkdir -p "$BGUIDE_DATA"
BGUIDE_PORT="$(free_port)"
bguide_sh() {
  env PATH="$BOARD_T/bin:$PATH" ORCA_CLI_COMMAND=orca HARNESS_METRICS_DIR="$BGUIDE_DATA" HARNESS_CLAUDE_PROJECTS_DIR="$BOARD_T/projects" \
    HARNESS_CLAUDE_SETTINGS="$BOARD_T/settings.json" BOARD_PORT="$BGUIDE_PORT" BOARD_NO_BROWSER=1 \
    BOARD_JIRA_URL= JIRA_BASE_URL= bash "$ROOT/scripts/board/board.sh" "$@"
}
BGUIDE_URL="$(bguide_sh open | jq -r '.url')"
BGUIDE_TOKEN="${BGUIDE_URL#*t=}"
BGUIDE_BASE="http://127.0.0.1:$BGUIDE_PORT"
assert_eq "403" "$(curl -s -o /dev/null -w '%{http_code}' "$BGUIDE_BASE/guide?t=wrong")" "guide endpoint checks the token"
assert_eq "403" "$(curl -s -o /dev/null -w '%{http_code}' -H "Host: attacker.example:$BGUIDE_PORT" "$BGUIDE_BASE/guide?t=$BGUIDE_TOKEN")" "guide endpoint checks the Host"
assert_eq "/ai-harness:harvest" "$(curl -s "$BGUIDE_BASE/guide?t=$BGUIDE_TOKEN" | jq -r '[.groups[].items[] | select(.id == "skills/harvest")][0].cmd')" "guide endpoint serves the feature list"
assert_eq "true" "$(bguide_sh stop | jq -r '.stopped')" "guide board stops"
BGUIDE_TPL="$(<"$ROOT/scripts/board/template.html")"
assert_contains "$BGUIDE_TPL" "guide: { label: '하네스 안내'" "the board has a harness guide view"
assert_contains "$BGUIDE_TPL" "'/guide?t='" "the guide view loads the feature list from the server"
assert_contains "$BGUIDE_TPL" "copyBtn('명령 복사', it.cmd" "each feature offers its command to copy"
assert_contains "$BGUIDE_TPL" "['agenda', 'settings', 'impact', 'refs', 'guide'].includes(saved)" "the board reopens the guide view after a reload"
assert_contains "$BGUIDE_TPL" "view === 'guide' || !names.length" "the guide view hides the project filter"
assert_contains "$BGUIDE_TPL" "function goLink(text, v, st, lt)" "guide links can open a tab of the work list"
assert_contains "$(<"$ROOT/skills/board/SKILL.md")" "하네스 안내" "board skill documents the guide view"
pass "harness board guide view: feature list from the repository, Korean titles, drift caught by tests (#432)"

# 하네스 안내 보강(#432): 처음 쓰는 사람의 시작 3단계, 흐름 단계의 자동/직접 구분과 카드 링크,
# 에이전트가 알아서 쓰는 것(스택 규칙·에이전트)은 한 묶음으로 기본 접힘, 묶음 목차, 첫 진입은 안내 화면.
python3 -I -B -c '
import sys
sys.path.insert(0, sys.argv[1] + "/scripts/board")
import guide
st = guide.state(sys.argv[1])
groups = {g["key"]: g for g in st["groups"]}
auto = groups["auto"]
assert auto["fold"] is True, auto
ids = {i["id"] for i in auto["items"]}
assert {"agents/design-reviewer", "agents/harvest-reviewer", "templates/ui-review", "templates/feature-sliced-design"} <= ids, ids
assert not any(i.startswith("skills/") or i.startswith("catalog/") for i in ids), ids
assert len(ids) == 11, sorted(ids)
assert all(g["fold"] is False for k, g in groups.items() if k != "auto"), [k for k, g in groups.items() if g["fold"]]
assert "stack" not in groups, "stack rules live in the auto group"
items = {i["id"]: i for g in st["groups"] for i in g["items"]}
assert items["skills/design-polish"]["title"] == "화면 점검 (하네스 없이)", items["skills/design-polish"]
assert items["templates/design-polish"]["title"] == "화면 다듬기"
' "$ROOT" || fail "guide folds the things agents use on their own into one group and names the global polish skill for repositories without a harness"
BGUIDE_TPL="$(<"$ROOT/scripts/board/template.html")"
BGUIDE_FN="$(sed -n '/---- 하네스 안내 ----/,/---- 레퍼런스 보드 ----/p' "$ROOT/scripts/board/template.html")"
assert_contains "$BGUIDE_FN" "'처음이면 이것부터'" "the guide starts newcomers with three steps"
assert_contains "$BGUIDE_FN" "['skills/setup', '셋업'," "the first step is setup"
assert_contains "$BGUIDE_FN" "['skills/harness-init', '프로젝트 하네스 만들기'," "the second step is the project harness"
assert_contains "$BGUIDE_FN" "['templates/implement-feature', '기능 개발'," "the third step is feature delivery"
assert_contains "$BGUIDE_FN" "function guideJump(" "guide links scroll to and focus a card"
assert_contains "$BGUIDE_FN" "c.tabIndex = -1" "a jumped-to card can take focus"
assert_contains "$BGUIDE_FN" "MODE = { auto: '자동', opt: '켜면 자동', manual: '직접 실행' }" "flow steps say whether they run on their own"
assert_contains "$BGUIDE_FN" "['기록', 'auto'," "recording runs on its own"
assert_contains "$BGUIDE_FN" "['자동 개선', 'opt', 'skills/harvest'" "auto harvest runs on its own only when turned on"
assert_contains "$BGUIDE_FN" "['동기화', 'opt', 'skills/harness-init'" "auto sync runs on its own only when turned on"
assert_contains "$BGUIDE_FN" "['효과 확인', 'manual', 'skills/harness-impact'" "impact check is run by the person"
assert_contains "$BGUIDE_FN" "goLink('켜는 곳: 하네스 설정', 'settings', 'harness')" "opt-in steps link to the settings tab that turns them on"
assert_contains "$BGUIDE_FN" "g.fold" "folded groups render as a collapsed row"
assert_contains "$BGUIDE_FN" "setAttribute('aria-expanded'" "the folded group head is an expand button"
assert_contains "$BGUIDE_FN" "'b-toc'" "the guide has a table of contents"
assert_contains "$BGUIDE_TPL" ".b-toc ul { margin: 0; padding: 0; list-style: none; display: flex; flex-wrap: wrap;" "the table of contents wraps instead of scrolling sideways"
# 시작 화면 규칙을 실제로 돌린다: 처음(저장 없음) → 안내, 쓰던 사람 → 그대로, ?view=guide → 안내.
BGUIDE_START="$(grep -A1 -m1 '^  const startView = ' "$ROOT/scripts/board/template.html")"
assert_eq "guide list list settings guide list" "$(BGUIDE_START="$BGUIDE_START" node -e 'eval(process.env.BGUIDE_START.replace("const startView", "var startView"));
console.log([startView("?t=x", null, false), startView("?t=x", null, true), startView("?t=x", "list", true), startView("?t=x", "settings", true), startView("?t=x&view=guide", "list", true), startView("?t=x&view=other", "list", true)].join(" "))')" \
  "a first-time board opens on the guide, a used board keeps its view, ?view=guide opens the guide"
assert_contains "$BGUIDE_TPL" "store('hb-tab') === null && store('hb-stab') === null" "someone who only used tabs is not a first-time visitor"
# 시작 단계·흐름 단계가 가리키는 카드가 기능 목록에 있어야 한다(없으면 링크가 조용히 글자가 된다).
BGUIDE_IDS="$(printf '%s\n' "$BGUIDE_FN" | sed -n "/const START = \[/,/^  \];/p;/const FLOW = \[/,/^  \];/p" | grep -oE "'(skills|templates|agents|catalog)/[a-z0-9-]+'" | tr -d "'" | sort -u)"
[[ -n "$BGUIDE_IDS" ]] || fail "guide start and flow steps name cards"
python3 -I -B -c '
import sys
sys.path.insert(0, sys.argv[1] + "/scripts/board")
import guide
have = {i["id"] for g in guide.state(sys.argv[1])["groups"] for i in g["items"]}
missing = [i for i in sys.argv[2].split() if i not in have]
assert not missing, missing
' "$ROOT" "$BGUIDE_IDS" || fail "every card the guide steps link to is in the feature list"
assert_contains "$(<"$ROOT/skills/board/SKILL.md")" "?view=guide" "board skill documents the guide query"
pass "harness board guide: first steps, flow modes with card links, folded agent-only group, table of contents, first open on the guide (#432)"

# 하네스 안내 카드에서 바로 실행(#442): guide.json의 run이 실행 범위(global·repo·harness·optional)를 정하고,
# 서버가 실행 가능 여부와 이유(하네스를 깐 저장소 없음·기본 스킬 미설치)를 내려 준다. 실행은 기존 POST /new를 쓴다.
# 범위는 각 SKILL.md 본문 근거로 정했다(PR 본문 "결정 사항" 표) — 바꾸면 여기와 표를 같이 고친다.
python3 -I -B -c '
import json, sys
root = sys.argv[1]
raw = json.load(open(root + "/scripts/board/guide.json", encoding="utf-8"))
for g in raw["groups"]:
    for i in g["items"]:
        run = i.get("run")
        assert run in (None, "global", "repo", "harness", "optional"), i
        if g.get("fold"):
            assert run is None, ("folded group has no run", i)
        if i["id"].startswith("agents/") or (i["id"].startswith("templates/") and not i.get("entry")):
            assert run is None, ("card without a command has no run", i)
        if i["id"].startswith("templates/") and i.get("entry"):
            assert run == "harness", ("workflows run only in a harness repository", i)
        if i["id"].startswith("catalog/"):
            assert run == "global", ("catalog skills run anywhere", i)
by = {i["id"]: i.get("run") for g in raw["groups"] for i in g["items"] if not i["id"].startswith(("catalog/", "agents/", "templates/"))}
want = {
  "skills/setup": "global", "skills/harness-update": "global", "skills/metrics": "global", "skills/board": None,
  "skills/handsfree": "global", "skills/handsfree-ui": "global",
  "skills/harvest": "harness", "skills/harness-impact": "harness",
  "skills/diagram": "optional", "skills/design-references": "optional", "skills/landing-page": "optional", "skills/explain-for": "optional",
  "skills/harness-init": "repo", "skills/autofix": "repo", "skills/understand-change": "repo", "skills/design-system-builder": "repo",
  "skills/design-screen": "repo", "skills/design-polish": "repo", "skills/ux-writing-builder": "repo", "skills/ux-writing-audit": "repo",
  "skills/web-design-guidelines": "repo", "skills/emil-design-eng": "repo",
}
assert by == want, {k: (by.get(k), want.get(k)) for k in set(by) | set(want) if by.get(k) != want.get(k)}
' "$ROOT" || fail "guide.json run scopes match each skill: global, repo, harness, optional; none without a command or in the folded group"
# 저장소 후보: Orca 저장소 목록, Claude Code 사용 기록(~/.claude.json의 projects 키만), 보드가 아는 저장소를 모아
# 없는 폴더·하위 폴더·worktree·임시 폴더·홈을 거르고 중복을 없앤 뒤 최근 사용 순(같으면 이름순)으로 준다.
BRUN_T="$TEST_TMP/guide-run"; BRUN_C="$BRUN_T/cand"; mkdir -p "$BRUN_T/skills/jira" "$BRUN_C/home" "$BRUN_C/tmp" "$BRUN_C/bin" "$BRUN_C/projects"
BRUN_C="$(cd "$BRUN_C" && pwd)"  # TMPDIR 끝의 / 때문에 생기는 // 를 없앤다(Claude Code 기록 폴더 이름은 정규화한 경로에서 나온다)
for r in alpha beta gamma; do mkdir -p "$BRUN_C/code/$r/.git"; done
mkdir -p "$BRUN_C/code/gamma/.ai-harness" "$BRUN_C/code/alpha/src" "$BRUN_C/code/wt" "$BRUN_C/code/plain" "$BRUN_C/tmp/scratch/.git" "$BRUN_C/code/scratchpad/x/.git" "$BRUN_C/home/.git"
printf '{}\n' >"$BRUN_C/code/gamma/.ai-harness/harness.json"
printf 'gitdir: /elsewhere\n' >"$BRUN_C/code/wt/.git"
jq -n --arg c "$BRUN_C" '{projects: {($c + "/code/alpha"): {secret: "x"}, ($c + "/code/alpha/src"): {}, ($c + "/code/wt"): {}, ($c + "/code/plain"): {},
  ($c + "/code/missing"): {}, ($c + "/tmp/scratch"): {}, ($c + "/code/scratchpad/x"): {}, ($c + "/home"): {}}, other: "ignored"}' >"$BRUN_C/claude.json"
cat >"$BRUN_C/bin/orca" <<EOF
#!/usr/bin/env bash
[[ "\$*" == "repo list --json" ]] || exit 1
printf '{"ok":true,"result":{"repos":[{"path":"%s","displayName":"beta"},{"path":"%s/","displayName":"alpha"}]}}\n' "$BRUN_C/code/beta" "$BRUN_C/code/alpha"
EOF
chmod +x "$BRUN_C/bin/orca"
BRUN_SLUG="$(printf '%s' "$BRUN_C/code/gamma" | sed 's/[^A-Za-z0-9]/-/g')"
mkdir -p "$BRUN_C/projects/$BRUN_SLUG"
PATH="$BRUN_C/bin:$PATH" python3 -I -B -c '
import json, os, sys
sys.path.insert(0, sys.argv[1] + "/scripts/board")
import guide
c = sys.argv[2]
got = guide.candidates(seeds=[c + "/code/gamma"], home=c + "/home", claude_json=c + "/claude.json",
                       projects_dir=c + "/projects", temp_roots=[c + "/tmp"])
names = [r["name"] for r in got]
assert names == ["gamma", "alpha", "beta"], got
g = got[0]
assert g["harness"] is True and g["used"] and g["path"] == c + "/code/gamma", g
assert got[1]["harness"] is False and got[1]["used"] is None, got[1]
assert got[1]["short"] == got[1]["path"], got[1]
home = guide.candidates(seeds=[c + "/code/alpha"], home=c + "/code", claude_json=c + "/none.json", projects_dir=c + "/projects", temp_roots=[], orca=False)
assert [r["short"] for r in home] == ["~/alpha"], home
assert guide.candidates(seeds=[], home=c + "/home", claude_json=c + "/none.json", projects_dir=c + "/projects", temp_roots=[], orca=False) == []
open(c + "/bad.json", "w").write("{\"projects\": [1, 2]}")
assert guide.candidates(seeds=[], home=c + "/home", claude_json=c + "/bad.json", projects_dir=c + "/projects", temp_roots=[], orca=False) == []
' "$ROOT" "$BRUN_C" || fail "launch candidates come from Orca, Claude Code history and known repositories, without subfolders, worktrees, temp folders or home, most recent first"
python3 -I -B -c '
import sys
sys.path.insert(0, sys.argv[1] + "/scripts/board")
import guide
root, skills = sys.argv[1], sys.argv[2]
def items(**kw):
    return {i["id"]: i for g in guide.state(root, **kw)["groups"] for i in g["items"]}
none = {"home": "/h", "repos": [{"path": "/r/one", "name": "one", "short": "/r/one", "harness": False, "used": None}]}
it = items(launch=none, skills_dir=skills)
wf = it["templates/implement-feature"]
assert (wf["run"], wf["runnable"], wf["blocked"]) == ("harness", False, "no_harness_repo"), wf
jira = it["catalog/jira"]
assert (jira["run"], jira["runnable"], jira["blocked"]) == ("global", False, "not_installed"), jira
setup = it["skills/setup"]
assert (setup["run"], setup["runnable"], setup["blocked"]) == ("global", True, None), setup
assert it["skills/harness-init"]["runnable"] is True and it["skills/harness-init"]["run"] == "repo"
assert it["skills/harness-init"]["prefer"] == "unharnessed" and it["skills/diagram"]["prefer"] is None, it["skills/harness-init"]
for k in ("skills/board", "agents/design-reviewer", "templates/ui-review"):
    assert it[k]["run"] is None and it[k]["runnable"] is False and it[k]["blocked"] is None, it[k]
open(skills + "/jira/SKILL.md", "w").write("---\nname: jira\n---\n")
some = {"home": "/h", "repos": none["repos"] + [{"path": "/r/two", "name": "two", "short": "/r/two", "harness": True, "used": None}]}
it = items(launch=some, skills_dir=skills)
assert it["templates/implement-feature"]["runnable"] is True and it["templates/implement-feature"]["blocked"] is None
assert it["catalog/jira"]["runnable"] is True, it["catalog/jira"]
assert guide.state(root, launch=some, skills_dir=skills)["launch"] == some
' "$ROOT" "$BRUN_T/skills" || fail "guide state says which cards can run and why not: no harness repository, catalog skill not installed"
# 서버: /guide·/launch가 격리된 기본 스킬 폴더(HM_CLAUDE_SKILLS_DIR)·사용 기록(HARNESS_CLAUDE_JSON)·가짜 orca로 판정한다.
BRUN_DATA="$TEST_TMP/guide-run-data"; mkdir -p "$BRUN_DATA/harvest-auto" "$BRUN_T/faketmp"
BRUN_PORT="$(free_port)"
brun_sh() {
  env PATH="$BRUN_C/bin:$BOARD_T/bin:$PATH" ORCA_CLI_COMMAND=orca HARNESS_METRICS_DIR="$BRUN_DATA" HARNESS_CLAUDE_PROJECTS_DIR="$BRUN_C/projects" \
    HARNESS_CLAUDE_SETTINGS="$BOARD_T/settings.json" HARNESS_CLAUDE_JSON="$BRUN_T/none.json" BOARD_LAUNCH_TTL=0 BOARD_TEMP_ROOTS="$BRUN_T/faketmp" \
    BOARD_PORT="$BRUN_PORT" BOARD_NO_BROWSER=1 HM_CLAUDE_SKILLS_DIR="$BRUN_T/server-skills" BOARD_JIRA_URL= JIRA_BASE_URL= \
    bash "$ROOT/scripts/board/board.sh" "$@"
}
BRUN_URL="$(brun_sh open | jq -r '.url')"
BRUN_BASE="http://127.0.0.1:$BRUN_PORT/guide?t=${BRUN_URL#*t=}"
brun_item() { curl -s "$BRUN_BASE" | jq -r --arg id "$1" '[.groups[].items[] | select(.id == $id)][0] | "\(.run)|\(.runnable)|\(.blocked)"'; }
assert_eq "harness|false|no_harness_repo" "$(brun_item templates/implement-feature)" "a workflow card cannot run before any repository has the harness"
assert_eq "global|false|not_installed" "$(brun_item catalog/jira)" "a catalog card cannot run before setup installs the skill"
assert_eq "alpha beta" "$(curl -s "$BRUN_BASE" | jq -r '[.launch.repos[].name] | join(" ")')" "the guide offers Orca repositories as launch candidates"
mkdir -p "$BRUN_T/server-skills/jira"
printf -- '---\nname: jira\n---\n' >"$BRUN_T/server-skills/jira/SKILL.md"
jq -cn --arg r "$BRUN_C/code/gamma" '{repo:$r}' >"$BRUN_DATA/harvest-auto/runs.jsonl"
assert_eq "harness|true|null" "$(brun_item templates/implement-feature)" "a workflow card runs once the board knows a harness repository"
assert_eq "global|true|null" "$(brun_item catalog/jira)" "a catalog card runs once the skill is installed"
assert_eq "gamma:true" "$(curl -s "http://127.0.0.1:$BRUN_PORT/launch?t=${BRUN_URL#*t=}" | jq -r '.repos[] | select(.harness) | "\(.name):\(.harness)"')" "the new-session picker gets the same candidates with the harness mark"
assert_eq "403" "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$BRUN_PORT/launch?t=wrong")" "launch candidates check the token"
assert_eq "true" "$(brun_sh stop | jq -r '.stopped')" "guide run board stops"
BRUN_FN="$(sed -n '/---- 하네스 안내 ----/,/---- 레퍼런스 보드 ----/p' "$ROOT/scripts/board/template.html")"
BRUN_DLG="$(sed -n '/---- 대화 상자: 새 세션/,/let cleaning = null/p' "$ROOT/scripts/board/template.html")"
BRUN_TPL="$(<"$ROOT/scripts/board/template.html")"
# 범위별 고르는 목록: harness는 하네스 저장소만, optional은 맨 위에 "저장소 없이(홈에서)", global은 목록 없음.
BRUN_PICK="$(sed -n '/^  const pickChoices = /,/^  };/p' "$ROOT/scripts/board/template.html")"
[[ -n "$BRUN_PICK" ]] || fail "the dialog has a pickChoices function"
assert_eq "two|~,one,two|one,two|" "$(BRUN_PICK="$BRUN_PICK" node -e 'eval(process.env.BRUN_PICK.replace("const pickChoices", "var pickChoices"));
const L = { home: "~", repos: [{ path: "/r/one", name: "one", harness: false }, { path: "/r/two", name: "two", harness: true }] };
console.log(["harness", "optional", "repo", "global"].map((s) => pickChoices(s, L).map((c) => c.home ? "~" : c.name).join(",")).join("|"))')" \
  "the picker lists only harness repositories for workflows, offers home first for optional cards and nothing for global ones"
# 기본 선택: optional은 홈, repo·harness는 후보가 하나일 때만 그것(아니면 고르기 전에는 띄우지 않음), 새 세션 버튼은 지난번 고른 곳.
# 하네스 만들기는 아직 하네스를 깔지 않은 저장소가 먼저 온다(깐 저장소에 실행하면 동기화가 된다).
BRUN_DEF="$(sed -n '/^  const pickDefault = /,/^  };/p' "$ROOT/scripts/board/template.html")"
[[ -n "$BRUN_DEF" ]] || fail "the dialog has a pickDefault function"
assert_eq "~||/r/two|/r/one|/r/one|two,one|one,two" "$(BRUN_PICK="$BRUN_PICK" BRUN_DEF="$BRUN_DEF" node -e 'eval(process.env.BRUN_PICK.replace("const pickChoices", "var pickChoices")); eval(process.env.BRUN_DEF.replace("const pickDefault", "var pickDefault"));
const L = { home: "~", repos: [{ path: "/r/two", name: "two", harness: true }, { path: "/r/one", name: "one", harness: false }] };
console.log([pickDefault("optional", pickChoices("optional", L), ""), pickDefault("repo", pickChoices("repo", L), ""), pickDefault("harness", pickChoices("harness", L), ""),
  pickDefault("repo", pickChoices("repo", L), "/r/one"), pickDefault("optional", pickChoices("optional", L), "/r/one"),
  pickChoices("repo", L).map((c) => c.name).join(","), pickChoices("repo", L, "unharnessed").map((c) => c.name).join(",")].join("|"))')" \
  "optional starts on home, repo waits for a pick unless one candidate, the new-session button keeps the last pick, harness-init lists repositories without the harness first"
assert_contains "$BRUN_TPL" "저장소를 고르세요. 목록에서 고르거나 경로를 직접 입력합니다." "launching without a repository asks for one under the field"
assert_contains "$BRUN_TPL" 'class="ds-field__error" id="fpickerr"' "the missing repository uses the field error part"
assert_contains "$BRUN_DLG" "if (pick.scope === 'global') { list.replaceChildren(); return; }" "a global card builds no repository list at all"
# 줄마다 이름 아래 경로가 실제로 보여야 같은 이름 저장소를 가른다 — 후보가 많아도 grid 행이 눌리지 않게 목록은 block 흐름.
assert_contains "$BRUN_TPL" ".b-pick { display: block;" "the picker list keeps each row's path line visible when it scrolls"
BRUN_SP="$(grep -m1 '^  const shortPath = ' "$ROOT/scripts/board/template.html")"
assert_eq "h/…/work/copy-b/shop|h/a/b" "$(BRUN_SP="$BRUN_SP" node -e 'eval(process.env.BRUN_SP.replace("const shortPath", "var shortPath")); console.log([shortPath("h/x/y/work/copy-b/shop"), shortPath("h/a/b")].join("|"))')" \
  "a long path keeps its end so two repositories with the same name are told apart"
assert_contains "$BRUN_DLG" "'저장소 없이(홈에서)'" "optional cards can run without a repository"
assert_contains "$BRUN_DLG" "if (!typed && cur < 0 && q && pick.shown.length)" "searching selects the first match so Enter never launches in a repository the list no longer shows"
assert_contains "$BRUN_DLG" "'다른 경로 직접 입력'" "the picker can open the typed path field"
assert_contains "$BRUN_DLG" "'어느 저장소와도 상관없어 홈에서 띄웁니다.'" "a global card says why it runs from home"
assert_contains "$BRUN_DLG" "\$('fpickfield').hidden = scope === 'global';" "a global card shows no repository picker"
assert_contains "$BRUN_DLG" "\$('fcwdfield').hidden = true;" "the typed path field starts folded behind the picker"
assert_contains "$BRUN_DLG" "\$('dlg').returnValue = '';" "closing the prefilled form with Esc does not reuse the last ok and start a session"
assert_contains "$BRUN_DLG" "if (res.ok && !draft)" "the form gets back what the new-session button had after a card run"
assert_contains "$BRUN_DLG" "post('/new'," "the new-session form starts the session through the existing endpoint"
assert_contains "$BRUN_DLG" "openNew({ scope: 'optional'" "the new-session button uses the same picker"
assert_contains "$BRUN_FN" "openNew({" "running a card opens the existing new-session form"
assert_contains "$BRUN_FN" "title: \`\${it.title} 실행\`" "the form opened from a card is titled with the card"
assert_contains "$BRUN_FN" "START.some(([id]) => id === it.id) ? 'ds-btn--sm ds-btn--primary' : 'ds-btn--sm'" "only the three first-step cards make run the filled primary button"
assert_contains "$BRUN_FN" "icon('play')" "run buttons carry the play icon"
assert_contains "$BRUN_FN" "copyBtn('명령 복사', it.cmd, 'ds-btn--sm ds-btn--ghost')" "copying the command becomes the secondary action"
assert_contains "$BRUN_FN" "'하네스를 깐 저장소가 없습니다'" "a blocked workflow card says why"
assert_contains "$BRUN_FN" "'아직 설치하지 않았습니다'" "a blocked catalog card says why"
assert_contains "$BRUN_FN" "toCard('프로젝트 하네스 만들기', 'skills/harness-init')" "the no-harness reason links to the harness card"
assert_contains "$BRUN_FN" "toCard('처음 셋업', 'skills/setup')" "the not-installed reason links to the setup card"
assert_contains "$BRUN_FN" "a.dataset.key = 'why:' + it.id" "each blocked card's reason link keeps its own focus key"
assert_contains "$BRUN_FN" "if (SERVER && it.run)" "a screen opened without the board server shows no run button"
assert_contains "$BRUN_FN" "'세션을 띄웠습니다 — 작업 현황에서 진행을 봅니다'" "a launched card says where to follow it"
assert_contains "$BRUN_FN" "goLink('작업 현황 열기', 'list')" "the launch toast links to the work list"
assert_contains "$BRUN_TPL" "if (ok && !action) timer = setTimeout(dismiss, 5000)" "a toast with an action stays until closed"
assert_contains "$(<"$ROOT/docs/design-system.md")" "동작이 든 토스트" "the design rules say how long a toast with an action stays"
assert_contains "$BRUN_TPL" "보드가 고른 저장소에서 Claude 세션을 띄웁니다. 질문과 권한 요청은 작업 현황에서 답합니다." "the reused new-session form explains where questions go"
assert_contains "$(<"$ROOT/skills/board/SKILL.md")" "저장소 없이(홈에서)" "board skill documents the launch scopes"
pass "harness board guide: run a feature card from the guide with the new-session form, scope-aware repository picker, blocked cards say why (#442)"

# 버전 바뀜 안내(#439): 확인한 플러그인 버전은 사용자 데이터(board/version-seen.json)에 두고, 보드와 세션 시작 안내가 같은 값을 본다.
# 바뀐 것은 플러그인과 함께 배포되는 CHANGELOG.md에서 읽는다 — 확인한 버전 초과 ~ 현재 버전 이하의 절을 합치고(건너뛴 버전 포함),
# Unreleased는 빼고, 해야 할 일 → 새 기능 → 동작 변경 → 버그 수정 → 기타 순으로 묶는다. 버전은 숫자로 견준다(0.9.1 < 0.10.0).
BVER_ROOT="$TEST_TMP/changelog"
mkdir -p "$BVER_ROOT"
cp -R "$ROOT/tests/fixtures/changelog/." "$BVER_ROOT"
BVER_DATA="$TEST_TMP/version-notes"; mkdir -p "$BVER_DATA"
python3 -c '
import json, os, sys
sys.path.insert(0, sys.argv[1] + "/scripts/board")
import changes
root, data = sys.argv[2], sys.argv[3]
seen = os.path.join(data, "board", "version-seen.json")
# 상태 없음(첫 설치·이 기능 이전 사용자): 쏟아내지 않고 현재 버전으로 조용히 기록한다.
st = changes.state(root, data)
assert st["current"] == "0.10.0" and st["unseen"] is False and st["seen"] == "0.10.0", st
assert json.load(open(seen))["seen"] == "0.10.0"
# 최근 업데이트(다시 펼쳐 보기): 확인한 범위를 모르면 현재 버전 절 하나.
assert [g["key"] for g in st["recent"]["groups"]] == ["todo", "feature", "fix"], st["recent"]
# 릴리스 이력(#457): 확인 여부와 무관하게 버전마다 날짜·묶음별 개수·묶음을 최신부터 준다(Unreleased 제외).
# 기능 카드의 최근 표시 기준(recent_from): 최신 릴리스 날짜에서 7일 안의 릴리스, 그보다 적으면 최근 3개 중 가장 오래된 버전.
assert [r["version"] for r in st["releases"]] == ["0.10.0", "0.9.1", "0.9.0"] and st["recent_from"] == "0.9.0", st
r0 = st["releases"][0]
assert r0["date"] == "2026-01-03" and r0["unseen"] is False, r0
assert r0["counts"] == {"todo": 1, "feature": 1, "change": 0, "fix": 1, "other": 0}, r0["counts"]
assert [g["key"] for g in r0["groups"]] == ["todo", "feature", "fix"], r0["groups"]
old_todo = st["releases"][2]["groups"][0]["items"][0]  # 굵은 제목 없는 항목에 요약이 있으면 요약이 제목, 원문은 펼친 곳
assert old_todo["title"] == "설정을 한 번 다시 저장하세요." and old_todo["summary"] is None and old_todo["body"].startswith("예전 설정 파일을 열어"), old_todo
rel = lambda v, d: {"version": v, "date": d}
assert changes._recent_from([rel("0.5.0", "2026-03-20"), rel("0.4.0", "2026-03-14"), rel("0.3.0", "2026-03-13"), rel("0.2.0", "2026-03-12"), rel("0.1.0", "2026-03-01")]) == "0.3.0"
assert changes._recent_from([rel("0.5.0", "2026-03-20"), rel("0.4.0", "2026-01-01"), rel("0.3.0", "2025-12-01"), rel("0.2.0", None)]) == "0.3.0"  # 7일 안이 적으면 최근 3개
assert st["recent"]["versions"] == ["0.10.0"] and st["recent"]["from"] == "0.9.1", st["recent"]
# 뒤처짐: 건너뛴 버전까지 합친다.
json.dump({"seen": "0.9.0"}, open(seen, "w"))
st = changes.state(root, data)
assert st["unseen"] is True and st["from"] == "0.9.0" and st["to"] == "0.10.0", st
assert st["versions"] == ["0.10.0", "0.9.1"], st["versions"]
assert [r["unseen"] for r in st["releases"]] == [True, True, False], st["releases"]  # 확인한 버전 뒤의 릴리스만 새 버전
keys = [g["key"] for g in st["groups"]]
assert keys == ["todo", "feature", "change", "fix"], keys
labels = {g["key"]: g["label"] for g in st["groups"]}
assert labels == {"todo": "업데이트 후 해야 할 일", "feature": "새 기능", "change": "동작 변경", "fix": "버그 수정"}, labels
by = {g["key"]: g["items"] for g in st["groups"]}
assert [i["title"] for i in by["feature"]] == ["새 화면이 생겼습니다"], by["feature"]
bt = chr(96)  # 백틱(셸 따옴표 안에 그대로 쓰지 않는다)
# 최근 이력은 유형·요약·원문·릴리스 이미지 참조를 각각 제공한다. 요약·이미지가 없는 옛 항목은 기존 본문을 유지한다.
feature = by["feature"][0]
assert feature["type"] == "feature" and feature["summary"] == "보드 안내에서 최근 릴리스 이력을 바로 봅니다.", feature
assert feature["body"] == bt + "board" + bt + " 화면에서 **바로** 봅니다. (#12)" and feature["version"] == "0.10.0", feature
assert [(i["alt"], i["path"]) for i in feature["images"]] == [("릴리스 이력 안내 화면", "assets/release-notes/history.png")], feature
assert feature["title"] == "새 화면이 생겼습니다" and "요약:" not in feature["body"] and "![" not in feature["body"], feature  # 요약·이미지는 원문에서 떼어 낸다
legacy = by["change"][0]
assert legacy["title"] == "기본값이 바뀌었습니다" and legacy["body"] == "이제 꺼져 있습니다. (#11, #10)\n이어지는 줄도 같은 항목입니다." and legacy["version"] == "0.9.1", legacy
assert legacy["type"] == "change" and legacy["summary"] is None and legacy["images"] == [], legacy
# 굵은 제목이 없는 항목은 첫 문장이 제목이고(마크다운 기호 없이), 남는 것이 이슈 번호뿐이면 제목에 붙이고 펼칠 것이 없다.
todo = by["todo"][0]
assert todo["title"] == "기존 프로젝트는 /harness-init --sync --apply로 받습니다. (#12)" and todo["body"] == "" and todo["version"] == "0.10.0", todo
assert todo["type"] == "todo" and todo["summary"] is None and todo["images"] == [], todo
assert [i["title"] for i in by["change"]] == ["기본값이 바뀌었습니다", "빨라졌습니다", "굵은 제목 없는 항목입니다."], by["change"]
assert by["change"][2]["body"] == "굵은 제목 없는 항목입니다. 펼치면 첫 문장도 함께 보입니다. (#8)", by["change"][2]  # 잘린 제목도 펼치면 전부 보인다
assert by["change"][0]["body"] == "이제 꺼져 있습니다. (#11, #10)\n이어지는 줄도 같은 항목입니다.", by["change"][0]
assert st["counts"] == {"todo": 1, "total": 6}, st["counts"]
assert "아직 나가지 않은 기능" not in json.dumps(st, ensure_ascii=False)
assert "처음 기능" not in json.dumps(st["groups"], ensure_ascii=False)
# 확인: 본 버전(to)까지만 기록한다 — 페이지를 연 뒤 플러그인이 또 올랐으면 그 버전은 남는다.
assert changes.confirm("0.11.0", root, data)["ok"] is False
assert changes.confirm("garbage", root, data)["ok"] is False
assert changes.confirm("0.10.0", root, data)["ok"] is True
assert json.load(open(seen)) == {"seen": "0.10.0", "prev": "0.9.0"}, open(seen).read()
st = changes.state(root, data)
assert st["unseen"] is False and st["recent"]["from"] == "0.9.0" and st["recent"]["versions"] == ["0.10.0", "0.9.1"], st
assert changes.confirm("0.9.1", root, data)["ok"] is False  # 되돌리지 않는다
# 확인한 버전이 더 높으면(되돌린 설치) 바뀐 것이 없고 상태를 건드리지 않는다. 깨진 상태 파일은 없는 것으로 본다.
json.dump({"seen": "0.11.0"}, open(seen, "w"))
assert changes.state(root, data)["unseen"] is False and json.load(open(seen)) == {"seen": "0.11.0"}
open(seen, "w").write("{not json")
assert changes.state(root, data)["unseen"] is False and json.load(open(seen))["seen"] == "0.10.0"
# 세션 시작 안내용 요약: 상태가 없으면 기록만 하고 알리지 않는다.
os.remove(seen)
assert changes.hint(root, data) is None and os.path.isfile(seen)
json.dump({"seen": "0.9.0"}, open(seen, "w"))
assert changes.hint(root, data) == {"from": "0.9.0", "to": "0.10.0", "todo": 1}, changes.hint(root, data)
# CHANGELOG가 없어도 버전이 올랐다는 사실은 말한다(묶음은 비어 있음).
nolog = os.path.join(data, "nolog"); os.makedirs(nolog + "/.claude-plugin", exist_ok=True)
open(nolog + "/.claude-plugin/plugin.json", "w").write(json.dumps({"version": "0.10.0"}))
st = changes.state(nolog, data)
assert st["unseen"] is True and st["groups"] == [], st
' "$ROOT" "$BVER_ROOT" "$BVER_DATA" || fail "version notes: seen state, merged CHANGELOG sections, buckets, confirm"
# 실제 CHANGELOG도 읽힌다: 현재 버전 절이 있고 묶음 이름이 알려진 것이다.
python3 -c '
import sys, tempfile
sys.path.insert(0, sys.argv[1] + "/scripts/board")
import changes
st = changes.state(sys.argv[1], tempfile.mkdtemp(dir=sys.argv[2]))
assert st["recent"]["versions"] == [st["current"]] and st["recent"]["groups"], st["recent"]
# 옛 절의 코드 블록은 앞 항목의 본문이고(울타리·빈 제목 항목이 생기지 않음), "#### 업데이트 후 해야 할 일"도 소제목이다.
text = open(sys.argv[1] + "/CHANGELOG.md", encoding="utf-8").read()
items = [(v["version"], b, it) for v in changes.parse(text) for b, it in v["items"]]
bad = [(v, it["title"]) for v, b, it in items if not it["title"].strip() or it["title"].startswith("```")]
assert not bad, bad[:5]
assert any(v == "0.17.0" and b == "todo" for v, b, it in items), "v0.17.0 #### heading"
' "$ROOT" "$TEST_TMP" || fail "the shipped CHANGELOG has a section for the current plugin version and parses without empty items"
# 기능 카드의 since: guide.json 모든 항목에 처음 들어간 릴리스 버전이 있고 형식이 맞다(아직 릴리스 전인 기능은 다음 버전). 화면에도 실린다.
python3 -c '
import json, re, sys
sys.path.insert(0, sys.argv[1] + "/scripts/board")
import changes, guide
raw = json.load(open(sys.argv[1] + "/scripts/board/guide.json", encoding="utf-8"))
bad = [i.get("id") for g in raw["groups"] for i in g["items"] if not re.fullmatch(r"\d+\.\d+\.\d+", str(i.get("since", "")))]
assert not bad, bad
items = {i["id"]: i for g in guide.state(sys.argv[1])["groups"] for i in g["items"]}
assert items["skills/harvest"]["since"] == "0.16.0" and items["skills/board"]["since"] == "0.63.0", items["skills/board"]
' "$ROOT" || fail "every guide.json item says the release it first shipped in"
# 서버: GET /guide/changes는 토큰·Host, POST /guide/changes/seen은 Origin·토큰을 확인한다.
mkdir -p "$BVER_DATA/srv/board"; printf '{"seen":"0.9.0"}' >"$BVER_DATA/srv/board/version-seen.json"
BVER_PORT="$(free_port)"
bver_sh() {
  env PATH="$BOARD_T/bin:$PATH" ORCA_CLI_COMMAND=orca HARNESS_METRICS_DIR="$BVER_DATA/srv" HM_PLUGIN_ROOT="$BVER_ROOT" HARNESS_CLAUDE_PROJECTS_DIR="$BOARD_T/projects" \
    HARNESS_CLAUDE_SETTINGS="$BOARD_T/settings.json" BOARD_PORT="$BVER_PORT" BOARD_NO_BROWSER=1 \
    BOARD_JIRA_URL= JIRA_BASE_URL= bash "$ROOT/scripts/board/board.sh" "$@"
}
BVER_URL="$(bver_sh open | jq -r '.url')"
BVER_TOKEN="${BVER_URL#*t=}"
BVER_BASE="http://127.0.0.1:$BVER_PORT"
assert_eq "403" "$(curl -s -o /dev/null -w '%{http_code}' "$BVER_BASE/guide/changes?t=wrong")" "version notes check the token"
assert_eq "true 0.9.0 0.10.0 1" "$(curl -s "$BVER_BASE/guide/changes?t=$BVER_TOKEN" | jq -r '"\(.unseen) \(.from) \(.to) \(.counts.todo)"')" "the board serves the changes since the seen version"
BVER_BODY="{\"t\":\"$BVER_TOKEN\",\"to\":\"0.10.0\"}"
assert_eq "403" "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d "$BVER_BODY" "$BVER_BASE/guide/changes/seen")" "confirming checks the Origin"
assert_eq "403" "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Origin: $BVER_BASE" -H 'Content-Type: application/json' -d '{"t":"wrong","to":"0.10.0"}' "$BVER_BASE/guide/changes/seen")" "confirming checks the token"
assert_eq "0.9.0" "$(jq -r '.seen' "$BVER_DATA/srv/board/version-seen.json")" "a refused confirm writes nothing"
assert_eq "true" "$(curl -s -X POST -H "Origin: $BVER_BASE" -H 'Content-Type: application/json' -d "$BVER_BODY" "$BVER_BASE/guide/changes/seen" | jq -r '.ok')" "confirming records the version"
assert_eq "false 0.10.0" "$(curl -s "$BVER_BASE/guide/changes?t=$BVER_TOKEN" | jq -r '"\(.unseen) \(.seen)"')" "after confirming nothing is unseen"
# 릴리스 캡처는 토큰을 가진 보드에서만 플러그인 assets/release-notes 안의 실제 이미지 하나를 읽는다.
# 경로 이탈·심볼릭 링크·이미지가 아닌 파일은 모두 거절한다.
printf 'not an image' >"$BVER_ROOT/assets/release-notes/notes.txt"
ln -s /etc/hosts "$BVER_ROOT/assets/release-notes/linked.png"
printf '<svg xmlns="http://www.w3.org/2000/svg"/>' >"$BVER_ROOT/assets/release-notes/drawn.svg"
assert_eq "403" "$(curl -s -o /dev/null -w '%{http_code}' "$BVER_BASE/release-notes/history.png")" "release image endpoint checks a missing token"
assert_eq "403" "$(curl -s -o /dev/null -w '%{http_code}' "$BVER_BASE/release-notes/history.png?t=wrong")" "release image endpoint checks a wrong token"
assert_eq "200 image/png" "$(curl -s -o /dev/null -w '%{http_code} %{content_type}' "$BVER_BASE/release-notes/history.png?t=$BVER_TOKEN")" "release image endpoint serves an allowed release image"
assert_eq "404" "$(curl --path-as-is -s -o /dev/null -w '%{http_code}' "$BVER_BASE/release-notes/../CHANGELOG.md?t=$BVER_TOKEN")" "release image endpoint rejects a path outside release notes"
assert_eq "404" "$(curl -s -o /dev/null -w '%{http_code}' "$BVER_BASE/release-notes/linked.png?t=$BVER_TOKEN")" "release image endpoint rejects a symbolic link"
assert_eq "404" "$(curl -s -o /dev/null -w '%{http_code}' "$BVER_BASE/release-notes/drawn.svg?t=$BVER_TOKEN")" "release image endpoint does not serve SVG (scripts would run on the board origin)"
assert_eq "404" "$(curl -s -o /dev/null -w '%{http_code}' "$BVER_BASE/release-notes/notes.txt?t=$BVER_TOKEN")" "release image endpoint rejects a non-image file"
# 플러그인이 업데이트되면(서버를 띄운 플러그인 폴더가 다르면) open이 옛 서버를 끄고 이 버전으로 다시 띄운다.
BVER_PID="$(jq -r '.pid' "$BVER_DATA/srv/board/server.json")"
assert_eq "$ROOT/scripts/board" "$(jq -r '.root' "$BVER_DATA/srv/board/server.json")" "the server records the plugin folder it runs from"
assert_eq "true" "$(bver_sh open | jq -r '.reused')" "the same plugin folder reuses the running board"
jq '.root = "/old/plugin/scripts/board"' "$BVER_DATA/srv/board/server.json" >"$BVER_DATA/conf.json" && cat "$BVER_DATA/conf.json" >"$BVER_DATA/srv/board/server.json"
BVER_OPEN="$(bver_sh open)"
assert_eq "false" "$(jq -r '.reused' <<<"$BVER_OPEN")" "a board from another plugin folder is replaced"
[[ "$(jq -r '.pid' <<<"$BVER_OPEN")" != "$BVER_PID" ]] || fail "the replaced board runs as a new process"
assert_eq "true" "$(bver_sh stop | jq -r '.stopped')" "version notes board stops"
# 화면: 안내 맨 위 패널, 사이드바 개수·새 소식, 카드의 새 기능 배지, 최소 마크다운(innerHTML 없이), 다시 그리기 생략.
BVER_FN="$(sed -n '/---- 하네스 안내 ----/,/---- 레퍼런스 보드 ----/p' "$ROOT/scripts/board/template.html")"
BVER_TPL="$(<"$ROOT/scripts/board/template.html")"
assert_contains "$BVER_FN" "'/guide/changes?t='" "the board loads the version notes from the server"
assert_contains "$BVER_FN" "post('/guide/changes/seen', { to: cdata.to })" "confirming posts the version the user saw"
assert_contains "$BVER_FN" "에서 바뀐 것" "the panel names the version range"
assert_contains "$BVER_FN" "'확인했습니다'" "the panel ends with a confirm button"
assert_contains "$BVER_FN" "btn('확인했습니다', 'ds-btn--primary')" "confirm is the panel's primary action"
assert_contains "$BVER_FN" "'릴리스 이력'" "the guide lists releases one row per version"
assert_contains "$BVER_FN" "'이전 릴리스 접기'" "older releases fold behind one row"
assert_contains "$BVER_FN" "badge(['info', '새 버전'])" "releases after the seen version say they are new"
assert_contains "$BVER_FN" "badge(['info', '새 기능'])" "cards added after the seen version carry one info badge"
assert_contains "$BVER_FN" "vcmp(it.since, cdata.recent_from) >= 0" "cards from recent releases stay marked new after the update is confirmed"
assert_contains "$BVER_FN" "el('span', 'ds-chip', '변경됨')" "cards a recent release talks about say they changed"
assert_contains "$BVER_FN" "'b-change__summary'" "an expanded item shows the plain summary first"
assert_contains "$BVER_FN" "'자세히'" "release history keeps the full changelog item behind a details control"
assert_contains "$BVER_FN" "setAttribute('aria-expanded', String(on))" "release history details expose their expanded state"
assert_contains "$BVER_FN" "setAttribute('aria-controls', did)" "release history details control their content by id"
assert_contains "$BVER_FN" "release-notes/" "release history builds image requests from approved release-note paths"
assert_contains "$BVER_FN" "const out = [...guideChanges(), guideIntro()" "the version notes come before the introduction"
assert_contains "$BVER_TPL" "badge(['info', '새 소식'])" "the sidebar says there is news when nothing needs doing"
assert_contains "$BVER_TPL" "'건, 업데이트 후 해야 할 일'" "the sidebar counts the update to-dos as human work"
assert_contains "$BVER_TPL" "loadChanges();" "the sidebar badge loads with the board"
assert_contains "$BVER_FN" "board.dataset.gsig === sig" "the guide is not rebuilt when its data did not change"
BVER_VCMP="$(grep -m1 '^  const vcmp = ' "$ROOT/scripts/board/template.html")"
[[ -n "$BVER_VCMP" ]] || fail "the board compares versions with vcmp"
assert_eq "1 -1 0 -1" "$(BVER_VCMP="$BVER_VCMP" node -e 'eval(process.env.BVER_VCMP.replace("const vcmp", "var vcmp")); console.log([vcmp("0.10.0", "0.9.1"), vcmp("0.9.1", "0.10.0"), vcmp("1.2.3", "1.2.3"), vcmp("", "0.1.0")].join(" "))')" "versions compare as numbers"
BVER_MD="$(sed -n '/^  function mdInline(/,/^  }/p' "$ROOT/scripts/board/template.html")"
[[ -n "$BVER_MD" ]] || fail "the board has an inline markdown renderer"
[[ "$BVER_MD" != *innerHTML* ]] || fail "inline markdown must not use innerHTML"
assert_contains "$(<"$ROOT/skills/board/SKILL.md")" "바뀐 것" "board skill documents the version notes"
pass "harness board guide: version notes since the seen version, confirm, sidebar badge, new-feature badges (#439)"

finish_tests
