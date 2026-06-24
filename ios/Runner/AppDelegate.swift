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
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // Register audio channels with the engine's binary messenger
    // At this point window?.rootViewController should be a FlutterViewController
    if let controller = window?.rootViewController as? FlutterViewController {
      SmartEyePlugin.registerMessenger(controller.binaryMessenger)
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

  // MARK: - Cookie helpers

  private func getCookies(for url: String, result: @escaping FlutterResult) {
    // sharedCookiesEnabled makes WKWebView use WKWebsiteDataStore.default()
    // Read from there AND copy to NSHTTPCookieStorage (dart:io needs it).
    WKWebsiteDataStore.default().httpCookieStore.getAllCookies { wkCookies in
      // Sync to NSHTTPCookieStorage so dart:io HttpClient can use them
      let shared = HTTPCookieStorage.shared
      for c in wkCookies { shared.setCookie(c) }
      let s = wkCookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
      result(s)
    }
  }
}
