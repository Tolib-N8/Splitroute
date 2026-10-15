import SplitrouteCore
import SwiftUI

extension AppModel {
    var statusColor: Color {
        switch state {
        case .running: return Theme.lime
        case .applying: return Theme.amber
        case .failed: return Theme.coral
        default: return Theme.text3
        }
    }

    var statusTitle: String {
        switch state {
        case .running: return L("Маршрутизация включена")
        case .applying: return L("Применяю…")
        case .stopped: return L("Маршрутизация выключена")
        case .notInstalled: return L("Компонент не установлен")
        case .needsUpdate: return L("Нужно обновить компонент")
        case .failed: return L("Ошибка ядра")
        }
    }
}

/// Мини-окно у значка в строке меню (design/app.pen → «Мини-окно (строка меню)»).
struct MenuBarPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @AppStorage("screen") private var screen: Screen = .apps
    /// Анимация крутится, только пока панель на экране.
    @State private var visible = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            flow.padding(.horizontal, 16)
            stats.padding(.horizontal, 16).padding(.top, 10)
            vpnSection
            activeSection
            suggestion
            footer.padding(.top, 14)
        }
        .frame(width: 380)
        .background(Color(red: 0.067, green: 0.067, blue: 0.067))
        .foregroundStyle(Theme.text)
        .preferredColorScheme(.dark)
        .onAppear { MainWindow.opener = { openWindow(id: "main") } }
        .onWindowVisibility { visible = $0 }
    }

    // MARK: Шапка

    private var header: some View {
        @Bindable var model = model
        return HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 9)
                .fill(LinearGradient(colors: [Color(red: 0.85, green: 1, blue: 0.42), Color(red: 0.61, green: 0.82, blue: 0.12)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 32, height: 32)
                .overlay(Image(systemName: "arrow.triangle.branch").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.bg))
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: "Splitroute").font(Theme.font(15, .bold))
                HStack(spacing: 6) {
                    StatusDot(color: model.statusColor, size: 7)
                    Text(model.statusTitle).font(Theme.font(12, .medium)).foregroundStyle(Theme.text2).lineLimit(1)
                }
            }
            Spacer()
            LimeToggle(isOn: $model.enabled)
                .disabled(model.state == .notInstalled)
        }
        .padding(EdgeInsets(top: 16, leading: 16, bottom: 14, trailing: 16))
    }

    // MARK: Потоки

    private var flow: some View {
        let graph = FlowGraph(model: model, maxApps: 5)
        return ZStack {
            if graph.apps.isEmpty {
                Text(L("Пока нечего показать")).font(Theme.font(12)).foregroundStyle(Theme.text3)
            } else {
                GeometryReader { geo in
                    FlowDiagram(graph: graph, size: geo.size, paused: !visible, style: .compact)
                }
                .padding(10)
            }
        }
        .frame(height: 176)
        .frame(maxWidth: .infinity)
        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var stats: some View {
        HStack(spacing: 14) {
            Label(Format.speed(model.speed.down), systemImage: "arrow.down")
            Label(Format.speed(model.speed.up), systemImage: "arrow.up")
            Spacer()
            ScenarioMenu()
        }
        .font(Theme.font(12, .semibold))
        .foregroundStyle(Theme.text2)
        .labelStyle(.titleAndIcon)
    }

    // MARK: VPN

    private var vpnExits: [Exit] {
        model.tunnelExits.filter { if case .vpnApp = $0.kind { return true } else { return false } }
    }

    @ViewBuilder private var vpnSection: some View {
        if !vpnExits.isEmpty {
            section(L("VPN")) {
                ForEach(vpnExits) { exit in
                    let up = model.isAvailable(exit)
                    let fallback = up ? nil : model.activeFallback(for: exit)
                    HStack(spacing: 10) {
                        StatusDot(color: up ? model.color(for: exit) : fallback != nil ? Theme.amber : Theme.coral, size: 8)
                        Text(exit.name).font(Theme.font(13, .semibold)).lineLimit(1)
                        Spacer()
                        Text(vpnState(exit, up: up))
                            .font(Theme.font(11, .medium))
                            .foregroundStyle(up ? Theme.text3 : fallback != nil ? Theme.amber : Theme.coral)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }

    private func vpnState(_ exit: Exit, up: Bool) -> String {
        if up { return L("подключён") + (model.vpnService(for: exit)?.interface.map { " · \($0)" } ?? "") }
        if let f = model.activeFallback(for: exit) { return L("отключён → \(f.name)") }
        return L("отключён") + ", " + model.fallbackNote(for: exit)
    }

    // MARK: Сейчас в сети

    private var activeKeys: [String] {
        model.activeApps.filter { $0.key != AppKey.system && $0.key != Bundle.main.bundlePath }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(4).map(\.key)
    }

    @ViewBuilder private var activeSection: some View {
        if !activeKeys.isEmpty {
            section(L("СЕЙЧАС В СЕТИ")) {
                ForEach(activeKeys, id: \.self) { key in
                    let entry = model.entry(forKey: key)
                    let exit = model.exit(for: entry)
                    HStack(spacing: 10) {
                        AppIcon(key: key, size: 24)
                        Text(entry.name).font(Theme.font(13, .medium)).lineLimit(1)
                        Spacer(minLength: 8)
                        RouteSegment(selected: RouteKind(exit), tunnelAvailable: model.preferredTunnel != nil, compact: true) { kind in
                            select(kind, for: entry, current: exit)
                        }
                        .frame(width: 176)
                    }
                }
            }
        }
    }

    /// Как в строке «Приложений»: VPN — текущий туннель или лучший доступный.
    private func select(_ kind: RouteKind, for entry: AppEntry, current: Exit) {
        let id: String
        switch kind {
        case .direct: id = Exit.directID
        case .block: id = Exit.blockID
        case .tunnel:
            if current.isTunnel { id = current.id } else if let t = model.preferredTunnel { id = t.id } else { return }
        }
        model.setRoute(appPath: entry.key, exitID: id)
    }

    // MARK: Подсказка

    @ViewBuilder private var suggestion: some View {
        if let first = model.suggestions.first {
            Button { openMain(.apps) } label: {
                HStack(spacing: 10) {
                    Image(systemName: "wand.and.stars").foregroundStyle(Theme.amber)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.suggestions.count == 1 ? L("Не открывается напрямую") : L("Не открываются напрямую: \(model.suggestions.count)"))
                            .font(Theme.font(12, .bold))
                        Text(model.suggestions.prefix(3).map(model.title(for:)).joined(separator: ", "))
                            .font(Theme.font(11, .medium)).foregroundStyle(Theme.text2).lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.text2)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(Theme.amber.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.amber.opacity(0.3)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(model.detail(for: first))
            .padding(.horizontal, 16).padding(.top, 14)
        }
    }

    // MARK: Низ

    private var footer: some View {
        HStack(spacing: 8) {
            Button { openMain(nil) } label: {
                Label(L("Открыть Splitroute"), systemImage: "macwindow")
                    .font(Theme.font(12, .bold))
                    .foregroundStyle(Theme.bg)
                    .padding(.horizontal, 14).frame(height: 32)
                    .background(Theme.lime, in: Capsule())
            }
            .buttonStyle(.plain)
            Spacer()
            if !Support.shared.links.isEmpty, let link = Support.shared.links.all.first {
                circleButton("heart", help: L("Поддержать Splitroute")) { Support.shared.open(link.url) }
            }
            circleButton("gearshape", help: L("Настройки")) { openMain(.settings) }
            circleButton("power", help: L("Выйти. Ядро продолжит работать, но без слежения за сетью")) { NSApp.terminate(nil) }
        }
        .padding(EdgeInsets(top: 12, leading: 16, bottom: 14, trailing: 16))
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private func circleButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 13)).foregroundStyle(Theme.text2)
                .frame(width: 32, height: 32)
                .overlay(Circle().stroke(Theme.line))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func openMain(_ target: Screen?) {
        if let target { screen = target }
        MainWindow.open()
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(Theme.font(11, .bold)).foregroundStyle(Theme.text3).tracking(0.8)
            content()
        }
        .padding(.horizontal, 16).padding(.top, 16)
    }
}
