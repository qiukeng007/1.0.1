import Flutter
import UIKit
import AVFoundation
import AudioToolbox

/// Handles audio recording and playback for iOS.
class SmartEyePlugin: NSObject {
  private var audioEngine: AVAudioEngine?
  private var audioFileHandle: FileHandle?
  private var audioDataSize: Int = 0
  private let audioSampleRate: Double = 16000

  /// Register audio channels on the given binary messenger.
  static func registerMessenger(_ messenger: FlutterBinaryMessenger) {
    let instance = SmartEyePlugin()

    let audioChannel = FlutterMethodChannel(name: "com.smarteye/audio", binaryMessenger: messenger)
    audioChannel.setMethodCallHandler { [weak instance] (call, result) in
      instance?.handle(call, result: result)
    }

    let playChannel = FlutterMethodChannel(name: "com.smarteye/audio_play", binaryMessenger: messenger)
    playChannel.setMethodCallHandler { [weak instance] (call, result) in
      instance?.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "startRecord":
      guard let args = call.arguments as? [String: Any],
            let path = args["path"] as? String else {
        result(FlutterError(code: "NO_PATH", message: "Missing path", details: nil))
        return
      }
      startRecording(path: path, result: result)
    case "stopRecord":
      stopRecording(result: result)
    case "beep":
      let start = (call.arguments as? [String: Any])?["start"] as? Bool ?? true
      playBeep(start: start)
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Audio Recording

  private func startRecording(path: String, result: @escaping FlutterResult) {
    let session = AVAudioSession.sharedInstance()
    switch session.recordPermission {
    case .denied:
      result(FlutterError(code: "PERMISSION_DENIED", message: "麦克风权限被拒绝", details: nil))
      return
    case .undetermined:
      session.requestRecordPermission { granted in
        DispatchQueue.main.async {
          granted
            ? self.startRecording(path: path, result: result)
            : result(FlutterError(code: "PERMISSION_DENIED", message: "麦克风权限被拒绝", details: nil))
        }
      }
      return
    default: break
    }

    do {
      try session.setCategory(.record, mode: .default)
      try session.setActive(true)

      let engine = AVAudioEngine()
      audioEngine = engine
      let inputNode = engine.inputNode
      let nativeFormat = inputNode.outputFormat(forBus: 0)

      // Prep WAV file with placeholder header
      let fileURL = URL(fileURLWithPath: path)
      try Data(count: 44).write(to: fileURL)
      audioFileHandle = try FileHandle(forWritingTo: fileURL)
      audioFileHandle?.seek(toFileOffset: 44)
      audioDataSize = 0

      let dstRate = audioSampleRate
      let srcRate = nativeFormat.sampleRate

      inputNode.installTap(onBus: 0, bufferSize: 1024, format: nativeFormat) { [weak self] buffer, _ in
        guard let self = self, let handle = self.audioFileHandle,
              let floatData = buffer.floatChannelData else { return }

        let frameLen = Int(buffer.frameLength)
        let ratio = dstRate / srcRate
        let outLen = Int(Double(frameLen) * ratio)
        var samples = [Int16](repeating: 0, count: outLen)

        for i in 0..<outLen {
          let srcIdx = Double(i) / ratio
          let srcFrame = Int(srcIdx)
          let frac = Float(srcIdx - Double(srcFrame))
          let a: Float, b: Float
          if srcFrame + 1 < frameLen {
            a = floatData.pointee[srcFrame]; b = floatData.pointee[srcFrame + 1]
          } else if srcFrame < frameLen {
            a = floatData.pointee[srcFrame]; b = a
          } else {
            a = 0; b = 0
          }
          let val = a + (b - a) * frac
          samples[i] = Int16(max(-32768, min(32767, val * 32767)))
        }
        samples.withUnsafeBytes { handle.write(Data($0)) }
        self.audioDataSize += outLen * 2
      }

      engine.prepare()
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

    if let handle = audioFileHandle {
      let totalLen = audioDataSize + 36
      let byteRate = Int(audioSampleRate) * 2
      handle.seek(toFileOffset: 0)
      handle.write("RIFF".data(using: .ascii)!)
      handle.write(intLE(totalLen))
      handle.write("WAVE".data(using: .ascii)!)
      handle.write("fmt ".data(using: .ascii)!)
      handle.write(intLE(16))
      handle.write(shortLE(1)); handle.write(shortLE(1))
      handle.write(intLE(Int(audioSampleRate))); handle.write(intLE(byteRate))
      handle.write(shortLE(2)); handle.write(shortLE(16))
      handle.write("data".data(using: .ascii)!)
      handle.write(intLE(audioDataSize))
      handle.closeFile()
      audioFileHandle = nil
      audioDataSize = 0
    }
    try? AVAudioSession.sharedInstance().setActive(false)
    result(nil)
  }

  // MARK: - Beep

  private func playBeep(start: Bool) {
    let soundID: SystemSoundID = 1104
    AudioServicesPlaySystemSound(soundID)
  }

  // MARK: - WAV helpers

  private func intLE(_ v: Int) -> Data {
    var val = UInt32(v)
    return Data(bytes: &val, count: 4)
  }
  private func shortLE(_ v: Int) -> Data {
    var val = UInt16(v)
    return Data(bytes: &val, count: 2)
  }
}
