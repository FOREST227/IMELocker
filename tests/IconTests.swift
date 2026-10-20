import Cocoa

func check(_ condition: Bool, _ message: String) {
  guard condition else { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

func verifyAlpha(_ data: Data, name: String) {
  guard let bitmap = NSBitmapImageRep(data: data) else {
    check(false, "Cannot decode \(name)"); return
  }
  let w = bitmap.pixelsWide, h = bitmap.pixelsHigh
  check(bitmap.hasAlpha, "\(name) must have transparency")
  for (x, y) in [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)] {
    check((bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 1) < 0.01,
          "\(name) has opaque canvas corners; older macOS will display a square")
  }
  check((bitmap.colorAt(x: w / 2, y: h / 2)?.alphaComponent ?? 0) > 0.99,
        "\(name) must retain its opaque artwork")
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let png = try Data(contentsOf: root.appendingPathComponent("Resources/AppIcon.png"))
verifyAlpha(png, name: "README PNG")
let icns = try Data(contentsOf: root.appendingPathComponent("Resources/AppIcon.icns"))
func length(at offset: Int) -> Int {
  icns[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
}
check(String(data: icns.prefix(4), encoding: .ascii) == "icns", "ICNS header")
check(length(at: 4) == icns.count, "ICNS file length")
var offset = 8
var types = Set<String>()
while offset < icns.count {
  check(offset + 8 <= icns.count, "ICNS chunk header")
  let count = length(at: offset + 4)
  check(count > 8 && offset + count <= icns.count, "ICNS chunk bounds")
  let type = String(data: icns[offset..<offset + 4], encoding: .ascii)!
  types.insert(type)
  let data = icns.subdata(in: offset + 8..<offset + count)
  verifyAlpha(data, name: type)
  if type == "ic10" { check(data == png, "README and app must use the same master icon") }
  offset += count
}
check(types == Set(["icp4", "icp5", "icp6", "ic11", "ic12", "ic07", "ic08", "ic13", "ic09", "ic14", "ic10"]),
      "All standard icon variants must be packaged")
print("PASS: README PNG and all 11 ICNS variants have transparent corners and opaque artwork")
