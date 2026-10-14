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
                title: "Куда идёт трафик",
                summary: "\(Format.bytes(graph.totalBytes)) за сутки · \(Format.apps(graph.apps.count))",
                footnote: model.updatedText
            ) {
                Text("Раздельный туннель · \(model.state.isRunning ? "Вкл" : "Выкл")")
                    .font(Theme.font(13)).foregroundStyle(Theme.text2)
            }
            if graph.apps.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 30)).foregroundStyle(Theme.text3)
                    Text("Пока нечего показать").font(Theme.font(15, .semibold))
                    Text("Настройте приложения или подождите, пока они выйдут в сеть").font(Theme.font(12)).foregroundStyle(Theme.text2)
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
                OutlineButton(title: "Добавить приложение", systemImage: "plus") { showAdd = true }
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
            .sorted { $0.1 > $1.1 }
            .prefix(maxApps)

        var exitWeights: [String: Double] = [:]
        var exitApps: [String: Int] = [:]
        for (entry, bytes) in entries {
            // Реальные потоки из статистики; если трафика ещё не было — показываем настроенный маршрут.
            var appFlows: [(String, Double)] = stats.keys(prefix: "flow:\(entry.key)|")
                .map { (String($0.split(separator: "|").last ?? ""), Double(stats.total($0))) }
                .filter { $0.1 > 0 }
            if appFlows.isEmpty {
                let exit = model.exit(for: entry)
                appFlows = [(exit.kind == .block ? "block" : exit.tag, 1)]
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
                title: exit.kind == .block ? "Заблокировано" : exit.name,
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
        exits.sort { center[$0.id]! < center[$1.id]! }
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

        // Порядок потоков на правом краю — по положению приложения, чтобы ленты меньше пересекались.
        let ordered = graph.flows.sorted { (appBands[$0.app]?.y ?? 0) < (appBands[$1.app]?.y ?? 0) }
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

struct FlowDiagram: View {
    @Environment(AppModel.self) private var model
    var graph: FlowGraph
    var size: CGSize
    var paused: Bool

    private let labelWidth: CGFloat = 220
    private let exitLabelWidth: CGFloat = 230

    var body: some View {
        let layout = FlowLayout(graph: graph, height: size.height)
        let left = labelWidth + 16
        let right = size.width - exitLabelWidth - 16
        ZStack(alignment: .topLeading) {
            TimelineView(.animation(paused: paused)) { context in
                Canvas { ctx, _ in
                    let t = context.date.timeIntervalSinceReferenceDate
                    draw(ctx: ctx, layout: layout, x0: left, x1: right, time: t)
                }
            }
            ForEach(graph.apps) { node in
                if let band = layout.appBands[node.id] {
                    HStack(spacing: 12) {
                        VStack(alignment: .trailing, spacing: 3) {
                            Text(node.title).font(Theme.font(13, .medium)).lineLimit(1)
                            Text(node.subtitle).font(Theme.font(11)).foregroundStyle(Theme.text3)
                        }
                        AppIcon(key: node.id, size: 30)
                    }
                    .frame(width: labelWidth, alignment: .trailing)
                    .position(x: labelWidth / 2, y: band.y + band.height / 2)
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
                    .frame(width: exitLabelWidth, alignment: .leading)
                    .position(x: size.width - exitLabelWidth / 2, y: band.y + band.height / 2)
                }
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private func draw(ctx: GraphicsContext, layout: FlowLayout, x0: CGFloat, x1: CGFloat, time: Double) {
        let width = x1 - x0

        // Вертикальные планки узлов.
        for (_, band) in layout.appBands {
            ctx.fill(Path(roundedRect: CGRect(x: x0 - 8, y: band.y, width: 2, height: band.height), cornerRadius: 1), with: .color(Theme.line))
        }
        for node in graph.exits {
            guard let band = layout.exitBands[node.id] else { continue }
            ctx.fill(Path(roundedRect: CGRect(x: x1 + 6, y: band.y, width: 3, height: band.height), cornerRadius: 1.5), with: .color(node.color))
        }

        for (index, flow) in graph.flows.enumerated() {
            guard let ends = layout.flowEnds[flow.id] else { continue }
            let y0 = ends.left.y + ends.left.height / 2
            let y1 = ends.right.y + ends.right.height / 2
            let h0 = max(ends.left.height, 4)
            let h1 = max(ends.right.height, 4)

            // Мягкое свечение ленты.
            var ribbon = Path()
            let steps = 24
            for i in 0...steps {
                let p = Double(i) / Double(steps)
                let c = mix(y0, y1, ease(p)), hw = mix(h0, h1, p) * 0.5 * pinch(p)
                let pt = CGPoint(x: x0 + width * p, y: c - hw)
                if i == 0 { ribbon.move(to: pt) } else { ribbon.addLine(to: pt) }
            }
            for i in stride(from: steps, through: 0, by: -1) {
                let p = Double(i) / Double(steps)
                let c = mix(y0, y1, ease(p)), hw = mix(h0, h1, p) * 0.5 * pinch(p)
                ribbon.addLine(to: CGPoint(x: x0 + width * p, y: c + hw))
            }
            ribbon.closeSubpath()
            ctx.fill(ribbon, with: .linearGradient(
                Gradient(colors: [Color.white.opacity(0.015), flow.color.opacity(0.05)]),
                startPoint: CGPoint(x: x0, y: 0), endPoint: CGPoint(x: x1, y: 0)))

            // Частицы: плотность растёт с текущей скоростью потока.
            let activity = min(1, log10(1 + flow.rate / 1024) / 3)  // 0 … ~1 МБ/с
            let count = Int(18 + (h0 + h1) * 0.9 + 160 * activity)
            let speedScale = 0.55 + 0.9 * activity
            let seed = Double(index) * 17.31
            for k in 0..<count {
                let hk = hash(Double(k), seed)
                let v = (36 + 44 * hash(seed, Double(k) * 1.7)) * speedScale
                let x = (hk * Double(width) + time * v).truncatingRemainder(dividingBy: Double(width))
                let p = x / Double(width)
                let lane = hash(Double(k) * 3.1, seed + 1) - 0.5
                let c = mix(y0, y1, ease(p))
                let hw = mix(h0, h1, p) * 0.5 * pinch(p)
                let y = c + lane * 2 * hw * 1.05
                let r = 0.5 + 1.1 * pow(hash(Double(k) * 0.7, seed + 2), 3)
                var alpha = 0.35 + 0.55 * hash(Double(k) * 1.9, seed + 3)
                alpha *= 0.7 + 0.3 * sin(time * 2.5 + hk * 60)
                alpha *= min(1, p * 12) * min(1, (1 - p) * 12)
                let col = Color.white.mix(with: flow.color, by: smoothstep(0.15, 0.85, p))
                ctx.fill(Path(ellipseIn: CGRect(x: Double(x0) + x - r, y: y - r, width: r * 2, height: r * 2)), with: .color(col.opacity(alpha)))
            }
        }
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
        var x = (a * 0.1031).truncatingRemainder(dividingBy: 1)
        var y = (b * 0.1031).truncatingRemainder(dividingBy: 1)
        var z = x
        let d = x * (y + 33.33) + y * (z + 33.33) + z * (x + 33.33)
        x += d; y += d; z += d
        let r = ((x + y) * z).truncatingRemainder(dividingBy: 1)
        return abs(r)
    }
}
