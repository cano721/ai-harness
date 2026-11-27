#!/usr/bin/env bash
# 회귀 테스트 — ga 카탈로그 스킬(catalog/ga): 설치, 키 파일 가져오기(set), 연결 확인(check) 분기, ga.py 설정 읽기·필터·정렬 (#639)
# 네트워크를 쓰지 않는다: check는 HM_SETUP_GA 대체 명령으로, ga.py는 --dry-run·함수 호출로 확인한다.
# 실행: bash tests/run.sh setup-ga
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-setup.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-setup.sh"

GA_PY="$ROOT/catalog/ga/scripts/ga.py"
SETUP_T="$TEST_TMP/setup-ga"
SETUP_CATALOG="$ROOT/catalog"
mkdir -p "$SETUP_T"
printf '{"env":{"KEEP":"1"}}\n' >"$SETUP_T/settings.json"
# 가짜 서비스 계정 키: 형식만 맞고 서명할 수 없는 값. 내용이 출력에 나오면 안 되는 표식(PRIVATE-MARKER)을 넣는다.
GA_KEY_SRC="$SETUP_T/downloads/demo-key.json"
mkdir -p "$SETUP_T/downloads"
jq -n '{type:"service_account", project_id:"demo-proj", client_email:"bot@demo-proj.iam.gserviceaccount.com",
  private_key:"-----BEGIN PRIVATE KEY-----\nPRIVATE-MARKER\n-----END PRIVATE KEY-----\n", token_uri:"https://oauth2.example.test/token"}' >"$GA_KEY_SRC"
chmod 644 "$GA_KEY_SRC"
cat >"$SETUP_T/ga.sh" <<'STUB'
#!/usr/bin/env bash
# setup.sh check ga가 부르는 ga.py check --json 대역. ga-reply.json 내용을 그대로 낸다.
printf '%s %s\n' "$*" "$HARNESS_CLAUDE_SETTINGS" >>"${0%/*}/ga-argv.log"
cat "${0%/*}/ga-reply.json"
STUB
chmod +x "$SETUP_T/ga.sh"
ga_reply() { printf '%s\n' "$1" >"$SETUP_T/ga-reply.json"; }
SETUP_ENV=(HM_SETUP_GA="$SETUP_T/ga.sh")

# 설치: 스크립트까지 디렉터리째, 표준 라이브러리만.
assert_eq "installed installed" "$(setup_cmd install --tool both ga | jq -r '.action' | paste -sd' ' -)" "ga installs for both tools"
for tool in claude codex; do
  assert_eq "./SKILL.md ./scripts/ga.py" "$(cd "$SETUP_T/$tool/ga" && find . -type f | LC_ALL=C sort | paste -sd' ' -)" "ga $tool copy carries its script"
done
if grep -hE '^(import|from) ' "$GA_PY" | tr ',' '\n' | sed -E 's/^(import|from) //; s/^ +//; s/ .*//' \
  | grep -vqE '^(argparse|base64|json|os|re|stat|subprocess|sys|tempfile|time|urllib\.(error|parse|request))$'; then
  fail "ga.py uses only the standard library"
fi

# check: 필수 키가 없으면 둘 다 이름을 댄다.
assert_eq "GA_KEY_FILE,GA_PROPERTY_ID" "$(setup_cmd check ga | jq -r '.missing | join(",")')" "ga check names both missing keys"

