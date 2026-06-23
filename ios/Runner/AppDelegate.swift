import Flutter
import UIKit
import WebKit
import SafariServices

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate, SFSafariViewControllerDelegate {
  private var webViewUserScriptInstalled = false
  private var safariLoginResult: FlutterResult?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Cookie channel — iOS equivalent of Android CookieManager
    if let controller = window?.rootViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(name: "com.smarteye/cookies", binaryMessenger: controller.binaryMessenger)
      channel.setMethodCallHandler { (call, result) in
        if call.method == "getCookies" {
          guard let args = call.arguments as? [String: Any],
                let url = args["url"] as? String else {
            result("")
            return
          }
          self.installWindowOpenOverrideIfNeeded()
          self.getCookies(for: url, result: result)
        } else if call.method == "openSafariLogin" {
          // Open login flow in SFSafariViewController (full Safari engine).
          // This handles WeChat OAuth redirect chains and cookie persistence
          // correctly, unlike embedded WKWebView.
          guard let args = call.arguments as? [String: Any],
                let url = args["url"] as? String else {
            result(FlutterError(code: "NO_URL", message: "Missing url", details: nil))
            return
          }
          self.openSafariLogin(url: url, result: result)
        } else {
          result(FlutterMethodNotImplemented)
        }
      }
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // MARK: - Safari Login

  private func openSafariLogin(url: String, result: @escaping FlutterResult) {
    guard let loginURL = URL(string: url) else {
      result(FlutterError(code: "BAD_URL", message: "Invalid URL: \(url)", details: nil))
      return
    }
    safariLoginResult = result

    // MUST be on main thread — MethodChannel callbacks can arrive on bg thread
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      let safariVC = SFSafariViewController(url: loginURL)
      safariVC.delegate = self
      safariVC.modalPresentationStyle = .pageSheet

      // Find topmost VC via UIApplication (more reliable than `window` in Flutter)
      guard let rootVC = self.topMostViewController() else {
        result(FlutterError(code: "NO_VC", message: "No view controller found", details: nil))
        self.safariLoginResult = nil
        return
      }
      rootVC.present(safariVC, animated: true) {
        NSLog("[SmartEye] SFSafariViewController presented")
      }
    }
  }

  private func topMostViewController() -> UIViewController? {
    guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
          let window = scene.windows.first(where: { $0.isKeyWindow }),
          let rootVC = window.rootViewController else {
      // Fallback: use the AppDelegate window
      if let rootVC = self.window?.rootViewController {
        var top = rootVC
        while let presented = top.presentedViewController {
          top = presented
        }
        return top
      }
      return nil
    }
    var top = rootVC
    while let presented = top.presentedViewController {
      top = presented
    }
    return top
  }

  // SFSafariViewControllerDelegate — called when user dismisses Safari
  func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
    let store = WKWebsiteDataStore.default()
    store.httpCookieStore.getAllCookies { [weak self] cookies in
      let cookieStr = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
      self?.safariLoginResult?(cookieStr)
      self?.safariLoginResult = nil
    }
    controller.dismiss(animated: true)
  }

  /// Walk the view hierarchy to find WKWebView instances and inject a
  /// document-start user script that converts window.open() calls into
  /// direct navigations.  WKWebView's createWebViewWith returns nil by
  /// default (the plugin does not create popup windows), so window.open
  /// is silently dropped — this script fixes that at the source.
  private func installWindowOpenOverrideIfNeeded() {
    guard !webViewUserScriptInstalled else { return }
    guard let rootView = window?.rootViewController?.view else { return }

    if let webView = findWKWebView(in: rootView) {
      let scriptSource = """
        window.open=function(u,t,f){\
          if(u&&typeof u==='string'&&u!==''&&u!=='about:blank'){\
            try{window.location.href=u;}catch(e){}\
            try{window.location.replace(u);}catch(e){}\
          }\
          return window;\
        };
        """
      let userScript = WKUserScript(
        source: scriptSource,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: false
      )
      webView.configuration.userContentController.addUserScript(userScript)
      webViewUserScriptInstalled = true
      NSLog("[SmartEye] WKUserScript installed: window.open → window.location override")
    }
  }

  /// Depth-first search for a WKWebView in the view hierarchy.
  private func findWKWebView(in view: UIView) -> WKWebView? {
    if let webView = view as? WKWebView {
      return webView
    }
    for subview in view.subviews {
      if let found = findWKWebView(in: subview) {
        return found
      }
    }
    return nil
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }

  /// Extract ALL cookies matching the target URL's domain from WKWebView's
  /// shared data store.  Handles HttpOnly cookies that JS document.cookie misses.
  ///
  /// Domain matching uses proper suffix comparison so that a cookie scoped to
  /// `.pospal.cn` matches `beta28.pospal.cn` (the previous implementation
  /// stripped dots and broke parent-domain matching).
  private func getCookies(for url: String, result: @escaping FlutterResult) {
    guard let siteURL = URL(string: url), let host = siteURL.host else {
      result("")
      return
    }
    let store = WKWebsiteDataStore.default()
    store.httpCookieStore.getAllCookies { cookies in
      let matched = cookies.filter { cookie in
        self.cookie(cookie, matchesHost: host)
      }
      // Fallback: if domain matching yields nothing, return ALL cookies so the
      // Dart side can still pick up the session cookie.
      let chosen = matched.isEmpty ? cookies : matched
      let cookieStr = chosen.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
      result(cookieStr)
    }
  }

  /// Returns true when `cookie`'s domain is a suffix of `host` (including the
  /// leading dot that marks domain-wide cookies in RFC 6265).
  ///
  /// Examples (host = "beta28.pospal.cn"):
  ///   cookie.domain = ".pospal.cn"         → true   (parent domain)
  ///   cookie.domain = "beta28.pospal.cn"   → true   (exact)
  ///   cookie.domain = ".beta28.pospal.cn"  → true   (subdomain scope)
  ///   cookie.domain = ".other.cn"          → false  (different domain)
  private func cookie(_ cookie: HTTPCookie, matchesHost host: String) -> Bool {
    let domain = cookie.domain
    // Exact match
    if host == domain { return true }
    // Domain cookie (leading dot): host is a subdomain, e.g. .pospal.cn matches a.pospal.cn
    if domain.hasPrefix(".") {
      let rootDomain = String(domain.dropFirst())
      if host == rootDomain { return true }
      if host.hasSuffix(domain) { return true }
      return false
    }
    // Non-dot domain: check if host ends with it (loose match for cookie scoped to subdomain)
    if host.hasSuffix(".\(domain)") || host == domain { return true }
    // Reverse: domain might be a subdomain of host
    if domain.hasSuffix(".\(host)") { return true }
    return false
  }
}
