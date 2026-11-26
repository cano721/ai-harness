#!/usr/bin/env bash
# 회귀 테스트 — setup 자격 증명 저장·확인·langfuse 카탈로그 스킬
# 실행: bash tests/run.sh setup-credentials
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-setup.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-setup.sh"

# 접속 정보: secret은 인자로 받지 않고 stdin으로만, 저장한 파일에서 바로 연결 확인. 자격 증명은 HTTP 호출 인자에도 싣지 않는다.
SETUP_T="$TEST_TMP/setup-creds"
SETUP_CATALOG="$ROOT/catalog"
mkdir -p "$SETUP_T"
printf '{"model":"opus","env":{"KEEP":"1"}}\n' >"$SETUP_T/settings.json"
cat >"$SETUP_T/http.sh" <<'STUB'
#!/usr/bin/env bash
conf="$(cat)"
printf '%s\n' "$*" >>"${0%/*}/argv.log"
case "$conf" in *bad-token*) printf 'HTTP 401\n' >&2; exit 1 ;; esac
case "$conf" in *pk-lf-from-cmd:sk-lf-from-cmd*) printf '{"data":[{"id":"p2","name":"FromCmd"}]}'; exit 0 ;; esac
case "$1" in
  */rest/api/3/myself) printf '{"displayName":"Kim"}' ;;
  */rest/api/3/field) printf '[{"id":"customfield_10113","name":"스프린트","schema":{"custom":"com.pyxis.greenhopper.jira:gh-sprint"}},{"id":"customfield_1","name":"x","schema":{"type":"string"}}]' ;;
  */rest/api/3/project/recent*) printf '[{"key":"ABC","name":"Alpha"}]' ;;
  */rest/api/3/issue/createmeta/*/issuetypes*) printf '{"issueTypes":[{"id":"1","name":"Epic","subtask":false,"hierarchyLevel":1},{"id":"2","name":"Task","subtask":false,"hierarchyLevel":0},{"id":"3","name":"Story","subtask":false,"hierarchyLevel":0},{"id":"4","name":"Sub-task","subtask":true,"hierarchyLevel":-1}]}' ;;
  */rest/api/3/search/jql*) printf '{"issues":[{"key":"%s-7"}]}' "$(sed -E 's/.*project%3D([A-Z0-9_]+).*/\1/' <<<"$1")" ;;
  */rest/api/3/issue/*-7/transitions) printf '{"transitions":[{"id":"11","name":"진행","to":{"name":"In Progress","statusCategory":{"key":"indeterminate"}}},{"id":"31","name":"Drop","to":{"name":"Drop","statusCategory":{"key":"done"}}}]}' ;;
  */api/public/projects) printf '{"data":[{"id":"p1","name":"Demo"}]}' ;;
  *) printf 'HTTP 404\n' >&2; exit 1 ;;
