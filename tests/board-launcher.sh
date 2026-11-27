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

# 창 앱 자동 재빌드(#622): 플러그인을 업데이트해 launcher-build가 지금 swift_stamp와 다르면 보드 열기가 분리 프로세스로
# 창 앱을 다시 만든다. open은 기다리지 않고, 실패 기록·락·런처 종류·플랫폼이 맞지 않으면 아무것도 하지 않는다.
AR_LOG="$BOARD_DATA/board/launcher-rebuild.log"
AR_LOCK="$BOARD_DATA/board/launcher-rebuild.lock"
AR_BUILD="$BL_APP/Contents/Resources/launcher-build"
ar_open() {
  PATH="${AR_PATH:-$BL_PATH}" BOARD_LAUNCHER_SWIFTC="${BL_SWIFTC_OVERRIDE-$BL_SWIFTC}" BOARD_LAUNCHER_TOOL_LOG="$BL_TOOL_LOG" \
    board_open_sh open --no-browser
}
ar_calls() { grep -c '^swiftc ' "$BL_TOOL_LOG" 2>/dev/null || true; }
ar_build() { cat "$AR_BUILD" 2>/dev/null || true; }
ar_stale_window() { # 창 앱의 빌드 기록만 낡게 만든다(창 앱이 아니면 새로 깐다)
  if [[ "$(launcher_sh status | jq -r '.kind')" != window ]]; then
    launcher_sh remove >/dev/null
    launcher_sh install >/dev/null
  fi
  printf 'stale\n' >"$AR_BUILD"
  rm -f "$AR_LOG" "$BOARD_DATA/board/bin/launcher-swift-failed"
}
ar_wait_rebuilt() {
  local _
  for _ in $(seq 1 100); do
    [[ "$(ar_build)" == "v2 swift"* && ! -d "$AR_LOCK" ]] && return 0
    sleep 0.1
  done
  return 1
}
# A1: 낡은 창 앱이면 open은 평소처럼 JSON 한 줄로 끝나고, 뒤에서 창 앱이 다시 만들어진다.
ar_stale_window
AR_BEFORE="$(ar_calls)"
AR_OUT="$(ar_open)" || fail "open with a stale window app exits 0"
assert_eq "1" "$(printf '%s\n' "$AR_OUT" | wc -l | tr -d ' ')" "open with a stale window app prints one JSON line"
assert_eq "true" "$(jq -r '.running' <<<"$AR_OUT")" "open with a stale window app reports the running board"
ar_wait_rebuilt || fail "open rebuilds a stale window app in the background (build=$(ar_build))"
assert_eq "$((AR_BEFORE + 1))" "$(ar_calls)" "the background rebuild compiles the window app once"
assert_file "$AR_LOG"
assert_eq "window" "$(launcher_sh status | jq -r '.kind')" "the rebuilt launcher is still the window app"
# A2·A4: gate가 열릴 때까지 기다리는 swiftc로 open이 재빌드를 기다리지 않음과, 연달아 연 두 번이 한 번만 빌드함을 본다.
AR_GATE="$BOARD_T/swiftc-gate-open"
AR_GATED="$BOARD_T/swiftc-gated"
cat >"$AR_GATED" <<EOF
#!/bin/bash
[[ "\${1:-}" == --version ]] && exec "$BL_SWIFTC" "\$@"
for _ in \$(seq 1 300); do [[ -f "$AR_GATE" ]] && break; sleep 0.1; done
exec "$BL_SWIFTC" "\$@"
EOF
chmod +x "$AR_GATED"
ar_stale_window
rm -f "$AR_GATE"
AR_BEFORE="$(ar_calls)"
BL_SWIFTC_OVERRIDE="$AR_GATED" ar_open >/dev/null || fail "open does not wait for the background rebuild"
assert_eq "stale" "$(ar_build)" "open returns before the rebuild finishes"
BL_SWIFTC_OVERRIDE="$AR_GATED" ar_open >/dev/null || fail "a second open during the rebuild exits 0"
touch "$AR_GATE"
ar_wait_rebuilt || fail "the gated rebuild finishes once the compiler continues"
assert_eq "$((AR_BEFORE + 1))" "$(ar_calls)" "two opens during one rebuild compile only once"
# A3: 같은 소스·같은 컴파일러로 실패한 기록이 있으면 다시 시도하지 않는다(분리 프로세스도 띄우지 않는다).
ar_stale_window
BOARD_LAUNCHER_SWIFTC_FAIL=1 launcher_sh install >/dev/null 2>&1
assert_file "$BOARD_DATA/board/bin/launcher-swift-failed"
AR_BEFORE="$(ar_calls)"
ar_open >/dev/null || fail "open with a recorded Swift failure exits 0"
assert_not_file "$AR_LOG"
assert_eq "$AR_BEFORE|stale" "$(ar_calls)|$(ar_build)" "open does not retry a recorded Swift failure"
# A4: 다른 프로세스가 락을 쥐고 있으면 재빌드하지 않는다. 락이 풀리면 다음 open이 다시 만든다.
ar_stale_window
mkdir -p "$AR_LOCK" && printf '%s\n' "$$" >"$AR_LOCK/pid"
AR_BEFORE="$(ar_calls)"
ar_open >/dev/null || fail "open with a held rebuild lock exits 0"
assert_file "$AR_LOG"
# 분리 프로세스가 락을 못 잡고 끝나는 것은 밖에서 볼 신호가 없다 — 빌드가 일어났다면 이 시간 안에 끝난다(A1 실측 1초 미만).
sleep 1
assert_eq "$AR_BEFORE|stale" "$(ar_calls)|$(ar_build)" "a held lock skips the rebuild"
rm -rf "$AR_LOCK"
ar_open >/dev/null || fail "open after the lock is released exits 0"
ar_wait_rebuilt || fail "open rebuilds once the lock is released"
# A5: 재빌드는 사용자가 설치할 때 담은 shim(PATH·BOARD_IDLE_EXIT)을 이 셸 값으로 덮어쓰지 않는다.
ar_stale_window
cp "$BL_SHIM" "$BOARD_T/shim-before"
cp "$BOARD_DATA/board/bin/launcher.applescript" "$BOARD_T/applescript-before"
mkdir -p "$BOARD_T/other-path"
AR_PATH="$BOARD_T/other-path:$BL_PATH" BOARD_IDLE_EXIT=77 ar_open >/dev/null || fail "open from another shell exits 0"
ar_wait_rebuilt || fail "open from another shell rebuilds the window app"
cmp -s "$BOARD_T/shim-before" "$BL_SHIM" || fail "the background rebuild keeps the installed shim"
cmp -s "$BOARD_T/applescript-before" "$BOARD_DATA/board/bin/launcher.applescript" || fail "the background rebuild keeps the AppleScript source"
# A6: 런처 없음·애플릿·남의 앱·swiftc 없음·macOS 아님·이미 최신이면 아무것도 하지 않는다.
ar_untouched() { # 설명
  local before
  before="$(ar_calls)"
  ar_open >/dev/null || fail "open exits 0: $1"
  assert_not_file "$AR_LOG"
  assert_eq "$before" "$(ar_calls)" "open does not rebuild: $1"
}
launcher_sh remove >/dev/null
rm -f "$AR_LOG"
ar_untouched "no launcher"
assert_not_file "$BL_APP/Contents/Info.plist"
BL_SWIFTC_OVERRIDE="$BOARD_T/no-swiftc" launcher_sh install >/dev/null 2>&1
ar_untouched "applet"
[[ -x "$BL_APP/Contents/MacOS/applet" && ! -e "$BL_APP/Contents/MacOS/harness-board" ]] || fail "open keeps the applet"
launcher_sh remove >/dev/null
mkdir -p "$BL_APP/Contents/Resources"
printf '<plist><dict><key>CFBundleIdentifier</key><string>com.example.other</string></dict></plist>\n' >"$BL_APP/Contents/Info.plist"
printf 'stale\n' >"$AR_BUILD"
ar_untouched "another app with the same name"
assert_contains "$(<"$BL_APP/Contents/Info.plist")" "com.example.other" "open leaves another app alone"
rm -rf "$BL_APP"
ar_stale_window
BL_SWIFTC_OVERRIDE="$BOARD_T/no-swiftc" ar_untouched "no swiftc"
assert_eq "stale" "$(ar_build)" "open without swiftc keeps the stale window app"
BO_PLATFORM=Linux ar_untouched "outside macOS"
assert_eq "stale" "$(ar_build)" "open outside macOS keeps the window app"
launcher_sh remove >/dev/null
launcher_sh install >/dev/null
rm -f "$AR_LOG"
ar_untouched "an up-to-date window app"
# A7: 재빌드가 실패해도 open 출력은 그대로이고, 쓰던 창 앱을 애플릿으로 낮추지 않는다.
ar_stale_window
AR_OUT="$(BOARD_LAUNCHER_SWIFTC_FAIL=1 ar_open)" || fail "open exits 0 when the background rebuild fails"
assert_eq "1" "$(printf '%s\n' "$AR_OUT" | wc -l | tr -d ' ')" "a failing rebuild keeps open to one JSON line"
assert_eq "true" "$(jq -r '.running' <<<"$AR_OUT")" "a failing rebuild keeps the open JSON"
for _ in $(seq 1 100); do
  [[ -f "$BOARD_DATA/board/bin/launcher-swift-failed" && ! -d "$AR_LOCK" ]] && break
  sleep 0.1
