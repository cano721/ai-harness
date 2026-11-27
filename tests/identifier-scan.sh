#!/usr/bin/env bash
# 회귀 테스트 — 공개 저장소 식별자 검사(scripts/identifier-scan.sh, #687): 금지어 목록 출처(env > config)·건너뜀,
# 대소문자 무시·고정 문자열 부분 일치, `파일:줄`만 출력(금지어·줄 내용 비출력), 경로 인자, 추적 파일·바이너리 제외, CI·기여 문서 연결
# 실행: bash tests/run.sh identifier-scan
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# 호출자 환경의 실제 금지어가 섞이지 않게 비우고, 격리된 데이터 폴더(HARNESS_METRICS_DIR=$TEST_TMP/lib-data)만 쓴다.
unset HM_IDENTIFIER_DENYLIST
mkdir -p "$HARNESS_METRICS_DIR"
rm -f "$HARNESS_METRICS_DIR/config"
SCAN="$ROOT/scripts/identifier-scan.sh"
SCAN_REPO="$TEST_TMP/scan-repo"
make_repo "$SCAN_REPO"
printf 'hello world\nline two uses ACME-CORP naming\nplain\n' >"$SCAN_REPO/doc.md"
printf 'nothing here\nglobex is on the second line? no: third\n' >"$SCAN_REPO/other.txt"
mkdir -p "$SCAN_REPO/sub"
printf 'safe\n' >"$SCAN_REPO/sub/clean.txt"
git -C "$SCAN_REPO" add doc.md other.txt sub/clean.txt
git -C "$SCAN_REPO" commit -q -m files

# 스캔을 저장소 cwd에서 돌리고 출력과 종료 코드를 SCAN_OUT·SCAN_RC에 남긴다(set -e에 걸리지 않게).
scan() {
  SCAN_RC=0
  SCAN_OUT="$(cd "$SCAN_REPO" && bash "$SCAN" "$@" 2>&1)" || SCAN_RC=$?
}

assert_not_contains() { # 문자열 부분 문자열 설명
  case "$1" in *"$2"*) fail "$3 (found unexpected: $2)" ;; esac
}

# 목록이 env에도 config에도 없으면 검사할 것이 없으니 건너뛰고 성공한다.
scan
assert_eq "0" "$SCAN_RC" "no denylist exits 0"
assert_contains "$SCAN_OUT" "건너뜀" "no denylist reports skipping"
pass "no denylist is skipped"

# env 목록(| 구분)에 대문자로 든 토큰도 대소문자 무시로 잡고, 출력은 파일:줄만 담는다.
HM_IDENTIFIER_DENYLIST='acme-corp|globex' scan
assert_eq "1" "$SCAN_RC" "match exits 1"
assert_contains "$SCAN_OUT" "doc.md:2" "output names file:line"
assert_contains "$SCAN_OUT" "other.txt:2" "second token matches in another file"
assert_not_contains "$SCAN_OUT" "line two uses" "output does not echo the line content"
SCAN_LOWER="$(printf '%s' "$SCAN_OUT" | tr '[:upper:]' '[:lower:]')"
assert_not_contains "$SCAN_LOWER" "acme" "output does not print the first denylist token"
assert_not_contains "$SCAN_LOWER" "globex" "output does not print the second denylist token"
pass "env denylist matches case-insensitively and prints only file:line"

# 줄바꿈 구분 목록도 | 구분과 같은 결과를 낸다.
HM_IDENTIFIER_DENYLIST=$'acme-corp\nglobex' scan
assert_eq "1" "$SCAN_RC" "newline-separated list exits 1"
assert_contains "$SCAN_OUT" "doc.md:2" "newline-separated list names file:line"
assert_contains "$SCAN_OUT" "other.txt:2" "newline-separated list matches the second token"
SCAN_LOWER="$(printf '%s' "$SCAN_OUT" | tr '[:upper:]' '[:lower:]')"
assert_not_contains "$SCAN_LOWER" "acme" "newline-separated output hides tokens"
assert_not_contains "$SCAN_LOWER" "globex" "newline-separated output hides the second token"
pass "newline-separated denylist behaves the same"

# env가 비면 격리 config의 같은 키를 읽는다.
printf 'HM_IDENTIFIER_DENYLIST="globex"\n' >"$HARNESS_METRICS_DIR/config"
scan
assert_eq "1" "$SCAN_RC" "config denylist exits 1 on match"
assert_contains "$SCAN_OUT" "other.txt:2" "config denylist names file:line"
pass "config denylist is used when env is empty"

