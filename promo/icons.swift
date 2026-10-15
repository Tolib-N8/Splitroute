// Иконки приложений для ролика — из установленных программ (в репозиторий не кладём: это чужие товарные знаки).
//   swift promo/icons.swift promo/public/icons
import AppKit
let out = CommandLine.arguments[1]
for (name, path) in [("wechat", "/Applications/WeChat.app"), ("whatsapp", "/Applications/WhatsApp.app"),
                     ("telegram", "/Applications/Telegram.app"), ("chrome", "/Applications/Google Chrome.app")] {
    let icon = NSWorkspace.shared.icon(forFile: path)
    let size = NSSize(width: 256, height: 256)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 256, pixelsHigh: 256, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    icon.draw(in: NSRect(origin: .zero, size: size))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
}