esac
STUB
chmod +x "$SETUP_T/http.sh"
SETUP_ENV=(HM_SETUP_HTTP="$SETUP_T/http.sh")
if setup_cmd set --tool claude ATLASSIAN_API_TOKEN "tok-in-argv" 2>/dev/null; then fail "secret accepted as an argument"; fi
assert_eq "missing" "$(setup_cmd check jira | jq -r 'if .missing then "missing" else "x" end')" "check reports missing keys"
setup_cmd set --tool claude JIRA_BASE_URL https://acme.atlassian.net/ >/dev/null
setup_cmd set --tool claude ATLASSIAN_USER me@acme.test >/dev/null
printf "good-tok'en\n" | setup_cmd set --tool both ATLASSIAN_API_TOKEN >/dev/null
assert_eq "1" "$(jq -r '.env.KEEP' "$SETUP_T/settings.json")" "settings.json keeps other env"
assert_eq "opus" "$(jq -r '.model' "$SETUP_T/settings.json")" "settings.json keeps other keys"
assert_eq "good-tok'en" "$(jq -r '.env.ATLASSIAN_API_TOKEN' "$SETUP_T/settings.json")" "secret saved to Claude settings"
# shellcheck disable=SC2016  # 변수는 source한 하위 셸에서 펼친다
assert_eq "good-tok'en" "$(env -i /bin/bash -c '. "$1"; printf %s "$ATLASSIAN_API_TOKEN"' _ "$SETUP_T/data/secrets.env")" "secret saved to sourceable Codex file"
assert_eq "600" "$(filemode "$SETUP_T/data/secrets.env")" "secrets file is private"
assert_eq "settings" "$(setup_cmd list | jq -r 'select(.name=="jira") | .env[2].source')" "saved secret visible without restart"
assert_eq "true Kim" "$(setup_cmd check jira | jq -r '"\(.ok) \(.as)"')" "check uses saved credentials"
DETECT="$(setup_cmd detect jira)"
assert_eq "customfield_10113 gh-sprint" "$(jq -r '.fields[0] | "\(.id) \(.type)"' <<<"$DETECT")" "detect finds sprint field by type"
assert_eq "1" "$(jq -r '.fields | length' <<<"$DETECT")" "detect ignores other fields"
assert_eq "ABC" "$(jq -r '.recent_projects[0].key' <<<"$DETECT")" "detect lists recent projects"
# 이슈 타입 계층·쓰지 않는 상태 질문의 선택지: 기본(최근) 프로젝트의 생성 가능 타입과 대표 이슈의 전환. (#243)
assert_eq "Epic:1 Task:0 Story:0 Sub-task:-1" "$(jq -r '[.issue_types[] | "\(.name):\(.hierarchy)"] | join(" ")' <<<"$DETECT")" "detect lists creatable issue types with hierarchy"
assert_eq "ABC-7 Drop:done" "$(jq -r '"\(.transitions.issue) \(.transitions.list[1] | "\(.name):\(.category)")"' <<<"$DETECT")" "detect lists transitions of a representative issue"
assert_eq "XY-7" "$(setup_cmd detect jira --project XY | jq -r '.transitions.issue')" "detect takes the project to inspect"
assert_eq "null 0" "$(setup_cmd detect jira --project 'a;b' | jq -r '"\(.project) \(.issue_types | length)"')" "detect ignores an invalid project key"
printf 'bad-token\n' | setup_cmd set --tool claude ATLASSIAN_API_TOKEN >/dev/null
assert_eq "false HTTP 401" "$(setup_cmd check jira | jq -r '"\(.ok) \(.error)"')" "check reports rejected credentials"
assert_eq "CONFLUENCE_BASE_URL" "$(setup_cmd check confluence | jq -r '.missing | join(",")')" "check names the missing base URL"
assert_eq "LANGFUSE_PUBLIC_KEY,LANGFUSE_SECRET_KEY" "$(setup_cmd check langfuse | jq -r '.missing | join(",")')" "langfuse check names missing project keys"
printf 'pk-lf-good\n' | setup_cmd set --tool claude LANGFUSE_PUBLIC_KEY >/dev/null
printf 'sk-lf-good\n' | setup_cmd set --tool claude LANGFUSE_SECRET_KEY >/dev/null
assert_eq "true Demo" "$(setup_cmd check langfuse | jq -r '"\(.ok) \(.as)"')" "langfuse check shows the project the keys point to"
assert_eq "https://cloud.langfuse.com/api/public/projects" "$(tail -1 "$SETUP_T/argv.log")" "langfuse check defaults to the EU cloud host"
setup_cmd set --tool claude LANGFUSE_HOST https://us.cloud.langfuse.com/ >/dev/null
setup_cmd check langfuse >/dev/null
assert_eq "https://us.cloud.langfuse.com/api/public/projects" "$(tail -1 "$SETUP_T/argv.log")" "langfuse check follows LANGFUSE_HOST"
printf 'sk-lf-bad-token\n' | setup_cmd set --tool claude LANGFUSE_SECRET_KEY >/dev/null
LF_CHECK="$(setup_cmd check langfuse)"
assert_eq "false HTTP 401" "$(jq -r '"\(.ok) \(.error)"' <<<"$LF_CHECK")" "langfuse check reports rejected keys"
assert_contains "$(jq -r '.hint' <<<"$LF_CHECK")" "LANGFUSE_HOST" "langfuse 401 points at key or region mismatch"
# 키 대신 비밀 저장소 명령(_CMD): 사용자 파일에 저장된 명령만 실행하고, 프로세스 환경의 명령은 무시한다.
jq 'del(.env.LANGFUSE_PUBLIC_KEY, .env.LANGFUSE_SECRET_KEY)' "$SETUP_T/settings.json" >"$SETUP_T/settings.tmp" && mv "$SETUP_T/settings.tmp" "$SETUP_T/settings.json"
SETUP_ENV=(HM_SETUP_HTTP="$SETUP_T/http.sh" LANGFUSE_PUBLIC_KEY_CMD="touch $SETUP_T/planted; printf pk-lf-from-cmd" LANGFUSE_SECRET_KEY_CMD="printf sk-lf-from-cmd")
assert_eq "LANGFUSE_PUBLIC_KEY,LANGFUSE_SECRET_KEY" "$(setup_cmd check langfuse | jq -r '.missing | join(",")')" "langfuse key commands in the process env are ignored"
[[ ! -e "$SETUP_T/planted" ]] || fail "a key command from the process env ran"
SETUP_ENV=(HM_SETUP_HTTP="$SETUP_T/http.sh")
setup_cmd set --tool claude LANGFUSE_PUBLIC_KEY_CMD 'printf "pk-lf-from-cmd\n"' >/dev/null
setup_cmd set --tool claude LANGFUSE_SECRET_KEY_CMD 'printf sk-lf-from-cmd' >/dev/null
assert_eq "true FromCmd" "$(setup_cmd check langfuse | jq -r '"\(.ok) \(.as)"')" "langfuse check runs the saved key commands"
assert_eq "LANGFUSE_SECRET_KEY_CMD settings" "$(setup_cmd list | jq -r 'select(.name=="langfuse") | .env[1] | "\(.found) \(.source)"')" "a saved key command counts as the key"
setup_cmd set --tool claude LANGFUSE_SECRET_KEY_CMD 'echo "session expired" >&2; exit 254' >/dev/null
LF_CHECK="$(setup_cmd check langfuse)"
assert_eq "false key command failed" "$(jq -r '"\(.ok) \(.error)"' <<<"$LF_CHECK")" "langfuse check reports a failing key command"
assert_contains "$(jq -r '.hint' <<<"$LF_CHECK")" "ssm:GetParameter" "failing key command hint names login and permissions"
if grep -qE "tok|bad-token|pk-lf|sk-lf" "$SETUP_T/argv.log"; then fail "credentials leaked into HTTP call arguments"; fi
if setup_cmd list | grep -q "tok'en"; then fail "list prints a credential"; fi
SETUP_ENV=()
for name in $CATALOG_NAMES; do
  assert_contains "$(<"$ROOT/catalog/$name/SKILL.md")" "/skills/$name.md" "catalog $name reads the user rule file"
  assert_eq "true" "$(jq -r --arg n "$name" '.skills[] | select(.name==$n) | all(.env[] | select(.secret); .issue.url != null)' "$ROOT/catalog/catalog.json")" "catalog $name secrets carry an issue URL"
