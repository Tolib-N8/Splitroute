import SplitrouteCore
import SwiftUI
import UniformTypeIdentifiers

struct JournalView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var appFilter: String?
    @State private var exitFilter: String?

    private var entries: [JournalEntry] {
        model.journalSnapshot.filter { e in
            (appFilter == nil || e.appKey == appFilter)
                && (exitFilter == nil || e.exitTag == exitFilter)
                && (query.isEmpty || e.host.localizedCaseInsensitiveContains(query)
                    || model.entry(forKey: e.appKey).name.localizedCaseInsensitiveContains(query))
        }
    }

    /// Выходы с трафиком за сутки, по убыванию.
    private var exitTotals: [(Exit, Int64)] {
        model.profile.allExits.map { ($0, model.stats.total("exit:" + $0.tag)) }
            .filter { pair in pair.1 > 0 || model.journal.entries.contains { $0.exitTag == pair.0.tag } }
            .sorted { $0.1 > $1.1 }
    }

    var body: some View {
        @Bindable var model = model
        let totals = exitTotals
        let sum = max(totals.reduce(0) { $0 + $1.1 }, 1)
        VStack(alignment: .leading, spacing: 0) {
            ScreenHeader(
                title: "Журнал",
                summary: "\(Format.bytes(totals.reduce(0) { $0 + $1.1 })) · \(Format.apps(Set(model.journal.entries.map(\.appKey)).count))",
                footnote: "Хранится \(Journal.keepDays) дней · только на этом Mac"
            ) {
                Text("Сегодня · \(model.journal.todayCount) соединений").font(Theme.font(13)).foregroundStyle(Theme.text2)
            }

            HStack(alignment: .bottom, spacing: 28) {
                VStack(alignment: .leading, spacing: 12) {
                    GeometryReader { geo in
                        HStack(spacing: 4) {
                            ForEach(totals, id: \.0.id) { exit, bytes in
                                Capsule().fill(model.color(for: exit))
                                    .frame(width: max(6, (geo.size.width - CGFloat(totals.count * 4)) * CGFloat(bytes) / CGFloat(sum)))
                            }
                        }
                    }
                    .frame(height: 8)
                    FlowLegend(totals: totals, sum: sum)
                }
                ExitHistogram(exits: totals.map(\.0)).frame(width: 520, height: 110)
            }
            .padding(.top, 30)

            HStack(spacing: 10) {
                Button { model.journalLive.toggle() } label: {
                    HStack(spacing: 8) {
                        StatusDot(color: model.journalLive ? Theme.lime : Theme.text3)
                        Text(model.journalLive ? "В реальном времени" : "На паузе")
                    }
                    .font(Theme.font(13, .semibold))
                    .foregroundStyle(model.journalLive ? Theme.lime : Theme.text2)
                    .padding(.horizontal, 14).frame(height: 36)
                    .background(model.journalLive ? Theme.lime.opacity(0.1) : Theme.surface, in: Capsule())
                }
                .buttonStyle(.plain)
                SearchField(placeholder: "Домен, приложение или IP", text: $query).frame(maxWidth: 280)
                filterMenu(title: appFilter.map { model.entry(forKey: $0).name } ?? "Все приложения") {
                    Button("Все приложения") { appFilter = nil }
                    ForEach(Array(Set(model.journal.entries.map(\.appKey))).sorted(), id: \.self) { key in
                        Button(model.entry(forKey: key).name) { appFilter = key }
                    }
                }
                filterMenu(title: exitFilter.flatMap { t in model.profile.allExits.first { $0.tag == t }?.name } ?? "Все маршруты") {
                    Button("Все маршруты") { exitFilter = nil }
                    ForEach(model.profile.allExits) { e in Button(e.name) { exitFilter = e.tag } }
                }
                Spacer()
                OutlineButton(title: "Экспорт", systemImage: "square.and.arrow.down") { export() }
            }
            .padding(.top, 28)

            JournalHeader().padding(.top, 20)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(entries.prefix(500)) { e in
                        JournalRow(entry: e)
                        Divider().overlay(Theme.line)
                    }
                    if entries.isEmpty {
                        Text(model.state.isRunning ? "Соединений пока нет" : "Ядро остановлено — включите маршрутизацию")
                            .font(Theme.font(13)).foregroundStyle(Theme.text2).padding(.top, 40)
                    }
                }
            }
            .scrollIndicators(.never)
        }
    }

    private func filterMenu<C: View>(title: String, @ViewBuilder content: () -> C) -> some View {
        Menu { content() } label: {
            HStack(spacing: 8) {
                Text(title).font(Theme.font(13)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9)).foregroundStyle(Theme.text2)
            }
            .padding(.horizontal, 12).frame(height: 36)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
            .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "splitroute-\(Journal.dayString(Date())).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let csv = Journal.csv(entries, appName: { model.entry(forKey: $0).name }) { tag in
            model.profile.allExits.first { $0.tag == tag }?.name ?? tag
        }
        try? csv.write(to: url, atomically: true, encoding: .utf8)
    }
}

