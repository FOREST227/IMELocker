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
  }

  private let log = Logger(subsystem: AppConstants.loggerSubsystem, category: "InputSourceLockService")
  private let defaults: UserDefaults
  private let system: InputSourceSystem
  private let systemNotificationCenter: DistributedNotificationCenter
  private let workspaceNotificationCenter = NSWorkspace.shared.notificationCenter
  private var enforceWorkItem: DispatchWorkItem?
  private var periodicCheckTimer: Timer?
  private var hasStarted = false

  private let handlerQueue = DispatchQueue(label: "com.inputsourcelock.handlers")
  private var stateChangeHandlers: [UUID: () -> Void] = [:]

  // 输入法列表缓存，在 kTISNotifyEnabledKeyboardInputSourcesChanged 时失效
  private var cachedSelectableSources: [InputSource]?

  private enum DefaultsKey {
    static let enabled = "enabled"
    static let targetID = "targetInputSourceID"
  }

  init(
    defaults: UserDefaults = .standard,
    system: InputSourceSystem = CarbonInputSourceSystem(),
    notificationCenter: DistributedNotificationCenter = .default()
  ) {
    self.defaults = defaults
    self.system = system
    self.systemNotificationCenter = notificationCenter
  }

  var lockStatus: LockStatus {
    guard isEnabled else { return .disabled }
    guard targetInputSourceID != nil else { return .noTarget }
    guard targetInputSource() != nil else { return .targetUnavailable }
    guard !isSecureInputEnabled else { return .paused }
    return currentInputSource()?.id == targetInputSourceID ? .locked : .restoring
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
      if newValue {
        if hasStarted { startPeriodicCheck() }
      } else {
        enforceWorkItem?.cancel()
        periodicCheckTimer?.invalidate()
        periodicCheckTimer = nil
      }
      notifyStateChanged()
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
      notifyStateChanged()
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
    timer.tolerance = 0.2
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

  private func scheduleEnforce(reason: String) {
    enforceWorkItem?.cancel()
    let item = DispatchWorkItem { [weak self] in
      self?.enforceNow(reason: reason)
    }
    enforceWorkItem = item
    DispatchQueue.main.asyncAfter(deadline: .now() + Timing.enforceDelay, execute: item)
  }

  private func enforceNow(reason: String) {
    defer { notifyStateChanged() }
    guard isEnabled else { return }
    guard !isSecureInputEnabled else { return }
    guard let targetID = targetInputSourceID else { return }

    let current = currentInputSource()
    if current?.id == targetID { return }

    guard let status = system.selectInputSource(id: targetID) else {
      log.error("Target input source not found: \(targetID, privacy: .public)")
      return
    }

    if status != noErr {
      log.error("TISSelectInputSource failed: \(status, privacy: .public) reason=\(reason, privacy: .public)")
    } else {
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

  @objc private func inputSourceChanged(_ notification: Notification) {
    enforce(reason: "inputSourceChanged")
    notifyStateChanged()
  }

  @objc private func inputSourcesEnabledChanged(_ notification: Notification) {
    cachedSelectableSources = nil
    autoPickWeChatIfNeeded()
    enforce(reason: "inputSourcesEnabledChanged")
    notifyStateChanged()
  }

  @objc private func activeAppChanged(_ notification: Notification) {
    enforce(reason: "activeAppChanged")
    notifyStateChanged()
  }

  private func handlePeriodicCheck() {
    guard isEnabled else { return }
    // Also refresh the list as a fallback for missed distributed notifications.
    cachedSelectableSources = nil
    autoPickWeChatIfNeeded()
    enforce(reason: "periodicCheck")
  }

  private func matchesWeChatByName(_ source: InputSource) -> Bool {
    let normalizedName = source.name.lowercased()
    return source.name.contains("微信") || normalizedName.contains("wechat")
  }

  private func matchesWeChatByID(_ source: InputSource) -> Bool {
    let normalizedID = source.id.lowercased()
    return normalizedID.contains("tencent") || normalizedID.contains("wechat")
  }

  private func notifyStateChanged() {
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
