import SplitrouteCore
import SwiftUI

/// Экран «Куда идёт трафик»: приложения слева, выходы справа, между ними — потоки частиц
/// по мотивам design/app-assets/flow.glsl.
struct RoutesView: View {
    @Environment(AppModel.self) private var model
    @State private var paused = false
    @State private var showAdd = false

    var body: some View {
        let graph = FlowGraph(model: model)
        VStack(alignment: .leading, spacing: 0) {
            ScreenHeader(
                title: L("Куда идёт трафик"),
                summary: L("\(Format.bytes(graph.totalBytes)) за сутки · \(Format.apps(graph.apps.count))"),
                footnote: model.updatedText
            ) {
                Text(L("Раздельный туннель · \(model.state.isRunning ? L("Вкл") : L("Выкл"))"))
                    .font(Theme.font(13)).foregroundStyle(Theme.text2)
            }
            if graph.apps.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 30)).foregroundStyle(Theme.text3)
                    Text(L("Пока нечего показать")).font(Theme.font(15, .semibold))
                    Text(L("Настройте приложения или подождите, пока они выйдут в сеть")).font(Theme.font(12)).foregroundStyle(Theme.text2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geo in
                    FlowDiagram(graph: graph, size: geo.size, paused: paused)
                }
                .padding(.top, 36)
            }
            HStack(spacing: 10) {
                Spacer()
                OutlineButton(title: L("Добавить приложение"), systemImage: "plus") { showAdd = true }
                Button { paused.toggle() } label: {
                    Image(systemName: paused ? "play.fill" : "pause.fill")
                        .frame(width: 38, height: 38)
                        .overlay(Circle().stroke(Theme.text.opacity(0.85), lineWidth: 1.2))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(.vertical, 20)
        }
        .sheet(isPresented: $showAdd) { AddAppSheet() }
    }
}

// MARK: - Модель графа

struct FlowGraph {
    struct Node: Identifiable {
        var id: String
        var title: String
        var subtitle: String
        var weight: Double
        var color: Color
    }

    struct Flow: Identifiable {
        var id: String { app + "|" + exit }
        var app: String
        var exit: String
        var weight: Double
        /// Текущая скорость, байт/с.
        var rate: Double
        var color: Color
    }

    var apps: [Node] = []
    var exits: [Node] = []
    var flows: [Flow] = []
    var totalBytes: Int64 = 0

    @MainActor
    init(model: AppModel, maxApps: Int = 8) {
        let stats = model.stats
        let entries = model.appEntries
            .map { ($0, stats.total("app:" + $0.key)) }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.key < $1.0.key }
            .prefix(maxApps)

        // Куда приложение может уйти по правилам доменов/IP/портов и наборам — помимо своего маршрута.
        let profile = model.profile
        let ruleTags = Set((profile.rules.filter(\.enabled).map(\.exitID) + profile.presets.filter(\.enabled).map(\.exitID))
            .compactMap { profile.exit(id: $0) }.map { model.resolution(for: $0).tag })

        var exitWeights: [String: Double] = [:]
        var exitApps: [String: Int] = [:]
        for (entry, bytes) in entries {
            // Граф показывает текущую настройку: маршрут приложения и выходы правил. Статистика за 24 ч
            // только распределяет толщину лент — иначе после смены выхода приложение ещё сутки
            // «вело» бы в старый.
            // Отключённый VPN: лента ведёт туда, куда трафик идёт на самом деле (резерв или блок).
            let exit = model.exit(for: entry)
            let ownTag = model.resolution(for: exit).tag
            let allowed = ruleTags.union([ownTag])
            // keys(prefix:) — Set с произвольным порядком; сортируем, чтобы порядок не менялся между пересчётами.
            var appFlows: [(String, Double)] = stats.keys(prefix: "flow:\(entry.key)|").sorted()
                .map { (String($0.split(separator: "|").last ?? ""), Double(stats.total($0))) }
                .filter { $0.1 > 0 && allowed.contains($0.0) }
            if !appFlows.contains(where: { $0.0 == ownTag }) {
                // Своего выхода в статистике ещё нет (маршрут только что сменили) — лента всё равно нужна.
                let rest = appFlows.reduce(0) { $0 + $1.1 }
                appFlows.append((ownTag, max(rest * 0.25, 1)))
            }
            let sum = appFlows.reduce(0) { $0 + $1.1 }
            let appWeight = max(Double(bytes), 1)
            for (tag, w) in appFlows {
                let share = appWeight * w / sum
                let rate = model.flowRates["flow:\(entry.key)|\(tag)"] ?? 0
                flows.append(Flow(app: entry.key, exit: tag, weight: share, rate: rate, color: model.color(forTag: tag)))
                exitWeights[tag, default: 0] += share
                exitApps[tag, default: 0] += 1
            }
            apps.append(Node(id: entry.key, title: entry.name, subtitle: Format.bytes(bytes), weight: appWeight, color: Theme.text2))
            totalBytes += bytes
        }

