import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
  private let lockService = InputSourceLockService()
  private let launchAtLoginService = LaunchAtLoginService()
  private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
  private let menu = NSMenu()
  private let updateChecker = UpdateChecker()
  private var displayedLockStatus: LockStatus?
  private var isMenuOpen = false
  private let menuBuilder = StatusMenuBuilder()
  private lazy var menuActions = StatusMenuActionHandlers(
    target: self,
    selectTarget: #selector(selectTarget(_:)),
    toggleCurrentAppExclusion: #selector(toggleCurrentAppExclusion(_:)),
    removeExcludedApp: #selector(removeExcludedApp(_:)),
    clearExcludedApps: #selector(clearExcludedApps),
    toggleLaunchAtLogin: #selector(toggleLaunchAtLogin(_:)),
    openLoginItemsSettings: #selector(openLoginItemsSettings),
    restart: #selector(restart),
    about: #selector(about),
    quit: #selector(quit)
  )

  func applicationDidFinishLaunching(_ notification: Notification) {
    menu.delegate = self
    menu.autoenablesItems = false

    if let button = statusItem.button {
      button.target = self
      button.action = #selector(handleStatusBarButtonClick(_:))
      button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    lockService.addStateChangeHandler { [weak self] in
      self?.handleLockStateChanged()
    }

    lockService.start()
    updateStatusButton(using: lockService.lockStatus)
  }

  func menuWillOpen(_ menu: NSMenu) {
    isMenuOpen = true
    lockService.refreshSelectableInputSources()
    menuBuilder.rebuild(menu: menu, using: currentState(), actions: menuActions)
  }

  func menuDidClose(_ menu: NSMenu) {
    isMenuOpen = false
    statusItem.menu = nil
  }

  private func currentState() -> AppViewState {
    AppViewState(lockService: lockService, launchAtLoginService: launchAtLoginService)
  }

  private func handleLockStateChanged() {
    updateStatusButton(using: lockService.lockStatus)
    if isMenuOpen { menuBuilder.updateInformation(menu: menu, using: currentState()) }
  }

  private func updateStatusButton(using lockStatus: LockStatus) {
    guard let button = statusItem.button else { return }
    guard displayedLockStatus != lockStatus else { return }
    displayedLockStatus = lockStatus
    button.toolTip = "\(lockStatus.description)\n左键打开菜单 · 右键快捷切换"
    button.setAccessibilityLabel(lockStatus.description)
    button.image = makeStatusImage(for: lockStatus)
    button.imagePosition = .imageOnly
    // 不设置 contentTintColor，由系统根据菜单栏外观自动着色（暗色=白，亮色=黑）
  }

  private func makeStatusImage(for status: LockStatus) -> NSImage? {
    let desc = AppConstants.statusImageAccessibilityDescription
    let candidates = SFSymbol.statusCandidates(for: status)
    let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)

    if let symbol = SFSymbol.image(candidates, description: desc)?.withSymbolConfiguration(config) {
      symbol.isTemplate = true
      return symbol
    }

    // 极端兜底：如果所有 SF Symbol 均不可用，用应用图标（非模板）。
    return NSImage(named: NSImage.applicationIconName)
  }

  @objc private func handleStatusBarButtonClick(_ sender: NSStatusBarButton) {
    let event = NSApp.currentEvent
    let action = StatusBarClickAction.resolve(
      eventType: event?.type,
      modifierFlags: event?.modifierFlags ?? []
    )
    switch action {
    case .toggleLock:
      toggleLockQuickly()
    case .openMenu:
      openStatusMenu()
    }
  }

  private func openStatusMenu() {
    statusItem.menu = menu
    statusItem.button?.performClick(nil)
    statusItem.menu = nil
  }

  private func toggleLockQuickly() {
    if lockService.isEnabled {
      lockService.isEnabled = false
    } else if let targetID = lockService.targetInputSourceID {
      lockService.lock(to: targetID, reason: "quickToggle")
    } else {
      openStatusMenu()
    }
  }

  @objc private func selectTarget(_ sender: NSMenuItem) {
    guard let id = sender.representedObject as? String else { return }
    if lockService.targetInputSourceID == id && lockService.isEnabled {
      // 已锁定到此项 → 解锁
      lockService.isEnabled = false
    } else {
      // 锁定到新目标
      lockService.lock(to: id, reason: "selectTarget")
    }
  }

  @objc private func toggleCurrentAppExclusion(_ sender: NSMenuItem) {
    guard let app = sender.representedObject as? RunningAppInfo else { return }
    lockService.toggleExclusion(for: app)
  }

  @objc private func removeExcludedApp(_ sender: NSMenuItem) {
    guard let bundleID = sender.representedObject as? String else { return }
    lockService.removeExcludedApp(bundleIdentifier: bundleID)
  }

  @objc private func clearExcludedApps() {
    lockService.clearExcludedApps()
  }

  @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
    do {
      try launchAtLoginService.setEnabled(!launchAtLoginService.isEnabled)
    } catch {
      AlertPresenter.show(title: "无法设置登录启动", message: String(describing: error))
    }
  }

  @objc private func openLoginItemsSettings() {
    launchAtLoginService.openSystemLoginItemsSettings()
  }

  @objc private func restart() {
    guard let bundleURL = relaunchBundleURL() else {
      AlertPresenter.show(title: "无法重启应用", message: "没有找到可用于重启的应用包，请先重新运行“输入法锁定”。")
      return
    }

    let configuration = NSWorkspace.OpenConfiguration()
    configuration.createsNewApplicationInstance = true
    configuration.arguments = [AppConstants.relaunchArgument]
    NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { application, error in
      DispatchQueue.main.async {
        if application != nil, error == nil {
          NSApplication.shared.terminate(nil)
        } else {
          AlertPresenter.show(title: "无法重启应用", message: "启动新实例失败：\(error?.localizedDescription ?? "未能启动应用")")
        }
      }
    }
  }

  @objc private func about() {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    let alert = NSAlert()
    alert.messageText = AppConstants.displayName
    alert.informativeText = "版本 \(version) (\(build))\n轻量 macOS 菜单栏工具，将输入法锁定到指定目标。"
    let updateLabel = NSTextField(wrappingLabelWithString: "正在检查更新…")
    updateLabel.frame = NSRect(x: 0, y: 0, width: 280, height: 36)
    updateLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
    updateLabel.textColor = .secondaryLabelColor
    alert.accessoryView = updateLabel
    alert.addButton(withTitle: "查看更新")
    alert.addButton(withTitle: "好")

    updateChecker.check { [weak alert, weak updateLabel] latest in
      guard let alert, let updateLabel else { return }
      guard let latest else {
        updateLabel.stringValue = "暂时无法检查更新，可点击“查看更新”访问发布页。"
        return
      }
      if ReleaseVersion.isNewer(latest, than: version) {
        updateLabel.stringValue = "● 有新版本 \(latest)"
        updateLabel.textColor = .systemRed
        alert.buttons.first?.title = "查看更新 (\(latest))"
        alert.layout()
      } else {
        updateLabel.stringValue = "当前已是最新版本"
      }
    }
    NSApp.activate(ignoringOtherApps: true)
    if alert.runModal() == .alertFirstButtonReturn {
      NSWorkspace.shared.open(AppConstants.latestReleasePageURL)
    }
  }

  @objc private func quit() {
    NSApplication.shared.terminate(nil)
  }

  private func relaunchBundleURL() -> URL? {
    let fileManager = FileManager.default
    let currentBundleURL = Bundle.main.bundleURL
    let parentDirectoryURL = currentBundleURL.deletingLastPathComponent()

    let candidateURLs = [
      currentBundleURL,
      parentDirectoryURL.appendingPathComponent("\(AppConstants.displayName).app"),
      parentDirectoryURL.appendingPathComponent("\(AppConstants.legacyDisplayName).app"),
    ]

    return candidateURLs.first { url in
      url.pathExtension == "app" && fileManager.fileExists(atPath: url.path)
        && Bundle(url: url)?.executableURL.map { fileManager.isExecutableFile(atPath: $0.path) } == true
    }
  }
}
