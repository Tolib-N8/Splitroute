import AppKit
import CoreText
import SwiftUI

/// Название «Splitroute», отрисованное один раз: растр для чёткого текста и точки для частиц.
/// Частицы летят ровно в пиксели этого же растра, поэтому буквы из них совпадают с текстом.
private struct SplashTitle {
    let image: CGImage
    let size: CGSize
    /// Цели частиц в координатах названия (точки, начало — левый верхний угол).
    let targets: [CGPoint]

    static let shared = make()

    private static func make() -> SplashTitle {
        Theme.registerFonts()
        // Manrope — вариативный шрифт: жирность задаётся осью wght (0x77676874), а не именем начертания.
        let font: NSFont = NSFont(name: "Manrope", size: 46).flatMap { base in
            let variation = NSFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String)
            return NSFont(descriptor: base.fontDescriptor.addingAttributes([variation: [0x77676874: 700]]), size: 46)
        } ?? .boldSystemFont(ofSize: 46)
        let text = NSAttributedString(string: "Splitroute", attributes: [
            .font: font, .foregroundColor: NSColor(Theme.text), .kern: -0.6,
        ])
        let line = CTLineCreateWithAttributedString(text)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = ceil(CTLineGetTypographicBounds(line, &ascent, &descent, &leading)) + 4
        let height = ceil(ascent + descent) + 4
        let scale: CGFloat = 3
        let w = Int(width * scale), h = Int(height * scale)
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.scaleBy(x: scale, y: scale)
        ctx.textPosition = CGPoint(x: 2, y: descent + 2)
        CTLineDraw(line, ctx)
        let image = ctx.makeImage()!

        // Прореживаем непрозрачные пиксели сеткой ~2 pt.
        var targets: [CGPoint] = []
        if let data = ctx.data?.assumingMemoryBound(to: UInt8.self) {
            let step = 2.0
            var y = 0.0
            while y < height {
                var x = 0.0
                while x < width {
                    let px = Int(x * scale), py = Int(y * scale)          // y растра — сверху вниз
                    if px < w, py < h, data[py * w * 4 + px * 4 + 3] > 110 { targets.append(CGPoint(x: x, y: y)) }
                    x += step
                }
                y += step
            }
        }
        return SplashTitle(image: image, size: CGSize(width: width, height: height), targets: targets)
    }
}

/// Частица приветствия: откуда, куда, когда.
private struct SplashParticle {
    var target: CGPoint
    var delay: Double
    var duration: Double
    var swirl: CGFloat
    var jitter: CGPoint
    var radius: CGFloat
}

/// Приветствие при запуске: логотип появляется и рисует свой знак, уезжает влево,
/// справа из частиц собирается «Splitroute», потом всё растворяется. Клик — пропустить.
struct SplashView: View {
    /// Один раз за запуск: окно, открытое снова из строки меню, без приветствия.
    @MainActor static var shown = false
    /// SPLITROUTE_SPLASH_SLOW=1 — в 4 раза медленнее, чтобы рассмотреть кадры.
    private static let timeScale: Double = ProcessInfo.processInfo.environment["SPLITROUTE_SPLASH_SLOW"] == "1" ? 4 : 1
    static let duration = 2.8

    var onFinish: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date.timeIntervalSinceReferenceDate
    @State private var skipAt: Double?

