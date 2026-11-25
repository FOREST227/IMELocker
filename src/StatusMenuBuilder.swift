import Cocoa

struct AppViewState {
  let currentInputSourceName: String
  let isLockEnabled: Bool
  let lockStatus: LockStatus
  let selectableInputSources: [InputSource]
  let targetInputSourceID: String?
  let frontmostApp: RunningAppInfo?
  let isFrontmostAppExcluded: Bool
  let excludedApps: [RunningAppInfo]
  let launchAtLoginStatus: LaunchAtLoginStatus

  init(lockService: InputSourceLockService, launchAtLoginService: LaunchAtLoginService) {
    self.init(lockService: lockService, launchAtLoginStatus: launchAtLoginService.status)
  }

  init(lockService: InputSourceLockService, launchAtLoginStatus: LaunchAtLoginStatus) {
    let availableInputSources = lockService.selectableInputSources()
    let currentSource = lockService.currentInputSource()
    let selectedTargetInputSourceID = lockService.targetInputSourceID
    let activeApp = lockService.frontmostApp()

    currentInputSourceName = currentSource?.name ?? AppConstants.unknownInputSourceName
    isLockEnabled = lockService.isEnabled
    lockStatus = lockService.lockStatus(current: currentSource, selectableSources: availableInputSources)
    selectableInputSources = availableInputSources
    targetInputSourceID = selectedTargetInputSourceID
    frontmostApp = activeApp
    isFrontmostAppExcluded = activeApp.map { lockService.isAppExcluded(bundleIdentifier: $0.bundleIdentifier) } ?? false
    excludedApps = lockService.excludedApps()
    self.launchAtLoginStatus = launchAtLoginStatus
  }

  var activeTargetInputSourceID: String? {
    isLockEnabled ? targetInputSourceID : nil
  }

  var menuStatusTitle: String {
    switch lockStatus {
    case .locked: return "已锁定"
    case .disabled: return "已解锁"
    case .noTarget: return "请选择输入法"
    case .targetUnavailable: return "目标输入法不可用"
    case .paused: return "已暂停 · 安全输入"
    case .pausedForApp: return "已暂停 · 当前应用例外"
    case .restoring: return "正在恢复输入法"
    }
  }

  var selectionHint: String {
    if selectableInputSources.isEmpty { return "请先在系统设置中添加输入法" }
    if lockStatus == .targetUnavailable { return "请选择其他输入法，或重新启用原目标" }
    return isLockEnabled && targetInputSourceID != nil
      ? "再次点击已选项可解锁 · 右键图标可快速切换" : "点击输入法即可锁定"
  }

  var launchAtLoginTitle: String {
    switch launchAtLoginStatus {
    case .requiresApproval: return "登录时启动 · 待批准"
    case .unsupported: return "登录时启动 · 需要 macOS 13"
    case .notFound: return "登录时启动 · 应用不可用"
    case .enabled, .disabled: return "登录时启动"
    }
  }

  var launchAtLoginStatusText: String {
    "登录启动：\(launchAtLoginStatus.description)"
  }

  var launchAtLoginControlState: NSControl.StateValue {
    switch launchAtLoginStatus {
    case .enabled:
      return .on
    case .requiresApproval:
      return .mixed
    case .disabled, .notFound, .unsupported:
      return .off
    }
  }

  var isLaunchAtLoginToggleEnabled: Bool {
    launchAtLoginStatus != .unsupported
  }

  var shouldShowOpenLoginItemsSettings: Bool {
    launchAtLoginStatus == .requiresApproval
  }
}

struct StatusMenuActionHandlers {
  let target: AnyObject
  let selectTarget: Selector
  let toggleCurrentAppExclusion: Selector
  let removeExcludedApp: Selector
  let clearExcludedApps: Selector
  let toggleLaunchAtLogin: Selector
  let openLoginItemsSettings: Selector
  let restart: Selector
  let about: Selector
  let quit: Selector
}

