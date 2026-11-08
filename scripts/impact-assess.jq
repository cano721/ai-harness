# 하네스 효과 읽기 판정 (#260): compare JSON → 지표별 비교 가능성, 설치 후 추세, 저장소 상태.
# 보드(scripts/board/impact.py)와 /harness-impact 리포트가 이 값을 그대로 쓴다. 화면은 새 규칙을 만들지 않는다.
#   - 비교 가능성: 설치 전후 표본(정리된 세션·정산된 PR)이 기준 미만이면 증감 대신 comparable:false + reason.
#     세션 정리(digest)는 harvest 도입 뒤부터 쌓여 설치 전이 0인 저장소가 많다 — 그때 0 → N은 "나빠짐"이 아니라 "안 잼"이다.
#   - 추세: 설치 후 최근 trend_weeks주 중 정리된 세션이 trend_week_digests개 이상인 주만 쓰고,
#     앞 절반과 뒤 절반의 비율(합계 / 정리된 세션)을 맞댄다. 주나 세션이 모자라면 insufficient.
#   - 저장소 상태: 좋은 신호(개선 사라짐·줄어듦, 줄어드는 추세, 비교 가능한 감소)와 나쁜 신호(재발, 느는 추세, 비교 가능한 증가)로 정하고,
#     신호가 없으면 gaps에 왜 모르는지 남긴다.
# 기준값을 바꾸면 보드(scripts/board/template.html)·리포트(skills/harness-impact/report-template.html)의 판정 기준 문구와
# skills/harness-impact/SKILL.md·README도 함께 고친다.

def min_digests: 5;
def min_prs: 10;
def trend_weeks: 8;
def trend_week_digests: 2;
def trend_min_weeks: 3;
def trend_min_digests: 10;
def trend_half_digests: 5;
def round2: (. * 100 | round) / 100;

# 차이가 큰 쪽의 20%(그리고 $floor) 안이면 비슷함.
def change_of($b; $a; $floor):
  if $b == null or $a == null then null
  elif (($a - $b) | fabs) <= ([0.2 * ([$a, $b] | max), $floor] | max) then "flat"
  elif $a < $b then "down" else "up" end;

