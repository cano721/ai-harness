#!/usr/bin/env bash
# 회귀 테스트 — Harness Board 하네스 설정 > 스킬 탭(setup.sh 상태·setup 세션·연결 확인)
# 실행: bash tests/run.sh board-skills
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-board.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-board.sh"

# 하네스 설정 > 스킬(#494): 카탈로그·디자인 스킬 상태는 setup.sh list·design list가 원본이고 실제 스킬 폴더와 맞는다.
# [설치]·[설정하기]·[제거]는 서버가 만든 지시문으로 setup 세션(claude --bg)을 띄우고, 세션이 끝나면 상태를 다시 읽는다.
# 연결 확인은 버튼으로만 setup.sh check를 부른다(가짜 Jira 서버). 키 값은 응답·기록 어디에도 남지 않는다.
BSK_T="$TEST_TMP/board-skills"
BSK_DATA="$BSK_T/data"; BSK_CL="$BSK_T/claude-skills"; BSK_CX="$BSK_T/codex-skills"
BSK_SECRET="bsk-secret-token-7f3a"
mkdir -p "$BSK_T/bin" "$BSK_DATA" "$BSK_CL" "$BSK_CX" "$BSK_T/jira/rest/api/3"
printf '[]\n' >"$BSK_T/agents.json"
# 가짜 claude: agents는 agents.json을 그대로, --bg는 인자(호출마다 한 줄)·cwd를 남기고 busy 세션 하나를 agents.json에 더한다.
cat >"$BSK_T/bin/claude" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == agents ]]; then cat "$BSK_T/agents.json"; exit 0; fi
if [[ "\$1" == --bg ]]; then
  { printf '%s' "\$*" | tr '\n' ' '; echo; } >>"$BSK_T/claude.log"; printf '%s\n' "\$PWD" >>"$BSK_T/claude-cwd.log"
  n="\$(wc -l <"$BSK_T/claude.log" | tr -d ' ')"
  jq --arg n "\$3" --arg sid "\$(printf 'bbbbbbbb-0000-0000-0000-%012d' "\$n")" --argjson at "\$(date +%s)000" --arg cwd "\$PWD" \
    '. + [{sessionId:\$sid, id:\$sid[0:8], kind:"background", status:"busy", state:"running", pid:4242, cwd:\$cwd, name:\$n, startedAt:\$at}]' \
    "$BSK_T/agents.json" >"$BSK_T/agents.tmp" && mv "$BSK_T/agents.tmp" "$BSK_T/agents.json"
  echo "backgrounded"; exit 0
