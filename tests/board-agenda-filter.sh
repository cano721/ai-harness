#!/usr/bin/env bash
# 회귀 테스트 — 보드 '내 일정' 할 일 출처 필터와 [지금 가져오기](#663):
# 출처 옵션·순서·저장값(hb-ag-source)·쌓인 요청 요약 개수·요청자별 조합(JS), POST /agenda/refresh-all(격리 보드).
# 실행: bash tests/run.sh board-agenda-filter
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

AF_TPLF="$ROOT/scripts/board/template.html"

# 1. 화면 배치: 필터는 답할 것 다음·새로 맡겨진 요청 앞, 고른 출처로 거른 할 일(mine)만 셋으로 가르고 답할 것·일정은 거르지 않는다.
AF_RENDER="$(sed -n '/function renderAgenda(/,/^  }$/p' "$AF_TPLF")"
[ -n "$AF_RENDER" ] || fail "renderAgenda is found in the template"
assert_contains "$AF_RENDER" "agSourceOptions(todos, srcs)" "the filter options come from the open to-dos and sources"
assert_contains "$AF_RENDER" "for (const it of mine)" "only the picked source's to-dos are split into sections"
assert_contains "$AF_RENDER" "agSection('reply', '답할 것', replies," "replies are not filtered"
assert_contains "$AF_RENDER" "sopts.length >= 2" "the filter shows only with two or more sources"
AF_ORDER="$(grep -n "agSection('reply'\|agSourceFilter(sopts\|agSection('fresh'" <<<"$AF_RENDER" | cut -d: -f1 | tr '\n' ' ')"
read -r AF_R AF_F AF_N <<<"$AF_ORDER"
if [ -z "$AF_N" ] || ! ((AF_R < AF_F && AF_F < AF_N)); then
  fail "the filter sits after replies and before new requests (lines: $AF_ORDER)"
fi
assert_contains "$AF_RENDER" "'agrefreshall'" "the header has the fetch-now button"
assert_contains "$AF_RENDER" "if (linked)" "the fetch-now button hides without a connected source"
assert_contains "$AF_RENDER" "if (agRefreshingAll) busy(rb" "a redraw keeps the fetch-now button busy"
assert_contains "$(<"$AF_TPLF")" "toast(agSourceAfterAdd(), true);" "adding a to-do clears a filter that would hide it"
pass "agenda places the source filter above the to-do sections"

# 안내 문서: 보드 스킬이 출처 필터 저장 키와 [지금 가져오기] API를 적는다.
AF_SKILL="$(<"$ROOT/skills/board/SKILL.md")"
for AF_W in "hb-ag-source" "[지금 가져오기]" "/agenda/refresh-all"; do
  assert_contains "$AF_SKILL" "$AF_W" "the board skill documents $AF_W"
done
pass "the board skill documents the source filter and fetch-now"

if command -v node >/dev/null 2>&1; then
  AF_FNS="$(sed -n '/function agFold(/,/^  }$/p;/function agFoldBlock(/,/^  }$/p;/function segment(/,/^  }$/p;/function agSourceOptions(/,/^  }$/p;/function agSourcePick(/,/^  }$/p;/function agSourceAfterAdd(/,/^  }$/p;/function agSourceCounts(/,/^  }$/p;/function agSourceFilter(/,/^  }$/p;/function agRefreshAll(/,/^  }$/p;/function staleFold(/,/^  }$/p;/function agStatusGroups(/,/^  }$/p' "$AF_TPLF")"
  for AF_W in "function agSourceOptions(" "function agSourcePick(" "function agSourceAfterAdd(" "function agSourceCounts(" "function agSourceFilter(" "function agRefreshAll(" "function staleFold(" "function segment(" "function agStatusGroups("; do
    assert_contains "$AF_FNS" "$AF_W" "the template has $AF_W"
  done
  AF_STUB='class E { constructor(t) { this.tag = t; this.attrs = {}; this.children = []; this.dataset = {}; this.hidden = false; this.textContent = ""; this.className = ""; this.id = ""; }
    setAttribute(k, v) { this.attrs[k] = String(v); } getAttribute(k) { return k in this.attrs ? this.attrs[k] : null; } removeAttribute(k) { delete this.attrs[k]; }
    append(...c) { this.children.push(...c.filter((x) => x != null)); } addEventListener() {} }
  const el = (t, c, x) => { const e = new E(t); if (c) e.className = c; if (x != null) e.textContent = x; return e; };
  const icon = (n, c) => el("svg", "ds-icon" + (c ? " " + c : ""));
  const all = (n, f, out = []) => { if (n instanceof E) { if (f(n)) out.push(n); n.children.forEach((c) => all(c, f, out)); } return out; };
  let LS = {}; const store = (k, v) => { if (v === undefined) return k in LS ? LS[k] : null; LS[k] = v; return null; };
  let renders = 0; const renderBoard = () => { renders++; };
  const sameVal = (a, b) => String(a ?? "") === String(b ?? "");
  const taskList = (rows, label) => { const u = el("ul", "b-agtasks"); u.setAttribute("aria-label", label); u.rows = rows; return u; };
  const busy = (b, label) => { b.setAttribute("aria-busy", "true"); b.textContent = label; };
  const agExp = new Set();
  let posts = 0, toasts = [], loads = 0, reply = null;
  const post = (path, body) => { posts++; return new Promise((res, rej) => { reply = { res, rej, path }; }); };
  const toast = (m, ok) => { toasts.push((ok ? "ok:" : "fail:") + m); };
  const loadAgenda = (f) => { loads++; };
  let agRefreshingAll = false;'

  # 2. 옵션·순서·저장값: [전체 | 연결한 곳(sources 순서)… | 할 일], 할 일이 있는 출처만. 이름은 source_name → 소스 name → id.
  AF_OUT="$(AF_JS="$AF_STUB
$AF_FNS" node -e 'eval(process.env.AF_JS + `
    const srcs = [{ id: "acme", name: "Acme 메신저" }, { id: "cal", name: "Example 캘린더" }, { id: "inbox", name: "Example 요청함" }, { id: "noname" }];
    const todos = [{ source: "todo" }, { source: "inbox", source_name: "Example 요청함" }, { source: "acme" }, { source: "inbox", source_name: "Example 요청함" }, { source: "noname" }];
    const opts = agSourceOptions(todos, srcs);
    console.log(opts.map((x) => x.join("=")).join(","));
    console.log(agSourceOptions([{ source: "todo" }], srcs).map((x) => x.join("=")).join(",") + "|" + agSourceOptions([], srcs).length);
    const row = agSourceFilter(opts, "inbox");
    const g = all(row, (x) => x.attrs.role === "radiogroup")[0], lab = all(row, (x) => x.id === g.getAttribute("aria-labelledby"))[0];
    console.log("label=" + lab.className + ":" + lab.textContent + " group=" + g.className);
    const radios = all(row, (x) => x.attrs.role === "radio");
    console.log(radios.map((b) => b.textContent + "=" + b.getAttribute("aria-checked")).join(","));
    radios.find((b) => b.textContent === "할 일").onclick(); console.log("saved=" + LS["hb-ag-source"] + " renders=" + renders);
    LS = { "hb-ag-source": "inbox" }; console.log("pick=" + agSourcePick(todos, opts) + " kept=" + LS["hb-ag-source"]);
    LS = { "hb-ag-source": "todo" }; const gone = agSourceOptions(todos.filter((x) => x.source !== "todo"), srcs);
    console.log("pick=[" + agSourcePick(todos, gone) + "] saved=[" + LS["hb-ag-source"] + "]");
    LS = {}; console.log("pick=[" + agSourcePick(todos, opts) + "]");
    for (const v of ["inbox", "todo", ""]) { LS = { "hb-ag-source": v }; console.log("add " + (v || "all") + ": " + agSourceAfterAdd() + " saved=[" + LS["hb-ag-source"] + "]"); }
  `)')"
  assert_eq "acme=Acme 메신저,inbox=Example 요청함,noname=noname,todo=할 일
todo=할 일|0
label=ds-sr:할 일 출처 group=ds-segment
전체=false,Acme 메신저=false,Example 요청함=true,noname=false,할 일=false
saved=todo renders=1
pick=inbox kept=inbox
pick=[] saved=[]
pick=[]
add inbox: 할 일을 추가했습니다. 보이도록 할 일 출처를 [전체]로 바꿨습니다. saved=[]
add todo: 할 일을 추가했습니다. saved=[todo]
add all: 할 일을 추가했습니다. saved=[]" "$AF_OUT" "the source filter lists sources in order, saves the pick, falls back to all when it is gone and after adding a to-do under another source"
  pass "agenda source filter options, pick and fallback"

  # 3. 쌓인 요청 요약 개수: 출처가 둘 이상일 때만 옵션 순서로 붙고 합은 N. 요청자별은 이미 걸러진 목록 위에서(AND).
  AF_OUT="$(AF_JS="$AF_STUB
$AF_FNS" node -e 'eval(process.env.AF_JS + `
    const opts = [["acme", "Jira"], ["inbox", "Teams"], ["todo", "할 일"]];
    const list = [{ source: "inbox", from: "가" }, { source: "acme", from: "가" }, { source: "inbox", from: "나" }, { source: "todo" }];
    const head = (n) => all(n, (x) => x.className === "b-agfold__text")[0].textContent;
    console.log(head(staleFold(list, { opts })));
    console.log(head(staleFold(list.filter((x) => x.source === "inbox"), { opts })) + "|");
    console.log(head(staleFold(list, {})) + "|");
    agExp.add("stale"); LS = { "hb-ag-group": "1" };
    const n = staleFold(list.filter((x) => x.source === "inbox"), { opts });
    console.log(all(n, (x) => x.className === "b-agwho").map((h) => h.textContent).join(",") + " rows=" + all(n, (x) => x.tag === "ul").map((u) => u.rows.map((r) => r.source).join("+")).join(","));
  `)')"
  assert_eq "쌓인 요청 4 · Jira 1 · Teams 2 · 할 일 1
쌓인 요청 2|
쌓인 요청 4|
가 1,나 1 rows=inbox,inbox" "$AF_OUT" "the stale summary adds per-source counts only for two or more sources and grouping stays within the filter"
  pass "agenda stale summary counts by source"

  # 4. [지금 가져오기]: busy → post 1회(연속 클릭 무시) → toast → 변수 해제 → loadAgenda(true)·renderBoard. 서버에 닿지 못하면 실패 토스트.
  AF_OUT="$(AF_JS="$AF_STUB
$AF_FNS" node -e 'eval(process.env.AF_JS + `
    (async () => {
      const b = el("button", "ds-btn", "지금 가져오기");
      const p1 = agRefreshAll(b); const p2 = agRefreshAll(b);
      console.log("busy=" + b.getAttribute("aria-busy") + " label=" + b.textContent + " posts=" + posts + " path=" + reply.path + " flag=" + agRefreshingAll);
      reply.res({ ok: true, message: "3곳에서 새로 가져왔습니다." }); await p1; await p2;
      console.log("toasts=" + toasts.join("/") + " flag=" + agRefreshingAll + " loads=" + loads + " renders=" + renders);
      const p3 = agRefreshAll(el("button")); reply.res({ ok: false, message: "Broken 메일에서 가져오지 못했습니다." }); await p3;
      const p4 = agRefreshAll(el("button")); reply.rej(new Error("down")); await p4;
      console.log(toasts.slice(1).join("/") + " posts=" + posts);
    })();
  `)')"
  assert_eq "busy=true label=가져오는 중 posts=1 path=/agenda/refresh-all flag=true
toasts=ok:3곳에서 새로 가져왔습니다. flag=false loads=1 renders=1
fail:Broken 메일에서 가져오지 못했습니다./fail:가져오지 못했습니다. 보드 서버에 닿지 못했습니다. posts=3" "$AF_OUT" "fetch-now posts once while busy and toasts the result"
  pass "agenda fetch-now button is busy once and toasts"

  # 4-b. Jira 상태 묶음(#668): 진행 중(indeterminate)과 할 일(그 밖)로 가르고, 묶음 안은 기한 오름차순 다음 기한 없는 것 최신순.
  AF_OUT="$(AF_JS="$AF_STUB
$AF_FNS" node -e 'eval(process.env.AF_JS + `
    const dueAt = (d) => (d ? Date.parse(d) : NaN); const agReceived = (it) => it.r || 0;
    const list = [{ id: "a", status_category: "new", r: 1 }, { id: "b", status_category: "indeterminate", due: "2026-12-05" },
      { id: "c", r: 5 }, { id: "d", status_category: "indeterminate", due: "2026-12-01" }, { id: "e", status_category: "weird", due: "2026-12-02", r: 9 },
      { id: "f", status_category: "done", r: 3 }];
    const [prog, todo] = agStatusGroups(list);
    console.log(prog.map((x) => x.id).join(",") + "|" + todo.map((x) => x.id).join(",") + "|" + list.map((x) => x.id).join(""));
    console.log(agStatusGroups([]).map((g) => g.length).join(","));
  `)')"
  assert_eq "d,b|e,c,f,a|abcdef
0,0" "$AF_OUT" "jira status groups put in-progress first and keep due-then-received order"
  pass "agenda groups jira to-dos by status category"

  # 4-c. 상태 칩(#668): status가 있는 항목만 제목 바로 뒤에 칩(글자 = 상태 이름, data-category = 분류)을 붙인다.
  AF_TROW="$(sed -n '/function taskRow(/,/^  }$/p' "$AF_TPLF")"
  AF_OUT="$(AF_JS="$AF_STUB
$AF_TROW" node -e 'eval(process.env.AF_JS + `
    const btn = (label, cls, f) => { const b = el("button", "ds-btn" + (cls ? " " + cls : ""), label); if (f) b.onclick = f; return b; };
    const badge = () => el("span", "ds-badge"); const chip = (x) => el("span", "ds-chip", x);
    const agTitle = (c, k, f, title) => [el("button", c, title), null];
    const dueInfo = () => null; const agOpenLink = () => null; const agAge = () => ""; const agKey = (it) => it.source + ":" + it.id;
    const agDeleteBtn = () => null; const agFresh = new Set(); const SERVER = true;
    const show = (it) => {
      const r = taskRow(it, 0, {});
      const st = all(r, (x) => / b-agtask__status$/.test(x.className));
      if (!st.length) return "none|" + r.children.map((c) => c.className.split(" ")[0]).join(",");
      const par = all(r, (x) => x.children.includes(st[0]))[0], i = par.children.indexOf(st[0]);
      return st.length + "|" + st[0].className + "|" + st[0].textContent + "|" + (st[0].dataset.category || "-") + "|after=" + par.children[i - 1].className;
    };
    console.log(show({ source: "jira", id: "A-1", title: "A-1 일", status: "진행 중", status_category: "indeterminate" }));
    console.log(show({ source: "jira", id: "A-2", title: "A-2 일", status: "할 일", status_category: "new" }));
    console.log(show({ source: "jira", id: "A-3", title: "A-3 일", status: "검토" }));
    console.log(show({ source: "todo", id: "t1", title: "직접" }));
  `)')"
  assert_eq "1|ds-chip b-agtask__status|진행 중|indeterminate|after=b-agtask__title
1|ds-chip b-agtask__status|할 일|new|after=b-agtask__title
1|ds-chip b-agtask__status|검토|-|after=b-agtask__title
none|b-agcheck,b-agtask__title,b-agtask__meta,b-agev__side" "$AF_OUT" "a status chip follows the title only when the item has a status"
  pass "agenda to-do rows show a status chip next to the title"
fi

# 4-d. Jira 상태 묶음 배치(#668): [Jira] 출처일 때만 진행 중 → 할 일 절이 새로 맡겨진 요청·기한 있음·쌓인 요청을 대신한다.
assert_contains "$AF_RENDER" "scur === 'jira'" "the status groups apply to the jira filter only"
assert_contains "$AF_RENDER" "agStatusGroups(mine)" "the groups split the picked jira to-dos"
assert_contains "$AF_RENDER" "agSection('fresh', '새로 맡겨진 요청', fresh, o), agSection('due', '기한 있음', due, o)" "other filters keep the new and due sections"
assert_contains "$AF_RENDER" "jira ? null : staleFold(stale, o)" "jira items do not repeat in the stale fold"
case "$AF_RENDER" in
  *"agSection('jira-progress', '진행 중', prog, o)"*"agSection('jira-todo', '할 일', rest, o)"*) ;;
  *) fail "the in-progress group comes before the to-do group" ;;
esac
# 칩 색은 statusCategory로: 진행 중은 진행 상태 토큰, 할 일은 중립 칩 그대로.
AF_CSS="$(grep -n 'b-agtask__status' "$AF_TPLF")"
assert_contains "$AF_CSS" '.b-agtask__status[data-category="indeterminate"]' "the in-progress chip has its own colour rule"
assert_contains "$AF_CSS" "var(--color-progress)" "the in-progress chip uses the progress tokens"
# 좁은 폭(≤760px)에서는 칩을 제목 아래 줄로 내려 제목 폭을 빼앗지 않는다: lead가 줄바꿈하고 제목은 한 줄을 다 쓴다.
AF_NARROW="$(awk '/@media \(max-width: 760px\)/{m=1} m&&/b-agtask__/{print} m&&/^}/{m=0}' "$AF_TPLF")"
assert_contains "$AF_NARROW" '.b-agtask__lead { flex-wrap: wrap;' "the status chip wraps below the title on narrow screens"
assert_contains "$AF_NARROW" '.b-agtask__lead > .b-agtitle { flex: 1 1 100%; }' "the title keeps the full line on narrow screens"
assert_contains "$AF_NARROW" '.b-agtask__status { max-width: 100%; }' "the status chip never overflows its cell on narrow screens"
assert_contains "$(<"$ROOT/skills/board/SKILL.md")" "status_category" "the board skill documents the status fields"
pass "agenda shows jira status groups only under the jira filter"

# 5. 서버 POST /agenda/refresh-all: 격리 보드(빈 사용자 스킬 폴더 + fixture 소스).
AF_T="$TEST_TMP/board-agenda-filter"
AF_DATA="$AF_T/data"
mkdir -p "$AF_T/bin" "$AF_DATA" "$HM_CLAUDE_SKILLS_DIR" "$HM_CODEX_SKILLS_DIR"
for AF_S in acme inbox cal broken slow; do cp -R "$ROOT/tests/fixtures/agenda/skills/$AF_S" "$HM_CLAUDE_SKILLS_DIR/"; done
# 보드 상태 수집이 실제 claude·orca를 부르지 않게 가짜를 둔다.
cat >"$AF_T/bin/claude" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == agents ]]; then echo "[]"; exit 0; fi
exit 1
EOF
cat >"$AF_T/bin/orca" <<'EOF'
#!/usr/bin/env bash
echo '{"ok":true,"result":{"runs":[],"workers":[]}}'
EOF
chmod +x "$AF_T/bin/claude" "$AF_T/bin/orca"
AF_PORT="$(free_port)"
af_board() {
  env -u ATLASSIAN_USER -u ATLASSIAN_API_TOKEN JIRA_BASE_URL= \
    PATH="$AF_T/bin:$PATH" HARNESS_METRICS_DIR="$AF_DATA" HARNESS_CLAUDE_PROJECTS_DIR="$AF_T/projects" \
    HARNESS_CLAUDE_SETTINGS="$AF_T/settings.json" BOARD_PORT="$AF_PORT" BOARD_NO_BROWSER=1 BOARD_IDLE_EXIT=0 \
    BOARD_AGENDA_FETCH_TIMEOUT=4 bash "$ROOT/scripts/board/board.sh" "$@"
}
AF_URL="$(af_board open | jq -r '.url')"
AF_TOKEN="${AF_URL#*t=}"
AF_BASE="http://127.0.0.1:$AF_PORT"
track_test_process "$(jq -r '.pid' "$AF_DATA/board/server.json")"
af_get() { curl -s "$AF_BASE/agenda?t=$AF_TOKEN"; }
af_post() { # 동작 본문(JSON) → "본문\n상태 코드"
  curl -s -w '\n%{http_code}' -X POST -H "Origin: $AF_BASE" -d "$(jq -cn --arg t "$AF_TOKEN" --argjson b "$2" '$b + {t: $t}')" "$AF_BASE/agenda/$1"
}
af_code() { tail -n 1 <<<"$1"; }
af_body() { sed '$d' <<<"$1"; }
af_wait() { # jq 조건 — 참이 될 때까지 /agenda를 다시 읽는다(최대 15초)
  local out=""
  for _ in $(seq 1 75); do
    out="$(af_get)"
    if jq -e "$1" >/dev/null 2>&1 <<<"$out"; then printf '%s' "$out"; return 0; fi
    sleep 0.2
  done
  printf '%s' "$out"
  return 1
}
af_tried() { jq -r '.tried_at' "$AF_DATA/board/agenda/cache/$1.json"; }
af_age() { # 캐시의 시각을 과거로 돌려 다시 모으면 tried_at이 바뀌는 것을 본다
  jq '.fetched_at = "2000-01-01T00:00:00Z" | .tried_at = "2000-01-01T00:00:00Z"' "$AF_DATA/board/agenda/cache/$1.json" >"$AF_T/age.json"
  mv "$AF_T/age.json" "$AF_DATA/board/agenda/cache/$1.json"
}

# AC12: 연결이 0곳이면 409.
AF_RES="$(af_post refresh-all '{}')"
assert_eq "409|false|연결된 곳이 없습니다." "$(af_code "$AF_RES")|$(af_body "$AF_RES" | jq -r '"\(.ok)|\(.message)"')" "refresh-all needs a connected source"
assert_eq "403" "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Origin: $AF_BASE" -d '{"t":"wrong"}' "$AF_BASE/agenda/refresh-all")" "refresh-all needs the board token"
pass "agenda refresh-all refuses without a connected source"

# AC8: 연결된 acme·inbox·cal을 한꺼번에 다시 모은다 — 주기(15분)가 지나지 않아도 tried_at이 바뀐다.
for AF_S in acme inbox cal; do af_post connect "{\"source\":\"$AF_S\"}" >/dev/null; done
af_wait '[.sources[] | select((.id == "acme" or .id == "inbox" or .id == "cal") and .state == "connected" and (.fetching | not))] | length == 3' >/dev/null \
  || fail "acme, inbox and cal connect and fetch"
for AF_S in acme inbox cal; do af_age "$AF_S"; done
AF_RES="$(af_post refresh-all '{}')"
assert_eq "200|true|3곳에서 새로 가져왔습니다." "$(af_code "$AF_RES")|$(af_body "$AF_RES" | jq -r '"\(.ok)|\(.message)"')" "refresh-all reports every source it refreshed"
assert_eq "Acme 메신저,Example 요청함,Example 캘린더||0" "$(af_body "$AF_RES" | jq -r '"\(.refreshed | sort | join(","))|\(.skipped | join(","))|\(.failed | length)"')" "refresh-all names the refreshed sources"
for AF_S in acme inbox cal; do
  [ "$(af_tried "$AF_S")" != "2000-01-01T00:00:00Z" ] || fail "refresh-all fetches $AF_S again right away"
done
AF_LOG="$(grep '"agenda_refresh-all"' "$AF_DATA/board/actions.jsonl" | tail -n 1)"
assert_eq "true|acme,cal,inbox||" "$(jq -r '"\(.ok)|\(.refreshed | sort | join(","))|\(.skipped | join(","))|\(.failed | join(","))"' <<<"$AF_LOG")" "the action log keeps source ids only"
case "$AF_LOG" in *"$AF_TOKEN"*|*"Acme 메신저"*) fail "the action log has no token or source name" ;; esac
pass "agenda refresh-all refetches every connected source"

# AC9: 한 곳이 실패하면 ok:false, 실패한 이름·사유와 성공한 곳 수를 함께 알린다.
mkdir -p "$AF_DATA/fixture-broken"; : >"$AF_DATA/fixture-broken/fail"
af_post connect '{"source":"broken"}' >/dev/null
af_wait '(.sources[] | select(.id == "broken") | .state) == "error"' >/dev/null || fail "broken connects and fails"
AF_RES="$(af_post refresh-all '{}')"
AF_MSG="$(af_body "$AF_RES" | jq -r '.message')"
assert_eq "200|false" "$(af_code "$AF_RES")|$(af_body "$AF_RES" | jq -r '.ok')" "a partly failed refresh-all is not ok"
assert_contains "$AF_MSG" "3곳에서 새로 가져왔습니다." "the message counts the sources that worked"
assert_contains "$AF_MSG" "Broken 메일에서 가져오지 못했습니다." "the message names the failed source"
assert_contains "$AF_MSG" "메일 서버에 로그인하지 못했습니다" "the message keeps the adapter reason"
assert_eq "broken|Broken 메일" "$(af_body "$AF_RES" | jq -r '.failed[0] | "\(.source)|\(.name)"')" "failed lists the source id and name"
af_post disconnect '{"source":"acme"}' >/dev/null; af_post disconnect '{"source":"inbox"}' >/dev/null; af_post disconnect '{"source":"cal"}' >/dev/null
AF_RES="$(af_post refresh-all '{}')"
AF_MSG="$(af_body "$AF_RES" | jq -r '.message')"
case "$AF_MSG" in "Broken 메일에서 가져오지 못했습니다."*) ;; *) fail "an all-failed message starts with the failure (got $AF_MSG)" ;; esac
case "$AF_MSG" in *"곳에서 새로 가져왔습니다"*) fail "an all-failed message has no success count" ;; esac
af_post disconnect '{"source":"broken"}' >/dev/null
pass "agenda refresh-all reports a failed source"

# AC10: 이미 수집 중인 소스(slow, 끝나지 않음)는 건너뛰고 그 스레드를 기다리지 않는다.
af_post connect '{"source":"acme"}' >/dev/null
af_wait '(.sources[] | select(.id == "acme") | .state == "connected" and (.fetching | not))' >/dev/null || fail "acme connects again"
af_post connect '{"source":"slow"}' >/dev/null
AF_START="$(date +%s)"
AF_RES="$(af_post refresh-all '{}')"
(($(date +%s) - AF_START < 4)) || fail "refresh-all does not wait for a fetch that was already running"
assert_eq "200|true|Slow 그룹웨어|Acme 메신저" "$(af_code "$AF_RES")|$(af_body "$AF_RES" | jq -r '"\(.ok)|\(.skipped | join(","))|\(.refreshed | join(","))"')" "a running source is skipped"
assert_contains "$(af_body "$AF_RES" | jq -r '.message')" "Slow 그룹웨어은(는) 이미 가져오는 중이라 건너뛰었습니다." "the message says the running source was skipped"
assert_eq "slow" "$(grep '"agenda_refresh-all"' "$AF_DATA/board/actions.jsonl" | tail -n 1 | jq -r '.skipped | join(",")')" "the action log keeps the skipped id"
af_post disconnect '{"source":"slow"}' >/dev/null
pass "agenda refresh-all skips a source that is already fetching"

af_board stop >/dev/null
finish_tests
