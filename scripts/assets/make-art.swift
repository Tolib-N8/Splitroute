// Генерирует иконку приложения (AppIcon.icns) и фон DMG из знака в design/app.pen:
// лаймовый градиент #D9FF6B → #9BD11E и lucide «split».
// swift scripts/assets/make-art.swift <out-dir>
import AppKit
import CoreGraphics

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/art")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func bitmap(_ w: Int, _ h: Int, _ draw: (CGContext) -> Void) -> CGImage {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Координаты как в SVG: y вниз.
    ctx.translateBy(x: 0, y: CGFloat(h))
    ctx.scaleBy(x: 1, y: -1)
    draw(ctx)
    return ctx.makeImage()!
}

func save(_ image: CGImage, _ name: String) {
    let rep = NSBitmapImageRep(cgImage: image)
    try! rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
}

/// lucide «split» в квадрате 24×24.
func splitGlyph() -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 16, y: 3)); p.addLine(to: CGPoint(x: 21, y: 3)); p.addLine(to: CGPoint(x: 21, y: 8))
    p.move(to: CGPoint(x: 8, y: 3)); p.addLine(to: CGPoint(x: 3, y: 3)); p.addLine(to: CGPoint(x: 3, y: 8))
    p.move(to: CGPoint(x: 12, y: 22)); p.addLine(to: CGPoint(x: 12, y: 13.7))
    p.addArc(tangent1End: CGPoint(x: 12, y: 12), tangent2End: CGPoint(x: 3, y: 3), radius: 4)
    p.addLine(to: CGPoint(x: 3, y: 3))
    p.move(to: CGPoint(x: 15, y: 9)); p.addLine(to: CGPoint(x: 21, y: 3))
    return p
}

func drawMark(_ ctx: CGContext, rect: CGRect, shadow: Bool) {
    let radius = rect.width * 0.225
    let shape = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    if shadow {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: rect.width * 0.012), blur: rect.width * 0.035, color: color(0x000000, 0.45))
        ctx.addPath(shape); ctx.setFillColor(color(0x9BD11E)); ctx.fillPath()
        ctx.restoreGState()
    }
    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(0xD9FF6B), color(0x9BD11E)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: rect.minX, y: rect.minY), end: CGPoint(x: rect.maxX, y: rect.maxY), options: [])
    // Мягкий блик сверху.
    let hl = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(0xFFFFFF, 0.28), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(hl, start: CGPoint(x: rect.midX, y: rect.minY), end: CGPoint(x: rect.midX, y: rect.midY), options: [])
    ctx.restoreGState()

    // Знак: 24 единицы → 56% ширины.
    let s = rect.width * 0.56 / 24
    ctx.saveGState()
    ctx.translateBy(x: rect.midX - 12 * s, y: rect.midY - 12.5 * s)
    ctx.scaleBy(x: s, y: s)
    ctx.addPath(splitGlyph())
    ctx.setStrokeColor(color(0x0A0A0A))
    ctx.setLineWidth(2.1)
    ctx.setLineCap(.round); ctx.setLineJoin(.round)
    ctx.strokePath()
    ctx.restoreGState()
}

// MARK: Иконка (сетка macOS: тело 824 из 1024)
let iconset = out.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for (size, scales) in [(16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])] {
    for scale in scales {
        let px = size * scale
        let img = bitmap(px, px) { ctx in
            let inset = CGFloat(px) * 100 / 1024
            drawMark(ctx, rect: CGRect(x: inset, y: inset * 0.92, width: CGFloat(px) - inset * 2, height: CGFloat(px) - inset * 2), shadow: px >= 64)
        }
        save(img, "AppIcon.iconset/icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png")
    }
}

// MARK: Фон DMG 660×420 (+@2x): тёмный, потоки частиц как на экране «Маршруты».
func hash(_ a: Double, _ b: Double) -> Double { let x = sin(a * 127.1 + b * 311.7) * 43758.5453; return x - x.rounded(.down) }