done
assert_file "$BOARD_DATA/board/bin/launcher-swift-failed"
[[ -x "$BL_APP/Contents/MacOS/harness-board" && ! -e "$BL_APP/Contents/MacOS/applet" ]] || fail "a failed background rebuild keeps the window app"
launcher_sh remove >/dev/null
bo_reset
pass "harness board open rebuilds a stale window app in the background"

# 격리(시험용) 보드 보기(#677): board.sh view <로컬 url>은 떠 있는 격리 보드를 창 앱의 시험용 창으로 띄운다.
# 서버를 켜거나 끄지 않고, 창 앱이 없거나 낡았거나 macOS가 아니면 브라우저 없이 안내만 한다(exit 1). 인자 오류는 exit 2.
BV_ISO="$BOARD_T/iso-data"
mkdir -p "$BV_ISO"
board_view_sh() { # 격리 데이터 디렉터리·BOARD_NO_BROWSER=1(격리 절 관례)에서 부른다
  env PATH="$BO_BIN:$BOARD_T/bin:$PATH" HARNESS_METRICS_DIR="$BV_ISO" BOARD_LAUNCHER_DIR="$BL_APPS" \
    BOARD_LAUNCHER_PLATFORM="${BO_PLATFORM:-Darwin}" BOARD_NO_BROWSER=1 bash "$ROOT/scripts/board/board.sh" view "$@"
}
bv_sum() { if [[ -f "$1" ]]; then cksum <"$1"; else echo none; fi; }
# V5: 창 앱은 시험용 창 요청을 받는 URL 스킴을 등록하고, 스킴이 들어간 빌드는 v2 stamp다.
launcher_sh remove >/dev/null
BL_PATH="$BO_BIN:$BL_PATH" launcher_sh install >/dev/null
assert_contains "$(<"$BL_APP/Contents/Info.plist")" "<string>harness-board-view</string>" "the window app registers the harness-board-view URL scheme"
assert_contains "$(<"$BL_APP/Contents/Info.plist")" "CFBundleURLSchemes" "the URL scheme is declared in CFBundleURLTypes"
assert_eq "v2 swift " "$(head -c 9 "$BL_APP/Contents/Resources/launcher-build")" "the window app with the view scheme is built with the v2 stamp"
# V1·V2: 사용자 보드(테스트 서버)가 떠 있는 상태에서 view는 open -a 한 번만 부르고 server.json을 건드리지 않는다.
bo_reset
board_sh open >/dev/null
BV_URL="http://127.0.0.1:$BOARD_PORT_T/?token=x"
BV_USER_BEFORE="$(bv_sum "$BOARD_DATA/board/server.json")"
BV_ISO_BEFORE="$(bv_sum "$BV_ISO/board/server.json")"
BV_OUT="$(board_view_sh "$BV_URL")" || fail "board.sh view with the window app exits 0"
assert_eq "1" "$(printf '%s\n' "$BV_OUT" | wc -l | tr -d ' ')" "view prints one JSON line"
assert_eq "window|$BV_URL|$BL_APP" "$(jq -r '[.view, .url, .app] | join("|")' <<<"$BV_OUT")" "view reports the window and the url"
assert_eq "-a $BL_APP harness-board-view://open?url=http%3A%2F%2F127.0.0.1%3A$BOARD_PORT_T%2F%3Ftoken%3Dx" "$(<"$BO_LOG")" \
  "view asks the window app for a trial window once"
