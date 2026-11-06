import UIKit
import WebKit
import UserNotifications
import AudioToolbox

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

final class VC: UIViewController, WKScriptMessageHandler, WKUIDelegate, UNUserNotificationCenterDelegate, UIImagePickerControllerDelegate, UINavigationControllerDelegate, WKNavigationDelegate {
    var camId: String?
    var pendingURL: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("pending.jpg")
    }
    var web: WKWebView!

    override func viewDidLoad() {
        super.viewDidLoad()
        let bgc = UIColor { t in t.userInterfaceStyle == .dark ? UIColor(red: 0.02, green: 0.027, blue: 0.05, alpha: 1) : UIColor(red: 0.914, green: 0.933, blue: 0.984, alpha: 1) }
        view.backgroundColor = bgc
        UNUserNotificationCenter.current().delegate = self
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
        web.navigationDelegate = self
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
        guard let d = m.body as? [String: Any] else { return }
        if (d["op"] as? String) == "fx" {
            let kind = d["kind"] as? String ?? "tap"
            let sound = (d["sound"] as? Bool) ?? true, haptic = (d["haptic"] as? Bool) ?? true
            if haptic {
                switch kind {
                case "success": UINotificationFeedbackGenerator().notificationOccurred(.success)
                case "warning": UINotificationFeedbackGenerator().notificationOccurred(.warning)
                case "error":   UINotificationFeedbackGenerator().notificationOccurred(.error)
                case "select":  UISelectionFeedbackGenerator().selectionChanged()
                case "heavy":   UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                case "soft":    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                default:        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            }
            if sound {
                // 系统音：跟随静音开关，不需要额外音频文件
                let ids: [String: UInt32] = ["tap": 1104, "select": 1104, "soft": 1104, "heavy": 1105,
                                              "success": 1407, "warning": 1053, "error": 1073]
                if let sid = ids[kind] { AudioServicesPlaySystemSound(sid) }
            }
            return
        }
        if (d["op"] as? String) == "notify" {
            let title = d["title"] as? String ?? "", body = d["body"] as? String ?? ""
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            let c = UNUserNotificationCenter.current()
            c.requestAuthorization(options: [.alert, .sound]) { ok, _ in
                guard ok else { return }
                let ct = UNMutableNotificationContent(); ct.title = title; ct.body = body; ct.sound = .default
                c.add(UNNotificationRequest(identifier: UUID().uuidString, content: ct, trigger: nil))
            }
            return
        }
        if (d["op"] as? String) == "takePending" {
            guard let id = d["id"] as? String else { return }
            if let data = try? Data(contentsOf: pendingURL) { reply(id, ["ok": true, "data": "data:image/jpeg;base64," + data.base64EncodedString()]) }
            else { reply(id, ["ok": false, "error": "none"]) }
            return
        }
        if (d["op"] as? String) == "clearPending" {
            try? FileManager.default.removeItem(at: pendingURL)
            return
        }
        if (d["op"] as? String) == "camera" {
            guard let id = d["id"] as? String else { return }
            guard UIImagePickerController.isSourceTypeAvailable(.camera) else { reply(id, ["ok": false, "error": "设备没有可用相机"]); return }
            camId = id
            let pk = UIImagePickerController(); pk.sourceType = .camera; pk.delegate = self
            present(pk, animated: true)
            return
        }
        guard let id = d["id"] as? String,
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

    // 相机占用前台时 iOS 可能回收网页进程，不处理就是整屏黑
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.load(URLRequest(url: URL(string: "app://localhost/index.html")!))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent n: UNNotification, withCompletionHandler h: @escaping (UNNotificationPresentationOptions) -> Void) {
        h([.banner, .list, .sound])
    }

    func reply(_ id: String, _ obj: [String: Any]) {
        guard let j = try? JSONSerialization.data(withJSONObject: obj),
              let str = String(data: j, encoding: .utf8) else { return }
        DispatchQueue.main.async {
            self.web.evaluateJavaScript("window.__nativeReply(\(String(reflecting: id)), \(str))", completionHandler: nil)
        }
    }

    // ---- 原生相机：网页里的 app:// 不是安全环境，<input capture> 打不开相机 ----
    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
        picker.dismiss(animated: true)
        guard let id = camId else { return }
        camId = nil
        guard let img = info[.originalImage] as? UIImage else { reply(id, ["ok": false, "error": "没有取到照片"]); return }
        // 用 UIGraphicsImageRenderer 重绘：自动处理方向和颜色空间（旧的 UIGraphicsBeginImageContext 在相机图上会画成近乎空白）
        let maxSide: CGFloat = 1800
        let k = min(1, maxSide / max(img.size.width, img.size.height))
        let sz = CGSize(width: (img.size.width * k).rounded(), height: (img.size.height * k).rounded())
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1; fmt.opaque = true
        let small = UIGraphicsImageRenderer(size: sz, format: fmt).image { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(origin: .zero, size: sz))
            img.draw(in: CGRect(origin: .zero, size: sz))
        }
        guard let data = small.jpegData(compressionQuality: 0.85), data.count > 20_000 else {
            // 编码后异常地小，说明重绘失败：退回直接压原图
            guard let raw = img.jpegData(compressionQuality: 0.7) else { reply(id, ["ok": false, "error": "编码失败"]); return }
            try? raw.write(to: pendingURL)
            reply(id, ["ok": true, "data": "data:image/jpeg;base64," + raw.base64EncodedString()])
            return
        }
        try? data.write(to: pendingURL)
        reply(id, ["ok": true, "data": "data:image/jpeg;base64," + data.base64EncodedString()])
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
        if let id = camId { reply(id, ["ok": false, "error": "cancel"]) }
        camId = nil
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
