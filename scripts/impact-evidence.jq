# impact.sh render: compare JSON + 에이전트 하이라이트 → 리포트에 싣는 JSON.
# 개선별 재발 판정은 여기서 계산한다. 에이전트는 개선 패턴에 맞는 finding id만 고르고, 세는 일과 판정은 하지 않는다.
#   - 후보 목록에 없는 id는 버린다(지어낸 id가 숫자를 만들지 못하게).
#   - 같은 세션의 finding 여러 개는 한 세션으로 센다.
#   - 반영 뒤 관측 세션이 min_observed 미만이고 재발도 없으면 "판단 보류" — 성공으로 세지 않는다.
#   - 반영 뒤 후보가 상한에 잘렸으면 재발이 빠졌을 수 있어 "사라짐" 대신 "판단 보류"다.
#   - 근거 batch는 문제가 있어 뽑힌 세션이라 비율이 부풀려진다. 에이전트가 반영 전 30일(window)도 맞췄으면
#     비율 비교 기준을 그쪽(반영 뒤와 같은 정의: 정리된 세션 전부)으로 삼는다.
#   - 맞춰 보지 않은 개선은 반영 뒤 관측 세션이 min_observed 미만이면 "판단 보류", 아니면 "판정 안 함"이다.
#   - 하이라이트에 matched_through(YYYY-MM-DD, 매칭할 때의 compare --today)가 있으면 그날까지의 세션으로만 판정한다.
#     render가 보관해 둔 매칭을 더 새 compare에 다시 쓸 때(보드), 아직 맞춰 보지 않은 뒤 세션이 분모에만 들어가
#     "사라짐·줄어듦"으로 기울지 않게 한다. 그 뒤 세션 수는 unjudged로 알린다.
# 후보 목록은 리포트에 싣지 않고, 맞춘 finding 요약 몇 개만 근거로 남긴다.

def min_observed: 5;
def example_cap: 3;

def matched($ids; $cands):
  ($cands | map({(.id): .}) | add // {}) as $ok
  | [$ids[]? | strings | select($ok[.] != null) | $ok[.]] | unique_by(.id);

def sessions_of: map(.id | split("#")[0]) | unique | length;

def verdict($bh; $ah; $observed; $before_observed):
  if $bh == 0 then "no_baseline"
  elif $observed < min_observed then (if $ah > 0 then "recurred" else "hold" end)
  elif $ah == 0 then "gone"
  elif ($ah / $observed) < ($bh / ([$before_observed, 1] | max)) then "reduced"
  else "recurred" end;

def pending_verdict($observed): if $observed < min_observed then "hold" else "unmatched" end;

# 반영 뒤 관측 세션 수. $mt가 있으면 그날까지만 센다(날짜별 수가 없는 옛 compare JSON은 전체).
def observed_through($after; $mt):
  if $mt == null or (($after.observed_by_day // null) | type) != "object" then ($after.observed // 0)
  else [$after.observed_by_day | to_entries[] | select(.key <= $mt) | .value] | add // 0 end;

def evidence($h):
  ((($h | objects) // {}).matched_through // null | if type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$") then . else null end) as $mt
  | ((($h | objects) // {}).improvements // [] | map(select(type == "object" and (.id | type) == "string") | {(.id): .}) | add // {}) as $HI
  | .improvements = ((.improvements // []) | map(
      . as $x
      | ($x.before.candidates.items // []) as $bc
      | ($x.before.window.candidates.items // []) as $wc
      | ($x.after.candidates.items // []) as $ac
      | ($x.after.candidates.truncated // false) as $atrunc
      | $HI[$x.id] as $m
      | observed_through($x.after; $mt) as $obs
      | (if $m == null then {verdict: pending_verdict($x.after.observed // 0)}
         else
           matched($m.before; $bc) as $bm
           | matched($m.after; $ac) as $am
           | (if $x.before.window != null and ($m | has("window")) then matched($m.window; $wc) else null end) as $wm
           | ($bm | sessions_of) as $bh
           | ($am | sessions_of) as $ah
           | (if $wm == null then null else ($wm | sessions_of) end) as $wh
           | (if ($wh // 0) > 0 then "window" else "batch" end) as $base
           | (if $base == "window" then verdict($wh; $ah; $obs; $x.before.window.observed)
              else verdict($bh; $ah; $obs; $x.before.observed) end) as $v
           | {label: ($m.label // null), note: ($m.note // null),
              before_hits: $bh, after_hits: $ah, window_hits: $wh, baseline: $base,
              before_truncated: ($x.before.candidates.truncated // false),
              window_truncated: ($x.before.window.candidates.truncated // false),
              after_truncated: $atrunc,
              verdict: (if $v == "gone" and $atrunc then "hold" else $v end),
              observed: $obs, as_of: $mt, unjudged: (($x.after.observed // 0) - $obs),
              before_examples: ($bm | sort_by(.date) | reverse | .[0:example_cap] | map({date, summary})),
              after_examples: ($am | sort_by(.date) | reverse | .[0:example_cap] | map({date, summary}))}
         end) as $r
      | $x | del(.before.candidates, .before.window.candidates, .after.candidates) | . + {result: $r}));
