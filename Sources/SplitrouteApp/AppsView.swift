import SplitrouteCore
import SwiftUI

enum RouteKind: String, CaseIterable {
    case tunnel = "VPN", direct = "Напрямую", block = "Блок"

    init(_ exit: Exit) {
        switch exit.kind {
        case .direct: self = .direct
        case .block: self = .block
        default: self = .tunnel
        }
    }
}

struct AppsView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var filter: RouteKind?
    @State private var showAdd = false

    private var entries: [AppEntry] {
        model.appEntries.filter { e in
            (query.isEmpty || e.name.localizedCaseInsensitiveContains(query) || e.detail.localizedCaseInsensitiveContains(query))
                && (filter == nil || RouteKind(model.exit(for: e)) == filter)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScreenHeader(
                title: "Приложения",
                summary: "\(model.profile.routes.count) настроено · \(model.detectedCount) обнаружено",
                footnote: model.updatedText
            ) {
                DefaultExitMenu()
            }
            HStack(spacing: 10) {
                SearchField(placeholder: "Найти приложение", text: $query).frame(maxWidth: 320)
                FilterPill(title: "Все", selected: filter == nil) { filter = nil }
                ForEach(RouteKind.allCases, id: \.self) { k in
                    FilterPill(title: k.rawValue, selected: filter == k) { filter = k }
                }
                Spacer()
                PrimaryButton(title: "Добавить приложение") { showAdd = true }
            }
            .padding(.top, 28)

            AppsTableHeader().padding(.top, 22)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(entries) { entry in
                        AppRow(entry: entry)
                        Divider().overlay(Theme.line)
                    }
                    if entries.isEmpty {
                        EmptyAppsHint(hasQuery: !query.isEmpty || filter != nil) { showAdd = true }
                            .padding(.top, 40)
                    }
                }
            }
            .scrollIndicators(.never)
        }
        .sheet(isPresented: $showAdd) { AddAppSheet() }
    }
}

private enum Column {
    static let route: CGFloat = 300
    static let server: CGFloat = 210
    static let traffic: CGFloat = 150
    static let menu: CGFloat = 36
}

struct AppsTableHeader: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Text("Приложение").frame(maxWidth: .infinity, alignment: .leading)
                Text("Маршрут").frame(width: Column.route, alignment: .leading)
                Text("Выход").frame(width: Column.server, alignment: .leading)
                Text("Трафик · 24 ч").frame(width: Column.traffic, alignment: .leading)
                Color.clear.frame(width: Column.menu, height: 1)
            }
            .font(Theme.font(11, .medium))
            .foregroundStyle(Theme.text2)
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
            Divider().overlay(Theme.line)
        }
    }
}

struct AppRow: View {
    @Environment(AppModel.self) private var model
    var entry: AppEntry
    @State private var hover = false

    private var exit: Exit { model.exit(for: entry) }
    private var routable: Bool { entry.key != AppKey.system }

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 14) {
                AppIcon(key: entry.key)
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.name).font(Theme.font(14, .medium))
                    Text(entry.route == nil ? "\(entry.detail) · без правила" : entry.detail)
                        .font(Theme.font(11)).foregroundStyle(Theme.text3).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(entry.route == nil ? 0.75 : 1)

            RouteSegment(selected: RouteKind(exit), dimmed: entry.route == nil, tunnelAvailable: !model.tunnelExits.isEmpty) { kind in
                select(kind)
            }
            .disabled(!routable)
            .frame(width: Column.route, alignment: .leading)

            ExitCell(exit: exit, editable: routable) { newExit in
                model.setRoute(appPath: entry.key, exitID: newExit.id)
            }
            .frame(width: Column.server, alignment: .leading)

            HStack(spacing: 10) {
                SparkBars(values: model.stats.bars("app:" + entry.key), color: model.color(for: exit))
                Text(Format.bytes(model.stats.total("app:" + entry.key))).font(Theme.font(12)).foregroundStyle(Theme.text2)
            }
            .frame(width: Column.traffic, alignment: .leading)

            Menu {
                if let route = entry.route {
                    Button("Убрать правило") { model.removeRoute(route) }
                }
                if entry.key != AppKey.system {
                    Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.key)]) }
                }
            } label: {
                Image(systemName: "ellipsis").foregroundStyle(Theme.text2)
            }
            .menuStyle(.button).buttonStyle(.plain)
            .menuIndicator(.hidden)
            .frame(width: Column.menu)
        }
        .padding(.horizontal, 16)
        .frame(height: 64)
        .background(hover ? Theme.surface : .clear, in: RoundedRectangle(cornerRadius: 10))
        .onHover { hover = $0 }
    }

    private func select(_ kind: RouteKind) {
        let id: String
        switch kind {
        case .direct: id = Exit.directID
        case .block: id = Exit.blockID
        case .tunnel:
            if exit.isTunnel { id = exit.id } else if let t = model.preferredTunnel { id = t.id } else { return }
        }
        model.setRoute(appPath: entry.key, exitID: id)
    }
}

