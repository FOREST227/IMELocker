import Cocoa
import Carbon

struct RunningAppInfo: Equatable, Hashable {
  let bundleIdentifier: String
  let localizedName: String
}

/// Isolates frontmost application lookup for per-app exclusion policy and testing.
protocol FrontmostAppProvider {
  func frontmostApp() -> RunningAppInfo?
}

struct WorkspaceFrontmostAppProvider: FrontmostAppProvider {
  func frontmostApp() -> RunningAppInfo? {
    guard let app = NSWorkspace.shared.frontmostApplication,
          let bundleID = app.bundleIdentifier,
          !bundleID.isEmpty else {
      return nil
    }
    if bundleID == Bundle.main.bundleIdentifier {
      return nil
    }
    let name = (app.localizedName?.isEmpty == false) ? app.localizedName! : bundleID
    return RunningAppInfo(bundleIdentifier: bundleID, localizedName: name)
  }
}

/// Reports live keyboard/mouse interaction state without requiring Accessibility or Input Monitoring permissions.
protocol UserActivityProvider {
  func secondsSinceLastKeyboardActivity() -> TimeInterval
  var hasActiveModifierKeys: Bool { get }
  var hasPressedMouseButtons: Bool { get }
}

struct CoreGraphicsUserActivityProvider: UserActivityProvider {
  func secondsSinceLastKeyboardActivity() -> TimeInterval {
    let keyDown = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
    let keyUp = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyUp)
    let flags = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .flagsChanged)
    return min(keyDown, min(keyUp, flags))
  }

  var hasActiveModifierKeys: Bool {
    !NSEvent.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
  }

  var hasPressedMouseButtons: Bool {
    NSEvent.pressedMouseButtons != 0
  }
}

/// Switches CJK / input-method sources through the focused app's Text Services Manager port
/// (the same path macOS's Input menu uses) to avoid the cross-process TISSelectInputSource race
/// where IMK activates and drops the input controller 1–8 ms later, leaving typing stuck in ASCII.
enum FocusedAppTSMSwitcher {
  private static let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
  private static let tsmPortName = "com.apple.tsm.portname" as CFString
  private static let selectMessageID: Int32 = 7
  private static let messageTimeout: CFTimeInterval = 0.25

  private typealias KeyFocusFn = @convention(c) (
    UnsafeMutablePointer<ProcessSerialNumber>,
    UnsafeMutablePointer<DarwinBoolean>
  ) -> Int32
  private typealias PSNToPIDFn = @convention(c) (
    UnsafePointer<ProcessSerialNumber>,
    UnsafeMutablePointer<pid_t>
  ) -> OSStatus
  private typealias RemotePortFn = @convention(c) (
    CFAllocator?,
    CFString,
    pid_t
  ) -> Unmanaged<CFMessagePort>?
  private typealias FlattenFn = @convention(c) (
    TISInputSource,
    UnsafeMutablePointer<Unmanaged<AnyObject>?>
  ) -> DarwinBoolean

  private static func symbol<T>(_ name: String, as _: T.Type) -> T? {
    dlsym(rtldDefault, name).map { unsafeBitCast($0, to: T.self) }
  }

  private static func focusedProcessPID() -> pid_t? {
    if let keyFocus = symbol("CPSGetKeyFocusProcess", as: KeyFocusFn.self),
       let psnToPID = symbol("GetProcessPID", as: PSNToPIDFn.self) {
      var psn = ProcessSerialNumber()
      var ignored: DarwinBoolean = false
      var pid: pid_t = -1
      if keyFocus(&psn, &ignored) == 0, psnToPID(&psn, &pid) == noErr, pid > 0 {
        return pid
      }
    }
    if let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier, frontPID > 0 {
      return frontPID
    }
    return nil
  }

  static func select(_ source: TISInputSource) -> Bool {
    guard let remotePort = symbol("CFMessagePortCreatePerProcessRemote", as: RemotePortFn.self),
          let flatten = symbol("_CreateFlattenedInputSource", as: FlattenFn.self),
          let pid = focusedProcessPID(),
          pid != ProcessInfo.processInfo.processIdentifier else {
      return false
    }

    var flatRef: Unmanaged<AnyObject>?
    guard flatten(source, &flatRef).boolValue,
          let flat = flatRef?.takeRetainedValue() else {
      return false
    }

    let request = ["tsmInputSourceSelectedInpSrcKey": flat] as CFDictionary
    guard let data = CFPropertyListCreateData(nil, request, .xmlFormat_v1_0, 0, nil)?.takeRetainedValue(),
          let port = remotePort(nil, tsmPortName, pid)?.takeRetainedValue() else {
      return false
    }

    var reply: Unmanaged<CFData>?
    let status = CFMessagePortSendRequest(
      port,
      selectMessageID,
      data,
      messageTimeout,
      messageTimeout,
      CFRunLoopMode.defaultMode.rawValue,
      &reply
    )
    guard status == kCFMessagePortSuccess else { return false }

    if let replyData = reply?.takeRetainedValue(),
       let dict = CFPropertyListCreateWithData(nil, replyData, 0, nil, nil)?.takeRetainedValue() as? [String: Any],
       let error = dict["tsmInputModeReplyToServerErrorKey"] as? Int,
       error != 0 {
      return false
    }
    return true
  }
}

