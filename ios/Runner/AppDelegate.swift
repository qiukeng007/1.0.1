import Flutter
import UIKit
import WebKit
import AVFoundation

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var webViewUserScriptInstalled = false

  // Audio recording state
  private var audioEngine: AVAudioEngine?
  private var audioFileHandle: FileHandle?
  private var audioDataSize: Int = 0
  private let audioSampleRate: Double = 16000

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    if let controller = window?.rootViewController as? FlutterViewController {
      let messenger = controller.binaryMessenger

      // ── Cookie channel ──
      let cookieChannel = FlutterMethodChannel(name: "com.smarteye/cookies", binaryMessenger: messenger)
      cookieChannel.setMethodCallHandler { (call, result) in
        if call.method == "getCookies" {
          guard let args = call.arguments as? [String: Any],
                let url = args["url"] as? String else {
            result("")
            return
          }
          self.installWindowOpenOverrideIfNeeded()
          self.getCookies(for: url, result: result)
        } else {
          result(FlutterMethodNotImplemented)
        }
      }

      // ── Audio recording channel (PCM WAV for offline ASR) ──
      let audioChannel = FlutterMethodChannel(name: "com.smarteye/audio", binaryMessenger: messenger)
      audioChannel.setMethodCallHandler { (call, result) in
        if call.method == "startRecord" {
          guard let args = call.arguments as? [String: Any],
                let path = args["path"] as? String else {
            result(FlutterError(code: "NO_PATH", message: "Missing path", details: nil))
            return
          }
          self.startRecording(path: path, result: result)
        } else if call.method == "stopRecord" {
          self.stopRecording(result: result)
        } else {
          result(FlutterMethodNotImplemented)
        }
      }

      // ── Audio play channel (beep feedback) ──
      let audioPlayChannel = FlutterMethodChannel(name: "com.smarteye/audio_play", binaryMessenger: messenger)
      audioPlayChannel.setMethodCallHandler { (call, result) in
        if call.method == "beep" {
          let start = (call.arguments as? [String: Any])?["start"] as? Bool ?? true
          self.playBeep(start: start)
          result(nil)
        } else {
          result(FlutterMethodNotImplemented)
        }
      }
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // MARK: - Audio Recording

  private func startRecording(path: String, result: @escaping FlutterResult) {
    // Check microphone permission
    switch AVAudioSession.sharedInstance().recordPermission {
    case .denied:
      result(FlutterError(code: "PERMISSION_DENIED", message: "麦克风权限被拒绝", details: nil))
      return
    case .undetermined:
      AVAudioSession.sharedInstance().requestRecordPermission { granted in
        DispatchQueue.main.async {
          if granted {
            self.startRecording(path: path, result: result)
          } else {
            result(FlutterError(code: "PERMISSION_DENIED", message: "麦克风权限被拒绝", details: nil))
          }
        }
      }
      return
    default:
      break
    }

    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.record, mode: .measurement, options: [])
      try session.setActive(true)

      audioEngine = AVAudioEngine()
      guard let engine = audioEngine else {
        result(FlutterError(code: "ENGINE_ERROR", message: "Failed to create audio engine", details: nil))
        return
      }

      let inputNode = engine.inputNode
      let inputFormat = inputNode.outputFormat(forBus: 0)

      // Convert to 16kHz mono 16-bit PCM (same as Android)
      guard let converter = AVAudioConverter(from: inputFormat, to: pcmFormat(sampleRate: audioSampleRate)) else {
        result(FlutterError(code: "CONVERTER_ERROR", message: "Failed to create audio converter", details: nil))
        return
      }

      // Prepare WAV file
      let fileURL = URL(fileURLWithPath: path)
      // Write placeholder WAV header (will be updated on stop)
      try Data(count: 44).write(to: fileURL)
      audioFileHandle = try FileHandle(forWritingTo: fileURL)
      audioFileHandle?.seek(toFileOffset: 44)
      audioDataSize = 0

      inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
        guard let self = self else { return }
        let targetCapacity = Int(Double(buffer.frameLength) * (self.audioSampleRate / inputFormat.sampleRate))
        guard let converted = AVAudioPCMBuffer(
          pcmFormat: self.pcmFormat(sampleRate: self.audioSampleRate),
          frameCapacity: AVAudioFrameCount(targetCapacity)
        ) else { return }

        var error: NSError?
        converter.convert(to: converted, error: &error) { _, _ in
          buffer
        }
        if error != nil { return }

        guard let channelData = converted.int16ChannelData else { return }
        let frames = Int(converted.frameLength)
        let data = Data(bytes: channelData.pointee, count: frames * 2) // 16-bit = 2 bytes
        self.audioFileHandle?.write(data)
        self.audioDataSize += data.count
      }

      try engine.start()
      result(true)

    } catch {
      result(FlutterError(code: "RECORD_ERROR", message: error.localizedDescription, details: nil))
    }
  }

  private func stopRecording(result: FlutterResult) {
    audioEngine?.inputNode.removeTap(onBus: 0)
    audioEngine?.stop()
    audioEngine = nil

    // Finalize WAV file: write RIFF header
    if let handle = audioFileHandle {
      let totalDataLen = audioDataSize + 36
      let byteRate = Int(audioSampleRate) * 2

      handle.seek(toFileOffset: 0)
      handle.write("RIFF".data(using: .ascii)!)
      handle.write(intLE(totalDataLen))
      handle.write("WAVE".data(using: .ascii)!)
      handle.write("fmt ".data(using: .ascii)!)
      handle.write(intLE(16))          // fmt chunk size
      handle.write(shortLE(1))         // PCM
      handle.write(shortLE(1))         // mono
      handle.write(intLE(Int(audioSampleRate)))
      handle.write(intLE(byteRate))
      handle.write(shortLE(2))         // block align
      handle.write(shortLE(16))        // bits per sample
      handle.write("data".data(using: .ascii)!)
      handle.write(intLE(audioDataSize))

      handle.closeFile()
      audioFileHandle = nil
      audioDataSize = 0
    }

    // Deactivate audio session
    try? AVAudioSession.sharedInstance().setActive(false)
    result(nil)
  }

  private func pcmFormat(sampleRate: Double) -> AVAudioFormat {
    return AVAudioFormat(
      commonFormat: .pcmFormatInt16,
      sampleRate: sampleRate,
      channels: 1,
      interleaved: false
    )!
  }

  // MARK: - Audio Playback (beep)

  private func playBeep(start: Bool) {
    // Use system sound for short beep feedback
    let soundID: SystemSoundID = start ? 1113 : 1114 // short beep / error beep
    AudioServicesPlaySystemSound(soundID)
  }

  // MARK: - WAV helpers

  private func intLE(_ v: Int) -> Data {
    var val = v
    return Data(bytes: &val, count: 4)
  }

  private func shortLE(_ v: Int) -> Data {
    var val = UInt16(v)
    return Data(bytes: &val, count: 2)
  }

  // MARK: - WKUserScript (window.open override)

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

  // MARK: - Cookie helpers

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
      let chosen = matched.isEmpty ? cookies : matched
      let cookieStr = chosen.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
      result(cookieStr)
    }
  }

  private func cookie(_ cookie: HTTPCookie, matchesHost host: String) -> Bool {
    let domain = cookie.domain
    if host == domain { return true }
    if domain.hasPrefix(".") {
      let rootDomain = String(domain.dropFirst())
      if host == rootDomain { return true }
      if host.hasSuffix(domain) { return true }
      return false
    }
    if host.hasSuffix(".\(domain)") || host == domain { return true }
    if domain.hasSuffix(".\(host)") { return true }
    return false
  }
}