done
pass "setup stores credentials off the transcript and checks them"

# langfuse 카탈로그 스킬은 scripts/까지 디렉터리째 설치·추적되고, 위험 등급 차단·별칭·키 파일 읽기는 네트워크 없이 확인한다.
SETUP_T="$TEST_TMP/setup-langfuse"
SETUP_CATALOG="$SETUP_T/catalog"
mkdir -p "$SETUP_T"
cp -R "$ROOT/catalog" "$SETUP_CATALOG"
assert_eq "installed installed" "$(setup_cmd install --tool both langfuse | jq -r '.action' | paste -sd' ' -)" "langfuse installs for both tools"
for tool in claude codex; do
  assert_eq "./SKILL.md ./scripts/lf.py ./scripts/register.py" "$(cd "$SETUP_T/$tool/langfuse" && find . -type f | LC_ALL=C sort | paste -sd' ' -)" "langfuse $tool copy carries its scripts"
  assert_eq "current" "$(setup_status langfuse "$tool")" "langfuse $tool copy is current"
done
printf '# local\n' >>"$SETUP_T/codex/langfuse/scripts/lf.py"
assert_eq "modified" "$(setup_status langfuse codex)" "edited script marks the copy modified"
printf '# v2\n' >>"$SETUP_CATALOG/langfuse/scripts/register.py"
assert_eq "outdated" "$(setup_status langfuse claude)" "changed catalog script marks the untouched copy outdated"
assert_eq "updated" "$(setup_cmd update --tool claude | jq -r 'select(.name=="langfuse") | .action')" "untouched copy refreshed with the new script"
assert_contains "$(<"$SETUP_T/claude/langfuse/scripts/register.py")" "# v2" "refreshed copy carries the new script"
assert_contains "$(<"$SETUP_T/codex/langfuse/scripts/lf.py")" "# local" "edited copy kept on refresh"
if grep -rhE '^(import|from) ' "$ROOT/catalog/langfuse/scripts" | grep -vqE '^import (argparse|base64|json|os|re|shutil|subprocess|sys|time|urllib\.(error|parse|request))$'; then
  fail "langfuse scripts use only the standard library"
fi