def digest_metric($B; $A; $k):
  {before: $B[$k], after: $A[$k], before_n: ($B.digested_sessions // 0), after_n: ($A.digested_sessions // 0)}
  | .reason = (if ($B.sessions // 0) == 0 then "no_baseline_sessions"
               elif .before_n == 0 then "no_baseline_digests"
               elif .before_n < min_digests or .after_n < min_digests then "few_digests"
               elif .before == null or .after == null then "no_value"
               else null end)
  | .comparable = (.reason == null)
  | .change = (if .comparable then change_of(.before; .after; 0.05) else null end);

def rework_metric($r):
  if ($r | type) != "object" or ($r.before | type) != "object" or ($r.after | type) != "object" then
    {before: null, after: null, before_n: null, after_n: null, comparable: false, reason: "no_rework", change: null}
  else
    {before: $r.before.rework_ratio, after: $r.after.rework_ratio,
     before_n: ($r.before.settled_prs // 0), after_n: ($r.after.settled_prs // 0)}
    | .reason = (if .before_n < min_prs or .after_n < min_prs then "few_prs"
                 elif .before == null or .after == null then "no_value" else null end)
    | .comparable = (.reason == null)
    | .change = (if .comparable then change_of(.before; .after; 5) else null end)
  end;

def rate($ws; $ck): ([$ws[] | .[$ck]] | add) as $c | ([$ws[] | .digested_sessions] | add) as $n
  | if $n == 0 then null else ($c / $n | round2) end;

# $k: 주별 세션당 비율 키, $ck: 주별 합계 키. 합계가 없는 옛 compare JSON은 비율 × 정리된 세션으로 되살린다.
def trend($weekly; $k; $ck):
  ([($weekly // [])[] | select(.after_install == true)] | .[-trend_weeks:]
    | map(. + {(($ck)): (.[$ck] // (if .[$k] == null then 0 else .[$k] * (.digested_sessions // 0) end)),
               digested_sessions: (.digested_sessions // 0)})) as $recent
  | [$recent[] | select(.digested_sessions >= trend_week_digests)] as $W
  | ($W | length) as $n
  | ([$W[] | .digested_sessions] | add // 0) as $dg
  | (($n / 2) | floor) as $h
  | {weeks: $n, digested: $dg,
     series: [$recent[] | {week, value: (if .digested_sessions >= trend_week_digests then .[$k] else null end), n: .digested_sessions}]}
  + (if $n < trend_min_weeks or $dg < trend_min_digests
        or ([$W[0:$h][] | .digested_sessions] | add // 0) < trend_half_digests
        or ([$W[$n - $h:][] | .digested_sessions] | add // 0) < trend_half_digests
     then {verdict: "insufficient", first: null, last: null}
     else rate($W[0:$h]; $ck) as $f | rate($W[$n - $h:]; $ck) as $l
       | {verdict: change_of($f; $l; 0.05), first: $f, last: $l} end);

def assess:
  ((.periods // {}).before // {}) as $B | ((.periods // {}).after // {}) as $A
  | {metrics: {
       corrections_per_session: digest_metric($B; $A; "corrections_per_session"),
       missing_context_per_session: digest_metric($B; $A; "missing_context_per_session"),
       # 가드는 하네스와 함께 깔린다. 설치 전 0은 잰 값이 아니다.
       guard_blocks: {before: $B.guard_blocks, after: $A.guard_blocks, comparable: false, reason: "after_only", change: null},
       rework: rework_metric(.rework)},
     trends: {
       corrections_per_session: trend(.weekly; "corrections_per_session"; "corrections"),
       missing_context_per_session: trend(.weekly; "missing_context_per_session"; "missing_context")}};

# 개선 판정(.improvements[].result.verdict)이 붙은 뒤에 부른다(impact-evidence.jq evidence).
def assess_status:
  assess as $X
  | ((.periods // {}).after // {}) as $A
  | [(.improvements // [])[] | (.result // {}).verdict // "unmatched"] as $v
  | def cnt($k): [$v[] | select(. == $k)] | length;
    def by_trend($want): [$X.trends | to_entries[] | select(.value.verdict == $want) | {by: "trend", metric: .key}];
    def by_metric($want): [$X.metrics | to_entries[] | select(.value.change == $want) | {by: "compare", metric: .key}];
  ((cnt("gone") + cnt("reduced")) as $ok
   | [(if $ok > 0 then {by: "improvement", n: $ok} else empty end)] + by_trend("down") + by_metric("down")) as $good
  | ([(if cnt("recurred") > 0 then {by: "improvement", n: cnt("recurred")} else empty end)] + by_trend("up") + by_metric("up")) as $bad
  | ($X.trends | [.[] | select(.verdict != "insufficient")] | length) as $trended
  | ($X.metrics | [.[] | select(.comparable)] | length) as $compared
  | ([(if ($A.sessions // 0) == 0 then {why: "no_recent_sessions"} else empty end),
      (if [$X.metrics.corrections_per_session.reason, $X.metrics.missing_context_per_session.reason]
          | any(. == "no_baseline_sessions" or . == "no_baseline_digests") then {why: "no_baseline"} else empty end),
      (if ($A.sessions // 0) > 0 and $trended == 0 then {why: "few_recent_digests"} else empty end),
      (if ($v | length) == 0 then {why: "no_improvements"} else empty end),
      (if cnt("unmatched") > 0 then {why: "unmatched_improvements", n: cnt("unmatched")} else empty end),
      (if cnt("hold") > 0 then {why: "few_observed", n: cnt("hold")} else empty end),
      (if cnt("no_baseline") > 0 then {why: "no_baseline_improvements", n: cnt("no_baseline")} else empty end)]) as $gaps
  | {key: (if ($A.sessions // 0) == 0 then "no_sessions"
           elif ($good | length) > 0 and ($bad | length) == 0 then "effective"
           elif ($good | length) > 0 then "mixed"
           elif ($bad | length) > 0 then "attention"
           elif $trended > 0 or $compared > 0 or cnt("hold") > 0 then "watching"
           else "insufficient" end),
     good: $good, bad: $bad, gaps: $gaps};

def assessment: assess + {status: assess_status};