fi
exit 1
EOF
chmod +x "$BSK_T/bin/claude"
BSK_KEYS="DATADOG_API_KEY DD_API_KEY DATADOG_APP_KEY DD_APP_KEY DATADOG_SITE DD_SITE SENTRY_AUTH_TOKEN SENTRY_ORG SENTRY_URL JIRA_BASE_URL ATLASSIAN_USER ATLASSIAN_API_TOKEN CONFLUENCE_BASE_URL LANGFUSE_PUBLIC_KEY LANGFUSE_SECRET_KEY LANGFUSE_HOST GA_KEY_FILE GA_PROPERTY_ID"
bsk_env() { # 사용자 환경의 키가 섞이지 않게 카탈로그 키를 모두 비운다. 보는 화면 없이 /settings/skills만 읽으므로
  # 작업 목록 캐시가 1초 지나면 그 자리에서 다시 모으게 한다(기본 30초) — 끝난 setup 세션이 바로 보인다.
  local k unset_args=()
  for k in $BSK_KEYS $(compgen -e | grep -E '^(LANGFUSE|GA_PROPERTY)_' || true); do unset_args+=(-u "$k"); done
  env "${unset_args[@]}" PATH="$BSK_T/bin:$BOARD_T/bin:$PATH" ORCA_CLI_COMMAND=orca HARNESS_METRICS_DIR="$BSK_DATA" \
    HARNESS_CLAUDE_PROJECTS_DIR="$BSK_T/projects" HARNESS_CLAUDE_SETTINGS="$BSK_T/settings.json" \
    HM_CLAUDE_SKILLS_DIR="$BSK_CL" HM_CODEX_SKILLS_DIR="$BSK_CX" BOARD_SKILLS_TTL=0 BOARD_STALE_SYNC_SECONDS=1 "$@"
}
bsk_setup() { bsk_env bash "$ROOT/scripts/setup.sh" "$@" >/dev/null; }
BSK_PORT="$(free_port)"
BSK_URL="$(bsk_env BOARD_PORT="$BSK_PORT" BOARD_NO_BROWSER=1 BOARD_IDLE_EXIT=0 BOARD_JIRA_URL= bash "$ROOT/scripts/board/board.sh" open | jq -r '.url')"
BSK_TOKEN="${BSK_URL#*t=}"
BSK_BASE="http://127.0.0.1:$BSK_PORT"
track_test_process "$(jq -r '.pid' "$BSK_DATA/board/server.json")"
bsk_get() { curl -s "$BSK_BASE/settings/skills?t=$BSK_TOKEN"; }
bsk_post() { curl -s -X POST -H "Origin: $BSK_BASE" -d "$(jq -c --arg t "$BSK_TOKEN" '. + {t: $t}' <<<"$2")" "$BSK_BASE/settings/skills/$1"; }
bsk_states() { jq -r --arg k "$2" '[.[$k][] | "\(.name)=\(.state)"] | join(" ")' <<<"$1"; }
bsk_wait() { # jq 조건이 참이 될 때까지 다시 읽는다(최대 20초)
  local out=""
  for _ in $(seq 1 40); do out="$(bsk_get)"; jq -e "$1" >/dev/null 2>&1 <<<"$out" && { printf '%s' "$out"; return 0; }; sleep 0.5; done
  printf '%s' "$out"; return 1
}
assert_eq "403" "$(curl -s -o /dev/null -w '%{http_code}' "$BSK_BASE/settings/skills?t=wrong")" "skills view checks the token"
assert_eq "403" "$(curl -s -o /dev/null -w '%{http_code}' -X POST -d "$(jq -cn --arg t "$BSK_TOKEN" '{t: $t, kind: "catalog", name: "jira", action: "install"}')" "$BSK_BASE/settings/skills/session")" "skill session checks the Origin"
assert_eq "403" "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Origin: $BSK_BASE" -d '{"t":"wrong","name":"jira"}' "$BSK_BASE/settings/skills/check")" "skill check checks the token"

# A1 빈 스킬 폴더: 카탈로그 6종 모두 미설치, 디자인은 내장·설치 불가를 빼고 미설치
BSK="$(bsk_get)"
assert_eq "true" "$(jq -r '.ok' <<<"$BSK")" "skills view answers"
assert_eq "datadog=missing sentry=missing jira=missing confluence=missing langfuse=missing ga=missing" "$(bsk_states "$BSK" catalog)" "an empty skill folder shows every catalog skill as missing"
assert_eq "impeccable=missing dataviz=builtin design-taste-frontend=missing ui-ux-pro-max=missing design-system-patterns=builtin emil-design-eng=builtin web-design-guidelines=builtin awesome-design=unavailable motion=unavailable" \
  "$(bsk_states "$BSK" design)" "design skills: builtin and not installable are not missing"

# A8 거부: 화이트리스트 밖 이름, 모르는 kind·action, 상태와 맞지 않는 action — claude를 부르지 않는다
for body in '{"kind":"catalog","name":"../x","action":"install"}' '{"kind":"catalog","name":"evil","action":"install"}' \
  '{"kind":"other","name":"jira","action":"install"}' '{"kind":"catalog","name":"jira","action":"delete"}' \
  '{"kind":"catalog","name":"jira","action":"remove"}' '{"kind":"catalog","name":"jira","action":"setup"}' \
  '{"kind":"design","name":"design-system-patterns","action":"install"}' '{"kind":"design","name":"impeccable","action":"setup"}' \
  '{"kind":"design","name":"motion","action":"install"}'; do
  assert_eq "false" "$(bsk_post session "$body" | jq -r '.ok')" "skill session refuses $body"
