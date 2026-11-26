#!/usr/bin/env bash
# 회귀 테스트 — 보드 갱신 비용·캐시 재사용·러너 상태 분류·화면 문구·미리보기 fixture
# 실행: bash tests/run.sh board-status-refresh
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# 갱신 비용(#380): 다음 갱신은 직전 수집 시간의 두 배 뒤(수집이 시간의 절반을 넘지 않게), 값싼 변경 지문이 같으면 전체 수집을
# 건너뛰되 최소 주기(BOARD_FULL_REFRESH_SECONDS)마다는 모은다. 마지막 결과는 0600 스냅숏으로 남겨 다시 띄우면 그것부터 보인다.
BRC_T="$TEST_TMP/board-refresh-cost"
mkdir -p "$BRC_T/data/harvest-auto" "$BRC_T/cfg/sessions" "$BRC_T/cfg/jobs/j1" "$BRC_T/home"
printf '{}\n' >"$BRC_T/cfg/sessions/1.json"
printf '{}\n' >"$BRC_T/cfg/jobs/j1/state.json"
printf 'a\n' >"$BRC_T/t.jsonl"
HOME="$BRC_T/home" HARNESS_METRICS_DIR="$BRC_T/data" BOARD_REFRESH_SECONDS=0.2 BOARD_FULL_REFRESH_SECONDS=30 \
  BOARD_CLAUDE_CONFIG_DIRS="$BRC_T/cfg" BOARD_CLAUDE_PROFILE_GLOBS="$BRC_T/none/*" python3 -I -B -c '
import importlib.util, json, os, stat, sys, time
def load():
    spec = importlib.util.spec_from_file_location("bs", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m); return m
T, data = sys.argv[2], os.environ["HARNESS_METRICS_DIR"]
bs = load()
assert bs.restore_snapshot() is False  # 서버가 뜰 때 부른다. 스냅숏이 없으면 아무것도 올리지 않는다
calls = []
def slow_build(cached=False):
    calls.append(cached); time.sleep(0.4)
    return {"items": [{"id": "n%d" % len(calls), "transcript": T + "/t.jsonl"}], "snapshot_at": None}
bs._build = slow_build
fp = [("a", "t")]
real_fp, bs.fingerprint = bs.fingerprint, lambda: fp[0]
bs._active["at"] = time.time()
bs.refresh_once()
assert calls == [True], calls  # 백그라운드 갱신은 status.sh의 입력 캐시를 쓴다
assert bs.refresh_wait() <= max(0.5, bs.REFRESH) + 0.01, bs.refresh_wait()  # 지문 확인은 느린 수집 뒤에도 REFRESH마다
bs._cache["at"] = time.time() - 5
bs.refresh_once()
assert len(calls) == 1, calls  # 지문이 같으면 건너뛴다
assert time.time() - bs._cache["at"] < 1  # 확인한 캐시는 새것으로 친다(요청이 그 자리에서 모으지 않게)
# 지문이 바뀌어도 직전 수집 시작 뒤 그 수집 시간의 두 배가 지나기 전에는 모으지 않고, 열리는 때에 맞춰 다시 본다
bs._timing.update(start=time.time(), dur=1.0)
fp[0] = ("b", "t"); bs._cache["at"] = time.time() - 5
bs.refresh_once()
assert len(calls) == 1 and bs._pending["at"] is not None, (calls, bs._pending)
assert bs.refresh_wait() <= max(0.5, bs.REFRESH) + 0.01, bs.refresh_wait()
bs._timing["start"] -= 3
bs.refresh_once()
assert len(calls) == 2 and bs._pending["at"] is None, calls  # 쉬는 시간이 지나면 바로 모은다
fp[0] = ("b", "t2"); bs._cache["at"] = time.time() - 5
bs.refresh_once()
assert len(calls) == 2, calls  # 대화 기록만 바뀌었으면(일하는 세션) TRANSCRIPT_REFRESH 안에서는 건너뛴다
bs._cache["at"] = time.time() - 5; bs._full["at"] = time.time() - bs.TRANSCRIPT_REFRESH - 1; bs._timing["dur"] = 0
bs.refresh_once()
assert len(calls) == 3, calls  # 그 뒤에는 모은다
bs._cache["at"] = time.time() - 5; bs._full["at"] = time.time() - bs.FULL_REFRESH - 1; bs._timing["dur"] = 0
bs.refresh_once()
assert len(calls) == 4, calls  # 지문이 같아도 최소 주기마다는 모은다
bs.worktree_candidates = lambda items: []  # 개발 머신의 실제 Orca·git worktree를 읽지 않게
# 정리(B1): 지문 확인은 캐시 시각만 새로 매기므로, 실제 일괄 정리는 나이와 관계없이 입력 캐시 없이 새로 모은다
bs._cache["at"] = time.time() - 5; bs.refresh_once()  # 건너뛴 확인 직후
n = len(calls)
bs.bulk_cleanup({"older_days": 1})
assert len(calls) == n + 1 and calls[-1] is False, calls
bs._cache["data"] = None
bs.status()
assert calls[-1] is False, calls  # 동작 뒤 비운 캐시는 입력 캐시 없이 새로 모은다
# 진짜 지문: 하네스 기록·세션 상태 파일·보이는 세션의 대화 기록이 바뀌면 달라진다
bs.fingerprint = real_fp
a = bs.fingerprint()
assert a == bs.fingerprint()
time.sleep(1.1)
with open(T + "/t.jsonl", "a") as f: f.write("b\n")
b = bs.fingerprint(); assert b != a
with open(data + "/harvest-auto/runs.jsonl", "a") as f: f.write("{}\n")
c = bs.fingerprint(); assert c != b
with open(T + "/cfg/sessions/2.json", "w") as f: f.write("{}")
d = bs.fingerprint(); assert d != c
with open(T + "/cfg/jobs/j1/state.json", "a") as f: f.write(" ")
assert bs.fingerprint() != d
# 스냅숏: 0600 파일, 다시 띄우면 첫 응답은 수집을 기다리지 않는 스냅숏
snap = os.path.join(data, "board", "snapshot.json")
assert stat.S_IMODE(os.stat(snap).st_mode) == 0o600, oct(os.stat(snap).st_mode)
saved = json.load(open(snap))
bs2 = load(); fresh = []
bs2._build = lambda cached=False: (fresh.append(1), {"items": [{"id": "fresh"}], "snapshot_at": None})[1]
assert bs2.restore_snapshot() is True
t0 = time.time(); d = bs2.status()
assert not fresh and time.time() - t0 < 0.5, fresh
assert [i["id"] for i in d["items"]] == [i["id"] for i in saved["items"]], d
assert d["snapshot_at"], d  # 화면이 "N분 전 상태 — 새로 모으는 중"을 보인다
assert bs2._wake.is_set()  # 바로 새로 모으도록 깨운다
bs2._active["at"] = time.time()
bs2.fingerprint = lambda: ("same", "x"); bs2._fp["last"] = ("same", "x")
bs2.refresh_once()
assert fresh, "a restored snapshot is replaced by a fresh collection even when the fingerprint did not change"
d = bs2.status()
assert d["items"][0]["id"] == "fresh" and d["snapshot_at"] is None, d
os.remove(snap)
bs3 = load(); bs3._build = lambda cached=False: {"items": [], "snapshot_at": None}
assert bs3.status()["snapshot_at"] is None  # 스냅숏이 없으면 예전처럼 그 자리에서 모은다
' "$ROOT/scripts/board/board-server.py" "$BRC_T" || fail "the board refresh backs off after slow collections, skips unchanged inputs within the full-refresh period and restores the last snapshot first"
# status.sh가 받는 환경: 백그라운드 갱신만 BOARD_CACHE_SECONDS를 넘긴다
assert_contains "$(sed -n '/^def _build(/,/^    data = json.loads/p' "$ROOT/scripts/board/board-server.py")" "BOARD_CACHE_SECONDS" "the background refresh lets status.sh reuse unchanged inputs"
BRC_TPL="$(<"$ROOT/scripts/board/template.html")"
assert_contains "$BRC_TPL" "새로 모으는 중" "the board says the list is a saved snapshot being refreshed"
assert_contains "$BRC_TPL" "data.snapshot_at" "the board reads when the snapshot was taken"
pass "board refresh backs off, skips unchanged inputs and opens with the last snapshot"

