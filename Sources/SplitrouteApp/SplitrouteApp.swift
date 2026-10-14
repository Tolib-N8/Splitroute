import SplitrouteCore
import SwiftUI

@main
struct SplitrouteApp: App {
    @State private var model = AppModel()
    @AppStorage("showMenuBar") private var showMenuBar = true

    var body: some Scene {
        Window("Splitroute", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 1180, minHeight: 760)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 960)

        MenuBarExtra(isInserted: $showMenuBar) {
            MenuBarContent().environment(model)
        } label: {
            Image(systemName: model.state == .running ? "arrow.triangle.branch" : "arrow.triangle.branch")
                .symbolRenderingMode(.hierarchical)
                .opacity(model.state == .running ? 1 : 0.5)
                .task { model.start() }
        }
        .menuBarExtraStyle(.menu)
    }
}

/// Значок в строке меню: включить/выключить и быстро переключить маршрут запущенного приложения.
struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    private var runningApps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleURL != nil && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    var body: some View {
        @Bindable var model = model
        Toggle("Маршрутизация", isOn: $model.enabled)
        Text(statusLine)
        Divider()
        Section("Запущенные приложения") {
            ForEach(runningApps, id: \.processIdentifier) { app in
                let path = app.bundleURL!.path
                let current = app.bundleIdentifier.flatMap { model.profile.route(for: $0) }?.exitID ?? model.profile.defaultExitID
                Menu {
                    ForEach(model.profile.allExits) { exit in
                        Button {
                            model.setRoute(appPath: path, exitID: exit.id)
                        } label: {
                            if exit.id == current { Label(exit.name, systemImage: "checkmark") } else { Text(exit.name) }
                        }
                    }
                } label: {
                    Text("\(app.localizedName ?? path) — \(model.profile.exit(id: current)?.name ?? "")")
                }
            }
        }
        Divider()
        Button("Открыть Splitroute") {
            openWindow(id: "main")
            NSApp.activate()
        }
        .keyboardShortcut("o")
        Button("Выйти") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }

    private var statusLine: String {
        switch model.state {
        case .running:
            let vpn = model.vpnServices.filter { $0.isConnected && !$0.isMesh }.map(\.name)
            return vpn.isEmpty ? "Работает · VPN-приложения отключены" : "Работает · " + vpn.joined(separator: ", ")
        case .applying: return "Применяю…"
        case .stopped: return "Выключено"
        case .notInstalled: return "Компонент не установлен"
        case .needsUpdate: return "Нужно обновить компонент"
        case .failed(let e): return "Ошибка: " + e
        }
    }
}
