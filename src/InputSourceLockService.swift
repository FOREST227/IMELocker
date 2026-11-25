import Cocoa
import Carbon
import os.log

struct InputSource: Hashable {
  let id: String
  let name: String
}

final class InputSourceLockService {
  private enum Timing {
    static let enforceDelay: TimeInterval = 0.01
    static let periodicCheckInterval: TimeInterval = 5.0
    static let periodicCheckTolerance: TimeInterval = 0.5
    static let rapidSwitchWindow: TimeInterval = 2.5
    static let maxRapidSwitchesBeforeBackoff = 4
    static let backoffBaseDelay: TimeInterval = 0.05
    static let maxBackoffDelay: TimeInterval = 2.0
  }

  private struct ObservedState: Equatable {
    let isEnabled: Bool
    let targetInputSourceID: String?
    let lockStatus: LockStatus
    let currentInputSourceID: String?
    let currentInputSourceName: String?
  }

  private let log = Logger(subsystem: AppConstants.loggerSubsystem, category: "InputSourceLockService")
  private let defaults: UserDefaults
  private let system: InputSourceSystem
  private let systemNotificationCenter: DistributedNotificationCenter
  private let workspaceNotificationCenter: NotificationCenter
  private let frontmostAppProvider: FrontmostAppProvider
  private var enforceWorkItem: DispatchWorkItem?
  private var periodicCheckTimer: Timer?
  private var hasStarted = false

  private let handlerQueue = DispatchQueue(label: "com.forest227.IMELocker.handlers")
  private var stateChangeHandlers: [UUID: () -> Void] = [:]
  private var lastNotifiedState: ObservedState?

  private var consecutiveEnforceFailures = 0
  private var rapidSwitchCount = 0
  private var lastSwitchAttemptDate: Date?

  // 输入法列表缓存，在 kTISNotifyEnabledKeyboardInputSourcesChanged、菜单打开或系统唤醒时失效
  private var cachedSelectableSources: [InputSource]?

  private enum DefaultsKey {
    static let enabled = "enabled"
    static let targetID = "targetInputSourceID"
    static let excludedBundleIDs = "excludedBundleIDs"
    static let excludedAppNames = "excludedAppNames"
  }

  init(
    defaults: UserDefaults = .standard,
    system: InputSourceSystem = CarbonInputSourceSystem(),
    notificationCenter: DistributedNotificationCenter = .default(),
    workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
    frontmostAppProvider: FrontmostAppProvider = WorkspaceFrontmostAppProvider()
  ) {
    self.defaults = defaults
    self.system = system
    self.systemNotificationCenter = notificationCenter
    self.workspaceNotificationCenter = workspaceNotificationCenter
    self.frontmostAppProvider = frontmostAppProvider
    migrateLegacyDefaultsIfNeeded()
  }

  var lockStatus: LockStatus {
    computeLockStatus(current: currentInputSource(), selectableSources: nil)
  }

  func lockStatus(current: InputSource?, selectableSources: [InputSource]) -> LockStatus {
    computeLockStatus(current: current, selectableSources: selectableSources)
  }

  deinit {
    enforceWorkItem?.cancel()
    periodicCheckTimer?.invalidate()
    systemNotificationCenter.removeObserver(self)
    workspaceNotificationCenter.removeObserver(self)
  }

  @discardableResult
  func addStateChangeHandler(_ handler: @escaping () -> Void) -> UUID {
    let id = UUID()
    handlerQueue.sync { stateChangeHandlers[id] = handler }
    return id
  }

  func removeStateChangeHandler(_ id: UUID) {
    handlerQueue.sync { stateChangeHandlers[id] = nil }
  }

  var isEnabled: Bool {
    get { defaults.object(forKey: DefaultsKey.enabled) as? Bool ?? true }
    set {
      defaults.set(newValue, forKey: DefaultsKey.enabled)
      resetEnforceBackoff()
      if newValue {
        if hasStarted { startPeriodicCheck() }
      } else {
        enforceWorkItem?.cancel()
        periodicCheckTimer?.invalidate()
        periodicCheckTimer = nil
      }
      notifyStateChangedIfNeeded()
    }
  }

  var targetInputSourceID: String? {
    get { defaults.string(forKey: DefaultsKey.targetID) }
    set {
      if let newValue {
        defaults.set(newValue, forKey: DefaultsKey.targetID)
      } else {
        defaults.removeObject(forKey: DefaultsKey.targetID)
      }
      resetEnforceBackoff()
      notifyStateChangedIfNeeded()
    }
  }