# status.sh·work.sh 입력 캐시(#380): BOARD_CACHE_SECONDS가 있으면 하네스 기록(무인 실행·러너·대기열)이 그대로일 때 지난 결과를,
# 설정 폴더의 세션 상태 파일(sessions/·jobs/)이 그대로일 때 지난 claude agents 결과를 그 초 동안 다시 쓴다. 없으면(기본) 늘 새로.
BSC_T="$TEST_TMP/board-status-cache"
mkdir -p "$BSC_T/bin" "$BSC_T/data/harvest-auto" "$BSC_T/data/board" "$BSC_T/cfg/sessions" "$BSC_T/projects"
BSC_REAL_JQ="$(command -v jq)"
cat >"$BSC_T/bin/jq" <<'FAKE'
#!/usr/bin/env bash
printf 'jq\n' >>"$FAKE_JQ_LOG"
exec "$REAL_JQ" "$@"
FAKE
cat >"$BSC_T/bin/claude" <<'FAKE'
#!/usr/bin/env bash
[[ "$1" == agents ]] || exit 1
printf 'agents\n' >>"$FAKE_CLAUDE_LOG"
echo '[]'
FAKE
chmod +x "$BSC_T/bin/jq" "$BSC_T/bin/claude"
bsc_fin() { jq -cn --arg at "$(jq -rn --argjson m "$1" '(now - $m * 60) | floor | todate')" --arg p "$2" \
  '{at: $at, event: "finished", project: $p, batch: "b", scope: "project", result: "left_for_user", exit_code: 0, artifact: null, log: null}'; }
bsc_fin 30 p1 >"$BSC_T/data/harvest-auto/runs.jsonl"
bsc_status() {
  : >"$BSC_T/jq.log"; : >"$BSC_T/claude.log"
  env -u CLAUDE_CONFIG_DIR PATH="$BSC_T/bin:$PATH" REAL_JQ="$BSC_REAL_JQ" FAKE_JQ_LOG="$BSC_T/jq.log" FAKE_CLAUDE_LOG="$BSC_T/claude.log" \
    HARNESS_METRICS_DIR="$BSC_T/data" HARNESS_CLAUDE_PROJECTS_DIR="$BSC_T/projects" HOME="$BSC_T/home" \
    BOARD_CLAUDE_PROFILE_GLOBS="$BSC_T/none/*" BOARD_CLAUDE_CONFIG_DIRS="$BSC_T/cfg" "$@" bash "$ROOT/scripts/board/status.sh"
}
BSC_COLD="$(bsc_status BOARD_CACHE_SECONDS=600)"
BSC_COLD_JQ="$(wc -l <"$BSC_T/jq.log" | tr -d ' ')"
assert_eq "1" "$(jq '[.items[] | select(.project == "p1")] | length' <<<"$BSC_COLD")" "the cold run lists the harness run"
BSC_WARM="$(bsc_status BOARD_CACHE_SECONDS=600)"
BSC_WARM_JQ="$(wc -l <"$BSC_T/jq.log" | tr -d ' ')"
assert_eq "$(jq -c 'del(.generated_at)' <<<"$BSC_COLD")" "$(jq -c 'del(.generated_at)' <<<"$BSC_WARM")" "a warm run prints the same status"
[ "$BSC_WARM_JQ" -lt $((BSC_COLD_JQ / 2)) ] || fail "a warm run reuses the harness part (jq calls cold=$BSC_COLD_JQ warm=$BSC_WARM_JQ)"
assert_eq "0" "$(grep -c agents "$BSC_T/claude.log")" "a warm run reuses claude agents while the session state files are unchanged"
for f in "$BSC_T/data/board/"status-cache* "$BSC_T/data/board/"agents-cache*; do
  [ -e "$f" ] || continue
  assert_eq "" "$(find "$f" -perm -g+r 2>/dev/null; find "$f" -perm -o+r 2>/dev/null)" "status caches are readable only by the user: $f"
done
bsc_fin 5 p2 >>"$BSC_T/data/harvest-auto/runs.jsonl"
assert_eq "1" "$(bsc_status BOARD_CACHE_SECONDS=600 | jq '[.items[] | select(.project == "p2")] | length')" "a new harness record is picked up at once"
printf '{}\n' >"$BSC_T/cfg/sessions/9.json"
bsc_status BOARD_CACHE_SECONDS=600 >/dev/null
assert_eq "1" "$(grep -c agents "$BSC_T/claude.log")" "a changed session state file asks that folder's claude agents again (only that folder)"
bsc_status >/dev/null
assert_eq "2" "$(grep -c agents "$BSC_T/claude.log")" "without BOARD_CACHE_SECONDS every folder is asked again"
pass "status.sh and work.sh reuse unchanged harness records and session lists only when the board asks"

# '세션으로 열기'가 띄우는 세션 이름은 원문 로그 제목이 아니라 시그니처다(#296): 원문 로그가 세션 이름·카드 제목으로 새지 않고, 시그니처로 에러 카드와 이어진다.
BO_DATA="$TEST_TMP/board-open-agent"
mkdir -p "$BO_DATA"
HARNESS_METRICS_DIR="$BO_DATA" python3 -I -B -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("bs", sys.argv[1]); bs = importlib.util.module_from_spec(spec); spec.loader.exec_module(bs)
got = {}
bs.new_bg = lambda cwd, prompt, name=None: got.update(cwd=cwd, name=name) or {"ok": True, "message": "ok"}
raw = "2026-11-11 23:59:04.078 ERROR 12345 --- [nio-8080-exec-1] c.a.s.FooService : 주문 저장 실패"
af = {"id": "autofix:orders:datadog:7c1e5a9b3d2f4e60", "kind": "autofix", "section": "autofix", "project": "orders", "signature": "datadog:7c1e5a9b3d2f4e60",
      "title": raw, "repo": "/work/acme/orders", "actions": ["open_agent"], "stage": "skipped", "stage_label": "건너뜀", "link": None, "detail": "요약"}
bs.run_action(af, "open_agent", {})
assert got["name"] == "orders 에러 이어 보기 datadog:7c1e5a9b3d2f4e60", got
assert "FooService" not in got["name"] and "12345" not in got["name"], got
named = {"id": "w1", "section": "work", "project": "orders", "title": got["name"], "detail": ""}
bs.link_autofix_sessions([af, named])
assert af.get("session_id") == "w1" and named.get("autofix_id") == af["id"], (af, named)
harness = {"id": "harvest|docs|t", "kind": "harvest", "section": "harness", "project": "docs", "title": "개선 — draft PR 검토", "repo": "/work/acme/docs",
           "actions": ["open_agent"], "link": "https://example.com/acme/docs/pull/77"}
bs.run_action(harness, "open_agent", {})
assert got["name"] == "docs 개선 — draft PR 검토", got  # 하네스 카드의 세션 이름은 그대로
' "$ROOT/scripts/board/board-server.py" || fail "open_agent names an autofix session by project and signature, not by the raw error title, and the card still links to it"
pass "board names the session opened from an autofix card by signature, not by the raw log title"

# 보드 화면(#296, 정적): 정리 즉시 반영·남은 이유·실패 카드·빈 로그·무변경 요약·자동 수정 제목이 template.html에 들어갔다.
BOARD_TPL2="$(<"$ROOT/scripts/board/template.html")"
# 정리 응답 뒤에는 정리된 것(ok)만 숨김에 남는다 — 그 사이 다시 돌기 시작해 서버가 뺀 세션도 바로 되돌아온다.
for BOARD_PART2 in "hiding.has(" "hiding.add(" "hiding.delete(" "res.results.filter((x) => x.ok)" "quiet_runs" "log_note" "fail_reason" "streak"; do
  assert_contains "$BOARD_TPL2" "$BOARD_PART2" "the board screen uses $BOARD_PART2"
done
[[ "$(grep -c -E '\.left\b' <<<"$BOARD_TPL2" || true)" -ge 2 ]] || fail "the cleanup plan screen and the result screen both show the reasons items were left"
if command -v node >/dev/null 2>&1; then
  # 자동 수정 제목: Spring Boot 로그 머리(pid --- [thread] logger :)도 걷어 낸다. 함수 본문만 잘라 실행한다.
  sed -n '/function humanTitle(raw) {/,/^  }$/p' "$ROOT/scripts/board/template.html" >"$TEST_TMP/human-title.js"
  printf '%s\n' 'console.log(JSON.stringify([
    humanTitle("2026-11-11 23:59:04.078 ERROR 12345 --- [nio-8080-exec-1] c.a.s.FooService : 주문 저장 실패"),
    humanTitle("2026-11-11 23:59:04.078  WARN 4242 --- [           main] c.a.OrderService : 결제 승인 실패"),
    humanTitle("2026-11-11 23:59:04.078 ERROR 12345 --- [shop] [nio-8080-exec-1] c.a.s.PayService : 환불 처리 실패"),
    humanTitle("2026-11-10 09:14:15.264 ERROR trace_id:4af2c9e1b7d84a0f9c3e - CartController:88: 장바구니 합계 계산에 실패했습니다. cartSn: 1042")]))' >>"$TEST_TMP/human-title.js"
  assert_eq '["주문 저장 실패","결제 승인 실패","환불 처리 실패","장바구니 합계 계산에 실패했습니다"]' "$(node "$TEST_TMP/human-title.js")" "a Spring Boot log head is stripped to the human message, other log heads still are"
