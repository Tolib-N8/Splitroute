import SplitrouteCore
import SwiftUI

enum Screen: String, CaseIterable, Identifiable {
    case routes, apps, servers, rules, journal, settings
    var id: String { rawValue }

    static let main: [Screen] = [.routes, .apps, .servers, .rules, .journal]

    var title: String {
        switch self {
        case .routes: return L("Маршруты")
        case .apps: return L("Приложения")
        case .servers: return L("Серверы")
        case .rules: return L("Правила")
        case .journal: return L("Журнал")
        case .settings: return L("Настройки")
        }
    }

    var icon: String {
        switch self {
        case .routes: return "point.3.connected.trianglepath.dotted"
        case .apps: return "square.grid.2x2"
        case .servers: return "globe"
        case .rules: return "line.3.horizontal.decrease"
        case .journal: return "waveform.path.ecg"
        case .settings: return "slider.horizontal.3"
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("screen") private var screen: Screen = .apps
    @AppStorage("onboardingDone") private var onboardingDone = false
    @Environment(Updater.self) private var updater
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ZStack {
            if onboardingDone {
                main
            } else {
                OnboardingView().ignoresSafeArea()
            }
        }
        .onAppear {
            // Уже настроенным пользователям приветствие не показываем.
            if UserDefaults.standard.object(forKey: "onboardingDone") == nil && !model.profile.routes.isEmpty {
                onboardingDone = true
            }
            model.start()
            updater.start()
            model.registerHotKeys { MainWindow.open() }
            MainWindow.opener = { openWindow(id: "main") }
            MainWindow.didOpen()
            let env = ProcessInfo.processInfo.environment
            if env["SPLITROUTE_PANEL_PREVIEW"] == "1" { openWindow(id: "panel-preview") }
            // SPLITROUTE_CLOSE_TEST=1 — закрыть главное окно через 5 с, как крестиком.
            if env["SPLITROUTE_CLOSE_TEST"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true }?.performClose(nil)
                }
            }
        }
        .onDisappear { MainWindow.didClose() }
    }

    private var main: some View {
        HStack(spacing: 0) {
            Sidebar(screen: $screen)
            VStack(spacing: 0) {
                TopBar()
                    .padding(.top, 14)
                    .padding(.trailing, 14)
                if case .notInstalled = model.state {
                    InstallBanner().padding(.top, 16).padding(.trailing, 32)
                } else if case .needsUpdate = model.state {
                    InstallBanner(update: true).padding(.top, 16).padding(.trailing, 32)
                } else if let error = model.lastError {
                    ErrorBanner(message: error).padding(.top, 16).padding(.trailing, 32)
                }
                UpdateBanner().padding(.trailing, 32)
                SupportBanner().padding(.trailing, 32)
                Group {
                    switch screen {
                    case .routes: RoutesView()
                    case .apps: AppsView()
                    case .servers: ServersView()
                    case .rules: RulesView()
                    case .journal: JournalView()
                    case .settings: SettingsView()
                    }
                }
                .padding(.top, 28)
                .padding(.trailing, 32)
                .padding(.leading, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .padding(.bottom, 16)
        .ignoresSafeArea()
        .background(Theme.bg)
        .foregroundStyle(Theme.text)
        .preferredColorScheme(.dark)
    }
}

struct Sidebar: View {
    @Binding var screen: Screen

    var body: some View {
        VStack(spacing: 22) {
            RoundedRectangle(cornerRadius: 10)
                .fill(Theme.lime)
                .frame(width: 36, height: 36)
                .overlay(Image(systemName: "arrow.triangle.branch").font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.bg))
                .padding(.top, 56)
                .padding(.bottom, 8)
            ForEach(Screen.main) { item($0) }
            Spacer()
            item(.settings).padding(.bottom, 8)
        }
        .frame(width: 92)
    }

    private func item(_ s: Screen) -> some View {
        Button { screen = s } label: {
            VStack(spacing: 6) {
                Image(systemName: s.icon)
                    .font(.system(size: 16))
                    .frame(width: 44, height: 34)
                    .background(screen == s ? Theme.surface2 : .clear, in: RoundedRectangle(cornerRadius: 9))
                Text(s.title).font(Theme.font(11, screen == s ? .semibold : .regular))
            }
            .foregroundStyle(screen == s ? Theme.lime : Theme.text2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct TopBar: View {
    @Environment(AppModel.self) private var model

    private var statusDetail: String {
        let connected = model.vpnServices.filter { $0.isConnected && !$0.isMesh }.map(\.name)
        var parts = [connected.isEmpty ? L("VPN-приложения отключены") : connected.joined(separator: ", ")]
        if let iface = model.physicalInterface { parts.append(L("сеть \(iface)")) }
        parts.append(Format.apps(model.profile.routes.count))
        return parts.joined(separator: " · ")
    }

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 10) {
            Circle()
                .fill(model.statusColor.opacity(0.25))
                .frame(width: 18, height: 18)
                .overlay(StatusDot(color: model.statusColor, size: 8))
            Text(model.statusTitle).font(Theme.font(13, .semibold))
            Text("· " + statusDetail).font(Theme.font(13)).foregroundStyle(Theme.text2).lineLimit(1)
            Spacer()
            ScenarioMenu()
            Label(Format.speed(model.speed.down), systemImage: "arrow.down")
                .font(Theme.font(12)).foregroundStyle(Theme.text2)
            Label(Format.speed(model.speed.up), systemImage: "arrow.up")
                .font(Theme.font(12)).foregroundStyle(Theme.text2)
                .padding(.trailing, 6)
            LimeToggle(isOn: $model.enabled)
                .disabled(model.state == .notInstalled)
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.line))
    }
}

struct InstallBanner: View {
    @Environment(AppModel.self) private var model
    var update = false

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "lock.shield").font(.system(size: 20)).foregroundStyle(Theme.lime)
            VStack(alignment: .leading, spacing: 4) {
                Text(update ? "Обновите системный компонент" : "Установите системный компонент")
                    .font(Theme.font(14, .semibold))
                Text("Ядро sing-box перехватывает трафик и раскладывает его по выходам. Понадобится пароль администратора — один раз.")
                    .font(Theme.font(12)).foregroundStyle(Theme.text2)
            }
            Spacer()
            PrimaryButton(title: update ? L("Обновить") : L("Установить"), systemImage: "arrow.down.circle") {
                Task { await model.installCore() }
            }
        }
        .padding(16)
        .background(Theme.lime.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.lime.opacity(0.35)))
    }
}