done
assert_eq "false" "$(bsk_post check '{"name":"evil"}' | jq -r '.ok')" "skill check refuses a name outside the catalog"
assert_not_file "$BSK_T/claude.log" "refused skill sessions never start claude"

# A2 setup.sh로 claude 폴더에 jira를 깔고 키가 없으면 '토큰 없음', 나머지는 그대로 미설치
bsk_setup install --tool claude jira
BSK="$(bsk_get)"
assert_eq "datadog=missing sentry=missing jira=no_token confluence=missing langfuse=missing ga=missing" "$(bsk_states "$BSK" catalog)" "an installed skill without keys is no_token"
assert_eq "current absent" "$(jq -r '.catalog[] | select(.name == "jira") | "\(.status.claude) \(.status.codex)"' <<<"$BSK")" "tool statuses come from setup.sh list"
assert_contains "$(jq -r '.catalog[] | select(.name == "jira") | .missing | join(",")' <<<"$BSK")" "ATLASSIAN_API_TOKEN" "the row names the missing keys"

# A4 직접 둔 같은 이름 폴더는 foreign 보조 표시 + 설치됨 계열, codex 폴더에만 깔면 codex 상태에 반영
mkdir -p "$BSK_CX/confluence"; printf -- '---\nname: confluence\n---\n' >"$BSK_CX/confluence/SKILL.md"
bsk_setup install --tool codex sentry
BSK="$(bsk_get)"
assert_eq "no_token" "$(jq -r '.catalog[] | select(.name == "confluence") | .state' <<<"$BSK")" "a hand-made folder counts as installed"
assert_eq "codex:foreign" "$(jq -r '.catalog[] | select(.name == "confluence") | [.flags[] | "\(.tool):\(.status)"] | join(",")' <<<"$BSK")" "a hand-made folder carries the foreign flag"
assert_eq "absent current no_token" "$(jq -r '.catalog[] | select(.name == "sentry") | "\(.status.claude) \(.status.codex) \(.state)"' <<<"$BSK")" "a codex-only install shows on the codex status"

# A5 디자인 스킬 폴더를 두면 설치됨
mkdir -p "$BSK_CL/impeccable"; printf -- '---\nname: impeccable\n---\n' >"$BSK_CL/impeccable/SKILL.md"
assert_eq "installed" "$(bsk_get | jq -r '.design[] | select(.name == "impeccable") | .state')" "a design skill folder shows as installed"

# A3 필수 키가 다 있으면 '연결 미확인', 응답에 키 값이 없다
BSK_JPORT="$(free_port)"
python3 -I -m http.server "$BSK_JPORT" --bind 127.0.0.1 --directory "$BSK_T/jira" >/dev/null 2>&1 &
track_test_process "$!"
printf '{"displayName":"Board Tester"}\n' >"$BSK_T/jira/rest/api/3/myself"
for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$BSK_JPORT/rest/api/3/myself" && break; sleep 0.1; done
jq -n --arg u "http://127.0.0.1:$BSK_JPORT" --arg s "$BSK_SECRET" '{env: {JIRA_BASE_URL: $u, ATLASSIAN_USER: "tester@example.com", ATLASSIAN_API_TOKEN: $s}}' >"$BSK_T/settings.json"
BSK="$(bsk_get)"
assert_eq "unverified" "$(jq -r '.catalog[] | select(.name == "jira") | .state' <<<"$BSK")" "keys present without a check is unverified"
case "$BSK" in *"$BSK_SECRET"*) fail "the skills view never carries a key value" ;; esac

