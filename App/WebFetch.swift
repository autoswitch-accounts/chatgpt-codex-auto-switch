import AppKit
import WebKit

/// `ChatGPTAccounts --web-fetch`：后台服务（Python）借 WebKit 调 chatgpt.com 的后端接口。
///
/// chatgpt.com 的 Cloudflare 会对非浏览器客户端拦 accounts/*、subscriptions（403 + cf-mitigated: challenge），
/// 浏览器里同样的请求能过。这里先在不显示的 WKWebView 里打开 chatgpt.com/backend-api/（拿到 Cloudflare 的 cookie），
/// 之后每个请求都在这个页面里用 fetch 发，带上槽位自己的 access_token。不登录网页、不存任何凭证。
///
/// 协议（一行一个 JSON）：启动后输出 {"ready":true} 或 {"ready":false,"error":…}；
/// stdin 每行 {"path","token","acct"} → stdout 每行 {"status","body"}（status 0 表示页面里出错，body 是错误说明）。
/// stdin 关闭就退出。
enum WebFetch {
    @MainActor private static var web: WKWebView!
    @MainActor private static var loader: Loader!

    static func run() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)            // 不出现在程序坞，也不抢焦点
        DispatchQueue.main.async { MainActor.assumeIsolated { start() } }
        app.run()
        exit(0)
    }

    @MainActor private static func start() {
        web = WKWebView(frame: .init(x: 0, y: 0, width: 800, height: 600), configuration: WKWebViewConfiguration())
        loader = Loader { ok, err in
            write(ok ? ["ready": true] : ["ready": false, "error": err])
            if ok { readLoop() } else { exit(1) }
        }
        web.navigationDelegate = loader
        web.load(URLRequest(url: URL(string: "https://chatgpt.com/backend-api/")!))
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) { loader.finish(false, "打开 chatgpt.com 超时") }
    }

    /// 后台线程逐行读请求，每个请求回主线程在页面里执行，一次一个
    @MainActor private static func readLoop() {
        Thread.detachNewThread {
            while let line = readLine() {
                guard let d = line.data(using: .utf8),
                      let req = try? JSONSerialization.jsonObject(with: d) as? [String: String] else {
                    write(["status": 0, "body": "请求格式不对"]); continue
                }
                let done = DispatchSemaphore(value: 0)
                Task { @MainActor in
                    write(await fetch(req["path"] ?? "", token: req["token"] ?? "", acct: req["acct"] ?? ""))
                    done.signal()
                }
                done.wait()
            }
            exit(0)
        }
    }

    @MainActor private static func fetch(_ path: String, token: String, acct: String) async -> [String: Any] {
        let js = """
            const r = await fetch('/backend-api/' + path, {headers: {Authorization: 'Bearer ' + token,
                'ChatGPT-Account-Id': acct, Accept: 'application/json'}, credentials: 'include'});
            return JSON.stringify({status: r.status, body: await r.text()});
            """
        do {
            let r = try await web.callAsyncJavaScript(js, arguments: ["path": path, "token": token, "acct": acct], contentWorld: .page)
            if let s = r as? String, let d = s.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                return o
            }
            return ["status": 0, "body": "页面没有返回结果"]
        } catch {
            return ["status": 0, "body": error.localizedDescription]
        }
    }

    private static let out = FileHandle.standardOutput
    private static let outLock = NSLock()
    private static func write(_ o: [String: Any]) {
        guard var d = try? JSONSerialization.data(withJSONObject: o) else { return }
        d.append(0x0A)
        outLock.lock(); out.write(d); outLock.unlock()
    }

    /// 首次加载完成（或失败）只回调一次
    private final class Loader: NSObject, WKNavigationDelegate {
        private var cb: ((Bool, String) -> Void)?
        init(_ cb: @escaping (Bool, String) -> Void) { self.cb = cb }
        func finish(_ ok: Bool, _ err: String) { let c = cb; cb = nil; c?(ok, err) }
        func webView(_ w: WKWebView, didFinish n: WKNavigation!) {
            // Cloudflare 的 JS 验证页（标题 Just a moment…）过一会儿会自己跳转；落到 backend-api/ 本身才算好
            w.evaluateJavaScript("document.title") { t, _ in
                if !((t as? String) ?? "").localizedCaseInsensitiveContains("just a moment") { self.finish(true, "") }
            }
        }
        func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { finish(false, e.localizedDescription) }
        func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) {
            finish(false, e.localizedDescription)
        }
    }
}