LF_T="$SETUP_T/lf"
mkdir -p "$LF_T/home/.cache/langfuse-skill" "$LF_T/data"
lf() {
  env -i PATH="$PATH" HOME="$LF_T/home" HARNESS_METRICS_DIR="$LF_T/data" \
    LANGFUSE_PUBLIC_KEY=pk-lf-default LANGFUSE_SECRET_KEY=sk-lf-default LANGFUSE_HOST=http://127.0.0.1:9 \
    LANGFUSE_PUBLIC_KEY_CHECKOUT_BOT=pk-lf-bot LANGFUSE_SECRET_KEY_CHECKOUT_BOT=sk-lf-bot \
    "${LF_ENV[@]+"${LF_ENV[@]}"}" python3 -I "$ROOT/catalog/langfuse/scripts/lf.py" "$@"
}
LF_ENV=()
# 도구 목록 캐시를 미리 둔다 — 호출 전에 차단되므로 127.0.0.1:9로는 요청이 나가지 않는다.
LF_TOOLS='[{"name":"listTraces","annotations":{"readOnlyHint":true}},{"name":"createComment","annotations":{}},{"name":"deleteDataset","annotations":{"destructiveHint":true}}]'
printf '%s' "$LF_TOOLS" >"$LF_T/home/.cache/langfuse-skill/http_127_0_0_1_9.tools.json"
printf '%s' "$LF_TOOLS" >"$LF_T/home/.cache/langfuse-skill/https_bot_example_test.tools.json"
LF_ENV=(LANGFUSE_HOST_CHECKOUT_BOT=https://bot.example.test)
assert_eq "read write destructive" "$(lf -p checkout-bot tools | awk '{print $2}' | paste -sd' ' -)" "tool risk comes from MCP annotations"
LF_ENV=()
set +e
LF_ERR="$(lf call createComment '{}' 2>&1)"; LF_RC=$?
assert_eq "2" "$LF_RC" "write tool without --yes exits 2"
assert_contains "$LF_ERR" "BLOCKED" "write tool is blocked"
LF_ERR="$(lf call deleteDataset '{}' --yes 2>&1)"; LF_RC=$?
assert_eq "2" "$LF_RC" "destructive tool with only --yes exits 2"
assert_contains "$LF_ERR" "--allow-destructive" "destructive block names the flag"
LF_ERR="$(lf rest DELETE /api/public/datasets/x --yes 2>&1)"; LF_RC=$?
assert_eq "2" "$LF_RC" "REST DELETE is blocked"
LF_ERR="$(lf rest POST /api/public/comments 2>&1)"; LF_RC=$?
assert_eq "2" "$LF_RC" "REST write without --yes is blocked"
LF_ERR="$(lf call listTraces '{}' 2>&1)"; LF_RC=$?
assert_eq "1" "$LF_RC" "unreachable host exits 1"
assert_contains "$LF_ERR" "cannot reach http://127.0.0.1:9" "unreachable host is reported without a traceback"
if grep -q "Traceback" <<<"$LF_ERR"; then fail "unreachable host leaks a Python traceback"; fi
LF_ERR="$(lf -p missing-proj tools 2>&1)"; LF_RC=$?
assert_eq "2" "$LF_RC" "unknown alias stops instead of using the default keys"
assert_contains "$LF_ERR" "checkout-bot" "unknown alias lists registered aliases"
set -e
assert_eq "(default) checkout-bot" "$(lf aliases | paste -sd' ' -)" "aliases map env suffixes back to names"
cat >"$LF_T/data/secrets.env" <<'SECRETS'
export LANGFUSE_PUBLIC_KEY_QA='pk-lf-q'\''a'
export LANGFUSE_SECRET_KEY_QA='sk-lf-qa'
SECRETS
mkdir -p "$LF_T/home/.claude"
printf '{"env":{"LANGFUSE_HOST_QA":"https://qa.example.test"}}\n' >"$LF_T/home/.claude/settings.json"
LF_LOOKUP="$(env -i PATH="$PATH" HOME="$LF_T/home" HARNESS_METRICS_DIR="$LF_T/data" python3 -I -B -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("lf", sys.argv[1]); lf = importlib.util.module_from_spec(spec); spec.loader.exec_module(lf)
print(lf.suffix("checkout-bot"), lf.lookup("LANGFUSE_PUBLIC_KEY_QA"), lf.credentials("qa")[0], ",".join(lf.aliases()))
' "$ROOT/catalog/langfuse/scripts/lf.py")"
assert_eq "_CHECKOUT_BOT pk-lf-q'a https://qa.example.test qa" "$LF_LOOKUP" "secrets.env and settings.json keys are read (quote escapes undone)"
[[ ! -e "$ROOT/catalog/langfuse/scripts/__pycache__" ]] || fail "tests leave no bytecode in the catalog (it would ship with installed copies)"

register() { env -i PATH="$PATH" HOME="$LF_T/home" HARNESS_METRICS_DIR="$LF_T/data" python3 -I "$ROOT/catalog/langfuse/scripts/register.py" "$@"; }
for bad in Bad_Alias -lead 'a b' '../x'; do
  set +e
  LF_ERR="$(register "$bad" --stage pk 2>&1)"; LF_RC=$?
  set -e
  assert_eq "1" "$LF_RC" "register rejects alias '$bad'"
  assert_contains "$LF_ERR" "alias:" "register explains the alias rule for '$bad'"
done
[[ ! -e "$LF_T/data/langfuse-staging" ]] || fail "rejected alias leaves no staging directory"
mkdir -p "$LF_T/data/langfuse-staging"
printf 'pk-lf-x' >"$LF_T/data/langfuse-staging/bad-settings.pk"
printf 'sk-lf-x' >"$LF_T/data/langfuse-staging/bad-settings.sk"
printf '[]\n' >"$LF_T/home/.claude/settings.json"
set +e
LF_ERR="$(register bad-settings 2>&1)"; LF_RC=$?
set -e
assert_eq "1" "$LF_RC" "register stops when settings.json is not a JSON object"
assert_contains "$LF_ERR" "not a JSON object" "register names the unusable settings file"
assert_eq "[]" "$(<"$LF_T/home/.claude/settings.json")" "register leaves a non-object settings.json unchanged"
[[ -e "$LF_T/data/langfuse-staging/bad-settings.sk" ]] || fail "register keeps staged keys when it stops before saving"

# 비밀 저장소 명령(_CMD): 사용자 파일의 명령만 실행하고, 같은 별칭의 키 값이 있으면 그것이 먼저다. 실패·형식 오류는 값 없이 멈춘다.
jq -n '{env:{
  LANGFUSE_PUBLIC_KEY_CMD_VAULT:"printf pk-lf-vault", LANGFUSE_SECRET_KEY_CMD_VAULT:"printf \"sk-lf-vault\\n\"",
  LANGFUSE_PUBLIC_KEY_CMD_BROKEN:"printf pk-lf-b", LANGFUSE_SECRET_KEY_CMD_BROKEN:"echo expired-token >&2; exit 3",
  LANGFUSE_PUBLIC_KEY_CMD_NOISY:"printf pk-lf-n", LANGFUSE_SECRET_KEY_CMD_NOISY:"printf leaked-value"}}' >"$LF_T/home/.claude/settings.json"