    private static let logo: CGFloat = 92
    private static let gap: CGFloat = 22
    private static let particles: [SplashParticle] = {
        let title = SplashTitle.shared
        func rnd(_ i: Int, _ k: Double) -> Double {
            let v = sin(Double(i) * 12.9898 + k * 78.233) * 43758.5453
            return v - floor(v)
        }
        return title.targets.enumerated().map { i, p in
            let xf = Double(p.x / max(title.size.width, 1))
            return SplashParticle(
                target: p,
                delay: 0.82 + 0.45 * xf + 0.12 * rnd(i, 1),
                duration: 0.45 + 0.2 * rnd(i, 2),
                swirl: CGFloat(rnd(i, 3) - 0.5) * 90,
                jitter: CGPoint(x: (rnd(i, 4) - 0.5) * 6, y: (rnd(i, 5) - 0.5) * 6),
                radius: 0.8 + 0.6 * CGFloat(rnd(i, 6))
            )
        }
    }()

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation) { context in
                let t = (context.date.timeIntervalSinceReferenceDate - start) / Self.timeScale
                frame(t: t, size: geo.size)
            }
        }
        .background(Theme.bg)
        .contentShape(Rectangle())
        .onTapGesture { skip() }
        .onAppear {
            Self.shown = true
            if reduceMotion { onFinish(); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.duration * Self.timeScale) { onFinish() }
        }
    }

    private func skip() {
        guard skipAt == nil else { return }
        skipAt = (Date.timeIntervalSinceReferenceDate - start) / Self.timeScale
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25 * Self.timeScale) { onFinish() }
    }

    // MARK: Кадр

    private func frame(t: Double, size: CGSize) -> some View {
        let title = SplashTitle.shared
        let cx = size.width / 2, cy = size.height / 2
        let groupWidth = Self.logo + Self.gap + title.size.width
        let finalLogoX = cx - groupWidth / 2 + Self.logo / 2
        let logoX = logoCenterX(at: t, cx: cx, final: finalLogoX)
        let textOrigin = CGPoint(x: finalLogoX + Self.logo / 2 + Self.gap, y: cy - title.size.height / 2)

        let appear = clamp(t / 0.35)
        let scale = 0.7 + 0.3 * easeOutBack(clamp(t / 0.55))
        let draw = easeInOut(clamp((t - 0.12) / 0.55))
        let fadeStart = skipAt ?? 2.35
        let overall = 1 - clamp((t - fadeStart) / (skipAt == nil ? 0.4 : 0.25))

        return ZStack {
            Canvas { ctx, _ in
                // Мягкое свечение лайма за логотипом.
                let r: CGFloat = 220
                ctx.fill(Path(ellipseIn: CGRect(x: logoX - r, y: cy - r, width: r * 2, height: r * 2)),
                         with: .radialGradient(Gradient(colors: [Theme.lime.opacity(0.12 * appear), .clear]),
                                               center: CGPoint(x: logoX, y: cy), startRadius: 0, endRadius: r))
                drawParticles(ctx, t: t, cx: cx, cy: cy, final: finalLogoX, origin: textOrigin)
                // Чёткое название проявляется поверх собравшихся частиц.
                let crisp = clamp((t - 1.95) / 0.3)
                if crisp > 0 {
                    ctx.opacity = crisp
                    ctx.draw(Image(decorative: title.image, scale: 3), in: CGRect(origin: textOrigin, size: title.size))
                }
            }
            LogoMark(size: Self.logo, traffic: nil, draw: draw, interactive: false)
                .scaleEffect(scale)
                .opacity(appear)
                .position(x: logoX, y: cy)
        }
        .opacity(overall)
    }

    private func logoCenterX(at t: Double, cx: CGFloat, final: CGFloat) -> CGFloat {
        cx + (final - cx) * easeInOut(clamp((t - 0.7) / 0.4))
    }

    private func drawParticles(_ ctx: GraphicsContext, t: Double, cx: CGFloat, cy: CGFloat, final: CGFloat, origin: CGPoint) {
        let fadeOut = 1 - clamp((t - 1.95) / 0.3)
        guard fadeOut > 0, t > 0.8 else { return }
        let s = Self.logo * 0.56 / 24
        let tipOffset = CGPoint(x: 9 * s, y: -9.5 * s)                  // кончик правой ветви (21,3) от центра знака
        let colors = 4, alphas = 4
        var buckets = [Path](repeating: Path(), count: colors * alphas)
        for p in Self.particles {
            let u = clamp((t - p.delay) / p.duration)
            guard u > 0 else { continue }
            let e = 1 - pow(1 - u, 3)
            let lx = logoCenterX(at: p.delay, cx: cx, final: final)
            let start = CGPoint(x: lx + tipOffset.x + p.jitter.x, y: cy + tipOffset.y + p.jitter.y)
            let end = CGPoint(x: origin.x + p.target.x, y: origin.y + p.target.y)
            let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2 - 26 + p.swirl)
            let k = CGFloat(e), q = 1 - k
            let x = q * q * start.x + 2 * q * k * mid.x + k * k * end.x
            let y = q * q * start.y + 2 * q * k * mid.y + k * k * end.y
            let alpha = min(1, u * 5) * fadeOut
            let ci = min(colors - 1, Int(e * Double(colors)))
            let ai = min(alphas - 1, Int(alpha * Double(alphas)))
            guard alpha > 0.05 else { continue }
            let r = p.radius * (1.6 - 0.6 * k)
            buckets[ci * alphas + ai].addEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
        }
        for c in 0..<colors {
            // От белого к лаймовому по мере полёта — как частицы на «Маршрутах», только наоборот: прилетают в цвет текста.
            let color = Theme.lime.mix(with: Theme.text, by: Double(c) / Double(colors - 1))
            for a in 0..<alphas where !buckets[c * alphas + a].isEmpty {
                ctx.fill(buckets[c * alphas + a], with: .color(color.opacity((Double(a) + 0.5) / Double(alphas))))
            }
        }
    }

    // MARK: Кривые

    private func clamp(_ v: Double) -> Double { min(max(v, 0), 1) }
    private func easeInOut(_ t: Double) -> Double { t * t * (3 - 2 * t) }
    private func easeOutBack(_ t: Double) -> Double {
        let c1 = 1.70158, c3 = c1 + 1
        return 1 + c3 * pow(t - 1, 3) + c1 * pow(t - 1, 2)
    }
}
