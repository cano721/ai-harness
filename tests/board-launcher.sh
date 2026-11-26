#!/usr/bin/env bash
# 회귀 테스트 — Harness Board 런처 앱과 창 앱 우선 열기
# 실행: bash tests/run.sh board-launcher
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-board.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-board.sh"

# 보드 런처(#355): 눌러서 여는 macOS 앱. 앱은 고정 경로 shim을 부르고, shim은 실행 시점에 가장 새 플러그인 설치본을 찾는다
# (업데이트로 설치 경로가 바뀌어도 안 깨지게). Finder가 주는 짧은 PATH 대신 install 때의 PATH를 쓴다.
BL_APPS="$BOARD_T/Applications"
BL_HOME="$BOARD_T/launcher-home"
# 앱 만드는 도구(swiftc·osacompile·plutil·codesign)는 OS와 상관없이 가짜를 쓴다. 호출 기록으로 Swift와 AppleScript 대체 경로를 구분한다.
# 진짜 컴파일은 아래 typecheck가 macOS에서 따로 본다.
chmod +x "$ROOT"/tests/fixtures/board-launcher/*
BL_PATH="$ROOT/tests/fixtures/board-launcher:$PATH"
BL_TOOL_LOG="$BOARD_T/launcher-tools.log"
BL_SWIFTC="$ROOT/tests/fixtures/board-launcher/swiftc"
launcher_sh() { PATH="$BL_PATH" BOARD_LAUNCHER_SWIFTC="${BL_SWIFTC_OVERRIDE-$BL_SWIFTC}" BOARD_LAUNCHER_TOOL_LOG="$BL_TOOL_LOG" BOARD_LAUNCHER_DIR="$BL_APPS" BOARD_LAUNCHER_PLATFORM=Darwin board_sh launcher "$@"; }
assert_eq "false" "$(launcher_sh status | jq -r '.installed')" "launcher is not installed by default"
if BOARD_LAUNCHER_PLATFORM=Linux BOARD_LAUNCHER_DIR="$BL_APPS" board_sh launcher install >/dev/null 2>&1; then fail "launcher install refuses outside macOS"; fi
# 같은 이름의 다른 앱(다른 bundle id)은 install·remove 모두 건드리지 않는다.
mkdir -p "$BL_APPS/Harness Board.app/Contents"
printf '<plist><dict><key>CFBundleIdentifier</key><string>com.example.other</string></dict></plist>\n' >"$BL_APPS/Harness Board.app/Contents/Info.plist"
if launcher_sh install >/dev/null 2>&1; then fail "launcher install refuses to replace another app with the same name"; fi
launcher_sh remove >/dev/null
assert_contains "$(<"$BL_APPS/Harness Board.app/Contents/Info.plist")" "com.example.other" "launcher leaves another app with the same name alone"
rm -rf "$BL_APPS/Harness Board.app"
BL_ON="$(launcher_sh install)"
BL_APP="$BL_APPS/Harness Board.app"
BL_SHIM="$BOARD_DATA/board/bin/open-board"
assert_eq "installed|$BL_APP" "$(jq -r '[.action, .app] | join("|")' <<<"$BL_ON")" "launcher install reports the app"
assert_file "$BL_APP/Contents/Info.plist"
# Swift 앱은 WKWebView 창과 앱 수명주기를 직접 관리한다.
assert_contains "$(<"$BL_APP/Contents/Info.plist")" "<string>com.ai-harness.board</string>" "the app keeps the launcher bundle id"
grep -q LSUIElement "$BL_APP/Contents/Info.plist" && fail "the app is not hidden from the Dock"
[[ -x "$BL_APP/Contents/MacOS/harness-board" ]] || fail "the app is a compiled Swift executable"
assert_eq "icns" "$(head -c 4 "$BL_APP/Contents/Resources/applet.icns")" "the app keeps its icon"
assert_contains "$(<"$BL_APP/Contents/Info.plist")" "harness-board" "the app declares its Swift executable"
assert_contains "$(<"$BL_TOOL_LOG")" "swiftc -O -parse-as-library " "launcher builds the single-file @main app as a library"
# 가짜 swiftc는 소스를 보지 않는다 — 진짜 swiftc가 있으면(macOS) 소스가 실제로 컴파일되는지 본다.
if [[ "$(uname -s)" == Darwin ]] && command -v swiftc >/dev/null 2>&1; then
  BL_TC="$(swiftc -parse-as-library -typecheck "$ROOT/scripts/board/BoardLauncher.swift" 2>&1)" || fail "BoardLauncher.swift compiles: $BL_TC"
fi
grep -q "^codesign --force -s - .*/Harness Board.app$" "$BL_TOOL_LOG" || fail "launcher ad-hoc signs the Swift app"
assert_file "$ROOT/scripts/board/BoardLauncher.swift"
assert_contains "$(<"$ROOT/scripts/board/BoardLauncher.swift")" "WKWebView" "the Swift launcher renders the board in WKWebView"
assert_contains "$(<"$ROOT/scripts/board/BoardLauncher.swift")" "--app" "the Swift launcher asks the shim to open without a browser"
assert_contains "$(<"$ROOT/scripts/board/BoardLauncher.swift")" "alive" "the Swift launcher exits when the board stops"
assert_contains "$(<"$ROOT/scripts/board/BoardLauncher.swift")" "stop" "the Swift launcher stops the board on quit"
# 내 일정의 앱 딥링크(#592): 창 앱은 허용 앱 스킴(msteams)을 OS에 넘겨 앱으로 연다. 목록 밖 스킴은 열지 않는다.
BL_OUTSIDE="$(sed -n '/func openOutside(/,/^    }$/p' "$ROOT/scripts/board/BoardLauncher.swift")"
assert_contains "$BL_OUTSIDE" "Self.appLinkSchemes" "openOutside opens the allowed app link schemes"
assert_contains "$(grep -E 'static let appLinkSchemes = ' "$ROOT/scripts/board/BoardLauncher.swift")" '"msteams"' "the window app allows msteams links"
case "$BL_OUTSIDE" in *'"javascript"'*|*'"file"'*|*'"data"'*) fail "openOutside does not open script or file schemes" ;; esac
python3 -I - "$BL_APP/Contents/Resources/applet.icns" <<'ICNS' || fail "the icon holds PNG images up to 512px"
import struct, sys
data = open(sys.argv[1], "rb").read()
assert data[:4] == b"icns" and struct.unpack(">I", data[4:8])[0] == len(data)
pos, kinds = 8, {}
while pos < len(data):
    kind, size = data[pos:pos + 4], struct.unpack(">I", data[pos + 4:pos + 8])[0]
    assert data[pos + 8:pos + 16] == b"\x89PNG\r\n\x1a\n"
    kinds[kind] = struct.unpack(">II", data[pos + 24:pos + 32])
    pos += size