struct ErrorBanner: View {
    @Environment(AppModel.self) private var model
    var message: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.coral)
            Text(message).font(Theme.font(12)).foregroundStyle(Theme.text).lineLimit(3).textSelection(.enabled)
            Spacer()
            Button("Повторить") { model.scheduleApply(immediately: true) }
                .buttonStyle(.plain).font(Theme.font(12, .semibold)).foregroundStyle(Theme.lime)
            Button { model.lastError = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(Theme.text2)
        }
        .padding(12)
        .background(Theme.coral.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.coral.opacity(0.4)))
    }
}

/// «Доступна версия X» — над содержимым экрана.
struct UpdateBanner: View {
    @Environment(Updater.self) private var updater
    @State private var showNotes = false

    var body: some View {
        switch updater.state {
        case .available(let a):
            banner(icon: "arrow.down.circle.fill", title: L("Доступна версия \(a.version)"), detail: L("У вас \(Updater.currentVersion)")) {
                if !a.notes.isEmpty {
                    Button("Что нового") { showNotes = true }.buttonStyle(.plain).font(Theme.font(12)).foregroundStyle(Theme.text2)
                        .popover(isPresented: $showNotes) {
                            ScrollView { Text(a.notes).font(Theme.font(12)).padding(16).frame(width: 360, alignment: .leading) }.frame(maxHeight: 300)
                        }
                }
                PrimaryButton(title: L("Установить"), systemImage: "arrow.down") { Task { await updater.install(a) } }
            }
        case .downloading(let a, let p):
            banner(icon: "arrow.down.circle", title: L("Загружаю \(a.version)…"), detail: "\(Int(p * 100))%") {
                ProgressView(value: p).frame(width: 160)
            }
        case .installing:
            banner(icon: "gearshape.2", title: L("Устанавливаю обновление…"), detail: L("Splitroute перезапустится")) { ProgressView().controlSize(.small) }
        case .failed(let e):
            banner(icon: "exclamationmark.triangle", title: L("Обновление"), detail: e) {
                Button("Повторить") { Task { await updater.check(userInitiated: true) } }
                    .buttonStyle(.plain).font(Theme.font(12, .semibold)).foregroundStyle(Theme.lime)
            }
        default:
            EmptyView()
        }
    }

    private func banner<C: View>(icon: String, title: String, detail: String, @ViewBuilder trailing: () -> C) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(Theme.lime)
            Text(title).font(Theme.font(13, .semibold))
            Text(detail).font(Theme.font(12)).foregroundStyle(Theme.text2).lineLimit(2)
            Spacer()
            trailing()
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.lime.opacity(0.3)))
        .padding(.top, 14)
    }
}

/// Переключатель сценариев в верхней панели (виден, когда сценарии есть).
struct ScenarioMenu: View {
    @Environment(AppModel.self) private var model
    @AppStorage("screen") private var screen: Screen = .apps

    var body: some View {
        if let active = model.activeScenario {
            Menu {
                ForEach(model.scenarios) { s in
                    Button { model.activateScenario(s.id) } label: {
                        if s.id == active.id { Label(s.name, systemImage: "checkmark") } else { Text(s.name) }
                    }
                }
                Divider()
                Button("Настроить сценарии…") { screen = .settings }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "square.stack.3d.up").font(.system(size: 11))
                    Text(active.name).font(Theme.font(12, .semibold)).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.text2)
                }
                .padding(.horizontal, 10).frame(height: 28)
                .background(Theme.surface2, in: Capsule())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .padding(.trailing, 8)
        }
    }
}
