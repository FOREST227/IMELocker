enum LockStatus: Equatable {
  case disabled, noTarget, targetUnavailable, paused, restoring, locked

  var description: String {
    switch self {
    case .disabled: return "输入法已解锁"
    case .noTarget: return "请选择目标输入法"
    case .targetUnavailable: return "目标输入法不可用"
    case .paused: return "锁定已暂停（安全输入）"
    case .restoring: return "正在尝试恢复目标输入法"
    case .locked: return "输入法已锁定"
    }
  }
}