assert kinds[b"ic09"] == (512, 512) and kinds[b"icp4"] == (16, 16), kinds
ICNS
assert_eq "window" "$(launcher_sh status | jq -r '.kind')" "status reports the window app"
# swiftc가 없거나 컴파일에 실패해도 AppleScript 런처 설치는 유지한다. 실패면 이유를 알린다.
launcher_sh remove >/dev/null
BL_ERR="$(BL_SWIFTC_OVERRIDE="$BOARD_T/no-swiftc" launcher_sh install 2>&1 >/dev/null)"
[[ -x "$BL_APP/Contents/MacOS/applet" && ! -e "$BL_APP/Contents/MacOS/harness-board" ]] || fail "launcher falls back to an applet when swiftc is unavailable"
assert_contains "$BL_ERR" "xcode-select --install" "a missing swiftc tells how to get the window app"
assert_eq "applet" "$(launcher_sh status | jq -r '.kind')" "status reports the applet fallback"
assert_file "$BOARD_DATA/board/bin/launcher.applescript"
# swiftc가 다시 생기면 다음 install이 창 앱으로 바꾼다.
assert_eq "installed" "$(launcher_sh install | jq -r '.action')" "launcher install upgrades the applet once swiftc is available"
assert_eq "window" "$(launcher_sh status | jq -r '.kind')" "the upgraded launcher is the window app"
# 이미 쓰던 창 앱은 새로 만들다 실패해도 애플릿으로 낮추지 않는다(빌드 기록이 어긋난 상황을 흉내 낸다).
printf 'stale\n' >"$BL_APP/Contents/Resources/launcher-build"
BL_ERR="$(BOARD_LAUNCHER_SWIFTC_FAIL=1 launcher_sh install 2>&1 >/dev/null)"
[[ -x "$BL_APP/Contents/MacOS/harness-board" && ! -e "$BL_APP/Contents/MacOS/applet" ]] || fail "a failed rebuild keeps the working window app"
assert_contains "$BL_ERR" "그대로 둡니다" "a failed rebuild says the current app was kept"
launcher_sh remove >/dev/null
BL_ERR="$(BOARD_LAUNCHER_SWIFTC_FAIL=1 launcher_sh install 2>&1 >/dev/null)"
[[ -x "$BL_APP/Contents/MacOS/applet" && ! -e "$BL_APP/Contents/MacOS/harness-board" ]] || fail "launcher falls back to an applet when Swift compilation fails"
assert_contains "$BL_ERR" "stub swiftc failure" "a failed Swift build tells why the browser launcher was installed"
# 같은 소스·같은 컴파일러로는 install마다 다시 컴파일하지 않는다.
assert_eq "unchanged" "$(BOARD_LAUNCHER_SWIFTC_FAIL=1 launcher_sh install 2>/dev/null | jq -r '.action')" "a failed Swift build is not retried on every install"
launcher_sh remove >/dev/null
assert_not_file "$BOARD_DATA/board/bin/launcher-swift-failed"
# Command Line Tools가 없는 맥: swiftc 명령은 있어도 xcode-select가 실패하면 쓰지 않는다.
BL_ERR="$(BL_SWIFTC_OVERRIDE="" BOARD_LAUNCHER_NO_CLT=1 launcher_sh install 2>&1 >/dev/null)"
[[ -x "$BL_APP/Contents/MacOS/applet" ]] || fail "a Mac without Command Line Tools gets the applet"
assert_contains "$BL_ERR" "xcode-select --install" "a Mac without Command Line Tools is told how to get the window app"
assert_eq "window" "$(BL_SWIFTC_OVERRIDE="" launcher_sh install >/dev/null && launcher_sh status | jq -r '.kind')" "swiftc found on PATH builds the window app"
launcher_sh remove >/dev/null
launcher_sh install >/dev/null
[[ -x "$BL_SHIM" ]] || fail "launcher shim is executable"
assert_eq "$ROOT" "$(<"$BOARD_DATA/board/bin/plugin-root")" "launcher records the plugin root as a fallback"
assert_eq "true" "$(launcher_sh status | jq -r '.installed')" "launcher status after install"
assert_eq "unchanged" "$(launcher_sh install | jq -r '.action')" "launcher install is idempotent"
[[ -z "$(find "$BL_APPS" "$BOARD_DATA/board/bin" -maxdepth 1 -name '*.new.*' -o -maxdepth 1 -name '*.old.*' -o -maxdepth 1 -name '*.tmp.*')" ]] || fail "launcher install leaves no staging files"
assert_eq "installed" "$(BOARD_IDLE_EXIT=45 launcher_sh install | jq -r '.action')" "launcher install picks up a new BOARD_IDLE_EXIT"
assert_contains "$(<"$BL_SHIM")" 'BOARD_IDLE_EXIT:-45' "the launcher carries BOARD_IDLE_EXIT set at install (Finder does not pass the shell environment)"
launcher_sh install >/dev/null
# shim은 설치본 캐시에서 가장 새 버전을 고르고(10 > 9), 없으면 기록한 경로를 쓴다. 가짜 설치본 board.sh는 받은 인자를 남긴다.
for v in 0.9.0 0.10.0; do
  mkdir -p "$BL_HOME/.claude/plugins/cache/ai-harness/ai-harness/$v/scripts/board"
  printf '#!/bin/bash\necho "%s $*" >>"%s"\n' "$v" "$BOARD_T/launcher-calls" >"$BL_HOME/.claude/plugins/cache/ai-harness/ai-harness/$v/scripts/board/board.sh"
  : # 설치본의 board.sh는 실행 비트가 없다 — shim은 bash로 부른다