  var isSecureInputEnabled: Bool {
    system.isSecureInputEnabled
  }

  func start() {
    guard !hasStarted else { return }
    hasStarted = true

    autoPickWeChatIfNeeded()
    observeSystemNotifications()
    startPeriodicCheck()
    enforce(reason: "start")
  }

  func lock(to targetID: String, reason: String) {
    defaults.set(targetID, forKey: DefaultsKey.targetID)
    defaults.set(true, forKey: DefaultsKey.enabled)
    resetEnforceBackoff()
    if hasStarted { startPeriodicCheck() }
    enforceNow(reason: reason)
  }

  @discardableResult
  func refreshSelectableInputSources() -> [InputSource] {
    cachedSelectableSources = nil
    return selectableInputSources()
  }

  func frontmostApp() -> RunningAppInfo? {
    frontmostAppProvider.frontmostApp()
  }

  var excludedBundleIdentifiers: Set<String> {
    Set(defaults.stringArray(forKey: DefaultsKey.excludedBundleIDs) ?? [])
  }

  func excludedApps() -> [RunningAppInfo] {
    let savedNames = defaults.dictionary(forKey: DefaultsKey.excludedAppNames) as? [String: String] ?? [:]
    return excludedBundleIdentifiers
      .map { bundleID in
        RunningAppInfo(bundleIdentifier: bundleID, localizedName: savedNames[bundleID] ?? bundleID)
      }
      .sorted { lhs, rhs in
        if lhs.localizedName == rhs.localizedName {
          return lhs.bundleIdentifier < rhs.bundleIdentifier
        }
        return lhs.localizedName.localizedStandardCompare(rhs.localizedName) == .orderedAscending
      }
  }

  func isAppExcluded(bundleIdentifier: String) -> Bool {
    excludedBundleIdentifiers.contains(bundleIdentifier)
  }

  var isCurrentAppExcluded: Bool {
    guard let app = frontmostAppProvider.frontmostApp() else { return false }
    return isAppExcluded(bundleIdentifier: app.bundleIdentifier)
  }

  func setAppExcluded(_ excluded: Bool, app: RunningAppInfo) {
    var ids = excludedBundleIdentifiers
    var names = defaults.dictionary(forKey: DefaultsKey.excludedAppNames) as? [String: String] ?? [:]
    if excluded {
      ids.insert(app.bundleIdentifier)
      names[app.bundleIdentifier] = app.localizedName
    } else {
      ids.remove(app.bundleIdentifier)
      names.removeValue(forKey: app.bundleIdentifier)
    }
    defaults.set(Array(ids).sorted(), forKey: DefaultsKey.excludedBundleIDs)
    defaults.set(names, forKey: DefaultsKey.excludedAppNames)
    resetEnforceBackoff()
    if !excluded && isEnabled {
      enforceNow(reason: "appExclusionRemoved")
    } else {
      notifyStateChangedIfNeeded()
    }
  }

  func toggleExclusion(for app: RunningAppInfo) {
    setAppExcluded(!isAppExcluded(bundleIdentifier: app.bundleIdentifier), app: app)
  }

  func removeExcludedApp(bundleIdentifier: String) {
    setAppExcluded(false, app: RunningAppInfo(bundleIdentifier: bundleIdentifier, localizedName: bundleIdentifier))
  }

  func clearExcludedApps() {
    defaults.removeObject(forKey: DefaultsKey.excludedBundleIDs)
    defaults.removeObject(forKey: DefaultsKey.excludedAppNames)
    resetEnforceBackoff()
    if isEnabled {
      enforceNow(reason: "clearExcludedApps")
    } else {
      notifyStateChangedIfNeeded()
    }
  }

  private func observeSystemNotifications() {
    // Carbon TIS posts CF distributed notifications, not local Foundation notifications.
    systemNotificationCenter.addObserver(
      self,
      selector: #selector(inputSourceChanged(_:)),
      name: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
      object: nil,
      suspensionBehavior: .deliverImmediately
    )
    systemNotificationCenter.addObserver(
      self,
      selector: #selector(inputSourcesEnabledChanged(_:)),
      name: NSNotification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String),
      object: nil,
      suspensionBehavior: .deliverImmediately
    )

