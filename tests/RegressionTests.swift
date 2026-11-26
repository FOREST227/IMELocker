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
  var selectableListQueries = 0
  var selectStatus: OSStatus = noErr
  var isSecureInputEnabled: Bool { secure }
  func selectableInputSources() -> [InputSource] {
    selectableListQueries += 1
    return sources
  }
  func currentInputSource() -> InputSource? { current }
  func selectInputSource(id: String) -> OSStatus? {
    guard let source = sources.first(where: { $0.id == id }) else { return nil }
    selections.append(id)
    if selectStatus == noErr {
      current = source
    }
    return selectStatus
  }
}

final class FakeFrontmostAppProvider: FrontmostAppProvider {
  var currentApp: RunningAppInfo? = RunningAppInfo(bundleIdentifier: "com.apple.Safari", localizedName: "Safari")
  func frontmostApp() -> RunningAppInfo? { currentApp }
}

final class FakeUserActivityProvider: UserActivityProvider {
  var idleSeconds: TimeInterval = 10.0
  var hasActiveModifierKeys = false
  var hasPressedMouseButtons = false
  func secondsSinceLastKeyboardActivity() -> TimeInterval { idleSeconds }
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
  static var lastRequest: URLRequest?
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [self] in
      Self.requests += 1
      Self.lastRequest = request
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
    let workspaceNotifications = NotificationCenter()
    let frontmostProvider = FakeFrontmostAppProvider()
    let userActivityProvider = FakeUserActivityProvider()
    let service = InputSourceLockService(
      defaults: defaults,
      system: system,
      notificationCenter: notifications,
      workspaceNotificationCenter: workspaceNotifications,
      frontmostAppProvider: frontmostProvider,
      userActivityProvider: userActivityProvider
    )
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

    system.current = InputSource(id: "test.abc", name: "ABC")
    workspaceNotifications.post(name: NSWorkspace.didWakeNotification, object: nil)
    waitUntil("system wake restores target immediately", timeout: 1) {
      system.current.id == "test.ime"
    }
    system.current = InputSource(id: "test.abc", name: "ABC")
    workspaceNotifications.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
    waitUntil("session unlock restores target immediately", timeout: 1) {
      system.current.id == "test.ime"
    }

    var stateCallbackCount = 0
    let handlerID = service.addStateChangeHandler { stateCallbackCount += 1 }
    let queriesBeforeIdle = system.selectableListQueries
    service.enforceSync(reason: "idle-1")
    service.enforceSync(reason: "idle-2")
    expect(stateCallbackCount == 0, "idle enforce must not fire redundant state change notifications")
    expect(system.selectableListQueries == queriesBeforeIdle, "idle enforce must reuse cached input sources")

    service.isEnabled = false
    stateCallbackCount = 0
    system.current = InputSource(id: "test.abc", name: "ABC")
    service.lock(to: "test.ime", reason: "atomic-lock")
    expect(system.current.id == "test.ime" && service.lockStatus == .locked, "atomic lock activates target")
    expect(stateCallbackCount == 1, "atomic lock notifies observers once")
    service.removeStateChangeHandler(handlerID)

    system.selectStatus = OSStatus(-50)
    system.current = InputSource(id: "test.abc", name: "ABC")
    service.enforceSync(reason: "fail-1")
    expect(service.currentEnforceDelay() >= 0.10, "first failure backs off enforce delay")
    service.enforceSync(reason: "fail-2")
    expect(service.currentEnforceDelay() >= 0.20, "consecutive failures increase backoff")
    system.selectStatus = noErr
    service.enforceSync(reason: "recover")
    expect(system.current.id == "test.ime" && service.currentEnforceDelay() == InputSourceLockService.defaultEnforceDelay,
           "recovery resets failure backoff")

    for _ in 0..<5 {
      system.current = InputSource(id: "test.abc", name: "ABC")
      service.enforceSync(reason: "bounce")
    }
    expect(service.currentEnforceDelay() >= 0.10, "rapid bounce loop backs off enforce delay")
    service.lock(to: "test.ime", reason: "reset-backoff")
    expect(service.currentEnforceDelay() == InputSourceLockService.defaultEnforceDelay, "explicit lock resets backoff")

    // Active typing strictly refuses background restoration until typing pauses.
    userActivityProvider.idleSeconds = 0.05
    system.current = InputSource(id: "test.abc", name: "ABC")
    notifications.deliver(kTISNotifySelectedKeyboardInputSourceChanged)
    RunLoop.main.run(until: Date().addingTimeInterval(0.25))
    expect(system.current.id == "test.abc", "active typing refuses automatic input source restoration")
    userActivityProvider.idleSeconds = 1.0
    waitUntil("restores target after typing pauses", timeout: 1.5) {
      system.current.id == "test.ime"
    }

