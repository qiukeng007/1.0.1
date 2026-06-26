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
    if let controller = window?.rootViewController as? FlutterViewController {
      SmartEyePlugin.registerMessenger(controller.binaryMessenger)
    }
  }

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
