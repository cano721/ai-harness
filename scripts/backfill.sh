#!/usr/bin/env bash
# 미처리/갱신된 transcript 전체 스캔 (Claude + Codex).
# - 이벤트 파일이 없거나 원본/추출기가 더 최신이거나 event version이 다르면 재추출 (멱등)
# - 진행 중 JSONL도 fromjson?로 불완전한 마지막 줄만 버릴 수 있으므로 즉시 처리
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$DIR/lib.sh"
done_n=0; skip_n=0; fail_n=0; cleanup_n=0; queue_n=0; queue_skip_n=0; queue_fail_n=0
shopt -s nullglob

# v0.7.x에서 Codex SessionEnd hook이 Claude extractor를 호출해 만든 파생 유령 이벤트 정리.
for ghost in "$HM_DATA_DIR"/events/claude-rollout-*.jsonl; do
  if jq -e 'select(.kind=="session" and .src=="claude" and (.sid|startswith("rollout-")))' \
    "$ghost" >/dev/null 2>&1; then
    find "$ghost" -delete
    cleanup_n=$((cleanup_n + 1))
  fi
done

# 큐 기록 스탬프: 이벤트도 큐 로직도 그대로면 record를 다시 부르지 않는다.
# 실측: 변경 없는 증분 backfill 4분 20초의 대부분이 이벤트 1771개 전부의 재기록이었다.
STAMP_DIR="$HM_DATA_DIR/.enqueued"
mkdir -p "$STAMP_DIR"

# 의존 스크립트가 "언제부터 지금 내용인가"를 내용 해시로 판단한다. 수정 시각을 쓰면 플러그인을
# 업데이트할 때마다(내용이 같아도 새로 설치되면) 전 세션을 다시 추출·기록한다 — 실측 2천여 세션에 1시간 이상.
DEP_STATE_DIR="$HM_DATA_DIR/.dep-state"
mkdir -p "$DEP_STATE_DIR"
dep_since() { # $1=그룹 이름, 나머지=파일 → 현재 내용이 처음 관측된 epoch
  local name="$1" hash="" state="" since="" newest=0 file="" file_mt=""
  shift
  hash="$(cat "$@" 2>/dev/null | { shasum 2>/dev/null || sha1sum; } | cut -c1-40)"
  state="$DEP_STATE_DIR/$name"
  if [[ -f "$state" && "$(sed -n '1p' "$state")" == "$hash" ]]; then
    since="$(sed -n '2p' "$state")"
    [[ "$since" =~ ^[0-9]+$ ]] && { printf '%s\n' "$since"; return; }
  fi
  # 처음이거나 내용이 바뀌었다. 기록이 없을 때는 기존과 같이 파일 수정 시각을 기준으로 한다.
  for file in "$@"; do
    file_mt="$(mtime "$file")"
    [[ -n "$file_mt" ]] && (( file_mt > newest )) && newest="$file_mt"
  done
  [[ -f "$state" ]] && newest="$(date +%s)"
  printf '%s\n%s\n' "$hash" "$newest" >"$state"
  printf '%s\n' "$newest"
}
queue_dep_mt="$(dep_since queue "$DIR/harvest-queue.sh" "$DIR/lib.sh")"
claude_dep_mt="$(dep_since extract-claude "$DIR/extract-claude.sh" "$DIR/extract-claude.jq" "$DIR/redact.jq" "$DIR/lib.sh")"
codex_dep_mt="$(dep_since extract-codex "$DIR/extract-codex.sh" "$DIR/redact.jq" "$DIR/lib.sh")"

enqueue_is_fresh() { # $1=event
  local stamp="$STAMP_DIR/${1##*/}" stamp_mt="" ev_mt=""
  [[ -f "$stamp" ]] || return 1
  stamp_mt="$(mtime "$stamp")"; ev_mt="$(mtime "$1")"
  [[ -n "$stamp_mt" && -n "$ev_mt" ]] && (( stamp_mt >= ev_mt && stamp_mt >= queue_dep_mt ))
}