LF_AUTH="$(env -i PATH="$PATH" HOME="$LF_T/home" HARNESS_METRICS_DIR="$LF_T/data" \
  LANGFUSE_PUBLIC_KEY_CMD_EVIL="touch $LF_T/planted; printf pk-lf-e" LANGFUSE_SECRET_KEY_CMD_EVIL="printf sk-lf-e" \
  python3 -I -B -c '
import base64, importlib.util, os, sys
spec = importlib.util.spec_from_file_location("lf", sys.argv[1]); lf = importlib.util.module_from_spec(spec); spec.loader.exec_module(lf)
user = lambda a: base64.b64decode(lf.credentials(a)[1].split()[1]).decode()
first = user("vault")
os.environ["LANGFUSE_SECRET_KEY_VAULT"] = "sk-lf-direct"
print(first, user("vault"), ",".join(lf.aliases()))
' "$ROOT/catalog/langfuse/scripts/lf.py")"
assert_eq "pk-lf-vault:sk-lf-vault pk-lf-vault:sk-lf-direct broken,noisy,qa,vault" "$LF_AUTH" "key commands from the user files supply keys, stored values win, env commands are not aliases"
set +e
LF_ENV=(LANGFUSE_PUBLIC_KEY_CMD_EVIL="touch $LF_T/planted; printf pk-lf-e" LANGFUSE_SECRET_KEY_CMD_EVIL="printf sk-lf-e")
LF_ERR="$(lf -p evil tools 2>&1)"; LF_RC=$?
LF_ENV=()
assert_eq "2" "$LF_RC" "a key command in the process env is not run"
[[ ! -e "$LF_T/planted" ]] || fail "lf.py ran a key command from the process env"
LF_ERR="$(lf -p broken tools 2>&1)"; LF_RC=$?
assert_eq "1" "$LF_RC" "failing key command exits 1"
assert_contains "$LF_ERR" "LANGFUSE_SECRET_KEY_CMD_BROKEN failed (exit 3): expired-token" "failing key command names itself and shows its stderr"
LF_ERR="$(lf -p noisy tools 2>&1)"; LF_RC=$?
assert_eq "1" "$LF_RC" "key command printing a non-key exits 1"
assert_contains "$LF_ERR" "must print one line starting with sk-lf-" "non-key output is explained"
if grep -q "leaked-value" <<<"$LF_ERR"; then fail "key command output is printed on a format error"; fi
LF_ERR="$(lf -p cmd tools 2>&1)"; LF_RC=$?
assert_eq "2" "$LF_RC" "alias 'cmd' is reserved in lf.py"
for bad in CMD Vault cmd_x; do
  LF_ERR="$(lf -p "$bad" tools 2>&1)"; LF_RC=$?
  assert_eq "2" "$LF_RC" "lf.py rejects alias '$bad' before mapping it to env names"
done
LF_ERR="$(register cmd-x --stage pk 2>&1)"; LF_RC=$?
assert_eq "1" "$LF_RC" "alias 'cmd-*' is reserved in register.py"
set -e

# register.py --pk-cmd/--sk-cmd: 명령으로 키를 받아 리전을 확인하고 명령과 host만 저장한다. 다른 방식의 기존 값은 지운다.
cat >"$LF_T/server.py" <<'PY'
import http.server, os, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        ok = self.path == "/api/public/projects" and self.headers.get("Authorization", "").startswith("Basic ")
        self.send_response(200 if ok else 401)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"data":[{"id":"p","name":"Stub"}]}' if ok else b'{}')
    def log_message(self, *a):
        pass
s = http.server.HTTPServer(("127.0.0.1", 0), H)
with open(sys.argv[1] + ".tmp", "w") as f:
    f.write(str(s.server_address[1]))
