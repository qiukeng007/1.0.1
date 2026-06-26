import UIKit
import Flutter
import WebKit
import AVFoundation

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var webViewUserScriptInstalled = false
  private var audioRecorder: AVAudioRecorder?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let session = AVAudioSession.sharedInstance()
    try? session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
    try? session.setActive(true)
    
    GeneratedPluginRegistrant.register(with: self)
    
    if let controller = window?.rootViewController as? FlutterViewController {
      setupAudioChannel(controller)
    }
    
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  private func setupAudioChannel(_ controller: FlutterViewController) {
    let channel = FlutterMethodChannel(name: "com.smarteye/audio_ios", binaryMessenger: controller.binaryMessenger)
    channel.setMethodCallHandler { [weak self] (call, result) in
      guard let self = self else { result(FlutterMethodNotImplemented); return }
      switch call.method {
      case "startRecord":
        guard let args = call.arguments as? [String: Any],
              let path = args["path"] as? String else {
          result(FlutterError(code: "INVALID_ARG", message: "path required", details: nil))
          return
        }
        let url = URL(fileURLWithPath: path)
        let settings: [String: Any] = [
          AVFormatIDKey: Int(kAudioFormatLinearPCM),
          AVSampleRateKey: 16000.0,
          AVNumberOfChannelsKey: 1,
          AVLinearPCMBitDepthKey: 16,
          AVLinearPCMIsFloatKey: false,
          AVLinearPCMIsBigEndianKey: false,
          AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        do {
          self.audioRecorder = try AVAudioRecorder(url: url, settings: settings)
          self.audioRecorder?.record()
          result(true)
        } catch {
          result(FlutterError(code: "RECORD_FAIL", message: error.localizedDescription, details: nil))
        }
      case "stopRecord":
        self.audioRecorder?.stop()
        self.audioRecorder = nil
        result(true)
      default:
        result(FlutterMethodNotImplemented)
      }
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
