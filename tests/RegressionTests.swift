import Cocoa
import Carbon

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
  if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

final class FakeInputSystem: InputSourceSystem {
  var sources = [InputSource(id: "test.ime", name: "Test IME"), InputSource(id: "test.abc", name: "ABC")]
  var current = InputSource(id: "test.abc", name: "ABC")
  var secure = false
  var selections: [String] = []
  var isSecureInputEnabled: Bool { secure }
  func selectableInputSources() -> [InputSource] { sources }
  func currentInputSource() -> InputSource? { current }
  func selectInputSource(id: String) -> OSStatus? {
    guard let source = sources.first(where: { $0.id == id }) else { return nil }
    selections.append(id)
    current = source
    return noErr
  }
}

private func waitUntil(_ message: String, timeout: TimeInterval = 2, _ predicate: () -> Bool) {
  let deadline = Date().addingTimeInterval(timeout)
  while !predicate() && Date() < deadline {
    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
  }
  expect(predicate(), message)
}

// Only the transport is replaced; UpdateChecker's parsing, scheduling and cache run unchanged.
private final class ReleaseProtocol: URLProtocol {
  static var status = 200
  static var payload = "{\"tag_name\":\"v0.0.4\"}"
  static var requests = 0
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [self] in
      Self.requests += 1
      let response = HTTPURLResponse(url: request.url!, statusCode: Self.status,
                                     httpVersion: nil, headerFields: nil)!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: Data(Self.payload.utf8))
      client?.urlProtocolDidFinishLoading(self)
    }
  }
  override func stopLoading() {}
}

private final class TestDistributedCenter: DistributedNotificationCenter, @unchecked Sendable {
  private let local = NotificationCenter()
  override func addObserver(_ observer: Any, selector: Selector, name: Notification.Name?,
                            object: String?, suspensionBehavior: SuspensionBehavior) {
    expect(suspensionBehavior == .deliverImmediately, "background app must receive input events immediately")
    local.addObserver(observer, selector: selector, name: name, object: object)
  }
  override func removeObserver(_ observer: Any) { local.removeObserver(observer) }
  func deliver(_ name: CFString) {
    local.post(name: Notification.Name(name as String), object: nil)
  }
}

