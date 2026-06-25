import Flutter
import UIKit
import WebKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var webViewUserScriptInstalled = false

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Register cookie persistence channel early, before any WebView is created
    if let controller = window?.rootViewController as? FlutterViewController {
      setupCookieChannel(controller)
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let controller = window?.rootViewController as? FlutterViewController {
      SmartEyePlugin.registerMessenger(controller.binaryMessenger)
      setupCookieChannel(controller)
    }
  }

  // MARK: - Cookie Persistence Channel

  private func setupCookieChannel(_ controller: FlutterViewController) {
    let channel = FlutterMethodChannel(
      name: "com.smarteye/cookies_persist",
      binaryMessenger: controller.binaryMessenger
    )
    channel.setMethodCallHandler { [weak self] (call, result) in
      guard let self = self else { result(FlutterMethodNotImplemented); return }
      switch call.method {
      case "getAllCookies":
        guard let url = call.arguments as? String, !url.isEmpty else {
          result(FlutterError(code: "INVALID_ARG", message: "url required", details: nil))
          return
        }
        self.getAllCookies(for: url, result: result)
      case "restoreCookies":
        guard let cookieStr = call.arguments as? String, !cookieStr.isEmpty else {
          result(nil)
          return
        }
        self.restoreCookies(cookieStr, result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func getAllCookies(for url: String, result: @escaping FlutterResult) {
    WKWebsiteDataStore.default().httpCookieStore.getAllCookies { wkCookies in
      let shared = HTTPCookieStorage.shared
      for c in wkCookies {
        shared.setCookie(c)
      }
      let s = wkCookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
      result(s)
    }
  }

  private func restoreCookies(_ cookieStr: String, result: @escaping FlutterResult) {
    let baseHost = "pospal.cn"
    let pairs = cookieStr.components(separatedBy: "; ")
    let group = DispatchGroup()
    for pair in pairs {
      let parts = pair.components(separatedBy: "=")
      guard parts.count >= 2 else { continue }
      let name = parts[0].trimmingCharacters(in: .whitespaces)
      let value = parts.dropFirst().joined(separator: "=").trimmingCharacters(in: .whitespaces)
      guard !name.isEmpty, !value.isEmpty else { continue }
      if let cookie = HTTPCookie(properties: [
        .domain: baseHost,
        .path: "/",
        .name: name,
        .value: value,
        .secure: "TRUE",
        .discard: "FALSE",
      ]) {
        group.enter()
        WKWebsiteDataStore.default().httpCookieStore.setCookie(cookie) {
          group.leave()
        }
      }
    }
    group.notify(queue: .main) {
      result(true)
    }
  }

  // MARK: - WKUserScript for window.open override

  private func installWindowOpenOverrideIfNeeded() {
    guard !webViewUserScriptInstalled else { return }
    guard let rootView = window?.rootViewController?.view else { return }
    if let webView = findWKWebView(in: rootView) {
      let script = """
        window.open=function(u,t,f){\
          if(u&&typeof u==='string'&&u!==''&&u!=='about:blank'){\
            try{window.location.href=u;}catch(e){}\
            try{window.location.replace(u);}catch(e){}\
          }\
          return window;\
        };
        """
      let userScript = WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false)
      webView.configuration.userContentController.addUserScript(userScript)
      webViewUserScriptInstalled = true
    }
  }

  private func findWKWebView(in view: UIView) -> WKWebView? {
    if let wv = view as? WKWebView { return wv }
    for sub in view.subviews { if let found = findWKWebView(in: sub) { return found } }
    return nil
  }
}

