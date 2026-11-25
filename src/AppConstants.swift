import Cocoa

/// SF Symbol 降级加载器。
/// 每个符号维护一条回退链：首选（SF Symbols 3+）→ 简化版 → 基础版（SF Symbols 1）。
/// macOS 12+ 对应 SF Symbols 3，但早期 12.0 构建可能存在个别缺失，
/// 因此所有链的最后一项均为 SF Symbols 1 就有的符号。
enum SFSymbol {
  // MARK: - 锁定状态图标（状态栏 + 菜单共用）

  static let statusLockEnabled = ["lock.shield.fill", "lock.shield", "lock.fill", "lock"]
  static let statusLockUnlocked = ["lock.open", "lock.slash", "lock"]
  static let statusLockPaused = ["pause.circle", "lock.shield", "lock"]
  static let statusLockWarning = ["exclamationmark.shield", "exclamationmark.triangle", "lock"]
  static let statusLockRestoring = ["lock.shield", "arrow.clockwise", "lock"]

  static func statusCandidates(for status: LockStatus) -> [String] {
    switch status {
    case .locked: return statusLockEnabled
    case .disabled: return statusLockUnlocked
    case .paused, .pausedForApp: return statusLockPaused
    case .targetUnavailable, .noTarget: return statusLockWarning
    case .restoring: return statusLockRestoring
    }
  }

  // MARK: - 菜单操作

  static let restart = ["arrow.clockwise", "arrow.2.circlepath"]
  static let quit = ["xmark.circle", "xmark.square", "xmark"]
  static let info = ["info.circle", "info"]
  static let openExternal = ["arrow.up.right.square", "arrow.up.right", "arrow.right"]
  static let excludedApps = ["nosign", "minus.circle"]
  static let clearAll = ["trash", "xmark.circle"]

  // MARK: - 选择状态

  static let inputSourceSelected = ["checkmark.circle.fill", "checkmark.circle", "checkmark"]
  static let inputSourceUnselected = ["circle", "minus"]
  static let pendingApproval = ["minus.circle.fill", "minus.circle", "minus"]

  // MARK: - 加载

  /// 按优先级尝试加载 SF Symbol，返回第一个成功匹配的 NSImage。
  /// 所有候选均失败时返回 nil（调用方自行兜底）。
  static func image(_ candidates: [String], description: String? = nil) -> NSImage? {
    for name in candidates {
      if let img = NSImage(systemSymbolName: name, accessibilityDescription: description) {
        return img
      }
    }
    return nil
  }
}

enum AppConstants {
  static let displayName = "输入法锁定"
  static let legacyDisplayName = "微信输入法锁定"
  static let legacyBundleIdentifier = "com.example.InputSourceLock"
  static let loggerSubsystem = "com.forest227.IMELocker"
  static let relaunchArgument = "--relaunch"
  static let statusImageAccessibilityDescription = "Input Source Lock"
  static let unknownInputSourceName = "未知"
  static let noSelectableInputSourcesText = "（未发现可选输入法）"
  static let latestReleasePageURL = URL(string: "https://github.com/FOREST227/IMELocker/releases/latest")!
  static let latestReleaseAPIURL = URL(string: "https://api.github.com/repos/FOREST227/IMELocker/releases/latest")!
}

enum AlertPresenter {
  static func show(title: String, message: String) {
    NSApp.activate(ignoringOtherApps: true)

    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.addButton(withTitle: "好")
    alert.runModal()
  }
}

enum SingleInstanceGuard {
  static func shouldExit(
    arguments: [String] = CommandLine.arguments,
    bundleIdentifier: String? = Bundle.main.bundleIdentifier,
    currentPID: Int32 = ProcessInfo.processInfo.processIdentifier,
    otherActivePIDs: (String) -> [Int32] = { bundleID in
      NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        .filter { !$0.isTerminated }
        .map(\.processIdentifier)
    }
  ) -> Bool {
    guard !arguments.contains(AppConstants.relaunchArgument) else { return false }
    guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return false }
    return otherActivePIDs(bundleIdentifier).contains { $0 != currentPID }
  }
}

enum StatusBarClickAction: Equatable {
  case openMenu
  case toggleLock

  static func resolve(
    eventType: NSEvent.EventType?,
    modifierFlags: NSEvent.ModifierFlags
  ) -> StatusBarClickAction {
    guard let eventType else { return .openMenu }
    let isRightClick = eventType == .rightMouseUp
      || (eventType == .leftMouseUp && modifierFlags.contains(.control))
    let isOptionClick = eventType == .leftMouseUp && modifierFlags.contains(.option)
    return (isRightClick || isOptionClick) ? .toggleLock : .openMenu
  }
}
