import SplitrouteCore
import SwiftUI

enum Screen: String, CaseIterable, Identifiable {
    case routes, apps, servers
    var id: String { rawValue }

    var title: String {
        switch self {
        case .routes: return "Маршруты"
        case .apps: return "Приложения"
        case .servers: return "Серверы"
        }
    }

    var icon: String {
        switch self {
        case .routes: return "point.3.connected.trianglepath.dotted"
        case .apps: return "square.grid.2x2"
        case .servers: return "globe"
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("screen") private var screen: Screen = .apps

    var body: some View {
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
                Group {
                    switch screen {
                    case .routes: RoutesView()
                    case .apps: AppsView()
                    case .servers: ServersView()
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
        .onAppear { model.start() }
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
            ForEach(Screen.allCases) { s in
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
            Spacer()
        }
        .frame(width: 92)
    }
}

struct TopBar: View {
    @Environment(AppModel.self) private var model

    private var statusColor: Color {
        switch model.state {
        case .running: return Theme.lime
        case .applying: return Theme.amber
        case .failed: return Theme.coral
        default: return Theme.text3
        }
    }

    private var statusTitle: String {
        switch model.state {
        case .running: return "Маршрутизация включена"
        case .applying: return "Применяю…"
        case .stopped: return "Маршрутизация выключена"
        case .notInstalled: return "Компонент не установлен"
        case .needsUpdate: return "Нужно обновить компонент"
        case .failed: return "Ошибка ядра"
        }
    }

    private var statusDetail: String {
        let connected = model.vpnServices.filter { $0.isConnected && !$0.isMesh }.map(\.name)
        var parts = [connected.isEmpty ? "VPN-приложения отключены" : connected.joined(separator: ", ")]
        if let iface = model.physicalInterface { parts.append("сеть \(iface)") }
        parts.append(Format.apps(model.profile.routes.count))
        return parts.joined(separator: " · ")
    }

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor.opacity(0.25))
                .frame(width: 18, height: 18)
                .overlay(StatusDot(color: statusColor, size: 8))
            Text(statusTitle).font(Theme.font(13, .semibold))
            Text("· " + statusDetail).font(Theme.font(13)).foregroundStyle(Theme.text2).lineLimit(1)
            Spacer()
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
            PrimaryButton(title: update ? "Обновить" : "Установить", systemImage: "arrow.down.circle") {
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