done
env -i HOME="$HOME" HM_PLUGIN_SEARCH_HOME="$BL_HOME" HARNESS_METRICS_DIR="$BOARD_DATA" /bin/bash "$BL_SHIM" open --app
assert_eq "0.10.0 open --no-browser" "$(<"$BOARD_T/launcher-calls")" "the Swift launcher opens the newest board without a browser"
# 설치본이 없으면 기록한 경로로 실제 보드를 연다. Finder처럼 PATH가 짧아도 install 때 PATH(jq·python3)를 쓴다.
env -i HOME="$HOME" PATH=/usr/bin:/bin HM_PLUGIN_SEARCH_HOME="$BOARD_T/no-plugins" HARNESS_METRICS_DIR="$BOARD_DATA" \
  BOARD_PORT="$BOARD_PORT_T" BOARD_NO_BROWSER=1 /bin/bash "$BL_SHIM"
assert_eq "true" "$(board_sh status | jq -r '.running')" "the launcher starts the board from the recorded plugin root with a short PATH"
bl_shim() { env -i HOME="$HOME" PATH=/usr/bin:/bin HM_PLUGIN_SEARCH_HOME="$BOARD_T/no-plugins" HARNESS_METRICS_DIR="$BOARD_DATA" BOARD_PORT="$BOARD_PORT_T" /bin/bash "$BL_SHIM" "$@"; }
bl_shim alive || fail "the shim reports a running board as alive (the app stays in the Dock)"
bl_shim stop >/dev/null || fail "the shim stops the board when the app quits"
assert_eq "false" "$(board_sh status | jq -r '.running')" "quitting the app stops the board"
BL_ALIVE=0; bl_shim alive || BL_ALIVE=$?
assert_eq "1" "$BL_ALIVE" "the shim reports a stopped board with 1 (the app then quits itself)"
BL_ALIVE=0; env -i HOME="$HOME" PATH=/usr/bin:/bin HM_PLUGIN_SEARCH_HOME="$BOARD_T/no-plugins" HARNESS_METRICS_DIR="$BOARD_T/no-data" /bin/bash "$BL_SHIM" alive || BL_ALIVE=$?
assert_eq "2" "$BL_ALIVE" "the shim reports a failed check with 2 so the app keeps its Dock icon"
assert_not_file "$BOARD_DATA/board/launcher.log"
# 예전 셸 스크립트 앱(같은 bundle id)은 Swift 앱으로 다시 설치한다.
rm -rf "$BL_APP" && mkdir -p "$BL_APP/Contents/MacOS"
printf '<plist><dict><key>CFBundleIdentifier</key><string>com.ai-harness.board</string><key>LSUIElement</key><true/></dict></plist>\n' >"$BL_APP/Contents/Info.plist"
printf '#!/bin/bash\n' >"$BL_APP/Contents/MacOS/harness-board"
assert_eq "installed" "$(launcher_sh install | jq -r '.action')" "launcher install replaces the v0.77.0 shell app"
[[ -x "$BL_APP/Contents/MacOS/harness-board" && ! -e "$BL_APP/Contents/MacOS/applet" ]] || fail "the replaced launcher is a Swift app"
assert_eq "removed" "$(launcher_sh remove | jq -r '.action')" "launcher remove"
assert_not_file "$BL_APP/Contents/Info.plist"
assert_not_file "$BL_SHIM"
assert_eq "unchanged" "$(launcher_sh remove | jq -r '.action')" "launcher remove is idempotent"
assert_contains "$(<"$ROOT/skills/setup/SKILL.md")" "board.sh launcher install" "setup offers the board launcher"
assert_contains "$(<"$ROOT/skills/board/SKILL.md")" "board.sh launcher" "board skill documents the launcher"
pass "harness board launcher app"