    // Holding modifier keys (e.g. Shift / Command) strictly refuses switching until released.
    userActivityProvider.hasActiveModifierKeys = true
    system.current = InputSource(id: "test.abc", name: "ABC")
    notifications.deliver(kTISNotifySelectedKeyboardInputSourceChanged)
    RunLoop.main.run(until: Date().addingTimeInterval(0.35))
    expect(system.current.id == "test.abc", "held modifier key refuses switching")
    userActivityProvider.hasActiveModifierKeys = false
    waitUntil("restores target after modifier key is released", timeout: 1.5) {
      system.current.id == "test.ime"
    }

    // Holding mouse buttons (e.g. selecting text or clicking candidates) strictly refuses switching until released.
    userActivityProvider.hasPressedMouseButtons = true
    system.current = InputSource(id: "test.abc", name: "ABC")
    notifications.deliver(kTISNotifySelectedKeyboardInputSourceChanged)
    RunLoop.main.run(until: Date().addingTimeInterval(0.35))
    expect(system.current.id == "test.abc", "pressed mouse button refuses switching")
    userActivityProvider.hasPressedMouseButtons = false
    waitUntil("restores target after mouse button is released", timeout: 1.5) {
      system.current.id == "test.ime"
    }

    // Mode-enabled parent containers are filtered out when their concrete child modes exist.
    let filteredSources = CarbonInputSourceSystem.filterSelectableSources([
      .init(id: "com.tencent.inputmethod.wetype", name: "微信输入法", isModeEnabledParent: true, isInputMode: false),
      .init(id: "com.tencent.inputmethod.wetype.pinyin", name: "微信输入法", isModeEnabledParent: false, isInputMode: true),
      .init(id: "com.example.standalone", name: "Standalone IME", isModeEnabledParent: true, isInputMode: false),
      .init(id: "com.apple.keylayout.ABC", name: "ABC", isModeEnabledParent: false, isInputMode: false),
    ])
    expect(filteredSources.map(\.id) == [
      "com.apple.keylayout.ABC",
      "com.example.standalone",
      "com.tencent.inputmethod.wetype.pinyin",
    ], "redundant mode-enabled parent container must be filtered out")

    // Legacy saved parent target ID automatically upgrades to its child input mode,
    // and reporting the parent ID as current must not trigger redundant re-selection.
    let upgradeSuite = "IMELocker.parent-upgrade.\(UUID().uuidString)"
    let upgradeDefaults = UserDefaults(suiteName: upgradeSuite)!
    defer { upgradeDefaults.removePersistentDomain(forName: upgradeSuite) }
    upgradeDefaults.set("com.tencent.inputmethod.wetype", forKey: "targetInputSourceID")
    let upgradeSystem = FakeInputSystem()
    upgradeSystem.sources = [
      InputSource(id: "com.tencent.inputmethod.wetype.pinyin", name: "微信输入法"),
      InputSource(id: "com.apple.keylayout.ABC", name: "ABC"),
    ]
    upgradeSystem.current = InputSource(id: "com.tencent.inputmethod.wetype", name: "微信输入法")
    let upgradeService = InputSourceLockService(
      defaults: upgradeDefaults,
      system: upgradeSystem,
      notificationCenter: TestDistributedCenter(),
      workspaceNotificationCenter: NotificationCenter(),
      frontmostAppProvider: FakeFrontmostAppProvider(),
      userActivityProvider: FakeUserActivityProvider()
    )
    upgradeService.start()
    expect(upgradeService.targetInputSourceID == "com.tencent.inputmethod.wetype.pinyin",
           "saved parent target ID must upgrade to concrete child input mode")
    expect(upgradeService.lockStatus == .locked, "parent container as current counts as locked")
    upgradeService.enforceSync(reason: "parent-match")
    expect(upgradeSystem.selections.isEmpty, "matching parent container must not re-select")
    upgradeService.isEnabled = false

