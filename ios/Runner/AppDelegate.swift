  private func cookieFile(_ key: String) -> URL {
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    return docs.appendingPathComponent(key + ".cookie")
  }

  private func saveAtomic(key: String, value: String, result: @escaping FlutterResult) {
    let url = cookieFile(key)
    let data = value.data(using: .utf8)!
    do {
      try data.write(to: url, options: .atomic)
      result(true)
    } catch {
      result(false)
    }
  }

  private func loadAtomic(key: String, result: @escaping FlutterResult) {
    let url = cookieFile(key)
    guard FileManager.default.fileExists(atPath: url.path) else {
      result(nil)
      return
    }
    do {
      let value = try String(contentsOf: url, encoding: .utf8)
      result(value)
    } catch {
      result(nil)
    }
  }

  