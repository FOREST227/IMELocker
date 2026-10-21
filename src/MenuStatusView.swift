import Cocoa

/// Informational menu content: labels stay readable without becoming actions.
final class MenuStatusView: NSView {
  private let symbol = NSImageView()
  private let heading = NSTextField(labelWithString: "")
  private let detail = NSTextField(labelWithString: "")
  override var isFlipped: Bool { true }

  init(state: AppViewState) {
    super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 64))
    symbol.frame = NSRect(x: 16, y: 14, width: 16, height: 18)
    symbol.contentTintColor = .labelColor
    heading.frame = NSRect(x: 40, y: 12, width: 244, height: 22)
    heading.font = .systemFont(ofSize: 13, weight: .semibold)
    heading.textColor = .labelColor
    heading.lineBreakMode = .byTruncatingTail
    heading.autoresizingMask = [.width]
    detail.frame = NSRect(x: 40, y: 36, width: 244, height: 18)
    detail.font = .systemFont(ofSize: 12)
    detail.textColor = .secondaryLabelColor
    detail.maximumNumberOfLines = 1
    detail.lineBreakMode = .byTruncatingTail
    detail.autoresizingMask = [.width]
    [symbol, heading, detail].forEach(addSubview)
    update(using: state)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func update(using state: AppViewState) {
    heading.stringValue = state.menuStatusTitle
    detail.stringValue = "当前使用\(state.currentInputSourceName)"
    detail.toolTip = detail.stringValue
    detail.setAccessibilityLabel(detail.stringValue)
    symbol.image = SFSymbol.image(state.lockStatus == .locked
      ? SFSymbol.statusLockEnabled : SFSymbol.statusLockDisabled)
    symbol.setAccessibilityElement(false)
  }
}

final class MenuInformationView: NSView {
  private let label: NSTextField
  override var isFlipped: Bool { true }

  init(text: String, isHeading: Bool = false) {
    label = NSTextField(labelWithString: text)
    super.init(frame: NSRect(x: 0, y: 0, width: 300, height: isHeading ? 26 : 28))
    label.frame = NSRect(x: 40, y: 5, width: 244, height: 18)
    label.font = .systemFont(ofSize: 11, weight: isHeading ? .medium : .regular)
    label.textColor = .secondaryLabelColor
    label.lineBreakMode = .byTruncatingTail
    label.autoresizingMask = [.width]
    label.toolTip = text
    addSubview(label)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func update(text: String) {
    label.stringValue = text
    label.toolTip = text
  }
}