enqueue_event() {
  local ev="$1" queue_result="" action="" rollup="" rollup_tmp=""
  local source_mtime=0 source_size=0
  if enqueue_is_fresh "$ev"; then
    queue_skip_n=$((queue_skip_n + 1))
    return
  fi
  if [[ -f "$ev" ]] \
    && jq -e 'select(.kind=="session")' "$ev" >/dev/null 2>&1 \
    && queue_result="$("$DIR/harvest-queue.sh" record "$ev" 2>/dev/null)"; then
    queue_n=$((queue_n + 1))
    : >"$STAMP_DIR/${ev##*/}"
    action="$(printf '%s' "$queue_result" | jq -r '.record_action // empty' 2>/dev/null || true)"
    rollup="$HM_DATA_DIR/rollups/$(basename "$ev")"
    # mtime만 바뀐 동일 transcript를 확인하려 상세 이벤트를 잠시 복원했더라도,
    # revision이 같으면 기존 rollup을 유지하고 상세 복사본은 다시 제거한다.
    if [[ "$action" == "unchanged" && -f "$rollup" && -f "$ev" ]]; then
      source_mtime="$(jq -sr 'map(select(.kind=="session") | .source_mtime // 0) | first // 0' "$ev")"
      source_size="$(jq -sr 'map(select(.kind=="session") | .source_size // 0) | first // 0' "$ev")"
      rollup_tmp="$(mktemp "$HM_DATA_DIR/rollups/.rollup-source.XXXXXX")"
      jq -c --argjson source_mtime "$source_mtime" --argjson source_size "$source_size" '
        if .kind=="session" then .source_mtime=$source_mtime | .source_size=$source_size else . end
      ' "$rollup" >"$rollup_tmp"
      mv "$rollup_tmp" "$rollup"
      find "$ev" -maxdepth 0 -type f -delete
    fi
  else
    queue_fail_n=$((queue_fail_n + 1))
  fi
}

