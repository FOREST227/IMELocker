import Foundation

struct ReleaseVersion: Comparable {
  private let numbers: [Int]
  private let prerelease: [String]

  init?(_ text: String) {
    let normalized = text.hasPrefix("v") ? String(text.dropFirst()) : text
    let version = normalized.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)[0]
    let parts = version.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
    let components = parts[0].split(separator: ".", omittingEmptySubsequences: false)
    guard components.count == 3 else { return nil }
    let parsed = components.compactMap { component -> Int? in
      guard !component.isEmpty, component.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
      return Int(component)
    }
    guard parsed.count == 3 else { return nil }
    numbers = parsed
    prerelease = parts.count == 2 ? parts[1].components(separatedBy: ".") : []
    guard prerelease.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") } }) else { return nil }
  }

  static func < (lhs: Self, rhs: Self) -> Bool {
    if lhs.numbers != rhs.numbers {
      return lhs.numbers.lexicographicallyPrecedes(rhs.numbers)
    }
    if lhs.prerelease.isEmpty { return false }
    if rhs.prerelease.isEmpty { return true }
    for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
      if let l = Int(left), let r = Int(right) { return l < r }
      if Int(left) != nil { return true }
      if Int(right) != nil { return false }
      return left < right
    }
    return lhs.prerelease.count < rhs.prerelease.count
  }

  static func isNewer(_ remote: String, than local: String) -> Bool {
    guard let remote = Self(remote), let local = Self(local) else { return false }
    return remote > local
  }
}

/// Called from the main thread; results are always delivered asynchronously on it.
final class UpdateChecker {
  private let session: URLSession
  private var cached: (version: String, date: Date)?
  private var pending: [(String?) -> Void] = []
  private var task: URLSessionDataTask?

  init(session: URLSession = .shared) { self.session = session }
  deinit { task?.cancel() }

  func check(completion: @escaping (String?) -> Void) {
    if let cached, Date().timeIntervalSince(cached.date) < 15 * 60 {
      DispatchQueue.main.async { completion(cached.version) }
      return
    }
    pending.append(completion)
    guard task == nil else { return }
    var request = URLRequest(url: URL(string: "https://api.github.com/repos/Forest227/IMELocker/releases/latest")!)
    request.timeoutInterval = 3
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    task = session.dataTask(with: request) { [weak self] data, response, error in
      var version: String?
      if error == nil, let response = response as? HTTPURLResponse, response.statusCode == 200,
         let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
         let tag = json["tag_name"] as? String, ReleaseVersion(tag) != nil {
        version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
      }
      let resolvedVersion = version
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.task = nil
        if let resolvedVersion { self.cached = (resolvedVersion, Date()) }
        let callbacks = self.pending
        self.pending.removeAll()
        callbacks.forEach { $0(resolvedVersion) }
      }
    }
    task?.resume()
  }
}
