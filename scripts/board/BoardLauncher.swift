// Harness Board의 macOS 창 런처(#455). 보드를 브라우저 탭 대신 이 앱 창 하나에 띄운다.
// 보드 서버를 켜고 끄는 일은 고정 경로 shim(open --app | alive | stop)에 맡긴다.
import AppKit
@preconcurrency import WebKit

enum ShimResult {
    case ok(String)
    case down         // 종료 코드 1: 보드가 꺼졌다
    case checkFailed  // 그 밖: 확인하지 못했다(플러그인 업데이트 중 등) — 앱을 끝내지 않는다
}

@main
final class HarnessBoardApp: NSObject, NSApplicationDelegate, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    private var window: NSWindow!
    private var webView: WKWebView!
    private var shim = ""
    private var board: URL?
    private var monitor: Timer?
    private var checking = false
    private var children: [NSWindow] = []

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

        webView = makeWebView(WKWebViewConfiguration())
        window = makeWindow(webView, title: "Harness Board", size: NSSize(width: 1100, height: 760))
        window.delegate = self
        webView.loadHTMLString("<html><body style='font:13px -apple-system;color:#888;display:grid;place-items:center;height:90vh'>보드를 여는 중…</body></html>", baseURL: nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // 서버가 뜰 때까지 몇 초 걸릴 수 있어 창을 먼저 보이고 뒤에서 연다. 실패 이유는 shim이 대화상자로 알렸다.
        DispatchQueue.global(qos: .userInitiated).async {
            let url = self.openBoard()
            DispatchQueue.main.async {
                guard let url else { NSApp.terminate(nil); return }
                self.board = url
                self.webView.load(URLRequest(url: url))
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
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    // 보드 창을 닫으면 앱을 끝낸다(로그·리포트 같은 보조 창만 닫을 때는 아니다).
    func windowWillClose(_ notification: Notification) {
        if let closing = notification.object as? NSWindow, closing === window {
            NSApp.terminate(nil)
        } else if let closing = notification.object as? NSWindow {
            children.removeAll { $0 === closing }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor?.invalidate()
        if board != nil { _ = runShim(["stop"], timeout: 5) }
    }

    // MARK: 링크

    private func isBoard(_ url: URL) -> Bool {
        guard let board else { return false }
        return url.scheme == board.scheme && url.port == board.port
            && (url.host == board.host || url.host == "localhost" || url.host == "127.0.0.1")
    }

    private func openOutside(_ url: URL) {
        if let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) {
            NSWorkspace.shared.open(url)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if url.scheme == "about" || isBoard(url) { decisionHandler(.allow); return }
        if navigationAction.targetFrame?.isMainFrame != false { openOutside(url) }
        decisionHandler(.cancel)
    }

    // target=_blank: 보드의 로그·리포트는 앱 안의 보조 창으로, 나머지는 기본 브라우저로 연다.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = navigationAction.request.url else { return nil }
        guard isBoard(url) else { openOutside(url); return nil }
        let child = makeWebView(configuration)
        let childWindow = makeWindow(child, title: "Harness Board", size: NSSize(width: 960, height: 700))
        childWindow.delegate = self
        children.append(childWindow)
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