fi
pass "board screen carries instant hiding, left reasons, failure cards, quiet runs and Spring Boot title cleanup"

# 화면 확인용 가짜 데이터(#296): 실패 streak 카드·quiet_runs·정리 left·Spring Boot 형식 제목이 있어 브라우저로 볼 수 있다. 가짜 값만.
python3 -I -B -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("pv", sys.argv[1]); pv = importlib.util.module_from_spec(spec); spec.loader.exec_module(pv)
s = pv.status("demo")
fail = [i for i in s["items"] if i.get("fail_reason")]
assert len(fail) == 1 and fail[0]["kind"] == "sync" and fail[0]["state"] == "needs_human" and fail[0]["streak"] == 3, fail
assert fail[0]["log"] is None and fail[0]["log_note"] and fail[0]["fail_reason"] == "45분 시간 제한으로 중단됨" and fail[0]["exit_code"] == 143, fail
assert s["quiet_runs"] and all({"kind", "count", "last_at"} <= set(q) for q in s["quiet_runs"]), s.get("quiet_runs")
assert any(i["kind"] == "autofix" and " --- [" in i["title"] and "ERROR" in i["title"] for i in s["items"]), "a Spring Boot style autofix title"
for req in ({"dry_run": True, "older_days": 1}, {"older_days": 1}):
    r = pv.bulk("demo", dict(req, t="demo"))
    assert r["left"] and all({"reason", "count", "label"} <= set(l) and l["count"] > 0 for l in r["left"]), r
assert pv.status("empty")["quiet_runs"] == []
' "$ROOT/tests/fixtures/board-preview/serve.py" || fail "the board preview server has the failure streak card, quiet runs, cleanup reasons and a Spring Boot style title"
pass "board preview fixture reproduces the #296 screens with fake data"

# 보드 정확도(#299) — harvest 대기열: 무인 실행이 batch마다 남긴 시도 표시로 다음 실행에서 실제로 돌 batch만 카드로 낸다.
# 같은 batch가 이미 하네스 없음·세션 수만·포기·실행됨으로 끝났으면 카드 대신 이유별 수(queue_hidden)로만 센다. batch 파일은 그대로 둔다.
BA_T="$TEST_TMP/board-accuracy"
BA_DATA="$BA_T/data"
mkdir -p "$BA_T/bin" "$BA_DATA"
ba_batch() { # $1=폴더 $2=project $3=batch_id $4=시도 표시 batch_id(없으면 -) $5=시도 결과
  mkdir -p "$BA_DATA/harvest-queue/$1"
  jq -cn --arg p "$2" --arg b "$3" '{project: $p, batch_id: $b, has_analysis_batch: true, created_at: "2026-11-01T00:00:00Z", counts: {sessions: 4}, reasons: ["errors"]}' \
    >"$BA_DATA/harvest-queue/$1/analysis-batch.json"
  [[ "$4" == - ]] || jq -cn --arg b "$4" --arg r "$5" '{batch_id: $b, at: "2026-11-02T00:00:00Z", result: $r, fails: 0}' >"$BA_DATA/harvest-queue/$1/auto-attempted-batch"
}
ba_batch p-home home b1 b1 no_harness
ba_batch p-notes notes b2 b2 sessions_only
ba_batch p-ran ran b3 b3 launched
ba_batch p-gone gone b4 b4 gave_up
ba_batch p-old2 old2 b5 b5 no_harness
ba_batch p-next next b6 b0 launched
ba_batch p-new new b7 - -
ba_batch p-retry retry b8 b8 failed
cat >"$BA_T/bin/claude" <<'FAKE'
#!/usr/bin/env bash
if [[ "$1" == agents ]]; then cat "$BA_AGENTS" 2>/dev/null || echo "[]"; exit 0; fi
exit 1
FAKE
chmod +x "$BA_T/bin/claude"
# 워크플로 러너: incomplete로 멈춘 것, running인데 실행 폴더에 오래 기록이 없는 것, 방금 기록이 있는 running.
ba_run() { # $1=run 폴더 $2=status $3=node — 작업 폴더 $BA_T/repo-<run 폴더>도 만든다(#615)
  mkdir -p "$BA_DATA/runs/$1" "$BA_T/repo-$1"
  jq -cn --arg s "$2" --arg n "$3" --arg r "$BA_T/repo-$1" '{run_id: "r1", workflow: "feature", status: $s, node: $n, repo: $r, request: "가짜 요청", started_at: "2026-11-01T00:00:00Z"}' \
    >"$BA_DATA/runs/$1/state.json"
  printf 'x\n' >"$BA_DATA/runs/$1/progress.log"
}
ba_run a/1 incomplete publish
ba_run b/1 running discover
ba_run c/1 running repair
ba_run d/1 baseline_changed approval
jq '.needs_user_decision = true' "$BA_DATA/runs/d/1/state.json" >"$BA_T/d.json" && mv "$BA_T/d.json" "$BA_DATA/runs/d/1/state.json"
touch -t 202601010000 "$BA_DATA/runs/b/1/state.json" "$BA_DATA/runs/b/1/progress.log"
ba_status() {
  env -u CLAUDE_CONFIG_DIR PATH="$BA_T/bin:$PATH" BA_AGENTS="$BA_T/agents.json" HARNESS_METRICS_DIR="$BA_DATA" HARNESS_CLAUDE_PROJECTS_DIR="$BA_T/projects" \
    BOARD_CLAUDE_PROFILE_GLOBS="$BA_T/none/*" BOARD_CLAUDE_CONFIG_DIRS= "$@" bash "$ROOT/scripts/board/status.sh"
}
BA_OUT="$(ba_status)"
assert_eq "new,next,retry" "$(jq -r '[.items[] | select(.kind == "harvest" and .state == "queued") | .project] | sort | join(",")' <<<"$BA_OUT")" \
  "only batches the next unattended run will take are queued cards"
assert_eq "gave_up:1|launched:1|no_harness:2|sessions_only:1" "$(jq -r '[.queue_hidden[] | "\(.reason):\(.count)"] | sort | join("|")' <<<"$BA_OUT")" \
  "batches that will not run are counted by reason instead of shown"
assert_file "$BA_DATA/harvest-queue/p-home/analysis-batch.json"
pass "board status queues only the harvest batches the next run takes and counts the rest by reason"

# 러너: 프로세스 기록(pid)이 없어 실행 폴더의 마지막 기록 시각을 본다. 중단(incomplete)·오래 조용한 running은 '중단됨'과 이어 가는 명령.
assert_eq "blocked|incomplete|workflow-driver.sh resume --workflow feature" "$(jq -r '.items[] | select(.kind == "runner" and (.cwd | endswith("repo-a/1"))) | "\(.state)|\(.stall)|\(.cmd)"' <<<"$BA_OUT")" \
  "an incomplete runner is stopped, not working"
assert_eq "blocked|no_activity" "$(jq -r '.items[] | select(.kind == "runner" and (.cwd | endswith("repo-b/1"))) | "\(.state)|\(.stall)"' <<<"$BA_OUT")" \
  "a running runner with no record for a long time is stopped"
assert_eq "running|null" "$(jq -r '.items[] | select(.kind == "runner" and (.cwd | endswith("repo-c/1"))) | "\(.state)|\(.stall)"' <<<"$BA_OUT")" \
  "a runner that just wrote its record is still working"
assert_eq "needs_human" "$(jq -r '.items[] | select(.kind == "runner" and (.cwd | endswith("repo-d/1"))) | .state' <<<"$BA_OUT")" \
  "a runner stopped because the repository changed after it stopped waits for a person (#371)"
assert_eq "null" "$(jq -r '.items[] | select(.kind == "runner" and (.cwd | endswith("repo-d/1"))) | .cmd' <<<"$BA_OUT")" \
  "a baseline-changed run does not offer approve even when a polish measurement awaited a decision (#371)"
assert_eq "running" "$(ba_status BOARD_RUNNER_STALE_MIN=99999999 | jq -r '.items[] | select(.kind == "runner" and (.cwd | endswith("repo-b/1"))) | .state')" \
  "BOARD_RUNNER_STALE_MIN sets how long a quiet runner still counts as working"
pass "board status shows a dead or incomplete workflow runner as stopped"