final class StatusMenuBuilder {
  private enum ItemIdentifier {
    static let inputSource = NSUserInterfaceItemIdentifier("inputSource")
    static let selectionHint = NSUserInterfaceItemIdentifier("selectionHint")
    static let currentAppExclusion = NSUserInterfaceItemIdentifier("currentAppExclusion")
  }

  func rebuild(menu: NSMenu, using state: AppViewState, actions: StatusMenuActionHandlers) {
    menu.removeAllItems()

    menu.autoenablesItems = false
    menu.minimumWidth = 300
    let header = NSMenuItem(title: state.menuStatusTitle, action: nil, keyEquivalent: "")
    header.view = MenuStatusView(state: state)
    menu.addItem(header)
    menu.addItem(.separator())
    addInformation(title: "输入法", isHeading: true, to: menu)
    addInputSourceItems(
      state.selectableInputSources,
      selectedID: state.activeTargetInputSourceID,
      to: menu,
      actions: actions
    )
    addInformation(title: state.selectionHint, identifier: ItemIdentifier.selectionHint, to: menu)

    menu.addItem(.separator())

    // ── 区域 3：应用例外与快捷操作 ──
    if let app = state.frontmostApp {
      let excludeItem = makeActionItem(
        title: abbreviatedMenuText("在「\(app.localizedName)」中暂停"),
        action: actions.toggleCurrentAppExclusion,
        image: nil,
        target: actions.target
      )
      applyCircularSelection(to: excludeItem)
      excludeItem.identifier = ItemIdentifier.currentAppExclusion
      excludeItem.state = state.isFrontmostAppExcluded ? .on : .off
      excludeItem.representedObject = app
      excludeItem.toolTip = "\(app.localizedName) (\(app.bundleIdentifier))"
      excludeItem.setAccessibilityLabel("在\(app.localizedName)中暂停锁定")
      menu.addItem(excludeItem)
    }

    if !state.excludedApps.isEmpty {
      let submenuItem = NSMenuItem(
        title: "例外应用（\(state.excludedApps.count)）",
        action: nil,
        keyEquivalent: ""
      )
      submenuItem.image = SFSymbol.image(SFSymbol.excludedApps, description: "例外应用")
      let submenu = NSMenu()
      submenu.autoenablesItems = false
      for app in state.excludedApps {
        let removeItem = makeActionItem(
          title: abbreviatedMenuText("移除「\(app.localizedName)」"),
          action: actions.removeExcludedApp,
          image: nil,
          target: actions.target
        )
        removeItem.representedObject = app.bundleIdentifier
        removeItem.toolTip = "\(app.localizedName) (\(app.bundleIdentifier))"
        submenu.addItem(removeItem)
      }
      submenu.addItem(.separator())
      submenu.addItem(
        makeActionItem(
          title: "清空全部例外",
          action: actions.clearExcludedApps,
          image: SFSymbol.image(SFSymbol.clearAll, description: "清空"),
          target: actions.target
        )
      )
      submenuItem.submenu = submenu
      menu.addItem(submenuItem)
    }

    let launchItem = makeActionItem(
      title: state.launchAtLoginTitle,
      action: actions.toggleLaunchAtLogin,
      image: nil,
      target: actions.target
    )
    applyCircularSelection(to: launchItem)
    launchItem.state = state.launchAtLoginControlState
    launchItem.isEnabled = state.isLaunchAtLoginToggleEnabled
    launchItem.toolTip = state.launchAtLoginStatusText
    menu.addItem(launchItem)

    if state.shouldShowOpenLoginItemsSettings {
      menu.addItem(
        makeActionItem(
          title: "打开系统登录项设置…",
          action: actions.openLoginItemsSettings,
          image: SFSymbol.image(SFSymbol.openExternal, description: "打开设置"),
          target: actions.target
        )
      )
    }

    menu.addItem(.separator())

    // ── 区域 4：应用操作 ──
    menu.addItem(
      makeActionItem(
        title: "重启应用",
        action: actions.restart,
        image: SFSymbol.image(SFSymbol.restart, description: "重启"),
        target: actions.target
      )
    )
    menu.addItem(
      makeActionItem(
        title: "关于「输入法锁定」",
        action: actions.about,
        image: SFSymbol.image(SFSymbol.info, description: "关于"),
        target: actions.target
      )
    )

    menu.addItem(.separator())

    menu.addItem(
      makeActionItem(
        title: "退出",
        action: actions.quit,
        keyEquivalent: "q",
        image: SFSymbol.image(SFSymbol.quit, description: "退出"),
        target: actions.target
      )
    )
  }

