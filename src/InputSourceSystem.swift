import Cocoa
import Carbon

/// Isolates system input-source operations from lock policy.
protocol InputSourceSystem {
  var isSecureInputEnabled: Bool { get }
  func selectableInputSources() -> [InputSource]
  func currentInputSource() -> InputSource?
  func selectInputSource(id: String) -> OSStatus?
}

struct CarbonInputSourceSystem: InputSourceSystem {
  var isSecureInputEnabled: Bool { IsSecureEventInputEnabled() }

  func selectInputSource(id: String) -> OSStatus? {
    guard let source = inputSourceRef(byID: id),
          boolProperty(source, kTISPropertyInputSourceIsEnabled),
          boolProperty(source, kTISPropertyInputSourceIsSelectCapable) else { return nil }
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

    var sources: [InputSource] = []
    sources.reserveCapacity(list.count)
    for source in list {
      guard boolProperty(source, kTISPropertyInputSourceIsSelectCapable) else { continue }
      guard boolProperty(source, kTISPropertyInputSourceIsEnabled) else { continue }
      guard let id = stringProperty(source, kTISPropertyInputSourceID) else { continue }
      guard let name = stringProperty(source, kTISPropertyLocalizedName) else { continue }

      sources.append(InputSource(id: id, name: name))
    }

    // 稳定排序：先按名称，再按 id
    sources.sort { lhs, rhs in
      if lhs.name == rhs.name { return lhs.id < rhs.id }
      return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
    return sources
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