# set GA_KEY_FILE: 서비스 계정 키가 아니면 거부, 맞으면 data/keys/ga.json(0600)으로 복사하고 그 경로를 저장한다. 원본은 지우지 않는다.
printf '{"type":"authorized_user"}\n' >"$SETUP_T/downloads/not-sa.json"
set +e
GA_OUT="$(setup_cmd set --tool claude GA_KEY_FILE "$SETUP_T/downloads/not-sa.json" 2>&1)"; GA_RC=$?
set -e
assert_eq "1" "$GA_RC" "a non service-account JSON is refused"
assert_contains "$GA_OUT" "not a service account" "the refusal names the reason"
[[ ! -e "$SETUP_T/data/keys/ga.json" ]] || fail "a refused key file is not copied"
GA_OUT="$(setup_cmd set --tool both GA_KEY_FILE "$GA_KEY_SRC")"
GA_DEST="$SETUP_T/data/keys/ga.json"
assert_eq "$GA_DEST $GA_KEY_SRC true" "$(jq -r 'select(.imported) | "\(.imported) \(.original) \(.remove_original)"' <<<"$GA_OUT")" "set reports the imported copy and the original to remove"
assert_eq "600" "$(filemode "$GA_DEST")" "the imported key file is private"
assert_eq "700" "$(filemode "$SETUP_T/data/keys")" "the keys directory is private"
cmp -s "$GA_KEY_SRC" "$GA_DEST" || fail "the imported key file is a byte copy"
[[ -f "$GA_KEY_SRC" ]] || fail "the original key file is left for the user to remove"
assert_eq "$GA_DEST" "$(jq -r '.env.GA_KEY_FILE' "$SETUP_T/settings.json")" "settings.json stores the imported path, not the download path"
assert_contains "$(<"$SETUP_T/data/secrets.env")" "export GA_KEY_FILE='$GA_DEST'" "secrets.env stores the imported path for Codex"
if grep -q "PRIVATE-MARKER" <<<"$GA_OUT$(setup_cmd list)"; then fail "set or list prints key file content"; fi
assert_eq "settings" "$(setup_cmd list | jq -r 'select(.name=="ga") | .env[0].source')" "the saved key file path is found without restart"
# 저장된 그 파일을 다시 넣으면(~/·상대 경로) 복사하지 않고 원본 삭제도 안내하지 않는다 — 하나뿐인 키를 지우게 하지 않는다.
GA_TILDE_PATH="$(printf '%s/data/keys/ga.json' '~')"  # ~를 펼치지 않고 setup에 그대로 넘긴다
GA_OUT="$(HOME="$SETUP_T" setup_cmd set --tool claude GA_KEY_FILE "$GA_TILDE_PATH")"
assert_eq "0 $GA_DEST" "$(grep -c remove_original <<<"$GA_OUT") $(jq -r '.env.GA_KEY_FILE' "$SETUP_T/settings.json")" "re-entering the stored key file via ~/ is not offered for removal"
GA_OUT="$(cd "$SETUP_T/data" && setup_cmd set --tool claude GA_KEY_FILE keys/ga.json)"
assert_eq "0" "$(grep -c remove_original <<<"$GA_OUT" || true)" "re-entering the stored key file via a relative path is not offered for removal"
# 틀린 --tool은 복사 전에 멈추고, 복사가 실패하면 원본 삭제를 안내하지 않고 실패한다.
rm -f "$GA_DEST"
if setup_cmd set --tool nope GA_KEY_FILE "$GA_KEY_SRC" >/dev/null 2>&1; then fail "an unknown tool is refused"; fi
[[ ! -e "$GA_DEST" ]] || fail "an unknown tool copies nothing"
chmod 500 "$SETUP_T/data/keys"
set +e
GA_OUT="$(setup_cmd set --tool claude GA_KEY_FILE "$GA_KEY_SRC" 2>&1)"; GA_RC=$?
set -e
chmod 700 "$SETUP_T/data/keys"
assert_eq "1 0" "$GA_RC $(grep -c remove_original <<<"$GA_OUT" || true)" "a failed copy exits 1 without offering to remove the original"
assert_contains "$GA_OUT" "original kept" "a failed copy says the original is kept"
setup_cmd set --tool claude GA_KEY_FILE "$GA_KEY_SRC" >/dev/null

# 속성 ID와 별칭 속성(GA_PROPERTY_<별칭>)은 비밀이 아니라 인자로 받는다. 소문자 별칭 이름은 거부한다.
setup_cmd set --tool claude GA_PROPERTY_ID 123456789 >/dev/null
setup_cmd set --tool claude GA_PROPERTY_CHECKOUT_WEB 987654321 >/dev/null
assert_eq "987654321" "$(jq -r '.env.GA_PROPERTY_CHECKOUT_WEB' "$SETUP_T/settings.json")" "an alias property is saved"
if setup_cmd set --tool claude GA_PROPERTY_bad 1 >/dev/null 2>&1; then fail "a lowercase env name is refused"; fi