assert_eq "" "$(<"$BO_XLOG")" "view does not use xdg-open"
assert_eq "$BV_USER_BEFORE" "$(bv_sum "$BOARD_DATA/board/server.json")" "view leaves the user server.json alone"
assert_eq "$BV_ISO_BEFORE" "$(bv_sum "$BV_ISO/board/server.json")" "view leaves the isolated server.json alone"
assert_eq "true" "$(board_sh status | jq -r '.running')" "view keeps the running board"
: >"$BO_LOG"
BV_OUT="$(board_view_sh "http://localhost:$BOARD_PORT_T/")" || fail "view accepts localhost"
assert_eq "window" "$(jq -r '.view' <<<"$BV_OUT")" "view opens a localhost url"
# V4: 로컬 http + 포트가 아니면 사용법(exit 2)이고 아무것도 열지 않는다.
bv_bad() { # 설명 인자...
  local what="$1" code=0
  shift
  : >"$BO_LOG"; : >"$BO_XLOG"
  board_view_sh "$@" >/dev/null 2>&1 || code=$?
  assert_eq "2" "$code" "view rejects $what with usage"
  assert_eq "|" "$(<"$BO_LOG")|$(<"$BO_XLOG")" "view opens nothing for $what"
}
bv_bad "https" "https://127.0.0.1:1/"
bv_bad "a remote host" "http://example.com:80/"
bv_bad "a url without a port" "http://127.0.0.1/"
bv_bad "no argument"
bv_bad "two arguments" "http://127.0.0.1:1/" "http://127.0.0.1:2/"
bv_bad "a file url" "file:///etc/passwd"
bv_bad "a userinfo host" "http://127.0.0.1:80@example.com/"
# V3: 창 앱으로 띄울 수 없으면 브라우저 없이 주소와 설치 안내만 내고 exit 1.
bv_refused() { # 설명 [open 로그 기대값]
  local code=0 err
  : >"$BO_LOG"; : >"$BO_XLOG"
  err="$(board_view_sh "$BV_URL" 2>&1 >/dev/null)" || code=$?
  assert_eq "1" "$code" "view exits 1: $1"
  assert_contains "$err" "launcher install" "view tells how to install the window app: $1"
  assert_contains "$err" "$BV_URL" "view shows the url: $1"
  assert_eq "${2:-}|" "$(<"$BO_LOG")|$(<"$BO_XLOG")" "view does not open a browser: $1"
}
BO_STUB_FAIL_APP=1 bv_refused "open -a fails" "-a $BL_APP harness-board-view://open?url=http%3A%2F%2F127.0.0.1%3A$BOARD_PORT_T%2F%3Ftoken%3Dx"
BO_PLATFORM=Linux bv_refused "outside macOS"
printf 'stale\n' >"$AR_BUILD"
bv_refused "a stale window app"
assert_eq "stale" "$(ar_build)" "view does not rebuild the stale window app from an isolated data directory"
launcher_sh remove >/dev/null
bv_refused "no launcher"
BL_SWIFTC_OVERRIDE="$BOARD_T/no-swiftc" launcher_sh install >/dev/null 2>&1
bv_refused "an applet"
launcher_sh remove >/dev/null
mkdir -p "$BL_APP/Contents/MacOS" "$BL_APP/Contents/Resources"
printf '<plist><dict><key>CFBundleIdentifier</key><string>com.example.other</string></dict></plist>\n' >"$BL_APP/Contents/Info.plist"
printf '#!/bin/bash\n' >"$BL_APP/Contents/MacOS/harness-board" && chmod +x "$BL_APP/Contents/MacOS/harness-board"
bv_refused "another app with the same name"
rm -rf "$BL_APP"
# V6: Swift 창 앱의 시험용 창 — URL 요청을 받고, 창마다 자기 기준으로 링크를 나누고, 닫거나 감시할 때 서버를 끄지 않는다.
BV_SWIFT="$ROOT/scripts/board/BoardLauncher.swift"
assert_contains "$(<"$BV_SWIFT")" "application(_ application: NSApplication, open urls:" "the window app receives view URLs"
assert_contains "$(<"$BV_SWIFT")" '"harness-board-view"' "the window app handles the harness-board-view scheme"
assert_contains "$(grep -F 'title:' "$BV_SWIFT")" "시험용" "trial windows are titled as trial boards"
BV_TERM="$(sed -n '/func applicationWillTerminate(/,/^    }$/p' "$BV_SWIFT")"
assert_contains "$BV_TERM" 'if board != nil { _ = runShim(["stop"]' "quitting stops only the user board it opened"
BV_TRIAL="$(sed -n '/\/\/ MARK: 시험용 창/,/\/\/ MARK: 링크/p' "$BV_SWIFT")"
assert_contains "$BV_TRIAL" "cannotConnectToHost" "a trial window watches its own server"
case "$BV_TRIAL$(sed -n '/func windowWillClose(/,/^    }$/p' "$BV_SWIFT")" in
  *'runShim(["stop"]'* | *'runShim(["alive"]'*) fail "trial windows neither stop nor check the user board" ;;