# 보드 열기는 창 앱 우선: macOS에 창 앱(kind=window)이 있으면 브라우저 대신 open -a로 그 창을 띄우거나 앞으로 가져온다.
# 창 앱이 없거나 applet이거나 macOS가 아니면 지금처럼 브라우저로 연다. 진짜 open·xdg-open 대신 받은 인자를 남기는 가짜를 쓴다.
BO_BIN="$BOARD_T/open-bin"
BO_LOG="$BOARD_T/open.log"
BO_XLOG="$BOARD_T/xdg-open.log"
mkdir -p "$BO_BIN"
cat >"$BO_BIN/open" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >>"$BO_LOG"
[[ "\${1:-}" == -a && "\${BO_STUB_FAIL_APP:-0}" == 1 ]] && exit 1
exit 0
EOF
cat >"$BO_BIN/xdg-open" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >>"$BO_XLOG"
exit 0
EOF
chmod +x "$BO_BIN/open" "$BO_BIN/xdg-open"
# board_sh는 BOARD_NO_BROWSER=1을 강제하므로 열기 분기를 보려면 따로 부른다.
board_open_sh() {
  env -u BOARD_NO_BROWSER PATH="$BO_BIN:$BOARD_T/bin:$PATH" ORCA_CLI_COMMAND=orca HARNESS_METRICS_DIR="$BOARD_DATA" \
    HARNESS_CLAUDE_PROJECTS_DIR="$BOARD_T/projects" HARNESS_CLAUDE_SETTINGS="$BOARD_T/settings.json" BOARD_PORT="$BOARD_PORT_T" \
    BOARD_LAUNCHER_DIR="$BL_APPS" BOARD_LAUNCHER_PLATFORM="${BO_PLATFORM:-Darwin}" BOARD_NO_BROWSER="${BO_NO_BROWSER:-0}" \
    BOARD_JIRA_URL= JIRA_BASE_URL= bash "$ROOT/scripts/board/board.sh" "$@"
}
bo_reset() { board_sh stop >/dev/null; : >"$BO_LOG"; : >"$BO_XLOG"; }
# 창 앱을 PATH에 가짜 open이 앞선 상태로 설치한다 — shim이 install 때 PATH를 담으므로 G에서도 가짜가 먼저 잡힌다.
BL_PATH="$BO_BIN:$BL_PATH" launcher_sh install >/dev/null
assert_eq "window" "$(launcher_sh status | jq -r '.kind')" "open: window app installed"
# A1: 서버가 꺼진 상태 → 서버를 띄운 뒤 창 앱만 연다.
bo_reset
BO_OUT="$(board_open_sh open)" || fail "open with the window app exits 0"
assert_eq "1" "$(printf '%s\n' "$BO_OUT" | wc -l | tr -d ' ')" "open prints one JSON line"
assert_eq "false" "$(jq -r '.reused' <<<"$BO_OUT")" "open starts a new server"
assert_eq "-a $BL_APP" "$(<"$BO_LOG")" "open launches the window app instead of the browser"
assert_eq "" "$(<"$BO_XLOG")" "open with the window app does not use xdg-open"
# A2: 서버가 떠 있으면 재사용하고 다시 open -a — 떠 있는 창 앱은 reopen으로 앞으로 온다.
: >"$BO_LOG"
BO_OUT="$(board_open_sh open)" || fail "reopen with the window app exits 0"
assert_eq "true" "$(jq -r '.reused' <<<"$BO_OUT")" "open reuses the running server"
assert_eq "-a $BL_APP" "$(<"$BO_LOG")" "open brings the running window app forward"
# E1·E2: --no-browser·BOARD_NO_BROWSER=1이면 창 앱도 브라우저도 열지 않는다.
bo_reset
BO_OUT="$(board_open_sh open --no-browser)" || fail "open --no-browser exits 0"
assert_contains "$(jq -r '.url' <<<"$BO_OUT")" "http://" "open --no-browser still prints the url"
assert_eq "|" "$(<"$BO_LOG")|$(<"$BO_XLOG")" "open --no-browser opens nothing"
bo_reset
BO_NO_BROWSER=1 board_open_sh open >/dev/null || fail "BOARD_NO_BROWSER=1 open exits 0"
assert_eq "|" "$(<"$BO_LOG")|$(<"$BO_XLOG")" "BOARD_NO_BROWSER=1 opens nothing"
# D: macOS가 아니면 창 앱이 있어도 xdg-open으로 브라우저를 연다.
bo_reset
BO_OUT="$(BO_PLATFORM=Linux board_open_sh open)" || fail "open on Linux exits 0"
assert_eq "$(jq -r '.url' <<<"$BO_OUT")" "$(<"$BO_XLOG")" "open outside macOS uses xdg-open with the url"
assert_eq "" "$(<"$BO_LOG")" "open outside macOS does not call open"
# F: open -a가 실패하면 브라우저로 되돌아간다.
bo_reset
BO_OUT="$(BO_STUB_FAIL_APP=1 board_open_sh open)" || fail "open exits 0 when the window app fails"
assert_eq "-a $BL_APP|$(jq -r '.url' <<<"$BO_OUT")" "$(paste -sd'|' "$BO_LOG")" "a failed window app falls back to the browser"
# G: 창 앱이 부르는 shim open --app은 board.sh open --no-browser라 앱을 다시 띄우지 않는다(재귀 없음).
bo_reset
BO_OUT="$(env -i HOME="$HOME" PATH=/usr/bin:/bin HM_PLUGIN_SEARCH_HOME="$BOARD_T/no-plugins" HARNESS_METRICS_DIR="$BOARD_DATA" \
  BOARD_PORT="$BOARD_PORT_T" BOARD_LAUNCHER_DIR="$BL_APPS" BOARD_LAUNCHER_PLATFORM=Darwin /bin/bash "$BL_SHIM" open --app)" \
  || fail "the shim opens for the window app"
