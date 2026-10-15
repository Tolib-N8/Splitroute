import SwiftUI

/// Знак lucide «split» — тот же, что на иконке приложения (scripts/assets/make-art.swift, splitGlyph()).
/// Порядок подпутей важен для `trim`: сначала ствол и ветви, потом стрелки — знак «прорастает» снизу.
struct SplitGlyph: Shape {
    /// Сетка 24×24 → прямоугольник.
    static func transform(for rect: CGRect) -> CGAffineTransform {
        let s = min(rect.width, rect.height) / 24
        return CGAffineTransform(translationX: rect.midX - 12 * s, y: rect.midY - 12.5 * s).scaledBy(x: s, y: s)
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 12, y: 22)); p.addLine(to: CGPoint(x: 12, y: 13.7))
        p.addArc(tangent1End: CGPoint(x: 12, y: 12), tangent2End: CGPoint(x: 3, y: 3), radius: 4)
        p.addLine(to: CGPoint(x: 3, y: 3))
        p.move(to: CGPoint(x: 15, y: 9)); p.addLine(to: CGPoint(x: 21, y: 3))
        p.move(to: CGPoint(x: 3, y: 8)); p.addLine(to: CGPoint(x: 3, y: 3)); p.addLine(to: CGPoint(x: 8, y: 3))
        p.move(to: CGPoint(x: 16, y: 3)); p.addLine(to: CGPoint(x: 21, y: 3)); p.addLine(to: CGPoint(x: 21, y: 8))
        return p.applying(Self.transform(for: rect))
    }

    /// Траектории «трафика» в сетке 24×24: вверх по стволу и в одну из ветвей.
    static let branches: [[CGPoint]] = {
        func quad(_ a: CGPoint, _ c: CGPoint, _ b: CGPoint, steps: Int = 6) -> [CGPoint] {
            (1...steps).map { i in
                let t = CGFloat(i) / CGFloat(steps), u = 1 - t
                return CGPoint(x: u * u * a.x + 2 * u * t * c.x + t * t * b.x, y: u * u * a.y + 2 * u * t * c.y + t * t * b.y)
            }
        }
        let left = [CGPoint(x: 12, y: 22), CGPoint(x: 12, y: 13.7)]
            + quad(CGPoint(x: 12, y: 13.7), CGPoint(x: 12, y: 12), CGPoint(x: 10.8, y: 10.8)) + [CGPoint(x: 3, y: 3)]
        let right = [CGPoint(x: 12, y: 22), CGPoint(x: 12, y: 14)]
            + quad(CGPoint(x: 12, y: 14), CGPoint(x: 12.4, y: 11), CGPoint(x: 15, y: 9)) + [CGPoint(x: 21, y: 3)]
        return [left, right]
    }()

    /// Точка на ломаной по доле длины 0…1.
    static func point(on line: [CGPoint], at f: Double) -> CGPoint {
        var lengths: [CGFloat] = []
        for i in 1..<line.count { lengths.append(hypot(line[i].x - line[i - 1].x, line[i].y - line[i - 1].y)) }
        var d = CGFloat(min(max(f, 0), 1)) * lengths.reduce(0, +)
        for (i, l) in lengths.enumerated() {
            if d <= l, l > 0 {
                let k = d / l
                return CGPoint(x: line[i].x + (line[i + 1].x - line[i].x) * k, y: line[i].y + (line[i + 1].y - line[i].y) * k)
            }
            d -= l
        }
        return line.last!
    }
}

/// Фаза «трафика» между кадрами — класс, чтобы не дёргать SwiftUI каждый кадр.
private final class LogoMotion {
    var phase = 0.0
    var speed = 0.4
    var last: Double?
}

/// Логотип Splitroute: лаймовый квадрат со знаком «развилка». Пока маршрутизация включена,
/// по ветвям бегут точки — тем быстрее, чем больше трафик. По клику знак перерисовывается.
struct LogoMark: View {
    var size: CGFloat
    /// Байт/с; nil — маршрутизация выключена, точки не бегут.
    var traffic: Double?
    /// Доля нарисованного знака (для приветствия).
    var draw: Double = 1
    var interactive = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var redraw: Double = 1
    @State private var bump = false
    @State private var visible = true
    @State private var motion = LogoMotion()

    private var glyphSize: CGFloat { size * 0.56 }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0xD9FF6B), Color(hex: 0x9BD11E)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                        .fill(LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0)], startPoint: .top, endPoint: .center))
                )
            SplitGlyph()
                .trim(from: 0, to: draw * redraw)
                .stroke(Theme.bg, style: StrokeStyle(lineWidth: glyphSize / 24 * 2.1, lineCap: .round, lineJoin: .round))
                .frame(width: glyphSize, height: glyphSize)
            if traffic != nil, !reduceMotion, draw >= 1 {
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !visible)) { context in
                    Canvas { ctx, canvas in drawTraffic(ctx, canvas, now: context.date.timeIntervalSinceReferenceDate) }
                }
                .frame(width: glyphSize, height: glyphSize)
                .opacity(redraw)
                .allowsHitTesting(false)
            }
        }
        .frame(width: size, height: size)
        .scaleEffect(bump ? 1.08 : 1)
        .contentShape(Rectangle())
        .onTapGesture { if interactive { replay() } }
        .onWindowVisibility { visible = $0 }
    }

    private func replay() {
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { redraw = 0 }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.45)) { bump = true }
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.7)) { redraw = 1 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) { bump = false }
        }
    }

    private func drawTraffic(_ ctx: GraphicsContext, _ canvas: CGSize, now: Double) {
        let dt = min(max(now - (motion.last ?? now), 0), 0.1)
        motion.last = now
        let target = 0.35 + log10(1 + (traffic ?? 0) / 1024) / 3      // ~0,35 … 1,4 оборота в секунду
        motion.speed += (target - motion.speed) * min(1, dt * 2)
        motion.phase += dt * motion.speed

        let tr = SplitGlyph.transform(for: CGRect(origin: .zero, size: canvas))
        let s = canvas.width / 24
        for (b, line) in SplitGlyph.branches.enumerated() {
            for k in 0..<3 {
                let f = (motion.phase + Double(k) / 3 + Double(b) * 0.17).truncatingRemainder(dividingBy: 1)
                let p = SplitGlyph.point(on: line, at: f).applying(tr)
                let alpha = sin(.pi * f)                                  // гаснут у начала и у кончика
                let glow = 2.2 * s, core = 0.95 * s
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - glow, y: p.y - glow, width: glow * 2, height: glow * 2)),
                         with: .color(.white.opacity(0.22 * alpha)))
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - core, y: p.y - core, width: core * 2, height: core * 2)),
                         with: .color(.white.opacity(0.95 * alpha)))
            }
        }
    }
}