    let terminal = RunningAppInfo(bundleIdentifier: "com.apple.Terminal", localizedName: "Terminal")
    let safari = RunningAppInfo(bundleIdentifier: "com.apple.Safari", localizedName: "Safari")
    frontmostProvider.currentApp = terminal
    service.lock(to: "test.ime", reason: "app-exclusion-setup")
    service.setAppExcluded(true, app: terminal)
    expect(service.lockStatus == .pausedForApp, "excluded frontmost app pauses lock")
    expect(service.excludedApps() == [terminal], "excluded apps list retains display name")
    system.current = InputSource(id: "test.abc", name: "ABC")
    service.enforceSync(reason: "excluded-app-check")
    expect(system.current.id == "test.abc", "excluded app must not force-switch input source")
    frontmostProvider.currentApp = safari
    workspaceNotifications.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
    waitUntil("switching to non-excluded app resumes lock", timeout: 1) {
      system.current.id == "test.ime"
    }
    frontmostProvider.currentApp = terminal
    system.current = InputSource(id: "test.abc", name: "ABC")
    service.removeExcludedApp(bundleIdentifier: terminal.bundleIdentifier)
    expect(system.current.id == "test.ime" && service.lockStatus == .locked,
           "removing exclusion immediately restores target")
    service.setAppExcluded(true, app: terminal)
    service.clearExcludedApps()
    expect(service.excludedApps().isEmpty, "clearing exclusions empties list")

    service.isEnabled = false
    system.sources.append(InputSource(id: "test.new", name: "New IME"))
    expect(service.refreshSelectableInputSources().contains { $0.id == "test.new" },
           "menu open refresh picks up newly added sources even when unlocked")
    system.sources.removeAll { $0.id == "test.new" }

    expect(!SingleInstanceGuard.shouldExit(arguments: ["app"], bundleIdentifier: "com.forest227.IMELocker",
                                           currentPID: 100, otherActivePIDs: { _ in [100] }),
           "first instance must run")
    expect(SingleInstanceGuard.shouldExit(arguments: ["app"], bundleIdentifier: "com.forest227.IMELocker",
                                          currentPID: 100, otherActivePIDs: { _ in [99, 100] }),
           "duplicate instance must exit")
    expect(!SingleInstanceGuard.shouldExit(arguments: ["app", AppConstants.relaunchArgument],
                                           bundleIdentifier: "com.forest227.IMELocker",
                                           currentPID: 100, otherActivePIDs: { _ in [99, 100] }),
           "relaunch instance must be allowed")

    expect(StatusBarClickAction.resolve(eventType: .leftMouseUp, modifierFlags: []) == .openMenu,
           "left click opens menu")
    expect(StatusBarClickAction.resolve(eventType: .rightMouseUp, modifierFlags: []) == .toggleLock,
           "right click toggles lock")
    expect(StatusBarClickAction.resolve(eventType: .leftMouseUp, modifierFlags: .option) == .toggleLock,
           "option-click toggles lock")
    expect(StatusBarClickAction.resolve(eventType: .leftMouseUp, modifierFlags: .control) == .toggleLock,
           "control-click toggles lock")
    expect(SFSymbol.statusCandidates(for: .locked) != SFSymbol.statusCandidates(for: .disabled),
           "locked and unlocked status icons differ")
    expect(SFSymbol.statusCandidates(for: .pausedForApp) == SFSymbol.statusCandidates(for: .paused),
           "paused states share pause status icon")
    expect(SFSymbol.statusCandidates(for: .targetUnavailable) != SFSymbol.statusCandidates(for: .disabled),
           "unavailable target shows warning status icon")

    let migrationSuite = "IMELocker.migration.\(UUID().uuidString)"
    let migrationDefaults = UserDefaults(suiteName: migrationSuite)!
    defer { migrationDefaults.removePersistentDomain(forName: migrationSuite) }
    InputSourceLockService.migrateLegacyDefaults(
      from: ["enabled": false, "targetInputSourceID": "legacy.ime"],
      to: migrationDefaults
    )
    expect(migrationDefaults.object(forKey: "enabled") as? Bool == false, "legacy enabled flag migrates")
    expect(migrationDefaults.string(forKey: "targetInputSourceID") == "legacy.ime", "legacy target ID migrates")
    InputSourceLockService.migrateLegacyDefaults(
      from: ["enabled": true, "targetInputSourceID": "overwrite.ime"],
      to: migrationDefaults
    )
    expect(migrationDefaults.string(forKey: "targetInputSourceID") == "legacy.ime",
           "migration never overwrites existing preferences")

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
    expect(ReleaseProtocol.lastRequest?.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json",
           "GitHub API Accept header set")
    expect(ReleaseProtocol.lastRequest?.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("IMELocker/") == true,
           "GitHub API User-Agent header set")
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