os.replace(sys.argv[1] + ".tmp", sys.argv[1])
s.serve_forever()
PY
python3 -I -B "$LF_T/server.py" "$LF_T/port" &
LF_SRV=$!
for _ in $(seq 100); do [[ -s "$LF_T/port" ]] && break; sleep 0.1; done
LF_HOST="http://127.0.0.1:$(<"$LF_T/port")"
regh() { env -i PATH="$PATH" HOME="$LF_T/home" HARNESS_METRICS_DIR="$LF_T/data" LANGFUSE_HOST="$LF_HOST" python3 -I -B "$ROOT/catalog/langfuse/scripts/register.py" "$@"; }
jq -n '{model:"opus", env:{KEEP:"1", LANGFUSE_PUBLIC_KEY_VAULT2:"pk-lf-old", LANGFUSE_SECRET_KEY_VAULT2:"sk-lf-old"}}' >"$LF_T/home/.claude/settings.json"
printf "export LANGFUSE_SECRET_KEY_VAULT2='sk-lf-old'\nexport OTHER='1'\n" >"$LF_T/data/secrets.env"
printf 'pk-lf-stale' >"$LF_T/data/langfuse-staging/vault2.pk"
set +e
LF_ERR="$(regh vault2 --pk-cmd 'printf pk-lf-v2' --sk-cmd 'echo denied >&2; exit 255' 2>&1)"; LF_RC=$?
set -e
assert_eq "1" "$LF_RC" "register stops when a key command fails"
assert_contains "$LF_ERR" "nothing saved" "failed key command saves nothing"
assert_eq "pk-lf-old" "$(jq -r '.env.LANGFUSE_PUBLIC_KEY_VAULT2' "$LF_T/home/.claude/settings.json")" "failed key command leaves settings unchanged"
LF_OUT="$(regh vault2 --pk-cmd 'printf pk-lf-v2' --sk-cmd 'printf sk-lf-v2' 2>&1)"
assert_contains "$LF_OUT" "project=['Stub']" "register checks the keys the commands print"
if grep -qE "pk-lf-v2|sk-lf-v2" <<<"$LF_OUT"; then fail "register prints keys from commands"; fi
assert_eq "printf pk-lf-v2|printf sk-lf-v2|$LF_HOST|null|null|1" \
  "$(jq -r '.env | [.LANGFUSE_PUBLIC_KEY_CMD_VAULT2, .LANGFUSE_SECRET_KEY_CMD_VAULT2, .LANGFUSE_HOST_VAULT2, .LANGFUSE_PUBLIC_KEY_VAULT2, .LANGFUSE_SECRET_KEY_VAULT2, .KEEP] | map(tostring) | join("|")' "$LF_T/home/.claude/settings.json")" \
  "register saves commands and host, drops the stored keys of that alias"
assert_eq "export OTHER='1'|export LANGFUSE_PUBLIC_KEY_CMD_VAULT2='printf pk-lf-v2'|export LANGFUSE_SECRET_KEY_CMD_VAULT2='printf sk-lf-v2'|export LANGFUSE_HOST_VAULT2='$LF_HOST'" \
  "$(paste -sd'|' "$LF_T/data/secrets.env")" "secrets.env gets the commands and loses the stored key"
[[ ! -e "$LF_T/data/langfuse-staging/vault2.pk" ]] || fail "saving commands clears staged keys of that alias"
mkdir -p "$LF_T/nohome"
env -i PATH="$PATH" HOME="$LF_T/nohome" HARNESS_METRICS_DIR="$LF_T/nohome/data" LANGFUSE_HOST="$LF_HOST" \
  python3 -I -B "$ROOT/catalog/langfuse/scripts/register.py" solo --pk-cmd 'printf pk-lf-s' --sk-cmd 'printf sk-lf-s' >/dev/null 2>&1
assert_contains "$(<"$LF_T/nohome/data/secrets.env")" "LANGFUSE_SECRET_KEY_CMD_SOLO='printf sk-lf-s'" "without ~/.claude register creates secrets.env"
assert_eq "600" "$(filemode "$LF_T/nohome/data/secrets.env")" "created secrets.env is private"
printf 'pk-lf-new' >"$LF_T/data/langfuse-staging/vault2.pk"
printf 'sk-lf-new' >"$LF_T/data/langfuse-staging/vault2.sk"
regh vault2 >/dev/null 2>&1
assert_eq "pk-lf-new|null|null" "$(jq -r '.env | [.LANGFUSE_PUBLIC_KEY_VAULT2, .LANGFUSE_PUBLIC_KEY_CMD_VAULT2, .LANGFUSE_SECRET_KEY_CMD_VAULT2] | map(tostring) | join("|")' "$LF_T/home/.claude/settings.json")" "registering keys drops the commands of that alias"
kill "$LF_SRV" 2>/dev/null || true
wait "$LF_SRV" 2>/dev/null || true
pass "langfuse catalog skill installs with scripts and enforces risk classes offline"