        for exit in model.profile.allExits where exitWeights[exit.tag] != nil {
            let bytes = stats.total("exit:" + exit.tag)
            let n = exitApps[exit.tag] ?? 0
            exits.append(Node(
                id: exit.tag,
                title: exit.kind == .block ? L("Заблокировано") : exit.name,
                subtitle: "\(Format.apps(n)) · \(Format.bytes(bytes))",
                weight: exitWeights[exit.tag] ?? 0,
                color: model.color(for: exit)
            ))
        }
        // Неизвестные теги (выход удалили, а статистика осталась) в граф не попадают.
        let known = Set(exits.map(\.id))
        flows.removeAll { !known.contains($0.exit) }

        // Выходы — в порядке среднего положения их приложений, чтобы ленты меньше перекрещивались.
        let appIndex = Dictionary(uniqueKeysWithValues: apps.enumerated().map { ($1.id, Double($0)) })
        var center: [String: Double] = [:]
        for e in exits {
            let fs = flows.filter { $0.exit == e.id }
            let w = fs.reduce(0) { $0 + $1.weight }
            center[e.id] = fs.reduce(0) { $0 + (appIndex[$1.app] ?? 0) * $1.weight } / max(w, 1e-9)
        }
        exits.sort { center[$0.id]! != center[$1.id]! ? center[$0.id]! < center[$1.id]! : $0.id < $1.id }
    }
}

// MARK: - Раскладка

struct FlowLayout {
    struct Band { var y: CGFloat; var height: CGFloat }

    var appBands: [String: Band] = [:]
    var exitBands: [String: Band] = [:]
    /// Полоса каждого потока на левом и правом краю.
    var flowEnds: [String: (left: Band, right: Band)] = [:]

    init(graph: FlowGraph, height: CGFloat) {
        appBands = Self.stack(graph.apps, height: height, gap: 18)
        exitBands = Self.stack(graph.exits, height: height, gap: 36)

        var leftCursor: [String: CGFloat] = appBands.mapValues(\.y)
        var rightCursor: [String: CGFloat] = exitBands.mapValues(\.y)
        let appTotals = Dictionary(grouping: graph.flows, by: \.app).mapValues { $0.reduce(0) { $0 + $1.weight } }
        let exitTotals = Dictionary(grouping: graph.flows, by: \.exit).mapValues { $0.reduce(0) { $0 + $1.weight } }

        // Детерминированный порядок: по приложению, затем по выходу, затем по id. Без второго и третьего
        // ключа потоки одного приложения менялись местами при каждом пересчёте (сортировка нестабильна),
        // и тонкий поток прыгал вверх-вниз по полосе приложения.
        let ordered = graph.flows.sorted { a, b in
            let ay = appBands[a.app]?.y ?? 0, by = appBands[b.app]?.y ?? 0
            if ay != by { return ay < by }
            let ey = exitBands[a.exit]?.y ?? 0, fy = exitBands[b.exit]?.y ?? 0
            if ey != fy { return ey < fy }
            return a.id < b.id
        }
        for f in ordered {
            guard let ab = appBands[f.app], let eb = exitBands[f.exit] else { continue }
            let lh = ab.height * CGFloat(f.weight / max(appTotals[f.app] ?? 1, 1e-9))
            let rh = eb.height * CGFloat(f.weight / max(exitTotals[f.exit] ?? 1, 1e-9))
            let l = Band(y: leftCursor[f.app]!, height: lh)
            let r = Band(y: rightCursor[f.exit]!, height: rh)
            leftCursor[f.app]! += lh
            rightCursor[f.exit]! += rh
            flowEnds[f.id] = (l, r)
        }
    }