# 러너 상태(#564): 아는 status마다 알맞은 칸·명령으로 분류한다. 사람 결정·승인·불변식 위반은 사람 필요, stopped는 이어 가기, 포기·fix_list는 끝남, 모르는 status는 막힘이고 어느 것도 '작업 중'이 아니다.
B5_T="$BA_T/data564"
b5_run() { # $1=데이터 폴더 $2=run 폴더 $3=status $4=node $5=추가 jq — 작업 폴더 $BA_T/repo-<run 폴더>도 만든다(#615)
  mkdir -p "$1/runs/$2" "$BA_T/repo-$2"
  jq -cn --arg s "$3" --arg n "$4" --arg r "$BA_T/repo-$2" '{run_id: "r1", workflow: "feature", status: $s, node: $n, repo: $r, request: "가짜 요청", started_at: "2026-11-01T00:00:00Z"}' \
    | jq -c "${5:-.}" >"$1/runs/$2/state.json"
  printf 'x\n' >"$1/runs/$2/progress.log"
}
b5_item() { # $1=데이터 폴더 $2=run 폴더 $3=jq 출력식 나머지는 ba_status 환경
  local d="$1" r="$2" f="$3"
  shift 3
  ba_status HARNESS_METRICS_DIR="$d" "$@" | jq -r --arg r "repo-$r" ".items[] | select(.kind == \"runner\" and (.cwd | endswith(\$r))) | $f"
}
B5_NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$B5_T"
b5_run "$B5_T" ud/1 user_decision user_decision ".message = \"결정 필요 이유\" | .finished_at = \"$B5_NOW\""
b5_run "$B5_T" wa/1 waiting_approval approval ".presented_at = \"$B5_NOW\""
b5_run "$B5_T" iv/1 invariant_violation invariant_violation ".message = \"불변식 위반\" | .finished_at = \"$B5_NOW\""
b5_run "$B5_T" st/1 stopped fix ".finished_at = \"$B5_NOW\""
b5_run "$B5_T" ab/1 abandoned brief ".started_at = \"$B5_NOW\""
b5_run "$B5_T" zz/1 weird_unknown review ".started_at = \"$B5_NOW\""
b5_run "$B5_T" fl/1 fix_list brief ".started_at = \"$B5_NOW\""
B5_ITEMS="$(ba_status HARNESS_METRICS_DIR="$B5_T" | jq -c '[.items[] | select(.kind == "runner")]')"
b5_get() { jq -r --arg r "repo-$1" ".[] | select(.cwd | endswith(\$r)) | $2" <<<"$B5_ITEMS"; }
assert_eq "needs_human|null" "$(b5_get ud/1 '"\(.state)|\(.cmd)"')" "a user_decision runner waits for a person with no command"
assert_contains "$(b5_get ud/1 .detail)" "결정 필요 이유" "a user_decision runner shows its message"
assert_eq "needs_human|workflow-driver.sh approve --run r1" "$(b5_get wa/1 '"\(.state)|\(.cmd)"')" "a waiting_approval runner offers approve"
assert_eq "needs_human|null" "$(b5_get iv/1 '"\(.state)|\(.cmd)"')" "an invariant_violation runner waits for a person"
assert_contains "$(b5_get iv/1 .detail)" "불변식 위반" "an invariant_violation runner shows its message"
assert_eq "blocked|stopped|workflow-driver.sh resume --workflow feature" "$(b5_get st/1 '"\(.state)|\(.stall)|\(.cmd)"')" "a stopped runner is stopped and offers resume"
assert_eq "done" "$(b5_get ab/1 .state)" "a recent abandoned runner is done"
assert_contains "$(b5_get ab/1 .detail)" "abandoned" "an abandoned runner detail keeps the original status"
assert_eq "done" "$(b5_get fl/1 .state)" "a recent fix_list runner is done"
assert_contains "$(b5_get fl/1 .detail)" "fix_list" "a fix_list runner detail keeps the original status"
assert_eq "blocked|null" "$(b5_get zz/1 '"\(.state)|\(.cmd)"')" "an unknown runner status is blocked, not working"
assert_contains "$(b5_get zz/1 .detail)" "weird_unknown" "an unknown runner status shows the original value"
assert_eq "0" "$(jq '[.[] | select(.state == "running")] | length' <<<"$B5_ITEMS")" "none of these runner statuses count as running"
pass "board status classifies each workflow runner status instead of calling it running"

# 결정 대기 나이(#564): 오래 방치된 결정 대기는 '사람 필요'로 계속 두지 않고 막힘(decision_stale)으로 내린다. 기준은 BOARD_DECISION_STALE_DAYS(기본 7).
B5_OLD="$BA_T/data564-old"
b5_run "$B5_OLD" old/1 await_approval await_approval '.needs_user_decision = true | .presented_at = "2026-01-01T00:00:00Z"'
b5_run "$B5_OLD" new/1 await_approval await_approval ".needs_user_decision = true | .presented_at = \"$B5_NOW\""
assert_eq "blocked|decision_stale|workflow-driver.sh approve --run r1" "$(b5_item "$B5_OLD" old/1 '"\(.state)|\(.stall)|\(.cmd)"')" \
  "a decision wait older than the limit is stale but still offers approve"
assert_eq "needs_human" "$(b5_item "$B5_OLD" new/1 .state)" "a decision wait presented just now still waits for a person"
assert_eq "needs_human" "$(b5_item "$B5_OLD" old/1 .state BOARD_DECISION_STALE_DAYS=99999)" "BOARD_DECISION_STALE_DAYS raises how long a decision wait stays with a person"
pass "board status marks a long-waiting runner decision as stale"

# 입력 캐시(#564): BOARD_DECISION_STALE_DAYS가 판정을 바꾸므로 캐시 키에 들어가야 한다. 같은 캐시 아래에서 이 값만 바꿔도 결과가 바뀐다.
B5_CACHE="$BA_T/data564-cache"
b5_run "$B5_CACHE" old/1 await_approval await_approval '.needs_user_decision = true | .presented_at = "2026-01-01T00:00:00Z"'
assert_eq "blocked" "$(b5_item "$B5_CACHE" old/1 .state BOARD_CACHE_SECONDS=600)" "the first run with the cache on sees the stale decision"
assert_eq "needs_human" "$(b5_item "$B5_CACHE" old/1 .state BOARD_CACHE_SECONDS=600 BOARD_DECISION_STALE_DAYS=99999)" \
  "changing only BOARD_DECISION_STALE_DAYS does not reuse the cached result"
pass "board status input cache key includes BOARD_DECISION_STALE_DAYS"

# 러너 카드 link(#588): 끝나지 않은 러너도 publish.pr_url이 있으면 카드 link로 실어야 보드가 PR 상태(병합·닫힘)를 읽을 수 있다. pr_url이 없으면 null.
B5_LINK="$BA_T/data588"
b5_pr() { printf '.publish.pr_url = "https://github.com/acme/shop/pull/%s" | .finished_at = "%s"' "$1" "$B5_NOW"; }
mkdir -p "$B5_LINK"
b5_run "$B5_LINK" ud/1 user_decision user_decision "$(b5_pr 601)"
b5_run "$B5_LINK" st/1 stopped fix "$(b5_pr 602)"
b5_run "$B5_LINK" fa/1 failed fix "$(b5_pr 603)"
b5_run "$B5_LINK" iv/1 invariant_violation invariant_violation "$(b5_pr 604)"
b5_run "$B5_LINK" np/1 stopped fix ".finished_at = \"$B5_NOW\""
for B5_CASE in ud/1:601:needs_human st/1:602:blocked fa/1:603 iv/1:604:needs_human; do
  B5_DIR="${B5_CASE%%:*}"
  B5_N="$(cut -d: -f2 <<<"$B5_CASE")"
  assert_eq "https://github.com/acme/shop/pull/$B5_N" "$(b5_item "$B5_LINK" "$B5_DIR" .link)" "an unfinished runner ($B5_DIR) carries its publish.pr_url as link"
done
assert_eq "null" "$(b5_item "$B5_LINK" np/1 .link)" "an unfinished runner without publish.pr_url has a null link"
pass "board status carries publish.pr_url as the link of unfinished runner cards"

# 러너 카드 PR 상태(#588): 멈춘 러너(needs_human·blocked)의 PR이 러너 밖에서 병합·닫히면 prstate.apply가 done으로 내려야 한다. 열림·캐시 없음·running·agent·bg는 그대로, harness는 기존 동작.
B5_PS="$(python3 -I -B -c '
import sys, time
sys.path.insert(0, sys.argv[1])
import prstate
url = lambda n: "https://github.com/acme/shop/pull/%d" % n
now = time.time()
prstate._cache.update({url(701): {"state": "MERGED", "at": now}, url(702): {"state": "CLOSED", "at": now},
                       url(703): {"state": "OPEN", "at": now}, url(705): {"state": "MERGED", "at": now},
                       url(706): {"state": "MERGED", "at": now}, url(707): {"state": "MERGED", "at": now},
                       url(708): {"state": "MERGED", "at": now}})
cmd = "workflow-driver.sh resume --workflow feature"
def card(n, kind, state, **kw):
    d = {"section": "work", "kind": kind, "state": state, "title": "t%d" % n, "link": url(n), "cmd": cmd, "actions": ["open_agent"]}
    d.update(kw)
    return d