# check 분기: 성공은 서비스 계정 이메일과 속성, 실패는 원인별 hint.
ga_reply '{"ok":true,"property":"123456789","as":"bot@demo-proj.iam.gserviceaccount.com","dimensions":3,"metrics":2}'
GA_CHECK="$(setup_cmd check ga)"
assert_eq "true bot@demo-proj.iam.gserviceaccount.com (property 123456789)" "$(jq -r '"\(.ok) \(.as)"' <<<"$GA_CHECK")" "ga check shows the service account and property"
assert_contains "$(tail -1 "$SETUP_T/ga-argv.log")" "check --json $SETUP_T/settings.json" "ga check reads the same settings file as setup"
ga_reply '{"ok":false,"error":"HTTP 403","reason":"PERMISSION_DENIED"}'
GA_CHECK="$(setup_cmd check ga)"
assert_eq "false HTTP 403 PERMISSION_DENIED" "$(jq -r '"\(.ok) \(.error)"' <<<"$GA_CHECK")" "ga check reports a denied property"
assert_contains "$(jq -r '.hint' <<<"$GA_CHECK")" "뷰어" "403 points at adding the service account as a viewer"
ga_reply '{"ok":false,"error":"HTTP 403","reason":"SERVICE_DISABLED"}'
assert_contains "$(setup_cmd check ga | jq -r '.hint')" "Google Analytics Data API" "SERVICE_DISABLED points at enabling the Data API"
ga_reply '{"ok":false,"error":"token request failed","reason":"invalid_grant"}'
assert_contains "$(setup_cmd check ga | jq -r '.hint')" "새 JSON 키" "a rejected token request points at a new key"
ga_reply 'not json'
assert_eq "false ga.py failed" "$(setup_cmd check ga | jq -r '"\(.ok) \(.error)"')" "unreadable ga.py output is a failure"
chmod 644 "$GA_DEST"
: >"$SETUP_T/ga-argv.log"
assert_eq "false key file permissions" "$(setup_cmd check ga | jq -r '"\(.ok) \(.error)"')" "a key file readable by others fails before any call"
assert_eq "0" "$(wc -l <"$SETUP_T/ga-argv.log" | tr -d ' ')" "ga.py is not run when the key file is too open"
chmod 600 "$GA_DEST"
jq --arg p "$SETUP_T/gone.json" '.env.GA_KEY_FILE = $p' "$SETUP_T/settings.json" >"$SETUP_T/s.tmp" && mv "$SETUP_T/s.tmp" "$SETUP_T/settings.json"
assert_eq "false key file not found" "$(setup_cmd check ga | jq -r '"\(.ok) \(.error)"')" "a missing key file is reported"
# 대역 없이 실제 ga.py: 가짜 키는 서명 단계에서 멈추고(네트워크 전), 오류만 낸다.
jq --arg p "$GA_DEST" '.env.GA_KEY_FILE = $p' "$SETUP_T/settings.json" >"$SETUP_T/s.tmp" && mv "$SETUP_T/s.tmp" "$SETUP_T/settings.json"
SETUP_ENV=()
GA_CHECK="$(setup_cmd check ga)"
assert_eq "false openssl failed" "$(jq -r '"\(.ok) \(.error)"' <<<"$GA_CHECK")" "the real ga.py stops at signing with a fake key"
if grep -q "PRIVATE-MARKER" <<<"$GA_CHECK"; then fail "check prints key file content"; fi
pass "setup ga: install, key file import (0600, original kept), check branches with hints (#639)"

