#!/usr/bin/env bash
# 회귀 테스트 — landing-browser.mjs launchBrowser의 엔진 인자(#678): 기본 chromium, 고른 엔진만 띄우고 다른 엔진으로 대신하지 않는다.
# 실제 브라우저 없이 $TEST_TMP의 가짜 playwright 모듈을 LANDING_PLAYWRIGHT로 준다.
# 실행: bash tests/run.sh design-landing-browser
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if ! command -v node >/dev/null 2>&1; then
  printf '# skip landing-browser engine checks: no node\n'
  finish_tests
  exit 0
fi

# 가짜 playwright: launch한 엔진을 FAKE_PW_LOG에 적고, FAKE_PW_FAIL과 같은 엔진은 실패한다.
LB_PW="$TEST_TMP/fake-playwright"
mkdir -p "$LB_PW" "$TEST_TMP/lb-home"
printf '{"name":"playwright","main":"index.js"}\n' >"$LB_PW/package.json"
cat >"$LB_PW/index.js" <<'EOF'
const fs = require("fs");
const engine = (name) => ({
  launch: async () => {
    fs.appendFileSync(process.env.FAKE_PW_LOG, name + "\n");
    if ((process.env.FAKE_PW_FAIL || "") === name) throw new Error(name + " executable doesn't exist");
    return { close: async () => {} };
  },
});
module.exports = { chromium: engine("chromium"), webkit: engine("webkit"), firefox: engine("firefox") };
EOF

# lb_launch <playwright 경로> <인자 JSON 또는 none>: 결과 요약 JSON을 찍는다. HOME을 비워 npx 캐시의 실제 playwright를 쓰지 않는다.
lb_launch() {
  : >"$TEST_TMP/lb.log"
  HOME="$TEST_TMP/lb-home" NODE_PATH="" LANDING_PLAYWRIGHT="$1" FAKE_PW_LOG="$TEST_TMP/lb.log" \
    node --input-type=module -e '
      const { launchBrowser } = await import(process.argv[1]);
      const r = process.argv[2] === "none" ? await launchBrowser() : await launchBrowser(JSON.parse(process.argv[2]));
      if (r.browser) await r.browser.close();
      console.log(JSON.stringify({ browser: !!r.browser, engine: r.engine || "", reason: r.reason || "" }));
    ' "$ROOT/scripts/landing-browser.mjs" "$2"
}

# 인자 없이 부르면(기존 호출처) chromium만 띄운다.
LB_OUT="$(lb_launch "$LB_PW" none)"
assert_eq "true:chromium" "$(jq -r '"\(.browser):\(.engine)"' <<<"$LB_OUT")" "no argument launches chromium"
assert_eq "chromium" "$(paste -sd ';' - <"$TEST_TMP/lb.log")" "only chromium is launched"
pass "launchBrowser defaults to chromium"

# 고른 엔진만 띄운다.
LB_OUT="$(lb_launch "$LB_PW" '{"engine":"webkit"}')"
assert_eq "true:webkit" "$(jq -r '"\(.browser):\(.engine)"' <<<"$LB_OUT")" "engine webkit launches webkit"
assert_eq "webkit" "$(paste -sd ';' - <"$TEST_TMP/lb.log")" "only webkit is launched"
pass "launchBrowser launches the requested engine"

# 고른 엔진이 뜨지 않으면 다른 엔진으로 대신하지 않고 이유를 돌려준다.
LB_OUT="$(FAKE_PW_FAIL=webkit lb_launch "$LB_PW" '{"engine":"webkit"}')"
assert_eq "false" "$(jq -r .browser <<<"$LB_OUT")" "a failed webkit returns no browser"
assert_contains "$(jq -r .reason <<<"$LB_OUT")" "WebKit" "the reason names the engine"
assert_eq "webkit" "$(paste -sd ';' - <"$TEST_TMP/lb.log")" "chromium is never tried in place of webkit"
pass "launchBrowser does not fall back to another engine"

# 알 수 없는 엔진은 띄우지 않는다.
LB_OUT="$(lb_launch "$LB_PW" '{"engine":"opera"}')"
assert_eq "false" "$(jq -r .browser <<<"$LB_OUT")" "an unknown engine returns no browser"
assert_contains "$(jq -r .reason <<<"$LB_OUT")" "opera" "the reason names the unknown engine"
assert_eq "" "$(cat "$TEST_TMP/lb.log")" "nothing is launched for an unknown engine"
pass "launchBrowser refuses an unknown engine"

# playwright가 없으면 설치는 사용자 승인 뒤에만 하라고 안내한다.
LB_OUT="$(lb_launch "$TEST_TMP/no-playwright" '{"engine":"webkit"}')"
assert_contains "$(jq -r .reason <<<"$LB_OUT")" "user's approval" "a missing Playwright is installed only with the user's approval"
assert_contains "$(jq -r .reason <<<"$LB_OUT")" "npx playwright install webkit" "the reason gives the engine install command"
pass "launchBrowser asks for approval before installing"

finish_tests