# A10 [연결 확인]: 결과(ok·at·error)만 기록하고 상태에 반영한다
BSK_CHECK="$(bsk_post check '{"name":"jira"}')"
assert_eq "true true" "$(jq -r '"\(.ok) \(.check.ok)"' <<<"$BSK_CHECK")" "a passing check is recorded"
assert_eq "true" "$(jq -r '.jira.ok' "$BSK_DATA/board/skill-checks.json")" "skill-checks.json keeps the result"
assert_eq "at ok" "$(jq -r '.jira | keys | join(" ")' "$BSK_DATA/board/skill-checks.json")" "skill-checks.json keeps only ok and at"
assert_eq "verified" "$(bsk_get | jq -r '.catalog[] | select(.name == "jira") | .state')" "a passing check makes the skill verified"
rm "$BSK_T/jira/rest/api/3/myself"
BSK_CHECK="$(bsk_post check '{"name":"jira"}')"
assert_eq "true false" "$(jq -r '"\(.ok) \(.check.ok)"' <<<"$BSK_CHECK")" "a failing check is recorded"
assert_contains "$(jq -r '.check.error' <<<"$BSK_CHECK")" "404" "a failing check says why"
assert_eq "unverified" "$(bsk_get | jq -r '.catalog[] | select(.name == "jira") | .state')" "a failing check leaves the skill unverified"
for f in "$BSK_DATA/board/skill-checks.json" "$BSK_DATA/board/actions.jsonl"; do
  case "$(cat "$f" 2>/dev/null)$BSK_CHECK" in *"$BSK_SECRET"*) fail "no key value in $f or the check answer" ;; esac
done

# A6 [설정하기]: 서버가 만든 지시문으로 홈에서 claude --bg, sid를 이름으로 찾아 기록한다. 브라우저 문자열은 지시문에 들어가지 않는다.
BSK_RES="$(bsk_post session '{"kind":"catalog","name":"jira","action":"setup","prompt":"INJECTED-BY-BROWSER"}')"
assert_eq "true" "$(jq -r '.ok' <<<"$BSK_RES")" "a setup session starts"
BSK_LOG="$(<"$BSK_T/claude.log")"
assert_contains "$BSK_LOG" "--bg --name 하네스 설정: 스킬 설정 jira" "the session is a named background session"
assert_contains "$BSK_LOG" "/ai-harness:setup" "the session runs the setup skill"
assert_contains "$BSK_LOG" "별도 터미널" "the prompt sends key values to a separate terminal"
assert_contains "$BSK_LOG" "setup.sh check jira" "the prompt checks the connection of that skill"
case "$BSK_LOG" in *INJECTED-BY-BROWSER*) fail "browser text never reaches the session prompt" ;; esac
assert_eq "$HOME" "$(head -1 "$BSK_T/claude-cwd.log")" "the setup session runs in the home folder"
assert_eq "bbbbbbbb-0000-0000-0000-000000000001 setup" "$(jq -r '.["catalog:jira"] | "\(.sid) \(.action)"' "$BSK_DATA/board/skill-sessions.json")" "the session id is recorded for the skill"

# A7 [설치]·[제거]: 동작별 setup.sh 명령이 지시문에 들어간다
bsk_post session '{"kind":"catalog","name":"datadog","action":"install"}' >/dev/null
bsk_post session '{"kind":"catalog","name":"confluence","action":"remove"}' >/dev/null
bsk_post session '{"kind":"design","name":"design-taste-frontend","action":"install"}' >/dev/null
bsk_post session '{"kind":"design","name":"impeccable","action":"remove"}' >/dev/null
assert_eq "5" "$(wc -l <"$BSK_T/claude.log" | tr -d ' ')" "each accepted request starts one session"
BSK_LOG="$(<"$BSK_T/claude.log")"
assert_contains "$(sed -n 2p "$BSK_T/claude.log")" "setup.sh install --tool <도구> datadog" "install prompt runs setup.sh install"
assert_contains "$(sed -n 3p "$BSK_T/claude.log")" "setup.sh remove --tool <도구> confluence" "remove prompt runs setup.sh remove"
assert_contains "$(sed -n 4p "$BSK_T/claude.log")" "setup.sh design install --tool <도구> design-taste-frontend" "design install prompt runs design install"
assert_contains "$(sed -n 5p "$BSK_T/claude.log")" "setup.sh design remove --tool <도구> impeccable" "design remove prompt runs design remove"
assert_contains "$BSK_LOG" "--name 하네스 설정: 스킬 제거 confluence" "remove sessions are named for the skill"