# ga.py: 설정 읽기 순서(env → settings.json → secrets.env), 별칭, 속성 ID 검사, 키 파일 권한, 필터·정렬, 오류 원인 분류.
GA_T="$SETUP_T/py"
mkdir -p "$GA_T/home/.claude" "$GA_T/data"
ga() { env -i PATH="$PATH" HOME="$GA_T/home" HARNESS_METRICS_DIR="$GA_T/data" "${GA_ENV[@]+"${GA_ENV[@]}"}" python3 -I -B "$GA_PY" "$@"; }
GA_ENV=()
cat >"$GA_T/data/secrets.env" <<'SECRETS'
export GA_PROPERTY_ID='111'
export GA_PROPERTY_APP='333'
export GA_PROPERTY_WEB='444'
SECRETS
printf '{"env":{"GA_PROPERTY_ID":"222","GA_PROPERTY_MEASURE":"G-ABC123"}}\n' >"$GA_T/home/.claude/settings.json"
assert_eq "(default) 222|app 333|measure G-ABC123|web 444" "$(ga aliases 2>/dev/null | tr '\t' ' ' | paste -sd'|' -)" "settings.json wins over secrets.env and aliases map back to names"
GA_ENV=(GA_PROPERTY_ID=999)
assert_eq "(default) 999" "$(ga aliases 2>/dev/null | head -1 | tr '\t' ' ')" "the process env wins over the user files"
GA_ENV=()
set +e
GA_ERR="$(ga report --prop missing --dry-run 2>&1)"; GA_RC=$?
assert_eq "1" "$GA_RC" "an unknown alias stops"
assert_contains "$GA_ERR" "Registered: (default), app, measure, web" "an unknown alias lists the registered ones instead of using the default"
GA_ERR="$(ga report --prop measure --dry-run 2>&1)"
assert_contains "$GA_ERR" "numeric property ID" "a G- measurement ID is refused"
GA_ERR="$(ga report --prop Bad_Alias --dry-run 2>&1)"
assert_contains "$GA_ERR" "alias:" "an invalid alias is refused"
set -e

# --order -<metric>: argparse가 옵션으로 오인하지 않고 내림차순이 된다(--order=-x 형식도 같다).
GA_BODY="$(ga report --dry-run --metrics eventCount,activeUsers --dims eventName --order -eventCount)"
assert_eq "eventCount true" "$(jq -r '.orderBys[0] | "\(.metric.metricName) \(.desc)"' <<<"$GA_BODY")" "--order -metric sorts descending"
assert_eq "eventName false" "$(ga report --dry-run --dims eventName --order=eventName | jq -r '.orderBys[0] | "\(.dimension.dimensionName) \(.desc)"')" "--order dimension sorts ascending"
assert_eq "activeUsers true" "$(ga realtime --dry-run --order -activeUsers | jq -r '.orderBys[0] | "\(.metric.metricName) \(.desc)"')" "realtime takes --order -metric too"
assert_eq "date" "$(ga report --dry-run --dims date | jq -r '.orderBys[0].dimension.dimensionName')" "a date dimension is ordered by date by default"
assert_eq "2026-11-01 today" "$(ga report --dry-run --start 2026-11-01 | jq -r '.dateRanges[0] | "\(.startDate) \(.endDate)"')" "--start without --end runs to today"
assert_eq "30daysAgo" "$(ga report --dry-run --days 30 | jq -r '.dateRanges[0].startDate')" "--days sets the range"
assert_eq "x true" "$(ga report --dry-run --dims x --order -x | jq -r '.orderBys[0] | "\(.dimension.dimensionName) \(.desc)"')" "--order -name on a dimension sorts it descending"
if ga report --dry-run --order --json >/dev/null 2>&1; then fail "--order without a value does not swallow the next option"; fi
set +e
GA_ERR="$(ga report --dry-run --end 2026-11-20 2>&1)"; GA_RC=$?
set -e
assert_eq "1" "$GA_RC" "--end without --start stops instead of silently using --days"
assert_contains "$GA_ERR" "--end needs --start" "the --end error says why"