    workspaceNotificationCenter.addObserver(
      self,
      selector: #selector(activeAppChanged(_:)),
      name: NSWorkspace.didActivateApplicationNotification,
      object: nil
    )
    workspaceNotificationCenter.addObserver(
      self,
      selector: #selector(systemDidWake(_:)),
      name: NSWorkspace.didWakeNotification,
      object: nil
    )
    workspaceNotificationCenter.addObserver(
      self,
      selector: #selector(systemDidWake(_:)),
      name: NSWorkspace.screensDidWakeNotification,
      object: nil
    )
    workspaceNotificationCenter.addObserver(
      self,
      selector: #selector(systemDidWake(_:)),
      name: NSWorkspace.sessionDidBecomeActiveNotification,
      object: nil
    )
  }

  private func startPeriodicCheck() {
    guard isEnabled else { return }
    periodicCheckTimer?.invalidate()

    let timer = Timer(
      timeInterval: Timing.periodicCheckInterval,
      repeats: true
    ) { [weak self] _ in
      self?.handlePeriodicCheck()
    }
    timer.tolerance = Timing.periodicCheckTolerance
    RunLoop.main.add(timer, forMode: .common)
    periodicCheckTimer = timer
  }

  func selectableInputSources() -> [InputSource] {
    if let cached = cachedSelectableSources {
      return cached
    }
    let sources = system.selectableInputSources()
    cachedSelectableSources = sources
    return sources
  }

  func currentInputSource() -> InputSource? { system.currentInputSource() }

  func targetInputSource() -> InputSource? {
    guard let id = targetInputSourceID else { return nil }
    return selectableInputSources().first(where: { $0.id == id })
  }

  func enforce(reason: String) {
    scheduleEnforce(reason: reason)
  }

  func enforceSync(reason: String) {
    enforceNow(reason: reason)
  }

  func currentEnforceDelay(now: Date = Date()) -> TimeInterval {
    let effectiveRapidCount: Int
    if let lastAttempt = lastSwitchAttemptDate,
       now.timeIntervalSince(lastAttempt) < Timing.rapidSwitchWindow {
      effectiveRapidCount = rapidSwitchCount
    } else {
      effectiveRapidCount = 0
    }
    let rapidExcess = max(0, effectiveRapidCount - Timing.maxRapidSwitchesBeforeBackoff)
    let backoffSteps = max(consecutiveEnforceFailures, rapidExcess)
    guard backoffSteps > 0 else { return Timing.enforceDelay }
    let exponent = min(backoffSteps - 1, 10)
    return min(Timing.backoffBaseDelay * Double(1 << exponent), Timing.maxBackoffDelay)
  }

  private func resetEnforceBackoff() {
    consecutiveEnforceFailures = 0
    rapidSwitchCount = 0
    lastSwitchAttemptDate = nil
  }

  private func scheduleEnforce(reason: String) {
    enforceWorkItem?.cancel()
    let delay = currentEnforceDelay()
    let item = DispatchWorkItem { [weak self] in
      self?.enforceNow(reason: reason)
    }
    enforceWorkItem = item
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
  }

  private func enforceNow(reason: String) {
    defer { notifyStateChangedIfNeeded() }
    guard isEnabled else { return }
    guard !isSecureInputEnabled else { return }
    guard !isCurrentAppExcluded else { return }
    guard let targetID = targetInputSourceID else { return }

    let current = currentInputSource()
    if current?.id == targetID {
      consecutiveEnforceFailures = 0
      return
    }

    let now = Date()
    if let lastAttempt = lastSwitchAttemptDate,
       now.timeIntervalSince(lastAttempt) < Timing.rapidSwitchWindow {
      rapidSwitchCount += 1
    } else {
      rapidSwitchCount = 1
    }
    lastSwitchAttemptDate = now

    guard let status = system.selectInputSource(id: targetID) else {
      cachedSelectableSources = nil
      consecutiveEnforceFailures = 0
      log.error("Target input source not found: \(targetID, privacy: .public)")
      return
    }

    if status != noErr {
      consecutiveEnforceFailures += 1
      log.error("TISSelectInputSource failed: \(status, privacy: .public) reason=\(reason, privacy: .public)")
    } else {
      consecutiveEnforceFailures = 0
      log.debug("Switched input source: \(targetID, privacy: .public) reason=\(reason, privacy: .public)")
    }
  }

  private func autoPickWeChatIfNeeded() {
    guard targetInputSourceID == nil else { return }

    let candidates = selectableInputSources()
    if let wechat = candidates.first(where: matchesWeChatByName) {
      targetInputSourceID = wechat.id
      log.debug("Auto-picked target input source: \(wechat.id, privacy: .public)")
      return
    }

    if let wechat = candidates.first(where: matchesWeChatByID) {
      targetInputSourceID = wechat.id
      log.debug("Auto-picked target input source by id: \(wechat.id, privacy: .public)")
    }
  }

  static func migrateLegacyDefaults(from legacy: [String: Any], to defaults: UserDefaults) {
    guard defaults.object(forKey: DefaultsKey.enabled) == nil,
          defaults.object(forKey: DefaultsKey.targetID) == nil else { return }
    if let enabled = legacy[DefaultsKey.enabled] as? Bool {
      defaults.set(enabled, forKey: DefaultsKey.enabled)
    }
    if let targetID = legacy[DefaultsKey.targetID] as? String {
      defaults.set(targetID, forKey: DefaultsKey.targetID)
    }
  }

  private func migrateLegacyDefaultsIfNeeded() {
    guard defaults === UserDefaults.standard else { return }
    guard let legacy = defaults.persistentDomain(forName: AppConstants.legacyBundleIdentifier) else { return }
    Self.migrateLegacyDefaults(from: legacy, to: defaults)
  }

  @objc private func inputSourceChanged(_ notification: Notification) {
    if isEnabled {
      enforce(reason: "inputSourceChanged")
    }
    notifyStateChangedIfNeeded()
  }

  @objc private func inputSourcesEnabledChanged(_ notification: Notification) {
    cachedSelectableSources = nil
    autoPickWeChatIfNeeded()
    if isEnabled {
      enforce(reason: "inputSourcesEnabledChanged")
    }
    notifyStateChangedIfNeeded()
  }

  @objc private func activeAppChanged(_ notification: Notification) {
    if isEnabled {
      enforce(reason: "activeAppChanged")
    }
    notifyStateChangedIfNeeded()
  }

  @objc private func systemDidWake(_ notification: Notification) {
    cachedSelectableSources = nil
    resetEnforceBackoff()
    autoPickWeChatIfNeeded()
    if isEnabled {
      enforce(reason: "systemDidWake")
    }
    notifyStateChangedIfNeeded()
  }

  private func handlePeriodicCheck() {
    guard isEnabled else { return }
    if targetInputSourceID == nil || targetInputSource() == nil {
      // Refresh list only when target is unset or missing, as a fallback for missed notifications.
      cachedSelectableSources = nil
      autoPickWeChatIfNeeded()
    }
    enforce(reason: "periodicCheck")
  }

  private func computeLockStatus(current: InputSource?, selectableSources: [InputSource]?) -> LockStatus {
    guard isEnabled else { return .disabled }
    guard let targetID = targetInputSourceID else { return .noTarget }
    let available = selectableSources ?? self.selectableInputSources()
    guard available.contains(where: { $0.id == targetID }) else { return .targetUnavailable }
    guard !isSecureInputEnabled else { return .paused }
    guard !isCurrentAppExcluded else { return .pausedForApp }
    return current?.id == targetID ? .locked : .restoring
  }

  private func matchesWeChatByName(_ source: InputSource) -> Bool {
    let normalizedName = source.name.lowercased()
    return source.name.contains("微信") || normalizedName.contains("wechat")
  }

  private func matchesWeChatByID(_ source: InputSource) -> Bool {
    let normalizedID = source.id.lowercased()
    return normalizedID.contains("tencent") || normalizedID.contains("wechat")
  }

  private func notifyStateChangedIfNeeded() {
    let current = currentInputSource()
    let snapshot = ObservedState(
      isEnabled: isEnabled,
      targetInputSourceID: targetInputSourceID,
      lockStatus: computeLockStatus(current: current, selectableSources: nil),
      currentInputSourceID: current?.id,
      currentInputSourceName: current?.name
    )
    guard snapshot != lastNotifiedState else { return }
    lastNotifiedState = snapshot

    let handlers: [() -> Void] = handlerQueue.sync {
      Array(stateChangeHandlers.values)
    }
    guard !handlers.isEmpty else { return }

    if Thread.isMainThread {
      handlers.forEach { $0() }
    } else {
      DispatchQueue.main.async {
        handlers.forEach { $0() }
      }
    }
  }
}