/// Isolates system input-source operations from lock policy.
protocol InputSourceSystem {
  var isSecureInputEnabled: Bool { get }
  func selectableInputSources() -> [InputSource]
  func currentInputSource() -> InputSource?
  func selectInputSource(id: String) -> OSStatus?
}

struct CarbonInputSourceSystem: InputSourceSystem {
  struct RawSourceDescriptor {
    let id: String
    let name: String
    let isModeEnabledParent: Bool
    let isInputMode: Bool
  }

  var isSecureInputEnabled: Bool { IsSecureEventInputEnabled() }

  func selectInputSource(id: String) -> OSStatus? {
    guard let source = inputSourceRef(byID: id),
          boolProperty(source, kTISPropertyInputSourceIsEnabled),
          boolProperty(source, kTISPropertyInputSourceIsSelectCapable) else { return nil }
    if isInputMethodOrMode(source), FocusedAppTSMSwitcher.select(source) {
      return noErr
    }
    return TISSelectInputSource(source)
  }

  func currentInputSource() -> InputSource? {
    guard let unmanaged = TISCopyCurrentKeyboardInputSource() else { return nil }
    let source = unmanaged.takeRetainedValue()
    guard let id = stringProperty(source, kTISPropertyInputSourceID) else { return nil }
    guard let name = stringProperty(source, kTISPropertyLocalizedName) else { return nil }
    return InputSource(id: id, name: name)
  }

  private func inputSourceRef(byID id: String) -> TISInputSource? {
    let filter = [kTISPropertyInputSourceID: id] as CFDictionary
    guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] else {
      return nil
    }
    return list.first
  }

  func selectableInputSources() -> [InputSource] {
    guard let list = TISCreateInputSourceList([kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource] as CFDictionary, false)?.takeRetainedValue() as? [TISInputSource] else {
      return []
    }

    let modeParentType = kTISTypeKeyboardInputMethodModeEnabled as String
    let inputModeType = kTISTypeKeyboardInputMode as String

    var descriptors: [RawSourceDescriptor] = []
    descriptors.reserveCapacity(list.count)
    for source in list {
      guard boolProperty(source, kTISPropertyInputSourceIsSelectCapable) else { continue }
      guard boolProperty(source, kTISPropertyInputSourceIsEnabled) else { continue }
      guard let id = stringProperty(source, kTISPropertyInputSourceID) else { continue }
      guard let name = stringProperty(source, kTISPropertyLocalizedName) else { continue }
      let type = stringProperty(source, kTISPropertyInputSourceType)
      descriptors.append(
        RawSourceDescriptor(
          id: id,
          name: name,
          isModeEnabledParent: type == modeParentType,
          isInputMode: type == inputModeType
        )
      )
    }

    return Self.filterSelectableSources(descriptors)
  }

  /// Drops mode-enabled parent containers (e.g. `com.tencent.inputmethod.wetype`) when their
  /// concrete child input modes (e.g. `com.tencent.inputmethod.wetype.pinyin`) are present.
  /// Selecting a parent container while TIS reports the child mode causes constant ID mismatch
  /// and repeated re-selection loops during typing.
  static func filterSelectableSources(_ descriptors: [RawSourceDescriptor]) -> [InputSource] {
    let inputModeIDs = descriptors.filter(\.isInputMode).map(\.id)
    var sources: [InputSource] = []
    sources.reserveCapacity(descriptors.count)

    for entry in descriptors {
      if entry.isModeEnabledParent {
        let prefix = entry.id + "."
        if inputModeIDs.contains(where: { $0.hasPrefix(prefix) }) {
          continue
        }
      }
      sources.append(InputSource(id: entry.id, name: entry.name))
    }

    // 稳定排序：先按名称，再按 id
    sources.sort { lhs, rhs in
      if lhs.name == rhs.name { return lhs.id < rhs.id }
      return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
    return sources
  }

  private func isInputMethodOrMode(_ source: TISInputSource) -> Bool {
    guard let type = stringProperty(source, kTISPropertyInputSourceType) else { return false }
    return type == (kTISTypeKeyboardInputMode as String)
      || type == (kTISTypeKeyboardInputMethodWithoutModes as String)
      || type == (kTISTypeKeyboardInputMethodModeEnabled as String)
  }

  private func anyProperty(_ source: TISInputSource, _ key: CFString) -> AnyObject? {
    guard let ptr = TISGetInputSourceProperty(source, key) else { return nil }
    return Unmanaged<AnyObject>.fromOpaque(ptr).takeUnretainedValue()
  }

  private func stringProperty(_ source: TISInputSource, _ key: CFString) -> String? {
    anyProperty(source, key) as? String
  }

  private func boolProperty(_ source: TISInputSource, _ key: CFString) -> Bool {
    guard let value = anyProperty(source, key) else { return false }
    if CFGetTypeID(value) == CFBooleanGetTypeID(), let bool = value as? Bool {
      return bool
    }
    if let number = value as? NSNumber { return number.boolValue }
    return false
  }
}
