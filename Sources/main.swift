import UIKit
import WebKit

final class SchemeHandler: NSObject, WKURLSchemeHandler {
    let root: URL
    init(root: URL) { self.root = root }
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        var path = url.path
        if path.isEmpty || path == "/" { path = "/index.html" }
        let file = root.appendingPathComponent(String(path.dropFirst()).removingPercentEncoding ?? "")
        guard file.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path),
              let data = try? Data(contentsOf: file) else {
            task.didReceive(HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!)
            task.didFinish(); return
        }
        let mimes = ["html": "text/html; charset=utf-8", "js": "application/javascript; charset=utf-8",
                     "css": "text/css; charset=utf-8", "png": "image/png"]
        let mime = mimes[file.pathExtension.lowercased()] ?? "application/octet-stream"
        let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                   headerFields: ["Content-Type": mime, "Content-Length": "\(data.count)", "Cache-Control": "no-cache"])!
        task.didReceive(resp); task.didReceive(data); task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

final class VC: UIViewController, WKScriptMessageHandler, WKUIDelegate {
    var web: WKWebView!

    override func viewDidLoad() {
        super.viewDidLoad()
        let bgc = UIColor { t in t.userInterfaceStyle == .dark ? UIColor(red: 0.02, green: 0.027, blue: 0.05, alpha: 1) : UIColor(red: 0.914, green: 0.933, blue: 0.984, alpha: 1) }
        view.backgroundColor = bgc
        let cfg = WKWebViewConfiguration()
        let www = Bundle.main.bundleURL.appendingPathComponent("www")
        cfg.setURLSchemeHandler(SchemeHandler(root: www), forURLScheme: "app")
        cfg.userContentController.add(self, name: "native")
        web = WKWebView(frame: .zero, configuration: cfg)
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.uiDelegate = self
        web.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(web)
        let g = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            web.topAnchor.constraint(equalTo: view.topAnchor),
            web.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            web.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: view.trailingAnchor)])
        web.load(URLRequest(url: URL(string: "app://localhost/index.html")!))
    }

    // JS -> 原生 HTTP（绕开 CORS）：{id, url, headers, body}
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        guard let d = m.body as? [String: Any], let id = d["id"] as? String,
              let urlStr = d["url"] as? String, let url = URL(string: urlStr) else { return }
        var req = URLRequest(url: url, timeoutInterval: 120)
        req.httpMethod = "POST"
        if let h = d["headers"] as? [String: String] { for (k, v) in h { req.setValue(v, forHTTPHeaderField: k) } }
        req.httpBody = (d["body"] as? String)?.data(using: .utf8)
        URLSession.shared.dataTask(with: req) { data, resp, err in
            var out: [String: Any] = [:]
            if let err = err { out = ["ok": false, "error": err.localizedDescription] }
            else {
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                out = ["ok": true, "status": code, "text": String(data: data ?? Data(), encoding: .utf8) ?? ""]
            }
            guard let j = try? JSONSerialization.data(withJSONObject: out),
                  let s = String(data: j, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                self.web.evaluateJavaScript("window.__nativeReply(\(String(reflecting: id)), \(s))", completionHandler: nil)
            }
        }.resume()
    }

    func webView(_ w: WKWebView, runJavaScriptAlertPanelWithMessage m: String, initiatedByFrame f: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = UIAlertController(title: nil, message: m, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "好", style: .default) { _ in completionHandler() })
        present(a, animated: true)
    }
    func webView(_ w: WKWebView, runJavaScriptConfirmPanelWithMessage m: String, initiatedByFrame f: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = UIAlertController(title: nil, message: m, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(false) })
        a.addAction(UIAlertAction(title: "确定", style: .default) { _ in completionHandler(true) })
        present(a, animated: true)
    }
}

final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    func application(_ app: UIApplication, didFinishLaunchingWithOptions o: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        window = UIWindow(frame: UIScreen.main.bounds)
        window?.rootViewController = VC()
        window?.makeKeyAndVisible()
        return true
    }
}
UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(AppDelegate.self))