esac
assert_contains "$(grep -F 'func isBoard(' "$BV_SWIFT")" "base: URL?" "isBoard compares with the base of each window"
case "$(sed -n '/func isBoard(/,/^    }$/p' "$BV_SWIFT")" in *'guard let board'*) fail "isBoard does not use the global user board alone" ;; esac
# V7: 문서와 사용법.
assert_contains "$(<"$ROOT/.ai-harness/docs/ui.md")" "board.sh view" "ui.md shows isolated boards with board.sh view"
assert_contains "$(sed -n '/^## 보드를 격리해 띄우기/,/^## /p' "$ROOT/.ai-harness/docs/ui.md")" "브라우저로 열지 않는다" "ui.md says not to open isolated boards in a browser"
assert_contains "$(<"$ROOT/skills/board/SKILL.md")" "board.sh view" "the board skill documents board.sh view"
assert_contains "$(bash "$ROOT/scripts/board/board.sh" --help 2>&1 || true)" "board.sh view" "usage lists view"
# V8: changelog 조각.
# 릴리스 준비가 조각을 CHANGELOG.md로 옮기므로 둘 중 한 곳에 있으면 된다.
assert_contains "$(cat "$ROOT"/changelog.d/677-*.md "$ROOT/CHANGELOG.md" 2>/dev/null)" "(#677)" "changelog entry for #677"
bo_reset
pass "harness board view opens an isolated board in a trial window"

finish_tests
