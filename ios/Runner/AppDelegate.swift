import Flutter
import UIKit
import WebKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
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
          self.getCookies(for: url, result: result)
        } else {
          result(FlutterMethodNotImplemented)
        }
      }
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
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
