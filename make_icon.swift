// 앱 아이콘(AppIcon.icns) 생성: 파란 둥근 사각형 + 왼쪽 화살표. 디자인 바꿀 때만 다시 실행.
//   swift make_icon.swift && iconutil -c icns AppIcon.iconset && rm -r AppIcon.iconset
import AppKit

func draw(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // macOS 아이콘 격자: 1024 중 가운데 824, 모서리 반경 ≈ 185
    let r = NSRect(x: s * 100 / 1024, y: s * 100 / 1024, width: s * 824 / 1024, height: s * 824 / 1024)
    let body = NSBezierPath(roundedRect: r, xRadius: s * 185 / 1024, yRadius: s * 185 / 1024)
    NSGradient(starting: NSColor(red: 0.36, green: 0.58, blue: 1.0, alpha: 1),
               ending: NSColor(red: 0.17, green: 0.33, blue: 0.86, alpha: 1))!.draw(in: body, angle: -90)
    let cfg = NSImage.SymbolConfiguration(pointSize: s * 0.42, weight: .bold)
        .applying(.init(paletteColors: [.white]))
    let arrow = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: nil)!.withSymbolConfiguration(cfg)!
    let a = arrow.size
    arrow.draw(in: NSRect(x: r.midX - a.width / 2 - s * 0.02, y: r.midY - a.height / 2, width: a.width, height: a.height))
    NSGraphicsContext.current = nil
    return rep.representation(using: .png, properties: [:])!
}

let dir = URL(fileURLWithPath: "AppIcon.iconset")
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! draw(base).write(to: dir.appendingPathComponent("icon_\(base)x\(base).png"))
    try! draw(base * 2).write(to: dir.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
