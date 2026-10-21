import Cocoa

private final class MenuActionProbe: NSObject {
  var selectedID: String?
  @objc func select(_ sender: NSMenuItem) { selectedID = sender.representedObject as? String }
  @objc func toggle(_ sender: NSMenuItem) {}
  @objc func settings() {}
  @objc func restart() {}
  @objc func about() {}
  @objc func quit() {}
}

func runMenuTests(lockService: InputSourceLockService) {
  func require(_ condition: Bool, _ message: String) {
    if !condition { fputs("FAIL: \(message)\n", stderr); exit(1) }
  }
  NSApplication.shared.setActivationPolicy(.prohibited)
  let probe = MenuActionProbe()
  let actions = StatusMenuActionHandlers(target: probe, selectTarget: #selector(MenuActionProbe.select(_:)),
    toggleLaunchAtLogin: #selector(MenuActionProbe.toggle(_:)), openLoginItemsSettings: #selector(MenuActionProbe.settings),
    restart: #selector(MenuActionProbe.restart), about: #selector(MenuActionProbe.about), quit: #selector(MenuActionProbe.quit))
  for status: LaunchAtLoginStatus in [.enabled, .disabled, .requiresApproval, .unsupported] {
    let state = AppViewState(lockService: lockService, launchAtLoginStatus: status)
    let menu = NSMenu()
    StatusMenuBuilder().rebuild(menu: menu, using: state, actions: actions)
    require(menu.items.first?.view is MenuStatusView, "status uses readable information view")
    let toggle = menu.items.first { $0.action == actions.toggleLaunchAtLogin }!
    require(toggle.title.contains("登录时启动"), "login wording")
    require(toggle.image == nil && toggle.onStateImage != nil && toggle.offStateImage != nil,
            "single circular indicator preserves native state")
    require(toggle.isEnabled == (status != .unsupported), "unsupported toggle stays disabled")
    if status == .requiresApproval {
      require(toggle.state == .mixed && toggle.title.contains("待批准"), "approval is visible")
      require(menu.items.contains { $0.action == actions.openLoginItemsSettings }, "approval settings action")
    }
    for item in menu.items where item.action == actions.selectTarget {
      require(item.image == nil && item.onStateImage != nil, "no duplicated checkmark")
      require(item.representedObject is String, "selection retains source ID")
    }
    require(menu.items.last?.keyEquivalent == "q", "quit shortcut preserved")
  }
  let suite = "IMELocker.menu-tests.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defer { defaults.removePersistentDomain(forName: suite) }
  let system = FakeInputSystem()
  let longName = String(repeating: "超长输入法名称", count: 10)
  system.sources[0] = InputSource(id: "test.ime", name: longName)
  let service = InputSourceLockService(defaults: defaults, system: system)
  let builder = StatusMenuBuilder()
  var previews: [(String, AppViewState)] = []
  for status: LockStatus in [.locked, .paused, .restoring, .targetUnavailable, .noTarget, .disabled] {
    service.isEnabled = status != .disabled
    service.targetInputSourceID = status == .noTarget ? nil : (status == .targetUnavailable ? "missing" : "test.ime")
    system.secure = status == .paused
    system.current = status == .restoring ? system.sources[1] : system.sources[0]
    let state = AppViewState(lockService: service, launchAtLoginStatus: .disabled)
    require(state.lockStatus == status, "state fixture")
    let menu = NSMenu()
    builder.rebuild(menu: menu, using: state, actions: actions)
    let source = menu.items.first { $0.representedObject as? String == "test.ime" }!
    require(source.title.count < longName.count && source.toolTip == longName,
            "long source names stay compact with a full-name tooltip")
    require(source.accessibilityLabel() == longName, "accessibility keeps full source name")
    require(source.action == actions.selectTarget && source.isEnabled, "long name remains selectable")
    probe.selectedID = nil
    menu.performActionForItem(at: menu.index(of: source))
    require(probe.selectedID == "test.ime", "native menu selection delivers the source ID")
    let header = menu.items.first!.view as! MenuStatusView
    let labels = header.subviews.compactMap { $0 as? NSTextField }
    require(labels.allSatisfy { $0.isEnabled && $0.frame.maxX <= header.bounds.width }, "readable labels fit header")
    require(labels.first?.stringValue == state.menuStatusTitle, "correct status text")
    service.isEnabled = false
    let updated = AppViewState(lockService: service, launchAtLoginStatus: .disabled)
    builder.updateInformation(menu: menu, using: updated)
    require(labels.first?.stringValue == updated.menuStatusTitle && menu.items.first?.title == updated.menuStatusTitle, "open-menu header refreshes")
    require(menu.items.contains { $0 === source }, "refresh preserves native action items")
    previews.append((state.menuStatusTitle, state))
  }

  if let directory = ProcessInfo.processInfo.environment["IMELOCKER_MENU_PREVIEW_DIR"] {
    try! FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
      let appearance = NSAppearance(named: appearanceName)!
      appearance.performAsCurrentDrawingAppearance {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: previews.count * 90))
        host.appearance = appearance
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        for (index, entry) in previews.enumerated() {
          let header = MenuStatusView(state: entry.1)
          header.frame.origin.y = CGFloat((previews.count - index - 1) * 90)
          host.addSubview(header)
        }
        host.layoutSubtreeIfNeeded()
        let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try! bitmap.representation(using: .png, properties: [:])!.write(to:
          URL(fileURLWithPath: directory).appendingPathComponent("menu-status-\(name).png"))
      }
    }
  }
  print("PASS: menu header, circular states, approval, unsupported login and native actions")
}