    /// Раскладывает узлы по вертикали: высота ~ корню из веса, но не меньше минимальной.
    private static func stack(_ nodes: [FlowGraph.Node], height: CGFloat, gap: CGFloat) -> [String: Band] {
        guard !nodes.isEmpty else { return [:] }
        let minH: CGFloat = 40, maxH: CGFloat = 170
        let free = max(0, height - gap * CGFloat(nodes.count - 1) - minH * CGFloat(nodes.count))
        let weights = nodes.map { sqrt(max($0.weight, 0)) }
        let sum = max(weights.reduce(0, +), 1e-9)
        let heights = weights.map { min(maxH, minH + free * CGFloat($0 / sum)) }
        // Если узлов мало, стопка не растягивается на всю высоту, а стоит по центру.
        let total = heights.reduce(0, +) + gap * CGFloat(nodes.count - 1)
        var y = max(0, (height - total) / 2)
        var result: [String: Band] = [:]
        for (n, h) in zip(nodes, heights) {
            result[n.id] = Band(y: y, height: h)
            y += h + gap
        }
        return result
    }
}

// MARK: - Отрисовка

/// Состояние анимации между кадрами. Класс, а не @State: меняется в каждом кадре и не должен
/// вызывать перерисовку SwiftUI.
final class FlowAnimator {
    struct Flow {
        var y0, y1, h0, h1: Double
        var activity: Double
        var phase: Double
    }

    var flows: [String: Flow] = [:]
    var lastTime: Double?
    let start = Date.timeIntervalSinceReferenceDate

    /// Сдвигает состояние к целевому плавно (экспоненциально), не скачком.
    func step(now: Double) -> (dt: Double, ease: Double) {
        let dt = min(max(now - (lastTime ?? now), 0), 0.1)
        lastTime = now
        return (dt, 1 - exp(-dt * 3))
    }
}

struct FlowDiagram: View {
    @Environment(AppModel.self) private var model
    var graph: FlowGraph
    var size: CGSize
    var paused: Bool
    @State private var animator = FlowAnimator()

    private let labelWidth: CGFloat = 220
    private let exitLabelWidth: CGFloat = 230
    /// Предел частиц на поток; видимая часть зависит от плотности, края гаснут плавно.
    private static let maxParticles = 360
    private static let hueSteps = 8
    private static let alphaSteps = 5