# 별칭 키(#621): LANGFUSE_PUBLIC_KEY_<S>·_CMD_<S>만 있어도 list는 키가 있다고 하고 check는 별칭마다 자기 host로 확인한다.
# 별칭 규칙은 lf.py aliases()와 같다 — 사용자 파일(settings·secrets.env)의 _CMD만 인정하고 프로세스 환경의 _CMD는 실행하지 않는다.
SETUP_T="$TEST_TMP/setup-lf-alias"
SETUP_CATALOG="$ROOT/catalog"
mkdir -p "$SETUP_T/data"
cat >"$SETUP_T/http.sh" <<'STUB'
#!/usr/bin/env bash
conf="$(cat)"
printf '%s\n' "$*" >>"${0%/*}/argv.log"
case "$conf" in *bad*) printf 'HTTP 401\n' >&2; exit 1 ;; esac
tag="$(sed -nE 's/.*pk-lf-([a-z0-9]+):.*/\1/p' <<<"$conf" | head -1)"
printf '{"data":[{"id":"p","name":"proj-%s"}]}' "$tag"
STUB
chmod +x "$SETUP_T/http.sh"
SETUP_ENV=(HM_SETUP_HTTP="$SETUP_T/http.sh")
LF_AGENT_HOST="https://agent.example.test"; LF_DEFAULT_HOST="https://us.example.test"
: >"$SETUP_T/argv.log"
lf_settings() { jq -n --argjson e "$1" '{env: $e}' >"$SETUP_T/settings.json"; }
lf_check() { setup_cmd check langfuse | tee -a "$SETUP_T/outputs.log"; }
lf_alias_names() { jq -r '[.projects[]?.alias] | join(",")' <<<"$1"; }
lf_settings "$(jq -n --arg ah "$LF_AGENT_HOST" --arg dh "$LF_DEFAULT_HOST" '{
  LANGFUSE_PUBLIC_KEY_AGENT:"pk-lf-agent", LANGFUSE_SECRET_KEY_AGENT:"sk-lf-agent", LANGFUSE_HOST_AGENT:$ah,
  LANGFUSE_PUBLIC_KEY_TALENT_POOL:"pk-lf-talent", LANGFUSE_SECRET_KEY_TALENT_POOL:"sk-lf-talent", LANGFUSE_HOST:$dh}')"
LF_LIST="$(setup_cmd list | tee -a "$SETUP_T/outputs.log" | jq -c 'select(.name == "langfuse")')"
assert_eq "LANGFUSE_PUBLIC_KEY_AGENT settings" "$(jq -r '.env[0] | "\(.found) \(.source)"' <<<"$LF_LIST")" "list finds the public key through the first alias"
assert_eq "LANGFUSE_SECRET_KEY_AGENT settings" "$(jq -r '.env[1] | "\(.found) \(.source)"' <<<"$LF_LIST")" "list finds the secret key through the first alias"
LF_CHECK="$(lf_check)"
assert_eq "true" "$(jq -r '.ok' <<<"$LF_CHECK")" "langfuse check passes when every alias passes"
assert_eq "agent,talent-pool" "$(lf_alias_names "$LF_CHECK")" "langfuse check reports one project entry per alias"
assert_eq "agent: proj-agent, talent-pool: proj-talent" "$(jq -r '.as' <<<"$LF_CHECK")" "langfuse check joins the alias projects"
assert_eq "true true" "$(jq -r '[.projects[]?.ok] | map(tostring) | join(" ")' <<<"$LF_CHECK")" "every alias entry is ok"
assert_eq "2" "$(wc -l <"$SETUP_T/argv.log" | tr -d ' ')" "langfuse check calls once per alias"
assert_contains "$(<"$SETUP_T/argv.log")" "$LF_AGENT_HOST/api/public/projects" "an alias follows its own LANGFUSE_HOST_<S>"
assert_contains "$(<"$SETUP_T/argv.log")" "$LF_DEFAULT_HOST/api/public/projects" "an alias without its own host follows LANGFUSE_HOST"

# 별칭 쌍이 secrets.env에만 있거나 설정의 _CMD 쌍이어도 인정한다.
: >"$SETUP_T/argv.log"
printf "export LANGFUSE_PUBLIC_KEY_OPS='pk-lf-ops'\nexport LANGFUSE_SECRET_KEY_OPS='sk-lf-ops'\n" >"$SETUP_T/data/secrets.env"
lf_settings '{"LANGFUSE_PUBLIC_KEY_CMD_VAULT":"printf pk-lf-vault","LANGFUSE_SECRET_KEY_CMD_VAULT":"printf sk-lf-vault"}'
LF_LIST="$(setup_cmd list | tee -a "$SETUP_T/outputs.log" | jq -c 'select(.name == "langfuse")')"
assert_eq "LANGFUSE_PUBLIC_KEY_OPS secrets" "$(jq -r '.env[0] | "\(.found) \(.source)"' <<<"$LF_LIST")" "list reads an alias pair from secrets.env"
LF_CHECK="$(lf_check)"
assert_eq "true ops,vault" "$(jq -r '"\(.ok) \([.projects[]?.alias] | join(","))"' <<<"$LF_CHECK")" "secrets.env aliases and saved key command pairs are checked"
assert_eq "ops: proj-ops, vault: proj-vault" "$(jq -r '.as' <<<"$LF_CHECK")" "key commands of an alias resolve to the key value"