struct FlowLegend: View {
    @Environment(AppModel.self) private var model
    var totals: [(Exit, Int64)]
    var sum: Int64

    var body: some View {
        HStack(spacing: 22) {
            ForEach(totals, id: \.0.id) { exit, bytes in
                HStack(spacing: 7) {
                    StatusDot(color: model.color(for: exit), size: 7)
                    Text(exit.kind == .block ? "Заблокировано" : exit.name).font(Theme.font(12, .semibold))
                    Text("\(Int((Double(bytes) / Double(sum) * 100).rounded()))% · \(Format.bytes(bytes))")
                        .font(Theme.font(12)).foregroundStyle(Theme.text3)
                }
            }
        }
    }
}

/// 24 часа, столбики сложены по выходам.
struct ExitHistogram: View {
    @Environment(AppModel.self) private var model
    var exits: [Exit]

    var body: some View {
        let series = exits.map { (model.color(for: $0), model.stats.bars("exit:" + $0.tag, count: 24)) }
        let totals = (0..<24).map { h in series.reduce(Int64(0)) { $0 + $1.1[h] } }
        let maxV = max(totals.max() ?? 1, 1)
        VStack(spacing: 6) {
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(0..<24, id: \.self) { h in
                    VStack(spacing: 1) {
                        ForEach(Array(series.enumerated().reversed()), id: \.offset) { _, s in
                            if s.1[h] > 0 {
                                Rectangle().fill(s.0.opacity(0.85))
                                    .frame(height: max(1.5, 86 * CGFloat(s.1[h]) / CGFloat(maxV)))
                            }
                        }
                        if totals[h] == 0 { Rectangle().fill(Theme.line).frame(height: 2) }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 90, alignment: .bottom)
            HStack {
                Text("−24 ч"); Spacer(); Text("−12 ч"); Spacer(); Text("сейчас")
            }
            .font(Theme.font(10)).foregroundStyle(Theme.text3)
        }
    }
}

private enum JCol {
    static let time: CGFloat = 80, app: CGFloat = 190, route: CGFloat = 170, reason: CGFloat = 170, bytes: CGFloat = 80, dur: CGFloat = 60
}

struct JournalHeader: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Время").frame(width: JCol.time, alignment: .leading)
                Text("Приложение").frame(width: JCol.app, alignment: .leading)
                Text("Хост").frame(maxWidth: .infinity, alignment: .leading)
                Text("Маршрут").frame(width: JCol.route, alignment: .leading)
                Text("Почему").frame(width: JCol.reason, alignment: .leading)
                Text("Объём").frame(width: JCol.bytes, alignment: .leading)
                Text("Длит.").frame(width: JCol.dur, alignment: .leading)
            }
            .font(Theme.font(11, .medium)).foregroundStyle(Theme.text2)
            .padding(.horizontal, 14).padding(.bottom, 10)
            Divider().overlay(Theme.line)
        }
    }
}

struct JournalRow: View {
    @Environment(AppModel.self) private var model
    var entry: JournalEntry

    private static let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        let exit = model.profile.allExits.first { $0.tag == entry.exitTag }
        let app = model.entry(forKey: entry.appKey)
        let blocked = exit?.kind == .block
        HStack(spacing: 12) {
            Text(Self.timeFormat.string(from: entry.start))
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.text3)
                .frame(width: JCol.time, alignment: .leading)
            HStack(spacing: 8) {
                AppIcon(key: entry.appKey, size: 20)
                Text(app.name).font(Theme.font(12, .medium)).lineLimit(1)
            }
            .frame(width: JCol.app, alignment: .leading)
            Text(entry.host).font(.system(size: 12, design: .monospaced)).lineLimit(1)
                .foregroundStyle(blocked ? Theme.text3 : Theme.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            HStack(spacing: 6) {
                StatusDot(color: exit.map(model.color(for:)) ?? Theme.text3)
                Text(blocked ? "Заблокировано" : exit?.name ?? entry.exitTag).font(Theme.font(12, .medium)).lineLimit(1)
            }
            .frame(width: JCol.route, alignment: .leading)
            Text(entry.reason).font(Theme.font(12)).foregroundStyle(Theme.text2).lineLimit(1).frame(width: JCol.reason, alignment: .leading)
            Text(blocked ? "—" : Format.bytes(entry.bytes)).font(Theme.font(12)).frame(width: JCol.bytes, alignment: .leading)
            Text(blocked ? "—" : duration).font(Theme.font(12)).foregroundStyle(Theme.text3).frame(width: JCol.dur, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
    }

    private var duration: String {
        let d = entry.duration
        if entry.end == nil { return "идёт" }
        return d < 60 ? String(format: "%.0f с", d) : String(format: "%.0f мин", d / 60)
    }
}