process() { # $1=transcript $2=event파일 $3=extractor
  local t="$1" ev="$2" ex="$3"
  local mt="" ev_mt="" ev_v="0" newest_dep=0 rollup="" rollup_mt=""
  local source_mtime=0 source_size=0 current_size=0
  mt="$(mtime "$t")"
  [[ -n "$mt" ]] || return
  # 서브에이전트 transcript(<sid>/subagents/)는 부모 이벤트에 합산된다 — 메인보다 늦게 끝나면 그 시각으로 신선도를 판정한다.
  # 롤업 판정은 원본(메인) 수정 시각과 비교하므로 mt는 그대로 둔다.
  local src_mt="$mt" agent="" agent_mt=""
  if [[ "$ex" == "extract-claude.sh" ]]; then
    for agent in "${t%.jsonl}"/subagents/*.jsonl; do
      agent_mt="$(mtime "$agent")"
      [[ -n "$agent_mt" ]] && (( agent_mt > src_mt )) && src_mt="$agent_mt"
    done
  fi

  # 검토 완료 후 보관 정책으로 rollup된 세션은 extractor 변경만으로 상세 이벤트를 되살리지 않는다.
  # 단, 같은 세션 transcript가 실제로 갱신됐으면 재개된 세션이므로 다시 추출·큐 등록한다.
  rollup="$HM_DATA_DIR/rollups/$(basename "$ev")"
  if [[ ! -f "$ev" && -f "$rollup" ]]; then
    source_mtime="$(jq -sr 'map(select(.kind=="session") | .source_mtime // 0) | first // 0' "$rollup" 2>/dev/null || printf '0')"
    source_size="$(jq -sr 'map(select(.kind=="session") | .source_size // 0) | first // 0' "$rollup" 2>/dev/null || printf '0')"
    current_size="$(filesize "$t")"; current_size="${current_size:-0}"
    if (( source_mtime > 0 )) && [[ "$mt" == "$source_mtime" && "$current_size" == "$source_size" ]]; then
      skip_n=$((skip_n + 1))
      return
    elif (( source_mtime == 0 )); then
      rollup_mt="$(mtime "$rollup")"
      if [[ -n "$rollup_mt" ]] && (( rollup_mt >= mt )); then
        skip_n=$((skip_n + 1))
        return
      fi
    fi
  fi

  if [[ "$ex" == "extract-claude.sh" ]]; then
    newest_dep="$claude_dep_mt"
  else
    newest_dep="$codex_dep_mt"
  fi

  if [[ -f "$ev" ]]; then
    ev_mt="$(mtime "$ev")"
    ev_v="$(jq -sr 'map(select(.kind=="session")) | first | .v // 0' "$ev" 2>/dev/null || printf '0')"
    if [[ "$ev_v" == "$HM_EVENT_VERSION" && -n "$ev_mt" ]] \
      && (( ev_mt >= src_mt && ev_mt >= newest_dep )); then
      skip_n=$((skip_n + 1))
      enqueue_event "$ev"
      return
    fi
  fi

  if "$DIR/$ex" "$t" 2>/dev/null; then
    done_n=$((done_n + 1))
    enqueue_event "$ev"
  else
    fail_n=$((fail_n + 1))
  fi
}

for t in "$HM_CLAUDE_PROJECTS_DIR"/*/*.jsonl; do
  [[ -f "$t" ]] || continue
  process "$t" "$HM_DATA_DIR/events/claude-$(basename "$t" .jsonl).jsonl" extract-claude.sh
done

while IFS= read -r codex_root; do
  [[ -d "$codex_root" ]] || continue
  while IFS= read -r t; do
    sid="$(basename "$t" .jsonl | sed 's/^rollout-//')"
    process "$t" "$HM_DATA_DIR/events/codex-${sid}.jsonl" extract-codex.sh
  done < <(find "$codex_root" -name 'rollout-*.jsonl' -type f 2>/dev/null)
done < <(codex_session_roots)

# 원본 transcript가 지워진(Claude는 오래된 기록을 자동 정리한다) 세션은 위에서 다시 추출되지 않아,
# 프로젝트 ID 규칙이 바뀌어도 옛 이름으로 남는다(실측: 같은 workspace 681세션이 옛 이름).
# 규칙(lib.sh)이 바뀐 뒤 한 번, 남은 작업 경로로 다시 판정해 이름만 고치고 큐에 다시 기록한다.
relabel_n=0
relabel_since="$(dep_since relabel "$DIR/lib.sh")"
relabel_state="$DEP_STATE_DIR/relabel-done"
if [[ "$(sed -n '1p' "$relabel_state" 2>/dev/null)" != "$relabel_since" ]]; then
  for ev in "$HM_DATA_DIR"/events/*.jsonl "$HM_DATA_DIR"/rollups/*.jsonl; do
    # here-string: /bin/bash 3.2는 단일 명령의 `< <(...)` fd를 닫지 않아 파일이 많으면 fd 한도에 닿는다
    IFS=$'\t' read -r transcript old_project cwd <<<"$(jq -r 'select(.kind=="session")
      | [(.transcript // ""), (.project // ""), (.cwd // "")] | @tsv' "$ev" 2>/dev/null | head -n 1)"
    [[ -n "$cwd" && -n "$old_project" ]] || continue
    [[ -n "$transcript" && -f "$transcript" ]] && continue
    # 경로가 사라졌거나 git·workspace로 판정되지 않으면 폴더 이름 휴리스틱뿐이라, 추출 당시 git으로 얻은
    # 올바른 이름을 덮어쓸 수 있다. 확실히 판정되는 경우만 고친다.
    [[ -d "$cwd" ]] || continue
    [[ -f "$cwd/.ai-harness/workspace.json" ]] || git -C "$cwd" rev-parse --show-toplevel >/dev/null 2>&1 || continue
    new_project="$(project_id_for_cwd "$cwd")"
    [[ -n "$new_project" && "$new_project" != "$old_project" ]] || continue
    tmp="$(mktemp "${ev%/*}/.relabel.XXXXXX")"
    if jq -c --arg p "$new_project" 'if has("project") then .project = $p else . end' "$ev" >"$tmp"; then
      touch -r "$ev" "$tmp"
      mv "$tmp" "$ev"
      relabel_n=$((relabel_n + 1))
      [[ "$ev" == "$HM_DATA_DIR"/events/* ]] && { find "$STAMP_DIR/${ev##*/}" -maxdepth 0 -type f -delete 2>/dev/null || true; enqueue_event "$ev"; }
    else
      find "$tmp" -maxdepth 0 -type f -delete
    fi
  done
  printf '%s\n' "$relabel_since" >"$relabel_state"
fi

# 이벤트가 정리(prune·rollup)된 스탬프는 더 쓸 일이 없다.
for stamp in "$STAMP_DIR"/*; do
  [[ -f "$HM_DATA_DIR/events/${stamp##*/}" ]] || find "$stamp" -maxdepth 0 -type f -delete
done

if (( fail_n > 0 || queue_fail_n > 0 )); then
  "$DIR/health.sh" failure backfill "extract_${fail_n}_queue_${queue_fail_n}" >/dev/null 2>&1 || true
else
  "$DIR/health.sh" success backfill >/dev/null 2>&1 || true
fi
echo "백필 완료: 처리 $done_n, 스킵 $skip_n, 실패 $fail_n, 큐 $queue_n, 큐 유지 $queue_skip_n, 큐 실패 $queue_fail_n, 유령 정리 $cleanup_n, 이름 재판정 $relabel_n"