assert_contains "$(printf '%s\n' "$BO_OUT" | tail -n 1 | jq -r '.url')" "http://" "the shim returns the board url to the window app"
assert_eq "|" "$(<"$BO_LOG")|$(<"$BO_XLOG")" "the shim for the window app does not reopen the app or a browser"
# C: applet 런처는 지금처럼 브라우저로 연다.
launcher_sh remove >/dev/null
BL_SWIFTC_OVERRIDE="$BOARD_T/no-swiftc" launcher_sh install >/dev/null 2>&1
assert_eq "applet" "$(launcher_sh status | jq -r '.kind')" "open: applet installed"
bo_reset
BO_OUT="$(board_open_sh open)" || fail "open with the applet exits 0"
assert_eq "$(jq -r '.url' <<<"$BO_OUT")" "$(<"$BO_LOG")" "open with the applet opens the url in the browser"
# B: 창 앱이 없으면 지금처럼 브라우저로 연다.
launcher_sh remove >/dev/null
bo_reset
BO_OUT="$(board_open_sh open)" || fail "open without a launcher exits 0"
assert_eq "$(jq -r '.url' <<<"$BO_OUT")" "$(<"$BO_LOG")" "open without the window app opens the url in the browser"
bo_reset
pass "harness board open prefers the window app"

finish_tests