# 필터: == != =~ ^=, 쉼표는 AND, 값 안의 연산자는 값으로 둔다.
GA_F="$(ga report --dry-run --filter 'eventName==sign_up' | jq -c '.dimensionFilter')"
assert_eq '{"filter":{"fieldName":"eventName","stringFilter":{"matchType":"EXACT","value":"sign_up"}}}' "$GA_F" "== is an exact match"
GA_F="$(ga report --dry-run --filter 'pagePath=~/a==b, platform^=Android,country!=Japan' | jq -c '[.dimensionFilter.andGroup.expressions[] | if .notExpression then "NOT " + .notExpression.filter.fieldName + " " + .notExpression.filter.stringFilter.matchType + " " + .notExpression.filter.stringFilter.value else .filter.fieldName + " " + .filter.stringFilter.matchType + " " + .filter.stringFilter.value end]')"
assert_eq '["pagePath CONTAINS /a==b","platform BEGINS_WITH Android","NOT country EXACT Japan"]' "$GA_F" "=~ ^= != and AND groups parse, the first operator splits"
set +e
GA_ERR="$(ga report --dry-run --filter 'eventName' 2>&1)"; GA_RC=$?
set -e
assert_eq "1" "$GA_RC" "a filter without an operator fails"
assert_contains "$GA_ERR" "op == != =~ ^=" "the filter error lists the operators"

# 키 파일: 없음·권한·형식은 네트워크 전에 멈추고, check --json은 한 줄 JSON으로 원인을 낸다. 내용은 출력하지 않는다.
assert_eq "false missing GA_KEY_FILE" "$(ga check --json | jq -r '"\(.ok) \(.error)"' || true)" "check --json reports a missing key setting"
cp "$GA_KEY_SRC" "$GA_T/key.json"
chmod 640 "$GA_T/key.json"
GA_ENV=(GA_KEY_FILE="$GA_T/key.json")
assert_eq "false key file permissions" "$(ga check --json | jq -r '"\(.ok) \(.error)"' || true)" "ga.py refuses a key file readable by others"
chmod 600 "$GA_T/key.json"
GA_CHECK="$(ga check --json || true)"
assert_eq "false openssl failed" "$(jq -r '"\(.ok) \(.error)"' <<<"$GA_CHECK")" "a fake private key fails at signing, before any request"
if grep -q "PRIVATE-MARKER" <<<"$GA_CHECK"; then fail "ga.py prints key file content"; fi
printf '{"type":"service_account"}' >"$GA_T/bad.json"
chmod 600 "$GA_T/bad.json"
GA_ENV=(GA_KEY_FILE="$GA_T/bad.json")
assert_eq "false bad key file" "$(ga check --json | jq -r '"\(.ok) \(.error)"' || true)" "a key file without the service account fields is refused"
GA_ENV=()

GA_REASONS="$(env -i PATH="$PATH" HOME="$GA_T/home" HARNESS_METRICS_DIR="$GA_T/data" python3 -I -B -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("ga", sys.argv[1]); ga = importlib.util.module_from_spec(spec); spec.loader.exec_module(ga)
print(ga.error_reason("{\"error\":{\"code\":403,\"status\":\"PERMISSION_DENIED\",\"details\":[{\"reason\":\"SERVICE_DISABLED\"}]}}"),
      ga.error_reason("{\"error\":{\"code\":403,\"status\":\"PERMISSION_DENIED\",\"message\":\"User does not have sufficient permissions\"}}"),
      ga.error_reason("{\"error\":{\"code\":403,\"message\":\"Google Analytics Data API has not been used in project 1 before or it is disabled.\"}}"),
      ga.error_reason("{\"error\":\"invalid_grant\",\"error_description\":\"Invalid JWT\"}"),
      ga.normalize_argv(["report", "--order", "-x", "--limit", "5"]) == ["report", "--order=-x", "--limit", "5"], sep=" ")
' "$GA_PY")"
assert_eq "SERVICE_DISABLED PERMISSION_DENIED SERVICE_DISABLED invalid_grant True" "$GA_REASONS" "Google error bodies map to one reason word"
[[ ! -e "$ROOT/catalog/ga/scripts/__pycache__" ]] || fail "tests leave no bytecode in the catalog (it would ship with installed copies)"
pass "ga.py: config lookup order, aliases, property ID check, key file guards, filters and --order -metric, error reasons (#639)"

finish_tests