# env와 config가 둘 다 있으면 env가 이긴다: config는 매치 토큰, env는 매치 없는 토큰.
HM_IDENTIFIER_DENYLIST='no-such-token' scan
assert_eq "0" "$SCAN_RC" "env wins over a matching config"
assert_contains "$SCAN_OUT" "통과" "env-over-config run passes"
rm -f "$HARNESS_METRICS_DIR/config"
pass "env denylist wins over config"

# 추적 안 된 파일과 추적된 바이너리(NUL 포함) 안의 토큰은 잡지 않는다.
printf 'untracked acme-corp\n' >"$SCAN_REPO/untracked.txt"
printf 'bin\0acme-corp\0\n' >"$SCAN_REPO/blob.bin"
git -C "$SCAN_REPO" add blob.bin
git -C "$SCAN_REPO" commit -q -m binary
HM_IDENTIFIER_DENYLIST='acme-corp' scan other.txt blob.bin sub
assert_eq "0" "$SCAN_RC" "binary file is skipped"
HM_IDENTIFIER_DENYLIST='acme-corp' scan
assert_eq "1" "$SCAN_RC" "tracked text file still matches"
assert_not_contains "$SCAN_OUT" "untracked.txt" "untracked file is not scanned"
assert_not_contains "$SCAN_OUT" "blob.bin" "tracked binary is not scanned"
pass "untracked files and binaries are ignored"

# 경로 인자를 주면 그 경로(파일·디렉토리)만 검사하고 다른 추적 파일의 토큰은 무시한다.
HM_IDENTIFIER_DENYLIST='acme-corp' scan sub other.txt
assert_eq "0" "$SCAN_RC" "paths without a match pass even if another tracked file matches"
HM_IDENTIFIER_DENYLIST='acme-corp' scan doc.md
assert_eq "1" "$SCAN_RC" "a file path argument is scanned"
assert_contains "$SCAN_OUT" "doc.md:2" "file argument names file:line"
# GNU grep은 -r에 파일 하나만 받으면 파일명을 빼서 `줄:내용`이 새어 나갔다 — 단일 파일에서도 줄 내용·토큰이 없어야 한다.
scan_lower="$(printf '%s' "$SCAN_OUT" | tr '[:upper:]' '[:lower:]')"
assert_not_contains "$scan_lower" "acme" "file argument output hides the token"
assert_not_contains "$scan_lower" "naming" "file argument output hides line content"
assert_not_contains "$SCAN_OUT" "2:line two" "file argument output is not line:content"
# 줄 내용에 `:숫자:`가 있어도 파일명 뒤 첫 줄 번호에서 자른다.
printf 'x\nacme-corp at 10:20:30 sharp\n' >"$SCAN_REPO/colon.txt"
HM_IDENTIFIER_DENYLIST='acme-corp' scan colon.txt
assert_eq "1" "$SCAN_RC" "colon file matches"
assert_contains "$SCAN_OUT" "colon.txt:2" "colon content still names file:line"
assert_not_contains "$SCAN_OUT" "sharp" "colon content is not printed"
assert_not_contains "$SCAN_OUT" ":20" "colon content numbers are not printed"
rm -f "$SCAN_REPO/colon.txt"
pass "path arguments limit the scan"

# 매치가 없으면 통과 문구와 함께 exit 0.
HM_IDENTIFIER_DENYLIST='initech' scan
assert_eq "0" "$SCAN_RC" "no match exits 0"
assert_contains "$SCAN_OUT" "통과" "no match reports passing"
pass "no match passes"

# 저장소 메타: CI가 비밀 변수로 검사를 돌리고, 기존 인라인 정규식 블록이 스크립트를 부르며, 기여 문서가 변수를 설명한다.
assert_contains "$(<"$ROOT/.github/workflows/test.yml")" "scripts/identifier-scan.sh" "CI runs the identifier scan"
assert_contains "$(<"$ROOT/.github/workflows/test.yml")" "secrets.HM_IDENTIFIER_DENYLIST" "CI passes the denylist secret"
for scan_area in setup board-agenda board-autofix design init-frontend-ui; do
  assert_contains "$(<"$ROOT/tests/$scan_area.sh")" "identifier-scan.sh" "tests/$scan_area.sh calls the identifier scan"
done
assert_eq "2" "$(grep -c 'identifier-scan.sh' "$ROOT/tests/design.sh")" "tests/design.sh calls the identifier scan in both blocks"
assert_contains "$(<"$ROOT/CONTRIBUTING.md")" "HM_IDENTIFIER_DENYLIST" "CONTRIBUTING documents the denylist variable"
pass "CI, tests and CONTRIBUTING wire up the identifier scan"

finish_tests