/// Сегмент VPN | Напрямую | Блок.
struct RouteSegment: View {
    var selected: RouteKind
    var dimmed = false
    var tunnelAvailable = true
    var onSelect: (RouteKind) -> Void

    private func color(_ k: RouteKind) -> Color {
        switch k {
        case .tunnel: return Theme.lime
        case .direct: return Theme.blue
        case .block: return Theme.coral
        }
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(RouteKind.allCases, id: \.self) { k in
                let on = k == selected
                Button { onSelect(k) } label: {
                    HStack(spacing: 6) {
                        if on { StatusDot(color: color(k)) }
                        Text(k.rawValue)
                    }
                    .font(Theme.font(12, on ? .semibold : .regular))
                    .foregroundStyle(on ? Theme.text : Theme.text3)
                    .frame(maxWidth: .infinity)
                    .frame(height: 26)
                    .background(on ? Theme.surface2.opacity(dimmed ? 0.5 : 1) : .clear, in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(k == .tunnel && !tunnelAvailable)
                .help(k == .tunnel && !tunnelAvailable ? "Нет ни одного VPN-выхода — подключите VPN-приложение или добавьте конфиг на экране «Серверы»" : "")
            }
        }
        .padding(3)
        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
    }
}

/// Колонка «Выход»: для туннелей — выбор конкретного VPN.
struct ExitCell: View {
    @Environment(AppModel.self) private var model
    var exit: Exit
    var editable: Bool
    var onSelect: (Exit) -> Void

    var body: some View {
        if exit.isTunnel && editable {
            Menu {
                ForEach(model.tunnelExits) { e in
                    Button {
                        onSelect(e)
                    } label: {
                        Text(e.name + (model.isAvailable(e) ? "" : " — отключён"))
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    StatusDot(color: model.isAvailable(exit) ? model.color(for: exit) : Theme.coral)
                    Text(exit.name).font(Theme.font(12, .medium)).foregroundStyle(Theme.text).lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9)).foregroundStyle(Theme.text2)
                }
                .padding(.horizontal, 10)
                .frame(height: 32)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
            }
            .menuStyle(.button).buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        } else {
            Text(model.subtitle(for: exit)).font(Theme.font(12)).foregroundStyle(Theme.text3).lineLimit(1)
        }
    }
}

/// «Новые приложения → Напрямую ›» — выбор маршрута по умолчанию.
struct DefaultExitMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            ForEach(model.profile.allExits) { e in
                Button(e.name) { model.profile.defaultExitID = e.id }
            }
        } label: {
            HStack(spacing: 6) {
                Text("Приложения без правила → \(model.profile.exit(id: model.profile.defaultExitID)?.name ?? "Напрямую")")
                Image(systemName: "chevron.right").font(.system(size: 10))
            }
            .font(Theme.font(13))
            .foregroundStyle(Theme.text2)
        }
        .menuStyle(.button).buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

