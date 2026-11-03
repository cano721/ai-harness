# impact.sh compare: 이벤트(입력, _f=이벤트 파일 이름) → 설치일 전후 비교 JSON
# 인자: $project $root $inst(설치일) $src(출처) $bs(전 시작) $asince(후 시작) $au(후 끝, 미포함) $len(구간 일수) $today
#       $digests[0] {파일이름: [교정]} · $history[0] harvest 리뷰 이력 · $applied[0] 자동 적용 규칙 · $rb/$ra 재작업(JSON|null)

def active_min_turns: 5;
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
| def evsum($s; $k): [($EV[$s.sid] // [])[] | select(.kind == $k) | (.n // 1)] | add // 0;
  # 세션이 가장 많이 언급한 이슈 키를 그 세션의 작업으로 본다(여러 키를 스친 세션을 중복으로 세지 않게).
  def task_key($s): [($EV[$s.sid] // [])[] | select(.kind == "jira_issue" and (.target // "") != "")]
    | if length == 0 then null else (sort_by(-(.n // 1), .target) | .[0].target) end;
  def period($since; $until):
    ($S | map(select(day_of >= $since and day_of < $until))) as $P
    | ($P | map(select((.turns // 0) >= active_min_turns))) as $A
    | ($P | map(select($D[._f] != null))) as $DG
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
        corrections: ([$DG[] | $D[._f] | length] | add // 0),
        corrections_per_session: per([$DG[] | $D[._f] | length] | add // 0; $DG | length),
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
  def corrections_in($since; $until):
    [$S[] | select(day_of >= $since and day_of < $until) | day_of as $d | ($D[._f] // [])[]
      | {date: $d, summary, evidence}] | sort_by(.date) | reverse
    | {total: length, truncated: (length > 200), items: .[0:200]};
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
            corrections_per_session: per([$WD[] | $D[._f] | length] | add // 0; $WD | length),
            errors_per_session: per([$W[] | select(has_cov("error")) | evsum(.; "error")] | add // 0; $W | map(select(has_cov("error"))) | length),
            guard_blocks: ([$W[] | evsum(.; "guard_block")] | add // 0)
          })
    ),
    corrections: {before: corrections_in($bs; $inst), after: corrections_in($asince; $au)},
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
  }