cases = [("runner-needs-human-merged", card(701, "runner", "needs_human")),
         ("runner-blocked-closed", card(702, "runner", "blocked", stall="stopped")),
         ("runner-needs-human-open", card(703, "runner", "needs_human")),
         ("runner-blocked-uncached", card(704, "runner", "blocked", stall="stopped")),
         ("runner-running-merged", card(705, "runner", "running")),
         ("agent-merged", card(706, "agent", "needs_human")),
         ("bg-merged", card(707, "bg", "needs_human")),
         ("harness-merged", {"section": "harness", "state": "needs_human", "title": "t708", "link": url(708), "actions": ["open_agent"]})]
prstate.apply([c for _, c in cases])
for name, c in cases:
    print("%s|%s|%s|%s|%s" % (name, c["state"], c["title"], c.get("cmd"), "stall" in c))
print("want704|%s" % (url(704) in prstate._want))
' "$ROOT/scripts/board")"
b5_ps() { grep "^$1|" <<<"$B5_PS" || true; }
assert_eq "runner-needs-human-merged|done|t701 → PR 병합됨|None|False" "$(b5_ps runner-needs-human-merged)" "a merged PR moves a person-waiting runner card to done and drops its command"
assert_eq "runner-blocked-closed|done|t702 → PR 닫힘|None|False" "$(b5_ps runner-blocked-closed)" "a closed PR moves a stopped runner card to done and drops stall and command"
assert_eq "runner-needs-human-open|needs_human|t703|workflow-driver.sh resume --workflow feature|False" "$(b5_ps runner-needs-human-open)" "an open PR leaves the runner card as it is"
assert_eq "runner-blocked-uncached|blocked|t704|workflow-driver.sh resume --workflow feature|True" "$(b5_ps runner-blocked-uncached)" "a runner card without a cached PR state is unchanged"
assert_eq "want704|True" "$(b5_ps want704)" "a runner card without a cached PR state asks for a lookup"
assert_eq "runner-running-merged|running|t705|workflow-driver.sh resume --workflow feature|False" "$(b5_ps runner-running-merged)" "a running runner card is unchanged even when its PR is merged"
assert_eq "agent-merged|needs_human|t706|workflow-driver.sh resume --workflow feature|False" "$(b5_ps agent-merged)" "an agent work card is unchanged"
assert_eq "bg-merged|needs_human|t707|workflow-driver.sh resume --workflow feature|False" "$(b5_ps bg-merged)" "a background work card is unchanged"
assert_eq "harness-merged|done|t708 → PR 병합됨|None|False" "$(b5_ps harness-merged)" "a harness card keeps moving to done when its PR is merged"
pass "prstate moves stopped runner cards to done when their PR ended outside the runner"

# 세션: 마지막 답이 API 오류인 세션은 '멈춤 — 다시 시작 필요', 작업 중인데 프로세스가 없는 세션은 '중단됨'. 정상 작업 중은 그대로.
mkdir -p "$BA_T/projects/p"
BA_NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
ba_agent() { # $1=sessionId $2=status $3=pid
  jq -cn --arg sid "$1" --arg st "$2" --argjson pid "$3" --arg cwd "$BA_T" --argjson t "$(($(date +%s) * 1000))" \
    '{sessionId: $sid, id: $sid[0:8], kind: "background", status: $st, state: "running", pid: $pid, cwd: $cwd, name: ("task " + $sid[-1:]), startedAt: $t}'
}
{ ba_agent aaaaaaaa-0000-4000-8000-000000000001 busy 4101; ba_agent aaaaaaaa-0000-4000-8000-000000000002 busy null; ba_agent aaaaaaaa-0000-4000-8000-000000000003 busy 4103; } | jq -s . >"$BA_T/agents.json"
jq -cn --arg t "$BA_NOW" '{type: "user", message: {content: "고쳐줘"}, timestamp: $t},
  {type: "assistant", isApiErrorMessage: true, message: {content: [{type: "text", text: "API Error: The response stopped arriving. The response above may be incomplete."}]}, timestamp: $t}' \
  >"$BA_T/projects/p/aaaaaaaa-0000-4000-8000-000000000001.jsonl"
jq -cn --arg t "$BA_NOW" '{type: "user", message: {content: "고쳐줘"}, timestamp: $t}, {type: "assistant", message: {content: [{type: "text", text: "고치는 중입니다"}]}, timestamp: $t}' \
  >"$BA_T/projects/p/aaaaaaaa-0000-4000-8000-000000000002.jsonl"