@main
struct RegressionTests {
  static func main() {
    // A lower/equal remote version must never be presented as an upgrade.
    for (remote, local, wanted) in [
      ("0.0.2", "0.0.3", false), ("v0.0.3", "0.0.3", false),
      ("0.0.10", "0.0.9", true), ("1.0.0", "0.9.9", true),
      ("1.0.0-beta.2", "1.0.0-beta.1", true),
      ("1.0.0-beta.10", "1.0.0-beta.2", true),
      ("1.0.0-beta", "1.0.0", false), ("1.0.0", "1.0.0-beta", true),
      ("1.0.0+build2", "1.0.0+build1", false), ("garbage", "1.0.0", false), ("", "1.0.0", false), ("v", "1.0.0", false)
    ] {
      expect(ReleaseVersion.isNewer(remote, than: local) == wanted, "version \(remote) vs \(local)")
    }

    let suite = "IMELocker.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let system = FakeInputSystem()
    let notifications = TestDistributedCenter()
    let service = InputSourceLockService(defaults: defaults, system: system, notificationCenter: notifications)
    runMenuTests(lockService: service)
    expect(service.lockStatus == .noTarget, "empty preferences cannot report locked")
    service.targetInputSourceID = "test.ime"
    expect(service.lockStatus == .restoring, "different input source is not locked yet")
    system.secure = true
    service.enforceSync(reason: "test")
    expect(service.lockStatus == .paused, "secure input pauses lock")
    expect(system.selections.isEmpty, "secure input must not change input source")
    system.secure = false
    service.enforceSync(reason: "test")
    expect(system.current.id == "test.ime", "lock resumes after secure input ends")
    expect(service.lockStatus == .locked, "successful selection reports locked")
    service.enforceSync(reason: "test")
    expect(system.selections.count == 1, "already selected source must not be selected again")
    service.isEnabled = false
    system.current = InputSource(id: "test.abc", name: "ABC")
    service.enforceSync(reason: "test")
    expect(system.selections.count == 1, "disabled lock must not switch")
    expect(service.lockStatus == .disabled, "disabled status")
    service.isEnabled = true
    service.targetInputSourceID = "removed.ime"
    expect(service.lockStatus == .targetUnavailable, "missing target must not report locked")
    service.enforceSync(reason: "test")
    expect(system.selections.count == 1, "missing target must not switch")
    service.targetInputSourceID = "test.ime"
    service.start()
    waitUntil("initial enforcement") { system.current.id == "test.ime" }
    system.current = InputSource(id: "test.abc", name: "ABC")
    notifications.deliver(kTISNotifySelectedKeyboardInputSourceChanged)
    waitUntil("distributed source change must restore target before periodic check", timeout: 1) {
      system.current.id == "test.ime"
    }
    system.sources.removeAll { $0.id == "test.ime" }
    notifications.deliver(kTISNotifyEnabledKeyboardInputSourcesChanged)
    expect(service.lockStatus == .targetUnavailable, "enabled-list event must invalidate cached target")
    system.sources.append(InputSource(id: "test.ime", name: "Test IME"))
    system.current = InputSource(id: "test.abc", name: "ABC")
    notifications.deliver(kTISNotifyEnabledKeyboardInputSourcesChanged)
    waitUntil("re-enabled target must resume lock", timeout: 1) { system.current.id == "test.ime" }
    system.secure = true
    system.current = InputSource(id: "test.abc", name: "ABC")
    notifications.deliver(kTISNotifySelectedKeyboardInputSourceChanged)
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    expect(system.current.id == "test.abc", "notification must respect secure input")
    system.secure = false
    waitUntil("periodic fallback resumes when secure input ends without a notification", timeout: 6) {
      system.current.id == "test.ime"
    }
    service.isEnabled = false

    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [ReleaseProtocol.self]
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel() }
    let checker = UpdateChecker(session: session)
    var results: [String?] = []
    checker.check { expect(Thread.isMainThread, "updates delivered on main thread"); results.append($0) }
    checker.check { results.append($0) }
    expect(results.isEmpty, "network check returns before delivering a result")
    var responsive = false
    DispatchQueue.main.async { responsive = results.isEmpty }
    waitUntil("main queue remains responsive during request", timeout: 0.1) { responsive }
    waitUntil("coalesced update results") { results.count == 2 }
    expect(results.allSatisfy { $0 == "0.0.4" }, "release tag normalization")
    expect(ReleaseProtocol.requests == 1, "concurrent checks share a request")
    checker.check { results.append($0) }
    waitUntil("cached update result") { results.count == 3 }
    expect(ReleaseProtocol.requests == 1, "cached checks must not repeat network request")
    expect(results.last! == "0.0.4", "cached version is retained")

    let retryChecker = UpdateChecker(session: session)
    ReleaseProtocol.status = 403
    results.removeAll()
    retryChecker.check { results.append($0) }
    waitUntil("HTTP failure result") { results.count == 1 }
    expect(results[0] == nil, "HTTP errors cannot advertise an update")
    ReleaseProtocol.status = 200
    retryChecker.check { results.append($0) }
    waitUntil("retry after HTTP error") { results.count == 2 }
    expect(results[1] == "0.0.4", "failed checks are not cached")
    if ProcessInfo.processInfo.environment["IMELOCKER_UI_TESTS"] == "1" {
      let app = NSApplication.shared
      app.setActivationPolicy(.prohibited)
      let alert = NSAlert()
      alert.messageText = "输入法锁定：自动化模态窗口测试"
      let label = NSTextField(labelWithString: "检查中")
      alert.accessoryView = label
      let modalChecker = UpdateChecker(session: session)
      var updated = false
      modalChecker.check { version in
        label.stringValue = version ?? "失败"
        updated = version == "0.0.4"
        app.abortModal()
      }
      let watchdog = Timer(timeInterval: 2, repeats: false) { _ in app.abortModal() }
      RunLoop.main.add(watchdog, forMode: .common)
      alert.runModal()
      watchdog.invalidate()
      alert.window.orderOut(nil)
      expect(updated && label.stringValue == "0.0.4", "update arrives inside NSAlert modal loop")
      print("PASS: asynchronous update in a real NSAlert modal loop")
    }
    print("PASS: versions, lock states, notifications, secure-input recovery, async updates and cache")
  }
}
