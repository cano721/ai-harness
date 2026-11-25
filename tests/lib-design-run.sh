#!/usr/bin/env bash
# 디자인 영역 중 랜딩 그래프 러너(landing-run.sh)를 스텁 측정·캡처로 돌리는 영역(tests/design-landing-*.sh)이 source하는 공용 준비: 스텁, lp 함수, 미리보기 훅.
# tests/lib.sh·tests/lib-design.sh 다음에 source한다. 영역 파일이 LP_W를 정한다. 단독 실행하지 않는다.
# shellcheck disable=SC2034  # 여기서 정한 값은 영역 파일이 쓴다
cat >"$TEST_TMP/lp-measure-stub.sh" <<'EOF'
#!/usr/bin/env bash
while [[ $# -gt 0 ]]; do case "$1" in --out) o="$2"; shift 2 ;; *) shift ;; esac; done
r="$(cat "${LP_STUB_RESULT_FILE}")"
printf '{"result":"%s","checks":[{"id":"overflow","status":"%s"}]}\n' "$r" "$r" >"$o"
EOF
chmod +x "$TEST_TMP/lp-measure-stub.sh"
cat >"$TEST_TMP/lp-capture-stub.sh" <<'EOF'
#!/usr/bin/env bash
while [[ $# -gt 0 ]]; do case "$1" in --out) o="$2"; shift 2 ;; *) shift ;; esac; done
mkdir -p "$o"; printf '{"result":"done"}\n' >"$o/captures.json"
EOF
chmod +x "$TEST_TMP/lp-capture-stub.sh"
export LANDING_MEASURE_CMD="$TEST_TMP/lp-measure-stub.sh" LP_STUB_RESULT_FILE="$TEST_TMP/lp-stub-result" LANDING_CAPTURE_CMD="$TEST_TMP/lp-capture-stub.sh"
lp() { "$ROOT/scripts/landing-run.sh" "$@" --work "$LP_W" 2>"$TEST_TMP/lp.err"; }
lp_rc() { local rc=0; lp "$@" >/dev/null || rc=$?; printf '%s' "$rc"; }
lp_review() { # fail_check needs_input [candidate] → review json path
  jq -n --argjson req "$(lp next --candidate "${3:-a}" | jq '.required_checks')" --arg f "$1" --argjson ni "$2" \
    '{rendered: true, checks: [$req[] | {check: ., status: (if . == $f then "fail" else "pass" end), severity: "major", first_viewport: false}], needs_input: [range($ni) | "cta"]}' >"$TEST_TMP/lp-review.json"
  printf '%s' "$TEST_TMP/lp-review.json"
}
cat >"$TEST_TMP/lp-preview-hook.sh" <<HOOK
#!/usr/bin/env bash
printf '%s\n' "\$1" >>"$TEST_TMP/lp-previews.log"
HOOK
chmod +x "$TEST_TMP/lp-preview-hook.sh"