for scale in [1, 2] {
    let w = 660 * scale, h = 420 * scale
    let img = bitmap(w, h) { ctx in
        let S = CGFloat(scale)
        ctx.setFillColor(color(0x0A0A0A)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        // Светлые карточки под иконками: Finder рисует подписи тёмным цветом, на тёмном фоне их не видно.
        for cx in [170.0, 490.0] {
            let card = CGRect(x: (cx - 82) * Double(S), y: 132 * Double(S), width: 164 * Double(S), height: 166 * Double(S))
            let path = CGPath(roundedRect: card, cornerWidth: 26 * S, cornerHeight: 26 * S, transform: nil)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: 6 * S), blur: 24 * S, color: color(0x000000, 0.6))
            ctx.addPath(path); ctx.setFillColor(color(0xF2F2EE)); ctx.fillPath()
            ctx.restoreGState()
            ctx.addPath(path); ctx.setStrokeColor(color(0xFFFFFF, 0.6)); ctx.setLineWidth(1 * S); ctx.strokePath()
        }
        // Частицы от карточки приложения к карточке «Программ».
        let flows: [(CGFloat, CGFloat, UInt32)] = [(180, 205, 0xC8F542), (205, 205, 0x6FA8FF), (230, 205, 0xA78BFA)]
        for (fi, f) in flows.enumerated() {
            for k in 0..<140 {
                let t = hash(Double(k), Double(fi) * 7.3)
                let x = 262 + t * 136
                let ease = t * t * (3 - 2 * t)
                let y = Double(f.0) + (Double(f.1) - Double(f.0)) * ease + (hash(Double(k) * 3.1, Double(fi)) - 0.5) * 22 * (1 - 0.5 * sin(.pi * t))
                let r = 0.6 + 1.2 * pow(hash(Double(k) * 0.7, Double(fi) + 2), 3)
                let fade = min(1, t * 6) * min(1, (1 - t) * 6)
                let a = (0.25 + 0.6 * hash(Double(k) * 1.9, Double(fi) + 3)) * fade
                let mix = CGFloat(t)
                let c = color(f.2)
                let comps = c.components!
                ctx.setFillColor(CGColor(srgbRed: 0.92 + (comps[0] - 0.92) * mix, green: 0.92 + (comps[1] - 0.92) * mix, blue: 0.92 + (comps[2] - 0.92) * mix, alpha: a))
                ctx.fillEllipse(in: CGRect(x: CGFloat(x - r) * S, y: CGFloat(y - r) * S, width: CGFloat(r * 2) * S, height: CGFloat(r * 2) * S))
            }
        }
        // Подписи: в CGContext с y вниз текст рисуем через NSGraphicsContext без флипа.
        ctx.saveGState()
        ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        func text(_ s: String, size: CGFloat, weight: NSFont.Weight, color c: NSColor, y: CGFloat) {
            let font = NSFont(name: "Manrope", size: size * S) ?? NSFont.systemFont(ofSize: size * S, weight: weight)
            let attr = NSAttributedString(string: s, attributes: [.font: NSFontManager.shared.convert(font, toHaveTrait: weight >= .semibold ? .boldFontMask : []), .foregroundColor: c, .kern: weight >= .semibold ? -0.3 * S : 0])
            let sz = attr.size()
            attr.draw(at: CGPoint(x: (CGFloat(w) - sz.width) / 2, y: CGFloat(h) - y * S - sz.height))
        }
        text("Splitroute", size: 26, weight: .semibold, color: NSColor(white: 0.95, alpha: 1), y: 42)
        text("Каждое приложение — своим путём", size: 13, weight: .regular, color: NSColor(white: 0.6, alpha: 1), y: 80)
        text("Перетащите Splitroute в папку «Программы»", size: 12, weight: .regular, color: NSColor(white: 0.5, alpha: 1), y: 340)
        ctx.restoreGState()
    }
    save(img, scale == 1 ? "dmg-background.png" : "dmg-background@2x.png")
}
print("ok: \(out.path)")
