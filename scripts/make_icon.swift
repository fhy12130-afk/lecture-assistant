import AppKit

// 生成 AppIcon.icns：渐变圆角方块 + 白色麦克风/文字气泡
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func draw(_ size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(size)
    let inset = s * 0.09
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = NSBezierPath(roundedRect: rect, xRadius: s * 0.19, yRadius: s * 0.19)
    NSGradient(colors: [NSColor(calibratedRed: 0.20, green: 0.32, blue: 0.86, alpha: 1),
                        NSColor(calibratedRed: 0.10, green: 0.62, blue: 0.70, alpha: 1)])!.draw(in: path, angle: -60)
    let cfg = NSImage.SymbolConfiguration(pointSize: s * 0.42, weight: .semibold)
        .applying(.init(paletteColors: [.white]))
    if let img = NSImage(systemSymbolName: "waveform.and.mic", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
        let w = img.size.width, h = img.size.height
        img.draw(in: NSRect(x: (s - w) / 2, y: (s - h) / 2 + s * 0.02, width: w, height: h))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    let data = draw(px).representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