# A9 세션이 도는 동안은 줄에 세션 상태가 붙고, 끝나면 기록을 지우고 실제 폴더를 다시 읽는다(연결 확인 기록도 지운다)
BSK="$(bsk_wait '.catalog[] | select(.name == "datadog") | .session.state == "running"')" || fail "a running setup session shows on its row ($BSK)"
assert_eq "running" "$(jq -r '.catalog[] | select(.name == "jira") | .session.state' <<<"$BSK")" "the setup session shows on the jira row"
bsk_setup install --tool claude datadog
printf '[]\n' >"$BSK_T/agents.json"
BSK="$(bsk_wait '.catalog[] | select(.name == "datadog") | .session == null and .state == "no_token"')" || fail "a finished session refreshes the row ($BSK)"
assert_eq "{}" "$(jq -c '.' "$BSK_DATA/board/skill-sessions.json")" "finished session records are dropped"
assert_eq "null" "$(jq -c '.jira' "$BSK_DATA/board/skill-checks.json")" "a finished setup session clears that skill's connection check"

# A11 화면: 하네스 설정에 '스킬' 탭, 상태별 버튼, 공용 세션 띄우기 장치
BSK_TPL="$(<"$ROOT/scripts/board/template.html")"
assert_contains "$BSK_TPL" "['skills', '스킬'," "harness settings has a skills tab"
assert_contains "$BSK_TPL" "async function startSetupSession(" "the board has a shared setup-session launcher"
assert_contains "$BSK_TPL" "'/settings/skills/session'" "the launcher posts to the skill session endpoint"
assert_contains "$BSK_TPL" "'/settings/skills/check'" "the skills tab checks connections on demand"
assert_contains "$(<"$ROOT/skills/setup/SKILL.md")" "보드" "setup skill mentions board-started sessions"
pass "harness board settings: skills tab state from setup.sh, setup sessions from the board, refresh after the session (#494)"

# 별칭 키(#621): 별칭 키만 있는 langfuse도 no_token이 아니라 unverified이고, 연결 확인은 별칭마다 자기 host로 한 뒤
# 프로젝트별 결과 [{alias, ok, error?}]만 기록한다(프로젝트 이름·hint·키 값은 기록하지 않는다). 모든 별칭이 통과해야 verified.
bsk_setup install --tool claude langfuse
BSK_LF_PK="pk-lf-bsk-alias"; BSK_LF_SK="sk-lf-bsk-alias"
mkdir -p "$BSK_T/lf-ok-a/api/public" "$BSK_T/lf-ok-b/api/public" "$BSK_T/lf-bad"
printf '{"data":[{"name":"Agent Proj"}]}\n' >"$BSK_T/lf-ok-a/api/public/projects"
printf '{"data":[{"name":"Talent Proj"}]}\n' >"$BSK_T/lf-ok-b/api/public/projects"
BSK_LF_PORTS=""
for d in lf-ok-a lf-ok-b lf-bad; do
  BSK_LF_P="$(free_port)"; BSK_LF_PORTS="$BSK_LF_PORTS $BSK_LF_P"
  python3 -I -m http.server "$BSK_LF_P" --bind 127.0.0.1 --directory "$BSK_T/$d" >/dev/null 2>&1 &
  track_test_process "$!"
  for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$BSK_LF_P/" && break; sleep 0.1; done