  private func addInputSourceItems(
    _ sources: [InputSource],
    selectedID: String?,
    to menu: NSMenu,
    actions: StatusMenuActionHandlers
  ) {
    guard !sources.isEmpty else {
      addInformation(title: AppConstants.noSelectableInputSourcesText, to: menu)
      return
    }

    for source in sources {
      let isSelected = source.id == selectedID
      let item = makeActionItem(
        title: abbreviatedMenuText(source.name),
        action: actions.selectTarget,
        image: nil,
        target: actions.target
      )
      applyCircularSelection(to: item)
      item.identifier = ItemIdentifier.inputSource
      item.toolTip = source.name
      item.setAccessibilityLabel(source.name)
      item.representedObject = source.id
      item.state = isSelected ? .on : .off
      menu.addItem(item)
    }
  }

  /// Use the native state column for one circular indicator, preserving menu
  /// selection semantics and accessibility without a second decorative icon.
  private func applyCircularSelection(to item: NSMenuItem) {
    item.onStateImage = SFSymbol.image(SFSymbol.inputSourceSelected, description: "已选中")
    item.offStateImage = SFSymbol.image(SFSymbol.inputSourceUnselected, description: "未选中")
    item.mixedStateImage = SFSymbol.image(SFSymbol.pendingApproval, description: "等待批准")
  }

  func updateInformation(menu: NSMenu, using state: AppViewState) {
    menu.items.first?.title = state.menuStatusTitle
    (menu.items.first?.view as? MenuStatusView)?.update(using: state)
    let activeTargetID = state.activeTargetInputSourceID
    for item in menu.items where item.identifier == ItemIdentifier.inputSource {
      item.state = (item.representedObject as? String) == activeTargetID ? .on : .off
    }
    if let excludeItem = menu.items.first(where: { $0.identifier == ItemIdentifier.currentAppExclusion }) {
      excludeItem.state = state.isFrontmostAppExcluded ? .on : .off
    }
    if let hint = menu.items.first(where: { $0.identifier == ItemIdentifier.selectionHint }) {
      hint.title = state.selectionHint
      (hint.view as? MenuInformationView)?.update(text: state.selectionHint)
    }
  }

  private func addInformation(title: String, isHeading: Bool = false,
                              identifier: NSUserInterfaceItemIdentifier? = nil, to menu: NSMenu) {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.view = MenuInformationView(text: title, isHeading: isHeading)
    if let identifier { item.identifier = identifier }
    menu.addItem(item)
  }

  private func abbreviatedMenuText(_ text: String) -> String {
    let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.menuFont(ofSize: 0)]
    guard (text as NSString).size(withAttributes: attributes).width > 236 else { return text }
    var prefix = text
    while !prefix.isEmpty && ((prefix + "…") as NSString).size(withAttributes: attributes).width > 236 {
      prefix.removeLast()
    }
    return prefix + "…"
  }

  /// 可点击操作项
  private func makeActionItem(
    title: String,
    action: Selector,
    keyEquivalent: String = "",
    image: NSImage? = nil,
    target: AnyObject
  ) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
    item.target = target
    if let image { item.image = image }
    return item
  }
}
