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

  /// Extract cookies from WKWebView's data store (handles HttpOnly)
  private func getCookies(for url: String, result: @escaping FlutterResult) {
    guard let siteURL = URL(string: url) else {
      result("")
      return
    }
    let store = WKWebsiteDataStore.default()
    store.httpCookieStore.getAllCookies { cookies in
      let filtered = cookies.filter { cookie in
        siteURL.host?.hasSuffix(cookie.domain.replacingOccurrences(of: ".", with: "")) == true
          || cookie.domain.contains(siteURL.host ?? "")
          || siteURL.host?.contains(cookie.domain.replacingOccurrences(of: ".", with: "")) == true
      }
      // Simpler: just get all cookies that match the domain loosely
      var allCookies: [HTTPCookie] = []
      for cookie in cookies {
        if let host = siteURL.host, host.contains(cookie.domain.replacingOccurrences(of: ".", with: "")) || cookie.domain.contains(host) {
          allCookies.append(cookie)
        }
      }
      // Fallback: if domain matching fails, return all cookies
      if allCookies.isEmpty {
        allCookies = cookies
      }
      let cookieStr = allCookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
      result(cookieStr)
    }
  }
}