done
read -r BSK_LF_A BSK_LF_B BSK_LF_BAD <<<"$BSK_LF_PORTS"
bsk_lf_settings() { # 에이전트 별칭 host, 인재풀 별칭 host
  jq -n --arg u "http://127.0.0.1:$BSK_JPORT" --arg s "$BSK_SECRET" --arg pk "$BSK_LF_PK" --arg sk "$BSK_LF_SK" \
    --arg ha "http://127.0.0.1:$1" --arg hb "http://127.0.0.1:$2" '{env: {
      JIRA_BASE_URL: $u, ATLASSIAN_USER: "tester@example.com", ATLASSIAN_API_TOKEN: $s,
      LANGFUSE_PUBLIC_KEY_AGENT: $pk, LANGFUSE_SECRET_KEY_AGENT: $sk, LANGFUSE_HOST_AGENT: $ha,
      LANGFUSE_PUBLIC_KEY_TALENT_POOL: $pk, LANGFUSE_SECRET_KEY_TALENT_POOL: $sk, LANGFUSE_HOST_TALENT_POOL: $hb}}' >"$BSK_T/settings.json"
}
bsk_lf_settings "$BSK_LF_A" "$BSK_LF_BAD"
BSK="$(bsk_get)"
assert_eq "unverified" "$(jq -r '.catalog[] | select(.name == "langfuse") | .state' <<<"$BSK")" "alias-only langfuse keys are unverified, not no_token"
BSK_CHECK="$(bsk_post check '{"name":"langfuse"}')"
assert_eq "true false" "$(jq -r '"\(.ok) \(.check.ok)"' <<<"$BSK_CHECK")" "a check with one failing alias is recorded as failed"
assert_eq "agent:true talent-pool:false" "$(jq -r '[.check.projects[]? | "\(.alias):\(.ok)"] | join(" ")' <<<"$BSK_CHECK")" "the check answer lists each alias result"
assert_contains "$(jq -r '.check.projects[]? | select(.alias == "talent-pool") | .error' <<<"$BSK_CHECK")" "404" "the failing alias carries its error"
assert_eq "true" "$(jq -r '.langfuse | has("projects")' "$BSK_DATA/board/skill-checks.json")" "skill-checks.json keeps the per-alias results"
assert_eq "alias ok|alias error ok" "$(jq -r '.langfuse.projects | map(keys | join(" ")) | join("|")' "$BSK_DATA/board/skill-checks.json")" "a project record has only alias, ok and error"
assert_eq "unverified" "$(bsk_get | jq -r '.catalog[] | select(.name == "langfuse") | .state')" "a failing alias leaves langfuse unverified"
assert_eq "talent-pool:false" "$(bsk_get | jq -r '[.catalog[] | select(.name == "langfuse") | .check.projects[]? | select(.ok == false) | "\(.alias):\(.ok)"] | join(" ")')" "the skills view shows the failing alias"
for f in "$BSK_DATA/board/skill-checks.json" "$BSK_DATA/board/actions.jsonl"; do
  case "$(cat "$f" 2>/dev/null)$BSK_CHECK$BSK" in
    *"$BSK_LF_PK"*|*"$BSK_LF_SK"*|*"Agent Proj"*) fail "no key value or project name in $f or the answers" ;;
  esac
done
bsk_lf_settings "$BSK_LF_A" "$BSK_LF_B"
BSK_CHECK="$(bsk_post check '{"name":"langfuse"}')"
assert_eq "true true" "$(jq -r '"\(.ok) \(.check.ok)"' <<<"$BSK_CHECK")" "a check with every alias passing is recorded as ok"
assert_eq "verified" "$(bsk_get | jq -r '.catalog[] | select(.name == "langfuse") | .state')" "every alias passing makes langfuse verified"
printf '{"displayName":"Board Tester"}\n' >"$BSK_T/jira/rest/api/3/myself"
bsk_post check '{"name":"jira"}' >/dev/null
assert_eq "at ok" "$(jq -r '.jira | keys | join(" ")' "$BSK_DATA/board/skill-checks.json")" "other skills keep only ok and at"
BSK_TPL="$(<"$ROOT/scripts/board/template.html")"
assert_contains "$BSK_TPL" "c.projects" "the skills row renders the per-alias results"
assert_contains "$BSK_TPL" "확인한 프로젝트" "the skills row captions the checked projects"
pass "board skills: alias-only langfuse is unverified, per-alias check results are recorded without keys, all aliases must pass (#621)"

finish_tests
