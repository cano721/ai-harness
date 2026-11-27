// Harness Board의 macOS 창 런처(#455). 보드를 브라우저 탭 대신 이 앱 창 하나에 띄운다.
// 보드 서버를 켜고 끄는 일은 고정 경로 shim(open --app | alive | stop)에 맡긴다.
// board.sh view(#677)가 보낸 harness-board-view://open?url=<격리 보드 주소>는 시험용 창으로 띄운다 — 서버는 켜거나 끄지 않는다.
import AppKit
@preconcurrency import WebKit

enum ShimResult {
    case ok(String)
    case down         // 종료 코드 1: 보드가 꺼졌다
    case checkFailed  // 그 밖: 확인하지 못했다(플러그인 업데이트 중 등) — 앱을 끝내지 않는다
}

// 격리(시험용) 보드 창 하나. 링크 판정 기준·보조 창·서버 감시를 창마다 따로 둔다.
final class TrialBoard {
    var base: URL
    let window: NSWindow
    let webView: WKWebView
    var children: [NSWindow] = []
    var monitor: Timer?
    var checking = false

    init(base: URL, window: NSWindow, webView: WKWebView) {
        self.base = base; self.window = window; self.webView = webView
    }
}

@main
final class HarnessBoardApp: NSObject, NSApplicationDelegate, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    private var window: NSWindow?  // 사용자 보드 창
    private var shim = ""
    private var board: URL?
    private var monitor: Timer?
    private var checking = false
    private var children: [NSWindow] = []
    private var trials: [TrialBoard] = []

    static func main() {
        let app = NSApplication.shared
        let delegate = HarnessBoardApp()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let configURL = Bundle.main.url(forResource: "launcher-config", withExtension: "json"),
              let data = try? Data(contentsOf: configURL),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let path = value["shim"] else { NSApp.terminate(nil); return }
        shim = path
        buildMenu()

        // board.sh view로 시동됐으면(기본 실행이 아님) 시험용 창 요청을 잠시 기다린다 — 그 창만 띄우고 사용자 보드 서버는 켜지 않는다.
        let isDefault = notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool ?? true
        if isDefault { openUserBoard(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.trials.isEmpty else { return }
            self.openUserBoard()
        }
    }

    private func openUserBoard() {
        guard window == nil else { return }
        let view = makeWebView(WKWebViewConfiguration())
        let userWindow = makeWindow(view, title: "Harness Board", size: NSSize(width: 1100, height: 760))
        userWindow.delegate = self
        window = userWindow
        view.loadHTMLString("<html><body style='font:13px -apple-system;color:#888;display:grid;place-items:center;height:90vh'>보드를 여는 중…</body></html>", baseURL: nil)
        userWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // 서버가 뜰 때까지 몇 초 걸릴 수 있어 창을 먼저 보이고 뒤에서 연다. 실패 이유는 shim이 대화상자로 알렸다.
        DispatchQueue.global(qos: .userInitiated).async {
            let url = self.openBoard()
            DispatchQueue.main.async {
                guard let url else {
                    // 시험용 창이 떠 있으면 그 창들은 두고 사용자 창만 거둔다.
                    if self.trials.isEmpty { NSApp.terminate(nil) } else { self.window = nil; userWindow.close() }
                    return
                }
                self.board = url
                view.load(URLRequest(url: url))
                self.startMonitor()
            }
        }
    }

    private func openBoard() -> URL? {
        guard case .ok(let output) = runShim(["open", "--app"]) else { return nil }
        let last = output.split(separator: "\n").last.map(String.init) ?? ""
        guard let object = try? JSONSerialization.jsonObject(with: Data(last.utf8)) as? [String: Any],
              let address = object["url"] as? String else { return nil }
        return URL(string: address)
    }

    // 보드가 자동 종료나 board.sh stop으로 꺼지면 앱도 끝난다. 확인은 셸을 띄우므로 메인 스레드 밖에서 한다.
    private func startMonitor() {
        monitor = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self, !self.checking else { return }
            self.checking = true
            DispatchQueue.global(qos: .utility).async {
                let result = self.runShim(["alive"])
                DispatchQueue.main.async {
                    self.checking = false
                    if case .down = result { NSApp.terminate(nil) }
                }
            }
        }
    }

    // Dock 아이콘을 다시 누르면 새 창 없이 그 창을 앞으로(최소화돼 있으면 되살려) 가져온다.
    // 시험용 창만 떠 있으면(board.sh open의 open -a 포함) 그때 사용자 보드 창을 연다.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard let window else { openUserBoard(); return true }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    // 사용자 보드 창을 닫으면 앱을 끝낸다(로그·리포트 같은 보조 창만 닫을 때는 아니다).
    // 시험용 창은 닫아도 서버를 끄지 않고, 사용자 창 없이 마지막 시험용 창이 닫히면 앱만 끝난다.
    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow else { return }
        if closing === window { NSApp.terminate(nil); return }
        if let index = trials.firstIndex(where: { $0.window === closing }) {
            let trial = trials.remove(at: index)
            trial.monitor?.invalidate()
            trial.children.forEach { $0.close() }
            if window == nil && trials.isEmpty { NSApp.terminate(nil) }
            return
        }
        children.removeAll { $0 === closing }
        trials.forEach { trial in trial.children.removeAll { $0 === closing } }
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor?.invalidate()
        trials.forEach { $0.monitor?.invalidate() }
        if board != nil { _ = runShim(["stop"], timeout: 5) }
    }

    // MARK: 시험용 창

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if let target = Self.trialTarget(url) { showTrial(target) }
        }
    }

    // harness-board-view://open?url=<주소>에서 로컬 보드 주소(http + 127.0.0.1/localhost + 포트)만 꺼낸다. board.sh view와 같은 규칙.
    private static func trialTarget(_ url: URL) -> URL? {
        guard url.scheme == "harness-board-view", url.host == "open",
              let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "url" })?.value,
              let target = URL(string: value), target.scheme == "http", target.port != nil,
              target.user == nil, target.host == "127.0.0.1" || target.host == "localhost" else { return nil }
        return target
    }

    // 같은 주소의 시험용 창이 있으면 그 창을 앞으로 가져와 새 주소를 연다.
    private func showTrial(_ target: URL) {
        if let trial = trials.first(where: { Self.sameBoard(target, $0.base) }) {
            trial.base = target
            trial.webView.load(URLRequest(url: target))
            if trial.window.isMiniaturized { trial.window.deminiaturize(nil) }
            trial.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = makeWebView(WKWebViewConfiguration())
        let trialWindow = makeWindow(view, title: "Harness Board — 시험용 :\(target.port.map(String.init) ?? "")",
                                     size: NSSize(width: 1100, height: 760))
        trialWindow.delegate = self
        let trial = TrialBoard(base: target, window: trialWindow, webView: view)
        trials.append(trial)
        view.load(URLRequest(url: target))
        trialWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        watch(trial)
    }

    // 격리 서버가 꺼지면(연결 거부) 그 시험용 창과 보조 창만 닫는다. 응답이 오면 상태 코드와 상관없이 살아 있다.
    // 사용자 서버 기준인 shim은 부르지 않는다. 일시적 오류로 닫히지 않게 연결 거부만 꺼짐으로 본다.
    private func watch(_ trial: TrialBoard) {
        trial.monitor = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self, weak trial] _ in
            guard let self, let trial, !trial.checking else { return }
            trial.checking = true
            var request = URLRequest(url: trial.base, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 4)
            request.httpMethod = "HEAD"
            URLSession.shared.dataTask(with: request) { _, _, error in
                let down = (error as? URLError)?.code == .cannotConnectToHost
                DispatchQueue.main.async {
                    trial.checking = false
                    if down, self.trials.contains(where: { $0 === trial }) { trial.window.close() }
                }
            }.resume()
        }
    }

    private func trial(of view: WKWebView) -> TrialBoard? {
        trials.first { trial in trial.webView === view || trial.children.contains { $0 === view.window } }
    }

    // MARK: 링크

    private static func sameBoard(_ url: URL, _ base: URL) -> Bool {
        url.scheme == base.scheme && url.port == base.port
            && (url.host == base.host || url.host == "localhost" || url.host == "127.0.0.1")
    }

    // 웹뷰가 속한 창의 기준 주소: 시험용 창(과 그 보조 창)은 자기 격리 보드, 나머지는 사용자 보드.
    private func base(of view: WKWebView) -> URL? { trial(of: view)?.base ?? board }

    private func isBoard(_ url: URL, base: URL?) -> Bool {
        guard let base else { return false }
        return Self.sameBoard(url, base)
    }

    // 내 일정이 target 없이 넘기는 앱 딥링크(#592). OS에 넘겨 그 앱(Teams)을 연다. agenda.py·template.html의 목록과 같아야 한다.
    private static let appLinkSchemes = ["msteams"]

    private func openOutside(_ url: URL) {
        if let scheme = url.scheme?.lowercased(), (["http", "https", "mailto"] + Self.appLinkSchemes).contains(scheme) {
            NSWorkspace.shared.open(url)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if url.scheme == "about" || isBoard(url, base: base(of: webView)) { decisionHandler(.allow); return }
        if navigationAction.targetFrame?.isMainFrame != false { openOutside(url) }
        decisionHandler(.cancel)
    }

    // target=_blank: 보드의 로그·리포트는 앱 안의 보조 창으로, 나머지는 기본 브라우저로 연다.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = navigationAction.request.url else { return nil }
        let parent = trial(of: webView)
        guard isBoard(url, base: base(of: webView)) else { openOutside(url); return nil }
        let child = makeWebView(configuration)
        let childWindow = makeWindow(child, title: webView.window?.title ?? "Harness Board", size: NSSize(width: 960, height: 700))
        childWindow.delegate = self
        // 보조 창은 부모 창의 기준을 물려받는다 — 시험용 창의 보조 창도 그 격리 보드 기준으로 링크를 나눈다.
        if let parent { parent.children.append(childWindow) } else { children.append(childWindow) }
        childWindow.makeKeyAndOrderFront(nil)
        return child
    }

    func webViewDidClose(_ webView: WKWebView) { webView.window?.close() }

    // MARK: JavaScript 대화상자

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert(); alert.messageText = message
        alert.runModal()
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert(); alert.messageText = message
        alert.addButton(withTitle: "확인"); alert.addButton(withTitle: "취소")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        let alert = NSAlert(); alert.messageText = prompt
        let input = NSTextField(string: defaultText ?? "")
        input.frame = NSRect(x: 0, y: 0, width: 360, height: 24)
        alert.accessoryView = input
        alert.addButton(withTitle: "확인"); alert.addButton(withTitle: "취소")
        completionHandler(alert.runModal() == .alertFirstButtonReturn ? input.stringValue : nil)
    }

    // MARK: 창·메뉴

    private func makeWebView(_ configuration: WKWebViewConfiguration) -> WKWebView {
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.uiDelegate = self
        return view
    }

    private func makeWindow(_ content: NSView, title: String, size: NSSize) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = title
        w.contentView = content
        w.isReleasedWhenClosed = false
        w.center()
        return w
    }

    // 메뉴가 없으면 ⌘C·⌘V·⌘Q 같은 단축키가 동작하지 않는다.
    private func buildMenu() {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let holder = NSMenuItem(); let menu = NSMenu(title: title)
            items.forEach(menu.addItem); holder.submenu = menu; main.addItem(holder)
        }
        func item(_ title: String, _ action: Selector?, _ key: String, _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key); i.keyEquivalentModifierMask = mods; return i
        }
        submenu("Harness Board", [item("Harness Board 종료", #selector(NSApplication.terminate(_:)), "q")])
        submenu("편집", [
            item("실행 취소", Selector(("undo:")), "z"),
            item("실행 복귀", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("오려두기", #selector(NSText.cut(_:)), "x"),
            item("복사하기", #selector(NSText.copy(_:)), "c"),
            item("붙여넣기", #selector(NSText.paste(_:)), "v"),
            item("전체 선택", #selector(NSText.selectAll(_:)), "a"),
        ])
        submenu("보기", [item("새로고침", #selector(WKWebView.reload(_:)), "r")])
        submenu("윈도우", [
            item("닫기", #selector(NSWindow.performClose(_:)), "w"),
            item("최소화", #selector(NSWindow.performMiniaturize(_:)), "m"),
        ])
        NSApp.mainMenu = main
    }

    // MARK: shim

    private func runShim(_ arguments: [String], timeout: TimeInterval = 60) -> ShimResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [shim] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return .checkFailed }
        var output = Data()
        let reader = DispatchQueue.global(qos: .utility)
        let readDone = DispatchSemaphore(value: 0)
        reader.async { output = pipe.fileHandleForReading.readDataToEndOfFile(); readDone.signal() }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return .checkFailed
        }
        _ = readDone.wait(timeout: .now() + 2)
        switch process.terminationStatus {
        case 0: return .ok(String(data: output, encoding: .utf8) ?? "")
        case 1: return .down
        default: return .checkFailed
        }
    }
}