struct EmptyAppsHint: View {
    var hasQuery: Bool
    var add: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.grid.2x2").font(.system(size: 28)).foregroundStyle(Theme.text3)
            Text(hasQuery ? "Ничего не найдено" : "Пока нет правил")
                .font(Theme.font(15, .semibold))
            if !hasQuery {
                Text("Добавьте, например, WhatsApp через VPN и WeChat напрямую.\nПриложения, которые выходят в сеть, появятся здесь сами.")
                    .multilineTextAlignment(.center)
                    .font(Theme.font(12)).foregroundStyle(Theme.text2)
                PrimaryButton(title: "Добавить приложение", action: add).padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct AddAppSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var apps: [InstalledApp] {
        let configured = Set(model.profile.routes.map(\.bundleID))
        return model.installedApps.filter {
            !configured.contains($0.bundleID) && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Добавить приложение").font(Theme.font(20, .semibold))
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(Theme.text2)
            }
            SearchField(placeholder: "Найти приложение", text: $query)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Text("Программы из терминала").font(Theme.font(11, .medium)).foregroundStyle(Theme.text2).padding(.top, 4)
                    ForEach(AppCatalog.installedVersionedFolders.filter { f in model.profile.routes.allSatisfy { $0.path != f.path } }, id: \.path) { f in
                        pickRow(key: f.path, name: f.name, detail: f.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") + " — правило переживёт обновления") { kind in
                            add(path: f.path, kind)
                        }
                    }
                    Button("Выбрать программу или папку…") { pickProgram() }
                        .buttonStyle(.plain).font(Theme.font(12, .semibold)).foregroundStyle(Theme.lime)
                        .padding(.vertical, 10)
                    Divider().overlay(Theme.line)
                    Text("Приложения").font(Theme.font(11, .medium)).foregroundStyle(Theme.text2).padding(.top, 12)
                    ForEach(apps) { app in
                        HStack(spacing: 12) {
                            AppIcon(key: app.path, size: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(app.name).font(Theme.font(13, .medium))
                                Text(app.bundleID).font(Theme.font(11)).foregroundStyle(Theme.text3)
                            }
                            Spacer()
                            ForEach(RouteKind.allCases, id: \.self) { kind in
                                Button(kind.rawValue) { add(app, kind) }
                                    .buttonStyle(.plain)
                                    .font(Theme.font(12, .semibold))
                                    .padding(.horizontal, 10).frame(height: 26)
                                    .overlay(Capsule().stroke(Theme.line))
                                    .disabled(kind == .tunnel && model.tunnelExits.isEmpty)
                            }
                        }
                        .padding(.vertical, 8)
                        Divider().overlay(Theme.line)
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 560, height: 560)
        .background(Theme.bg)
        .foregroundStyle(Theme.text)
    }

    private func exitID(_ kind: RouteKind) -> String {
        switch kind {
        case .tunnel: return model.preferredTunnel?.id ?? Exit.directID
        case .direct: return Exit.directID
        case .block: return Exit.blockID
        }
    }

    private func add(_ app: InstalledApp, _ kind: RouteKind) {
        model.profile.setRoute(AppRoute(bundleID: app.bundleID, name: app.name, path: app.path, exitID: exitID(kind)))
    }

    private func add(path: String, _ kind: RouteKind) {
        model.setRoute(appPath: path, exitID: exitID(kind))
    }

    private func pickProgram() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.message = "Программа, .app или папка. Для программы правило ставится на её папку."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        let path = isDir.boolValue && !url.path.hasSuffix(".app") ? url.path + "/" : url.path
        add(path: path, .tunnel)
    }

    private func pickRow(key: String, name: String, detail: String, onPick: @escaping (RouteKind) -> Void) -> some View {
        HStack(spacing: 12) {
            AppIcon(key: key, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(Theme.font(13, .medium))
                Text(detail).font(Theme.font(11)).foregroundStyle(Theme.text3).lineLimit(1)
            }
            Spacer()
            ForEach(RouteKind.allCases, id: \.self) { kind in
                Button(kind.rawValue) { onPick(kind) }
                    .buttonStyle(.plain)
                    .font(Theme.font(12, .semibold))
                    .padding(.horizontal, 10).frame(height: 26)
                    .overlay(Capsule().stroke(Theme.line))
                    .disabled(kind == .tunnel && model.tunnelExits.isEmpty)
            }
        }
        .padding(.vertical, 8)
    }
}