cp "$BA_T/projects/p/aaaaaaaa-0000-4000-8000-000000000002.jsonl" "$BA_T/projects/p/aaaaaaaa-0000-4000-8000-000000000003.jsonl"
BA_WORK="$(env -u CLAUDE_CONFIG_DIR PATH="$BA_T/bin:$PATH" BA_AGENTS="$BA_T/agents.json" HARNESS_METRICS_DIR="$BA_DATA" HARNESS_CLAUDE_PROJECTS_DIR="$BA_T/projects" \
  BOARD_CLAUDE_PROFILE_GLOBS="$BA_T/none/*" BOARD_CLAUDE_CONFIG_DIRS= bash "$ROOT/scripts/board/work.sh")"
assert_eq "1:blocked|api_error 2:blocked|no_process 3:running|null" \
  "$(jq -r '[sort_by(.sid)[] | "\(.sid[-1:]):\(.state)|\(.stall)"] | join(" ")' <<<"$BA_WORK")" \
  "an API-error session must be restarted, a working session without a process stopped, a live one keeps working"
pass "board work list shows sessions cut off by an API error or without a process as stopped"

# 읽지 않은 결과: 살아 있지 않은 백그라운드 세션의 결과는 하루가 지나면 끝난 일(idle)로 넘긴다. 최근 결과·살아 있는 세션은 그대로.
mkdir -p "$BA_T/srv/board"
printf '{}' >"$BA_T/srv/board/seen.json"
HARNESS_METRICS_DIR="$BA_T/srv" python3 -I -B -c '
import importlib.util, sys
from datetime import datetime, timedelta, timezone
spec = importlib.util.spec_from_file_location("bs", sys.argv[1]); bs = importlib.util.module_from_spec(spec); spec.loader.exec_module(bs)
iso = lambda h: (datetime.now(timezone.utc) - timedelta(hours=h)).strftime("%Y-%m-%dT%H:%M:%SZ")
items = [{"section": "work", "kind": "bg", "sid": "old", "live": False, "state": "done", "at": iso(30)},
         {"section": "work", "kind": "bg", "sid": "new", "live": False, "state": "done", "at": iso(2)},
         {"section": "work", "kind": "bg", "sid": "alive", "live": True, "state": "done", "at": iso(30)}]
got = {i["sid"]: i["state"] for i in bs.classify_work(items)}
assert got == {"old": "idle", "new": "review", "alive": "review"}, got
' "$ROOT/scripts/board/board-server.py" || fail "a finished background result older than a day moves to done; recent and live ones stay unread"
pass "board moves day-old results of ended background sessions out of unread"

# 화면(#299): 숫자는 칸 제목과 같은 단위로, 내부 식별자 제목은 사람 말로, 같은 이유 건너뜀·대기열은 묶은 뒤 자른다. 함수만 잘라 node로 실행.
BOARD_TPL3="$(<"$ROOT/scripts/board/template.html")"
for BOARD_PART3 in "queue_hidden" "i.stall" "sync_pr_no_credentials" "작업 묶음 안 작업자 질문" "세션 안 하위 에이전트" "작업자 세션"; do
  assert_contains "$BOARD_TPL3" "$BOARD_PART3" "the board screen uses $BOARD_PART3"
done
if command -v node >/dev/null 2>&1; then
  { sed -n '/function todoTally(units) {/,/^  }$/p' "$ROOT/scripts/board/template.html"
    sed -n '/function sigTitle(t, project) {/,/^  }$/p' "$ROOT/scripts/board/template.html"
    sed -n '/function headKeys(keys, max) {/,/^  }$/p' "$ROOT/scripts/board/template.html"
    printf '%s\n' 'console.log(JSON.stringify([
      todoTally([{u: 1, asks: 0}, {u: 1, asks: 4}, {u: 3, asks: 0}]),
      sigTitle("shop datadog:5b1c0d2e9f8a7b6c", "shop"), sigTitle("billing sentry:4410293", "billing"), sigTitle("주문 목록 정렬 고치기", "shop"),
      [...headKeys(["r:a", "r:a", "q:harvest", "r:a", "t:1", "t:2", "q:harvest"], 2)]]))'
  } >"$TEST_TMP/board-299.js"
  assert_eq '[{"total":3,"parts":["답할 것 2","검토할 것 1"],"asks":4},"shop 운영 에러 이어 보기 (Datadog)","billing 운영 에러 이어 보기 (Sentry)",null,["r:a","q:harvest"]]' \
    "$(node "$TEST_TMP/board-299.js")" "todo summary counts cards like the lane title and shows worker asks apart; internal titles become words; lanes cut after grouping"
fi
pass "board screen counts todo like its title, names internal titles and groups before cutting a lane"

# 미리보기 서버(#299): 위 상황을 가짜 데이터로 재현한다.
python3 -I -B -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("pv", sys.argv[1]); pv = importlib.util.module_from_spec(spec); spec.loader.exec_module(pv)
s = pv.status("demo"); items = s["items"]
assert s["queue_hidden"] and all({"reason", "count"} <= set(q) for q in s["queue_hidden"]), s.get("queue_hidden")
assert {"api_error", "no_process", "no_activity"} <= {i.get("stall") for i in items}, [i.get("stall") for i in items]
assert any(i["section"] == "work" and not i.get("autofix_id") and " datadog:" in i["title"] for i in items), "an unlinked internal-id session title"
assert any(i.get("group") and i["group"]["role"] == "worker" and i["state"] == "needs_human" for i in items), "a worker asking inside a group"
assert any(i.get("group") and i.get("subagents") for i in items), "a group card with subagents"
assert sum(1 for i in items if i.get("reason") == "sync_pr_no_credentials") >= 2, "repeated skips with one cause"
assert pv.status("empty")["queue_hidden"] == []
' "$ROOT/tests/fixtures/board-preview/serve.py" || fail "the board preview server reproduces the #299 situations"
pass "board preview fixture reproduces the #299 screens with fake data"

# 위임한 세션의 결과 유지(#465): 대화형 세션은 살아 있는 동안만 claude agents 목록에 있다. 부모 대화 기록에서 띄운 것으로 확인된
# 터미널(links.json scan handles → 짝지은 sid)의 세션이 탭을 닫아 목록에서 빠지면, transcript로 끝난 항목을 되살려 묶음·PR이 남게 한다.
# 띄운 기록이 없는 세션(사람이 직접 연 탭)은 되살리지 않는다.
WD_T="$(mkdir -p "$TEST_TMP/work-delegated" && cd "$TEST_TMP/work-delegated" && pwd -P)"
mkdir -p "$WD_T/bin" "$WD_T/projects/parent" "$WD_T/projects/child" "$WD_T/metrics/board" "$WD_T/member"
cat >"$WD_T/bin/claude" <<'FAKE'
#!/usr/bin/env bash
[[ "$1" == agents ]] || exit 1
cat "$FAKE_AGENTS"
FAKE
chmod +x "$WD_T/bin/claude"
WD_PARENT="cccccccc-0000-4000-8000-000000000001"
WD_CHILD="cccccccc-0000-4000-8000-000000000002"
WD_SOLO="cccccccc-0000-4000-8000-000000000003"
WD_NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
jq -cn --arg sid "$WD_PARENT" --arg cwd "$WD_T" --argjson t "$(($(date +%s) * 1000))" \
  '[{sessionId: $sid, id: $sid[0:8], kind: "interactive", status: "idle", pid: 4242, cwd: $cwd, startedAt: $t}]' >"$WD_T/agents.json"
jq -cn --arg t "$WD_NOW" '{type: "user", message: {content: "작업 맡겨줘"}, timestamp: $t}' >"$WD_T/projects/parent/$WD_PARENT.jsonl"
for WD_SID in "$WD_CHILD" "$WD_SOLO"; do
  { jq -cn --arg t "$WD_NOW" --arg cwd "$WD_T/member" '{type: "user", cwd: $cwd, message: {content: "#12 고쳐줘"}, timestamp: $t}'
    jq -cn '{type: "ai-title", aiTitle: "Fix the example issue"}'
    jq -cn --arg t "$WD_NOW" '{type: "assistant", message: {content: [{type: "text", text: "PR을 열었습니다."}]}, timestamp: $t}'
  } >"$WD_T/projects/child/$WD_SID.jsonl"
done
jq -cn --arg p "$WD_T/projects/parent/$WD_PARENT.jsonl" --arg c "$WD_CHILD" --arg s "$WD_SOLO" \
  '{handles: {"term_11111111-2222-3333-4444-555555555555": $c, "term_aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee": $s},
    scan: {($p): {v: 2, offset: 0, handles: ["term_11111111-2222-3333-4444-555555555555"]}}}' >"$WD_T/metrics/board/links.json"
WD_OUT="$(env -u CLAUDE_CONFIG_DIR PATH="$WD_T/bin:$PATH" FAKE_AGENTS="$WD_T/agents.json" HARNESS_METRICS_DIR="$WD_T/metrics" \
  HARNESS_CLAUDE_PROJECTS_DIR="$WD_T/projects" BOARD_CLAUDE_PROFILE_GLOBS="$WD_T/none/*" BOARD_CLAUDE_CONFIG_DIRS= bash "$ROOT/scripts/board/work.sh")"
assert_eq "done|false|member|Fix the example issue" \
  "$(jq -r --arg s "$WD_CHILD" '.[] | select(.sid == $s) | "\(.state)|\(.live)|\(.project)|\(.title)"' <<<"$WD_OUT")" \
  "a delegated session whose tab closed comes back as an ended item named after its own folder"
assert_eq "" "$(jq -r --arg s "$WD_SOLO" '.[] | select(.sid == $s) | .sid' <<<"$WD_OUT")" "a closed session no parent spawned stays out"
assert_eq "1" "$(jq -r --arg s "$WD_PARENT" '[.[] | select(.sid == $s)] | length' <<<"$WD_OUT")" "the parent is listed once"
WD_TPL="$(<"$ROOT/scripts/board/template.html")"
# shellcheck disable=SC2016  # 템플릿 리터럴을 글자 그대로 찾는다
assert_contains "$WD_TPL" '`끝남 · PR #${n}`' "a finished worker in a group reads as ended with its PR, not as resting"
assert_contains "$WD_TPL" "memberStatus(it), ago(it.at)" "group member rows use the worker status"
pass "work.sh keeps a delegated session after its tab closes"

# 러너 카드 branch·workflow·release_tag(#605): publish 전에 멈춘 런은 .publish.branch가 없으므로 state의 .branch → .publish.branch →
# (끝나지도 도는 중도 아닐 때만) 저장소의 현재 브랜치 순으로 카드에 싣는다. release 런은 .release.tag를 release_tag로 싣는다.
B6_T="$BA_T/data605"
mkdir -p "$B6_T"
b6_repo() { # $1=run 폴더 $2=그 저장소의 브랜치 — b5_run이 쓰는 $BA_T/repo-<run 폴더>에 커밋 하나짜리 git 저장소를 만들고 그 커밋을 출력한다
  mkdir -p "$BA_T/repo-$1"
  git init -q -b "$2" "$BA_T/repo-$1"
  git -C "$BA_T/repo-$1" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m "run $1"
  git -C "$BA_T/repo-$1" rev-parse HEAD
}
b5_run "$B6_T" br/1 user_decision user_decision ".message = \"결정\" | .finished_at = \"$B5_NOW\" | .branch = \"fix/592-state\""
b5_run "$B6_T" pb/1 stopped fix ".finished_at = \"$B5_NOW\" | .publish = {branch: \"fix/592-publish\"}"
b6_repo pb/1 fix/592-other >/dev/null
b5_run "$B6_T" bp/1 stopped fix ".finished_at = \"$B5_NOW\" | .branch = \"fix/592-state\" | .publish = {branch: \"fix/592-publish\"}"
b6_repo bp/1 fix/592-other >/dev/null
# 현재 브랜치는 런이 만든 커밋(head ≠ start_head)을 담을 때만 쓴다(#615).
B6_HEAD="$(b6_repo gi/1 fix/592-x)"
b5_run "$B6_T" gi/1 stopped fix ".finished_at = \"$B5_NOW\" | .head = \"$B6_HEAD\" | .start_head = \"base\""
b6_repo wb/1 feat/unrelated >/dev/null
b5_run "$B6_T" wb/1 stopped fix ".finished_at = \"$B5_NOW\" | .head = \"$B6_HEAD\" | .start_head = \"base\""
B6_SAME="$(b6_repo ns/1 feat/unrelated)"
b5_run "$B6_T" ns/1 stopped fix ".finished_at = \"$B5_NOW\" | .head = \"$B6_SAME\" | .start_head = \"$B6_SAME\""
b5_run "$B6_T" nr/1 stopped fix ".finished_at = \"$B5_NOW\""
rmdir "$BA_T/repo-nr/1"
b5_run "$B6_T" ng/1 user_decision user_decision ".finished_at = \"$B5_NOW\" | .publish = {pr_url: \"https://github.com/acme/shop/pull/615\"}"
rmdir "$BA_T/repo-ng/1"
b5_run "$B6_T" ru/1 running discover ".started_at = \"$B5_NOW\""
b6_repo ru/1 fix/592-x >/dev/null
b5_run "$B6_T" dn/1 "done" brief ".finished_at = \"$B5_NOW\""
b6_repo dn/1 fix/592-x >/dev/null
b5_run "$B6_T" re/1 user_decision user_decision ".message = \"결정\" | .finished_at = \"$B5_NOW\" | .workflow = \"release\" | .release = {tag: \"v0.95.0\", version: \"0.95.0\"}"
assert_eq "fix/592-state" "$(b5_item "$B6_T" br/1 .branch)" "a runner card carries the branch recorded in state.json"
assert_eq "fix/592-publish" "$(b5_item "$B6_T" pb/1 .branch)" "without state.branch the card falls back to publish.branch before the repository's current branch"
assert_eq "fix/592-state" "$(b5_item "$B6_T" bp/1 .branch)" "state.branch wins over publish.branch"
assert_eq "fix/592-x" "$(b5_item "$B6_T" gi/1 .branch)" "a stopped runner with no recorded branch reads its repository's current branch"
assert_eq "null" "$(b5_item "$B6_T" wb/1 .branch)" "the repository's current branch is not used when it does not contain the run's head commit"
assert_eq "null" "$(b5_item "$B6_T" ns/1 .branch)" "the repository's current branch is not used when the run made no commit"
assert_eq "null" "$(b5_item "$B6_T" nr/1 .branch)" "a runner whose repository folder is gone has a null branch"
assert_eq "done|null" "$(b5_item "$B6_T" nr/1 '"\(.state)|\(.cmd)"')" "an unfinished runner whose folder is gone and has no PR is done"
assert_eq "true" "$(b5_item "$B6_T" nr/1 '.detail | test("작업 폴더가 지워져")')" "the done card says the work folder is gone"
assert_eq "needs_human" "$(b5_item "$B6_T" ng/1 .state)" "a runner whose folder is gone but has a PR is still judged by that PR"
assert_eq "null" "$(b5_item "$B6_T" ru/1 .branch)" "a running runner does not read the repository's current branch"
assert_eq "null" "$(b5_item "$B6_T" dn/1 .branch)" "a done runner does not read the repository's current branch"
assert_eq "feature|null" "$(b5_item "$B6_T" br/1 '"\(.workflow)|\(.release_tag)"')" "a feature runner card carries its workflow and a null release_tag"
assert_eq "release|v0.95.0" "$(b5_item "$B6_T" re/1 '"\(.workflow)|\(.release_tag)"')" "a release runner card carries workflow release and its tag"
pass "board status carries branch, workflow and release_tag on runner cards"

# 러너 카드 PR·태그 판정(#605): PR 링크가 없는 멈춘 러너도 작업 브랜치 PR이 밖에서 끝났거나 release 태그가 원격에 있으면 prstate.apply가 done으로 내린다.
# 캐시 키는 "branch\t<cwd>\t<branch>"·"tag\t<cwd>\t<tag>", 값은 기존 URL 캐시와 같은 {"state": ..., "at": t}다.
B6_PS="$(python3 -I -B -c '
import sys, time
sys.path.insert(0, sys.argv[1])
import prstate
now = time.time()
cmd = "workflow-driver.sh resume --workflow feature"
bk = lambda cwd, b: "\t".join(["branch", cwd, b])
tk = lambda cwd, t: "\t".join(["tag", cwd, t])
def card(n, state="needs_human", **kw):
    d = {"section": "work", "kind": "runner", "state": state, "title": "t%d" % n, "link": None, "cwd": "/work/shop-%d" % n, "cmd": cmd,
         "actions": ["open_agent"], "workflow": "feature", "branch": "fix/592-x", "release_tag": None}
    if state == "blocked":
        d["stall"] = "stopped"
    d.update(kw)
    return d
def put(c, st, at=None, key=None):
    prstate._cache[key or bk(c["cwd"], c["branch"])] = {"state": st, "at": now if at is None else at}
cases = []
def add(name, c):
    cases.append((name, c))
    return c
put(add("merged", card(1)), "MERGED")
put(add("closed", card(2, "blocked")), "CLOSED")
put(add("declined", card(3)), "DECLINED")
put(add("open", card(4)), "OPEN")
put(add("none", card(5)), "NONE")
add("uncached", card(6, "blocked"))
put(add("open-stale", card(7)), "OPEN", now - prstate.OPEN_TTL - 10)
put(add("none-stale", card(8)), "NONE", now - prstate.OPEN_TTL - 10)
put(add("develop", card(9, branch="develop")), "MERGED")
put(add("main", card(10, branch="main")), "MERGED")
add("master", card(11, branch="master"))
add("trunk", card(12, branch="trunk"))
put(add("nobranch", card(13, branch=None)), "MERGED", key=bk("/work/shop-13", "None"))
put(add("running", card(14, "running")), "MERGED")
put(add("agent", card(15, kind="agent")), "MERGED")
put(add("rel-tagged", card(16, workflow="release", release_tag="v0.95.0", branch="release/0.95.0")), "TAGGED", key=tk("/work/shop-16", "v0.95.0"))
put(add("rel-untagged", card(17, workflow="release", release_tag="v0.95.0", branch="release/0.95.0")), "UNTAGGED", key=tk("/work/shop-17", "v0.95.0"))
put(add("rel-branch-only", card(18, workflow="release", release_tag="v0.95.0", branch="release/0.95.0")), "MERGED")
add("rel-notag", card(19, workflow="release", release_tag=None, branch="release/0.95.0"))
put(add("rel-untagged-stale", card(20, workflow="release", release_tag="v0.95.0")), "UNTAGGED", now - prstate.OPEN_TTL - 10, key=tk("/work/shop-20", "v0.95.0"))
url = "https://github.com/acme/shop/pull/21"
prstate._cache[url] = {"state": "OPEN", "at": now}
put(add("link-open", card(21, link=url)), "MERGED")
url22 = "https://github.com/acme/shop/pull/22"
prstate._cache[url22] = {"state": "MERGED", "at": now}
add("link-merged", card(22, link=url22))
wanted = {n: c for n, c in cases}
before = set(prstate._want)
prstate.apply([c for _, c in cases])
for name, c in cases:
    print("%s|%s|%s|%s|%s|%s" % (name, c["state"], c["title"], c.get("cmd"), "stall" in c, "open_agent" in c["actions"]))
def wants(c):
    return sorted(k for k in prstate._want if c["cwd"] in k)
for name, c in cases:
    print("want-%s|%s" % (name, wants(c)))
' "$ROOT/scripts/board" 2>&1)"
b6_ps() { grep "^$1|" <<<"$B6_PS" || true; }
CMD6="workflow-driver.sh resume --workflow feature"
BK6="'branch\\t/work/shop-6\\tfix/592-x'"
assert_eq "merged|done|t1 → PR 병합됨|None|False|False" "$(b6_ps merged)" "a merged work-branch PR moves a person-waiting runner card without a PR link to done"
assert_eq "closed|done|t2 → PR 닫힘|None|False|False" "$(b6_ps closed)" "a closed work-branch PR moves a stopped runner card to done and drops stall and command"
assert_eq "declined|done|t3 → PR 거절됨|None|False|False" "$(b6_ps declined)" "a declined work-branch PR moves the runner card to done"
assert_eq "open|needs_human|t4|$CMD6|False|True" "$(b6_ps open)" "an open work-branch PR leaves the runner card as it is"
assert_eq "none|needs_human|t5|$CMD6|False|True" "$(b6_ps none)" "a branch with no PR leaves the runner card as it is"
assert_eq "uncached|blocked|t6|$CMD6|True|True" "$(b6_ps uncached)" "a branch card without a cached state is unchanged"
assert_eq "want-uncached|[$BK6]" "$(b6_ps want-uncached)" "a branch card without a cached state asks for a lookup by its branch key"
assert_eq "want-open-stale|['branch\\t/work/shop-7\\tfix/592-x']" "$(b6_ps want-open-stale)" "an OPEN branch state past OPEN_TTL is asked again"
assert_eq "want-none-stale|['branch\\t/work/shop-8\\tfix/592-x']" "$(b6_ps want-none-stale)" "a NONE branch state past OPEN_TTL is asked again"
assert_eq "want-open|[]" "$(b6_ps want-open)" "a fresh OPEN branch state is not asked again"
assert_eq "want-none|[]" "$(b6_ps want-none)" "a fresh NONE branch state is not asked again"
assert_eq "develop|needs_human|t9|$CMD6|False|True" "$(b6_ps develop)" "a card on develop is unchanged even when the cache says MERGED"
assert_eq "main|needs_human|t10|$CMD6|False|True" "$(b6_ps main)" "a card on main is unchanged even when the cache says MERGED"
for B6_NAME in develop main master trunk nobranch rel-notag; do
  assert_eq "want-$B6_NAME|[]" "$(b6_ps "want-$B6_NAME")" "a $B6_NAME card never asks for a lookup"
done
assert_eq "nobranch|needs_human|t13|$CMD6|False|True" "$(b6_ps nobranch)" "a card with no branch is unchanged"
assert_eq "running|running|t14|$CMD6|False|True" "$(b6_ps running)" "a running runner card is unchanged even when its branch PR is merged"
assert_eq "agent|needs_human|t15|$CMD6|False|True" "$(b6_ps agent)" "an agent work card is unchanged"
assert_eq "rel-tagged|done|t16 → 릴리스 태그 v0.95.0 있음|None|False|False" "$(b6_ps rel-tagged)" "a release runner whose tag exists on the remote moves to done"
assert_eq "rel-untagged|needs_human|t17|$CMD6|False|True" "$(b6_ps rel-untagged)" "a release runner whose tag is not on the remote is unchanged"
assert_eq "want-rel-untagged|[]" "$(b6_ps want-rel-untagged)" "a fresh UNTAGGED state is not asked again"
assert_eq "want-rel-untagged-stale|['tag\\t/work/shop-20\\tv0.95.0']" "$(b6_ps want-rel-untagged-stale)" "an UNTAGGED state past OPEN_TTL is asked again by its tag key"
assert_eq "rel-branch-only|needs_human|t18|$CMD6|False|True" "$(b6_ps rel-branch-only)" "a release runner is judged by its tag, never by its branch PR"
assert_eq "want-rel-branch-only|['tag\\t/work/shop-18\\tv0.95.0']" "$(b6_ps want-rel-branch-only)" "a release runner asks for its tag key, not a branch key"
assert_eq "link-open|needs_human|t21|$CMD6|False|True" "$(b6_ps link-open)" "a card with a PR link keeps using the PR url state, not its branch"
assert_eq "want-link-open|[]" "$(b6_ps want-link-open)" "a card with a PR link does not ask for its branch"
assert_eq "link-merged|done|t22 → PR 병합됨|None|False|False" "$(b6_ps link-merged)" "a card with a merged PR link keeps the existing behavior"
pass "prstate moves stopped runner cards to done by work-branch PR state or release tag when there is no PR link"

# 러너 카드 조회 worker(#605): _fetch가 브랜치 키는 gh(GitHub)·curl(Bitbucket)로, 태그 키는 git ls-remote로 묻는다. 가짜 gh·curl을 PATH 앞에 두고 원격은 로컬 bare 저장소.
B6_W="$(mkdir -p "$TEST_TMP/prstate-fetch/bin" && cd "$TEST_TMP/prstate-fetch" && pwd -P)"
cat >"$B6_W/bin/gh" <<'FAKE'
#!/usr/bin/env bash
printf '%s|%s\n' "$PWD" "$*" >>"$FAKE_GH_LOG"
[[ "$1 $2" == "pr list" ]] || exit 64
[[ " $* " == *" --head fix/592-x "* ]] || { echo '[]'; exit 0; }
case "$FAKE_GH_MODE" in
  merged) echo '[{"state":"MERGED","headRefName":"fix/592-x","url":"https://github.com/acme/shop/pull/9"},{"state":"OPEN","headRefName":"fix/592-xy","url":"https://github.com/acme/shop/pull/10"}]' ;;
  open) echo '[{"state":"MERGED","headRefName":"fix/592-x","url":"https://github.com/acme/shop/pull/9"},{"state":"OPEN","headRefName":"fix/592-x","url":"https://github.com/acme/shop/pull/11"}]' ;;
  closed) echo '[{"state":"CLOSED","headRefName":"fix/592-x","url":"https://github.com/acme/shop/pull/9"}]' ;;
  empty) echo '[]' ;;
  *) exit 1 ;;
esac
FAKE
cat >"$B6_W/bin/curl" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_CURL_LOG"
cat >>"$FAKE_CURL_LOG"
echo '{"values":[{"state":"MERGED","source":{"branch":{"name":"fix/592-x"}}}]}'
FAKE
chmod +x "$B6_W/bin/gh" "$B6_W/bin/curl"
git init -q --bare "$B6_W/origin.git"
git init -q -b main "$B6_W/tagged"
git -C "$B6_W/tagged" remote add origin "$B6_W/origin.git"
git -C "$B6_W/tagged" -c user.email=test@example.com -c user.name=test commit -q --allow-empty -m init
git -C "$B6_W/tagged" tag v0.95.0
git -C "$B6_W/tagged" push -q origin main v0.95.0
git init -q -b main "$B6_W/gh-repo"
git -C "$B6_W/gh-repo" remote add origin https://github.com/acme/shop.git
git init -q -b main "$B6_W/bb-repo"
git -C "$B6_W/bb-repo" remote add origin https://bitbucket.org/acme/shop.git
git init -q -b main "$B6_W/bad-origin"
git -C "$B6_W/bad-origin" remote add origin "$B6_W/missing.git"
git init -q -b main "$B6_W/no-origin"
B6_FETCH="$(env -u ATLASSIAN_USER -u BITBUCKET_API_TOKEN PATH="$B6_W/bin:$PATH" FAKE_GH_LOG="$B6_W/gh.log" FAKE_CURL_LOG="$B6_W/curl.log" GIT_TERMINAL_PROMPT=0 \
  python3 -I -B -c '
import os, sys
sys.path.insert(0, sys.argv[1])
import prstate
w = sys.argv[2]
bk = lambda d, b: "\t".join(["branch", os.path.join(w, d), b])
tk = lambda d, t: "\t".join(["tag", os.path.join(w, d), t])
def show(name, v):
    print("%s|%s" % (name, v))
for mode in ("merged", "open", "closed", "empty", "fail"):
    os.environ["FAKE_GH_MODE"] = mode
    show("gh-" + mode, prstate._fetch(bk("gh-repo", "fix/592-x")))
os.environ["FAKE_GH_MODE"] = "merged"
show("gh-other-branch", prstate._fetch(bk("gh-repo", "fix/592-y")))
show("tag-yes", prstate._fetch(tk("tagged", "v0.95.0")))
show("tag-no", prstate._fetch(tk("tagged", "v9.9.9")))
show("tag-bad-origin", prstate._fetch(tk("bad-origin", "v0.95.0")))
show("tag-no-origin", prstate._fetch(tk("no-origin", "v0.95.0")))
show("branch-no-origin", prstate._fetch(bk("no-origin", "fix/592-x")))
show("bb-no-creds", prstate._fetch(bk("bb-repo", "fix/592-x")))
os.environ.update(ATLASSIAN_USER="u", BITBUCKET_API_TOKEN="t")
show("bb-merged", prstate._fetch(bk("bb-repo", "fix/592-x")))
' "$ROOT/scripts/board" "$B6_W" 2>&1)"
b6_fetch() { grep "^$1|" <<<"$B6_FETCH" || true; }
assert_eq "gh-merged|MERGED" "$(b6_fetch gh-merged)" "a GitHub branch key with only merged PRs for that exact head reads MERGED"
assert_eq "gh-open|OPEN" "$(b6_fetch gh-open)" "any open PR for the branch makes the state OPEN"
assert_eq "gh-closed|CLOSED" "$(b6_fetch gh-closed)" "a closed-only branch reads CLOSED"
assert_eq "gh-empty|NONE" "$(b6_fetch gh-empty)" "a branch with no PR reads NONE"
assert_eq "gh-fail|None" "$(b6_fetch gh-fail)" "a failing gh gives no state"
assert_eq "gh-other-branch|NONE" "$(b6_fetch gh-other-branch)" "PRs of other head branches are ignored"
assert_contains "$(<"$B6_W/gh.log")" "$B6_W/gh-repo|pr list --head fix/592-x --state all" "gh is asked from the card's repository for that branch and all states"
assert_eq "tag-yes|TAGGED" "$(b6_fetch tag-yes)" "a tag on the remote reads TAGGED"
assert_eq "tag-no|UNTAGGED" "$(b6_fetch tag-no)" "a tag missing on a reachable remote reads UNTAGGED"
assert_eq "tag-bad-origin|None" "$(b6_fetch tag-bad-origin)" "an unreachable remote gives no tag state"
assert_eq "tag-no-origin|None" "$(b6_fetch tag-no-origin)" "a repository without origin gives no tag state"
assert_eq "branch-no-origin|None" "$(b6_fetch branch-no-origin)" "a branch key in a repository without origin gives no state"
assert_eq "bb-no-creds|None" "$(b6_fetch bb-no-creds)" "a Bitbucket branch key without credentials gives no state"
assert_eq "bb-merged|MERGED" "$(b6_fetch bb-merged)" "a Bitbucket branch key reads the merged state through curl"
assert_contains "$(<"$B6_W/curl.log")" 'user = "u:t"' "the Bitbucket credentials go to curl on stdin, not the command line"
assert_contains "$(<"$B6_W/curl.log")" "pullrequests" "Bitbucket is asked for the pull requests list"
pass "prstate worker looks up work-branch PRs through gh or Bitbucket and release tags through git ls-remote"

finish_tests
