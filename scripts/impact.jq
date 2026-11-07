# impact.sh compare: 이벤트(입력, _f=이벤트 파일 이름) → 설치일 전후 비교 JSON
# 인자: $project $root $inst(설치일) $src(출처) $bs(전 시작) $asince(후 시작) $au(후 끝, 미포함) $len(구간 일수) $today
#       $digests[0] {파일이름: {c: 교정, m: 프로젝트 사실 모름(missing_context), f: 모든 finding}}
#       $history[0] harvest 리뷰 이력 · $applied[0] 자동 적용 규칙 · $rb/$ra 재작업(JSON|null)
# 지표별 비교 가능성·설치 후 추세는 impact-assess.jq가 정한다(-L scripts). 저장소 상태는 판정이 붙은 뒤 evidence가 더한다.
include "impact-assess";

def active_min_turns: 5;
# 개선별 재발 후보: 한쪽 목록 상한, 반영 전 근거가 batch 기록에 없을 때 볼 날 수.
def candidate_cap: 300;
def baseline_days: 30;
def harness_workflows: ["implement-feature", "fix-bug", "review", "understand-change"];
def ep: . + "T00:00:00Z" | fromdateiso8601;
def day_of: (.ended // .started // "")[0:10];
def median: map(select(. != null)) | sort
  | if length == 0 then null
    elif length % 2 == 1 then .[length / 2 | floor]
    else (.[length / 2 - 1] + .[length / 2]) / 2 end;
def round2: (. * 100 | round) / 100;
def secs: sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;
def per($a; $b): if $b == 0 then null else ($a / $b | round2) end;
def has_cov($k): ((.coverage // []) | index($k)) != null;
# 월요일 시작 주. gmtime[6]은 0=일요일.
def week_of: (. | ep) as $e | ($e | gmtime[6]) as $wd | ($e - ((($wd + 6) % 7) * 86400)) | todate[0:10];
def harness_use:
  (.kind == "doc_read" and ((.target // "") | test("^\\.ai-harness/(docs|workflows)/")))
  or (.kind == "workflow" and ((.target // "") | ltrimstr("ai-harness:")) as $n | harness_workflows | index($n) != null);

[inputs] as $all
| $digests[0] as $D
| ($all | map(select(.kind == "session" and ((.internal // false) | not) and .project == $project
    and (day_of >= $bs) and (day_of < $au)))) as $S
| ($S | map({(.sid): true}) | add // {}) as $sidset
| ($all | map(select(.kind != "session" and $sidset[.sid // ""] == true)) | group_by(.sid)
   | map({(.[0].sid): .}) | add // {}) as $EV
| ($all | map(select(.kind == "session" and ((.internal // false) | not) and .project == $project
    and $D[._f] != null))) as $PD
| def evsum($s; $k): [($EV[$s.sid] // [])[] | select(.kind == $k) | (.n // 1)] | add // 0;
  # 세션이 가장 많이 언급한 이슈 키를 그 세션의 작업으로 본다(여러 키를 스친 세션을 중복으로 세지 않게).
  def task_key($s): [($EV[$s.sid] // [])[] | select(.kind == "jira_issue" and (.target // "") != "")]
    | if length == 0 then null else (sort_by(-(.n // 1), .target) | .[0].target) end;
  def period($since; $until):
    ($S | map(select(day_of >= $since and day_of < $until))) as $P
    | ($P | map(select((.turns // 0) >= active_min_turns))) as $A
    | ($P | map(select($D[._f] != null))) as $DG
    | ($P | map(select(has_cov("guard_sample")))) as $GS
    | ($P | map(select(has_cov("error")))) as $ER
    | {
        since: $since, until: $until,
        sessions: ($P | length),
        active_sessions: ($A | length),
        turns_median: ($A | map(.turns) | median),
        minutes_median: ($A | map(select(.started and .ended)
          | try ((((.ended | secs) - (.started | secs)) / 60) | round) catch null) | median),
        tok_out_median: ($A | map(.tok_out) | median),
        ctx_peak_median: ($A | map(.ctx_peak) | median),
        errors_per_session: per([$ER[] | evsum(.; "error")] | add // 0; $ER | length),
        guard_blocks: ([$P[] | evsum(.; "guard_block")] | add // 0),
        permission_denies: ([$P[] | evsum(.; "permission_deny")] | add // 0),
        compacts_per_session: per([$P[] | evsum(.; "compact")] | add // 0; $P | length),
        digested_sessions: ($DG | length),
        corrections: ([$DG[] | $D[._f].c | length] | add // 0),
        corrections_per_session: per([$DG[] | $D[._f].c | length] | add // 0; $DG | length),
        missing_context: ([$DG[] | $D[._f].m | length] | add // 0),
        missing_context_per_session: per([$DG[] | $D[._f].m | length] | add // 0; $DG | length),
        # 사례는 guard_sample을 기록하는 추출기 버전의 세션에서만 나온다. 그 전 세션의 차단은 수만 있다.
        guard_samples: ([$GS[] | ($EV[.sid] // [])[] | select(.kind == "guard_sample")]
          | group_by(.target) | map({target: .[0].target, n: (map(.n // 1) | add)}) | sort_by(-.n, .target) | .[0:8]),
        guard_blocks_unsampled: ([$P[] | select(has_cov("guard_sample") | not) | evsum(.; "guard_block")] | add // 0),
        models: ($P | map(.model // "unknown") | group_by(.) | map({(.[0]): length}) | add // {})
      }
      + ($P | map(. as $s | task_key($s) as $k | select($k != null) | $s + {_task: $k}) | group_by(._task)
         | map({sessions: length, turns: (map(.turns // 0) | add),
                # 작업 시간 = 세션별 (끝 - 시작) 합. 첫 시작~마지막 끝은 밤·주말을 끼어 부풀려진다.
                hours: (map(try (((.ended | secs) - (.started | secs)) / 3600) catch null | numbers) | add // null)})
         | {tasks: length,
            task_sessions_median: (map(.sessions) | median),
            task_turns_median: (map(.turns) | median),
            task_hours_median: (map(.hours) | median | if . == null then null else round2 end)});
  # 에이전트가 묶을 목록. 상한을 넘으면 truncated로 알린다(묶음 수치를 센 값처럼 쓰지 않게).
  def findings_in($since; $until; $key):
    [$S[] | select(day_of >= $since and day_of < $until) | day_of as $d | ($D[._f][$key] // [])[]
      | {date: $d, summary, evidence}] | sort_by(.date) | reverse
    | {total: length, truncated: (length > 200), items: .[0:200]};
  def corrections_in($since; $until): findings_in($since; $until; "c");
  # 세션들의 finding을 에이전트가 개선 패턴과 맞춰 볼 후보로 낸다. id = 세션 파일 이름#finding 순번.
  # 상한을 넘으면 최신부터 남긴다. 반영 뒤 쪽에서 오래된 쪽을 남기면 최근 재발이 빠져 "사라짐"으로 읽힌다.
  def candidates($sessions):
    [$sessions[] | ._f as $f | day_of as $d | ($D[$f].f // []) | to_entries[]
      | {id: "\($f)#\(.key)", date: $d, category: .value.category, summary: .value.summary}]
    | sort_by(.date, .id) | reverse | {truncated: (length > candidate_cap), items: .[0:candidate_cap]};
  def top_model: to_entries | max_by(.value) | .key;

  period($bs; $inst) as $before
| period($asince; $au) as $after
| ($S | map(select(day_of >= $asince and (.turns // 0) >= active_min_turns))) as $AA
| {
    v: 1,
    project: $project,
    root: $root,
    generated_at: (now | todate),
    today: $today,
    installed: {date: $inst, source: $src},
    window_days: $len,
    periods: {before: $before, after: $after},
    weekly: (
      [range(($bs | week_of | ep); ($au | ep); 7 * 86400) | todate[0:10]]
      | map(. as $w
        | ($S | map(select((day_of | week_of) == $w))) as $W
        | ($W | map(select($D[._f] != null))) as $WD
        | {
            week: $w,
            after_install: ($w >= ($inst | week_of)),
            sessions: ($W | length),
            turns_median: ($W | map(select((.turns // 0) >= active_min_turns) | .turns) | median),
            corrections: ([$WD[] | $D[._f].c | length] | add // 0),
            corrections_per_session: per([$WD[] | $D[._f].c | length] | add // 0; $WD | length),
            missing_context: ([$WD[] | $D[._f].m | length] | add // 0),
            missing_context_per_session: per([$WD[] | $D[._f].m | length] | add // 0; $WD | length),
            digested_sessions: ($WD | length),
            errors_per_session: per([$W[] | select(has_cov("error")) | evsum(.; "error")] | add // 0; $W | map(select(has_cov("error"))) | length),
            guard_blocks: ([$W[] | evsum(.; "guard_block")] | add // 0)
          })
    ),
    corrections: {before: corrections_in($bs; $inst), after: corrections_in($asince; $au)},
    missing_context: {before: findings_in($bs; $inst; "m"), after: findings_in($asince; $au; "m")},
    # 개선별 재발 추적: harvest가 반영한 개선마다 근거 batch(반영 전)와 반영 뒤 세션의 finding을 나란히 낸다.
    # 패턴 매칭은 에이전트가 highlights에서 한다.
    # batch는 harvest 큐가 신호(교정·오류·차단·insight) 있는 세션을 먼저 골라 만든 표본이고, 반영 뒤 쪽은 정리된 세션 전부다.
    # 그래서 batch 비율과 반영 뒤 비율을 맞대면 "줄어듦"이 쉽게 나온다. 같은 정의(정리된 세션 전부)의 반영 전 30일을
    # window로 함께 내고, render는 window 매칭이 있으면 그 비율로 줄어듦·재발을 판정한다.
    improvements: (
      [$history[0][] | select((.review.outcome // "") == "improved" and ((.reviewed_at // "") != ""))
        | select((.reviewed_at[0:10]) < $au)]
      | sort_by(.reviewed_at) | to_entries
      | map(.key as $i | .value as $h | $h.reviewed_at as $at
        | ([$h.markers // [] | .[] | strings | rtrimstr(".json")] | map({(.): true}) | add // {}) as $mk
        | ($PD | map(select($mk[._f] == true))) as $BM
        | ($at[0:10] | ep) as $e | (($e - baseline_days * 86400) | todate[0:10]) as $from
        | ($PD | map(select(day_of >= $from and (.started // .ended // "") < $at))) as $WS
        | (if ($mk | length) > 0 then {basis: "batch", sessions: $BM}
           else {basis: "window", since: $from, sessions: $WS} end) as $B
        | ($PD | map(select((.started // .ended // "") >= $at and day_of < $au))) as $AF
        | {id: "h\($i + 1)", date: $at[0:10], summary: $h.review.summary, expected: $h.review.expected,
           artifact: $h.review.artifact, change: $h.review.change,
           before: ({basis: $B.basis, since: $B.since, batch_sessions: ($mk | length), observed: ($B.sessions | length),
                    candidates: candidates($B.sessions)}
                    + (if $B.basis == "batch" then {window: {since: $from, observed: ($WS | length), candidates: candidates($WS)}} else {} end)),
           # 날짜별 관측 세션 수: 저장해 둔 매칭(highlights.matched_through)으로 판정할 때 그날까지의 분모를 다시 센다.
           after: {since: $at, observed: ($AF | length),
                   observed_by_day: ($AF | map(day_of) | group_by(.) | map({(.[0]): length}) | add // {}),
                   candidates: candidates($AF)}})
    ),
    timeline: (
      ([$history[0][] | select((.review.outcome // "") == "improved")
         | {date: ((.reviewed_at // "")[0:10]), kind: "harvest", summary: .review.summary,
            expected: .review.expected, artifact: .review.artifact, change: .review.change}]
       + [$applied[0][] | select(.event == "applied" and (.project == $project or .scope == "global"))
         | {date: ((.at // "")[0:10]), kind: "rule", summary: .text, expected: .expected,
            artifact: null, scope: .scope}])
      | map(select(.date >= $bs and .date < $au)) | sort_by(.date)
    ),
    adoption: {
      active_sessions: ($AA | length),
      harness_sessions: ($AA | map(select([($EV[.sid] // [])[] | select(harness_use)] | length > 0)) | length),
      top_docs: ([$AA[] | ($EV[.sid] // [])[] | select(.kind == "doc_read" and ((.target // "") | startswith(".ai-harness/")))]
        | group_by(.target) | map({target: .[0].target, n: (map(.n // 1) | add)}) | sort_by(-.n) | .[0:5])
    },
    rework: (if $rb == null and $ra == null then null else {before: $rb, after: $ra} end),
    warnings: (
      [ (if $before.sessions == 0 then "before_missing" else empty end),
        (if $len < 7 then "short_window" else empty end),
        (if $asince > $inst then "gap" else empty end),
        (if $before.active_sessions < 10 or $after.active_sessions < 10 then "low_sample" else empty end),
        (if $before.digested_sessions < 5 or $after.digested_sessions < 5 then "few_digests" else empty end),
        (if $before.sessions > 0 and $after.sessions > 0
            and ($before.models | top_model) != ($after.models | top_model) then "model_shift" else empty end) ]
    )
  } | . + {assessment: assess}