    var body: some View {
        let layout = FlowLayout(graph: graph, height: size.height)
        let left = labelWidth + 16
        let right = size.width - exitLabelWidth - 16
        ZStack(alignment: .topLeading) {
            TimelineView(.animation(paused: paused)) { context in
                Canvas { ctx, _ in
                    draw(ctx: ctx, layout: layout, x0: left, x1: right, now: context.date.timeIntervalSinceReferenceDate)
                }
            }
            ForEach(graph.apps) { node in
                if let band = layout.appBands[node.id] {
                    HStack(spacing: 12) {
                        VStack(alignment: .trailing, spacing: 3) {
                            Text(node.title).font(Theme.font(13, .medium)).lineLimit(1)
                            Text(node.subtitle).font(Theme.font(11)).foregroundStyle(Theme.text3)
                        }
                        .transaction { $0.animation = nil }
                        AppIcon(key: node.id, size: 30)
                    }
                    .frame(width: labelWidth, alignment: .trailing)
                    .position(x: labelWidth / 2, y: band.y + band.height / 2)
                    .animation(.easeInOut(duration: 0.8), value: band.y + band.height / 2)
                }
            }
            ForEach(graph.exits) { node in
                if let band = layout.exitBands[node.id] {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(node.title).font(Theme.font(13, .semibold)).lineLimit(1)
                            Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                        }
                        Text(node.subtitle).font(Theme.font(11)).foregroundStyle(Theme.text3)
                    }
                    .transaction { $0.animation = nil }
                    .frame(width: exitLabelWidth, alignment: .leading)
                    .position(x: size.width - exitLabelWidth / 2, y: band.y + band.height / 2)
                    .animation(.easeInOut(duration: 0.8), value: band.y + band.height / 2)
                }
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private func draw(ctx: GraphicsContext, layout: FlowLayout, x0: CGFloat, x1: CGFloat, now: Double) {
        let width = Double(x1 - x0)
        guard width > 0 else { return }
        let (dt, k) = animator.step(now: now)
        FrameLog.shared.frame(dt)
        let time = now - animator.start

        // Вертикальные планки узлов.
        for (_, band) in layout.appBands {
            ctx.fill(Path(roundedRect: CGRect(x: x0 - 8, y: band.y, width: 2, height: band.height), cornerRadius: 1), with: .color(Theme.line))
        }
        for node in graph.exits {
            guard let band = layout.exitBands[node.id] else { continue }
            ctx.fill(Path(roundedRect: CGRect(x: x1 + 6, y: band.y, width: 3, height: band.height), cornerRadius: 1.5), with: .color(node.color))
        }

        var alive = Set<String>()
        for flow in graph.flows {
            guard let ends = layout.flowEnds[flow.id] else { continue }
            alive.insert(flow.id)
            // Целевые значения; текущие плавно к ним тянутся.
            let target = FlowAnimator.Flow(
                y0: ends.left.y + ends.left.height / 2, y1: ends.right.y + ends.right.height / 2,
                h0: max(ends.left.height, 4), h1: max(ends.right.height, 4),
                activity: min(1, log10(1 + flow.rate / 1024) / 3),  // 0 … ~1 МБ/с
                phase: 0
            )
            var f = animator.flows[flow.id] ?? target
            f.y0 += (target.y0 - f.y0) * k
            f.y1 += (target.y1 - f.y1) * k
            f.h0 += (target.h0 - f.h0) * k
            f.h1 += (target.h1 - f.h1) * k
            f.activity += (target.activity - f.activity) * k * 0.5
            // Фаза накапливается, поэтому смена скорости меняет только темп, а не положение частиц.
            f.phase += dt * (0.55 + 0.9 * f.activity)
            animator.flows[flow.id] = f

            drawRibbon(ctx: ctx, f, color: flow.color, x0: Double(x0), width: width)

            // Зерно — от id потока, а не от его номера: порядок потоков меняется вместе с трафиком,
            // и с номером все частицы потока перескакивали бы в новые места.
            let seed = Self.seed(flow.id)
            let density = 18 + (f.h0 + f.h1) * 0.9 + 160 * f.activity
            let count = min(Self.maxParticles, Int(density) + 8)
            // Частицы собираются в пути по (оттенок × прозрачность) — десятки вызовов fill вместо сотен.
            var buckets = [Path](repeating: Path(), count: Self.hueSteps * Self.alphaSteps)
            for i in 0..<count {
                let fade = min(1, max(0, (density - Double(i)) / 8))   // мягкий край плотности
                guard fade > 0 else { break }
                let hk = hash(Double(i), seed)
                let v = 36 + 44 * hash(seed, Double(i) * 1.7)
                let x = (hk * width + f.phase * v).truncatingRemainder(dividingBy: width)
                let p = x / width
                let lane = hash(Double(i) * 3.1, seed + 1) - 0.5
                let c = mix(f.y0, f.y1, ease(p))
                let hw = mix(f.h0, f.h1, p) * 0.5 * pinch(p)
                let y = c + lane * 2 * hw * 1.05
                let r = 0.5 + 1.1 * pow(hash(Double(i) * 0.7, seed + 2), 3)
                var alpha = 0.35 + 0.55 * hash(Double(i) * 1.9, seed + 3)
                alpha *= 0.7 + 0.3 * sin(time * 2.5 + hk * 60)
                alpha *= min(1, p * 12) * min(1, (1 - p) * 12) * fade
                let hue = min(Self.hueSteps - 1, Int(smoothstep(0.15, 0.85, p) * Double(Self.hueSteps)))
                let a = min(Self.alphaSteps - 1, Int(alpha * Double(Self.alphaSteps)))
                guard a > 0 || alpha > 0.05 else { continue }
                buckets[hue * Self.alphaSteps + a].addEllipse(in: CGRect(x: Double(x0) + x - r, y: y - r, width: r * 2, height: r * 2))
            }
            for h in 0..<Self.hueSteps {
                let col = Color.white.mix(with: flow.color, by: (Double(h) + 0.5) / Double(Self.hueSteps))
                for a in 0..<Self.alphaSteps where !buckets[h * Self.alphaSteps + a].isEmpty {
                    ctx.fill(buckets[h * Self.alphaSteps + a], with: .color(col.opacity((Double(a) + 0.5) / Double(Self.alphaSteps))))
                }
            }
        }
        animator.flows = animator.flows.filter { alive.contains($0.key) }
    }

    private func drawRibbon(ctx: GraphicsContext, _ f: FlowAnimator.Flow, color: Color, x0: Double, width: Double) {
        var ribbon = Path()
        let steps = 24
        for i in 0...steps {
            let p = Double(i) / Double(steps)
            let pt = CGPoint(x: x0 + width * p, y: mix(f.y0, f.y1, ease(p)) - mix(f.h0, f.h1, p) * 0.5 * pinch(p))
            if i == 0 { ribbon.move(to: pt) } else { ribbon.addLine(to: pt) }
        }
        for i in stride(from: steps, through: 0, by: -1) {
            let p = Double(i) / Double(steps)
            ribbon.addLine(to: CGPoint(x: x0 + width * p, y: mix(f.y0, f.y1, ease(p)) + mix(f.h0, f.h1, p) * 0.5 * pinch(p)))
        }
        ribbon.closeSubpath()
        ctx.fill(ribbon, with: .linearGradient(
            Gradient(colors: [Color.white.opacity(0.015), color.opacity(0.05)]),
            startPoint: CGPoint(x: x0, y: 0), endPoint: CGPoint(x: x0 + width, y: 0)))
    }

    private static func seed(_ id: String) -> Double {
        var h: UInt32 = 2_166_136_261
        for b in id.utf8 { h = (h ^ UInt32(b)) &* 16_777_619 }
        return Double(h % 10_000) * 0.731
    }

    // Функции из flow.glsl.
    private func ease(_ t: Double) -> Double {
        let t = min(max(t, 0), 1)
        return t * t * t * (t * (t * 6 - 15) + 10)
    }

    private func pinch(_ t: Double) -> Double { 1 - 0.5 * sin(.pi * min(max(t, 0), 1)) }

    private func mix(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

    private func smoothstep(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
        let t = min(max((x - e0) / (e1 - e0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    private func hash(_ a: Double, _ b: Double) -> Double {
        let x = sin(a * 127.1 + b * 311.7) * 43758.5453
        return x - x.rounded(.down)
    }
}

/// Замер ровности кадров: SPLITROUTE_FRAME_LOG=1 — раз в 5 с пишет в stderr интервалы между кадрами.
final class FrameLog: @unchecked Sendable {
    static let shared = FrameLog()
    private let enabled = ProcessInfo.processInfo.environment["SPLITROUTE_FRAME_LOG"] == "1"
    private var samples: [Double] = []
    private let lock = NSLock()

    func frame(_ dt: Double) {
        guard enabled, dt > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        samples.append(dt * 1000)
        guard samples.reduce(0, +) > 5000 else { return }
        let sorted = samples.sorted()
        let median = sorted[sorted.count / 2]
        let hitches = samples.filter { $0 > median * 1.6 }.count
        let line = String(format: "frames=%d median=%.1fms p99=%.1fms max=%.1fms hitches=%d\n",
                          samples.count, median, sorted[Int(Double(sorted.count) * 0.99)], sorted.last!, hitches)
        FileHandle.standardError.write(Data(line.utf8))
        samples.removeAll()
    }
}