# 프로세스 환경의 _CMD는 별칭이 아니고 실행하지 않는다(설정 파일에 쓴 명령만 신뢰한다).
: >"$SETUP_T/argv.log"; rm -f "$SETUP_T/planted"; : >"$SETUP_T/data/secrets.env"
lf_settings '{"LANGFUSE_PUBLIC_KEY_AGENT":"pk-lf-agent","LANGFUSE_SECRET_KEY_AGENT":"sk-lf-agent"}'
SETUP_ENV=(HM_SETUP_HTTP="$SETUP_T/http.sh" LANGFUSE_PUBLIC_KEY_CMD_EVIL="touch $SETUP_T/planted; printf pk-lf-evil" LANGFUSE_SECRET_KEY_CMD_EVIL="printf sk-lf-evil")
LF_CHECK="$(lf_check)"
assert_eq "agent" "$(lf_alias_names "$LF_CHECK")" "an alias command in the process env is not an alias"
assert_not_file "$SETUP_T/planted" "an alias command in the process env is never executed"
SETUP_ENV=(HM_SETUP_HTTP="$SETUP_T/http.sh")

# 별칭 하나만 키가 틀리면 전체는 실패하되 그 별칭만 원인을 달고, 나머지는 통과한다.
lf_settings "$(jq -n --arg ah "$LF_AGENT_HOST" '{
  LANGFUSE_PUBLIC_KEY_AGENT:"pk-lf-agent", LANGFUSE_SECRET_KEY_AGENT:"sk-lf-bad", LANGFUSE_HOST_AGENT:$ah,
  LANGFUSE_PUBLIC_KEY_TALENT_POOL:"pk-lf-talent", LANGFUSE_SECRET_KEY_TALENT_POOL:"sk-lf-talent"}')"
LF_CHECK="$(lf_check)"
assert_eq "false" "$(jq -r '.ok' <<<"$LF_CHECK")" "one failing alias fails the check"
assert_contains "$(jq -r '.error' <<<"$LF_CHECK")" "agent" "the error names the failing alias"
assert_eq "false true" "$(jq -r '[.projects[]?.ok] | map(tostring) | join(" ")' <<<"$LF_CHECK")" "only the failing alias is not ok"
LF_HINT="$(jq -r '.projects[]? | select(.alias == "agent") | .hint' <<<"$LF_CHECK")"
assert_contains "$LF_HINT" "LANGFUSE_HOST_AGENT" "the alias 401 hint points at its host key"
assert_contains "$LF_HINT" "register.py agent" "the alias 401 hint points at register.py"
assert_contains "$(jq -r '.projects[]? | select(.alias == "talent-pool") | .as' <<<"$LF_CHECK")" "proj-talent" "the other alias still reports its project"

# 공개 키만 있는 별칭은 비밀 키 이름을 대며 실패하고, 짝이 있는 별칭이 list의 found가 된다.
lf_settings '{"LANGFUSE_PUBLIC_KEY_AGENT":"pk-lf-agent","LANGFUSE_PUBLIC_KEY_TALENT_POOL":"pk-lf-talent","LANGFUSE_SECRET_KEY_TALENT_POOL":"sk-lf-talent"}'
LF_LIST="$(setup_cmd list | tee -a "$SETUP_T/outputs.log" | jq -c 'select(.name == "langfuse")')"
assert_eq "LANGFUSE_PUBLIC_KEY_TALENT_POOL" "$(jq -r '.env[0].found' <<<"$LF_LIST")" "list skips an alias that lacks its secret key"
LF_CHECK="$(lf_check)"
assert_eq "false" "$(jq -r '.ok' <<<"$LF_CHECK")" "an alias with only a public key fails the check"
assert_contains "$(jq -r '.error' <<<"$LF_CHECK")" "missing LANGFUSE_SECRET_KEY_AGENT" "the error names the missing secret key"
assert_eq "false" "$(jq -r '.projects[]? | select(.alias == "agent") | .ok' <<<"$LF_CHECK")" "the incomplete alias entry is not ok"

# 기본 키와 별칭이 함께 있으면 둘 다 확인한다.
: >"$SETUP_T/argv.log"
lf_settings '{"LANGFUSE_PUBLIC_KEY":"pk-lf-main","LANGFUSE_SECRET_KEY":"sk-lf-main","LANGFUSE_PUBLIC_KEY_AGENT":"pk-lf-agent","LANGFUSE_SECRET_KEY_AGENT":"sk-lf-agent","LANGFUSE_HOST_AGENT":"https://agent.example.test"}'
LF_CHECK="$(lf_check)"
assert_eq "true agent,default" "$(jq -r '"\(.ok) \([.projects[]?.alias] | sort | join(","))"' <<<"$LF_CHECK")" "the default key and an alias are both checked"
assert_eq "2" "$(wc -l <"$SETUP_T/argv.log" | tr -d ' ')" "one call per key pair when the default and an alias coexist"
assert_contains "$(jq -r '.as' <<<"$LF_CHECK")" "default: proj-main" "the default alias is named default in the summary"

# 키 값은 호출 인자·check·list 출력 어디에도 남지 않는다. (카탈로그 안내문의 `pk-lf-…` 자리표시자는 값이 아니므로 접두사 뒤 영숫자가 있을 때만 값으로 본다.)
if grep -qE '[ps]k-lf-[a-z0-9]' "$SETUP_T/argv.log" "$SETUP_T/outputs.log"; then fail "alias key values leaked into argv or output"; fi
pass "langfuse alias keys: list finds them, check verifies each alias with its own host, keys stay out of argv and output (#621)"

finish_tests
