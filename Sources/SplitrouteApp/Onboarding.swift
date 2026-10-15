import AppKit
import SplitrouteCore
import SwiftUI

/// Первый запуск: перенос в «Программы», установка компонента, выходы, приложения, итог.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("onboardingDone") private var done = false
    @State private var step: Step = .welcome
    @State private var picks: [String: RouteKind?] = [:]   // путь → выбранный маршрут (nil — не трогать)
    @State private var cnDirect = true
    @State private var showImport = false
    @State private var moveError: String?

    enum Step: Int, CaseIterable { case welcome, move, component, exits, apps, finish }

    private static var inApplications: Bool { Bundle.main.bundlePath.hasPrefix("/Applications/") }

    private var steps: [Step] {
        Step.allCases.filter { $0 != .move || (!Self.inApplications && HelperClient.runningFromBundle) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(steps, id: \.self) { s in
                    Capsule().fill(s.rawValue <= step.rawValue ? Theme.lime : Theme.line).frame(width: 28, height: 4)
                }
            }
            .padding(.top, 26)
            Group {
                switch step {
                case .welcome: welcome
                case .move: move
                case .component: component
                case .exits: exits
                case .apps: apps
                case .finish: finish
                }
            }
            .frame(maxWidth: 620, maxHeight: .infinity)
            .padding(.horizontal, 40)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
        .foregroundStyle(Theme.text)
        .sheet(isPresented: $showImport) { ImportSheet() }
        .onAppear { preparePicks() }
    }

    private func next() {
        guard let i = steps.firstIndex(of: step), i + 1 < steps.count else { return }
        withAnimation(.snappy) { step = steps[i + 1] }
    }

    private func back() {
        guard let i = steps.firstIndex(of: step), i > 0 else { return }
        withAnimation(.snappy) { step = steps[i - 1] }
    }

    private func footer(primary: String, enabled: Bool = true, skip: String? = nil, onSkip: (() -> Void)? = nil, action: @escaping () -> Void) -> some View {
        HStack {
            if step != .welcome {
                Button(L("Назад")) { back() }.buttonStyle(.plain).font(Theme.font(13)).foregroundStyle(Theme.text2)
            }
            Spacer()
            if let skip {
                Button(skip) { (onSkip ?? next)() }.buttonStyle(.plain).font(Theme.font(13)).foregroundStyle(Theme.text2).padding(.trailing, 12)
            }
            PrimaryButton(title: primary, systemImage: "arrow.right", action: action)
                .disabled(!enabled).opacity(enabled ? 1 : 0.4)
        }
        .padding(.bottom, 32)
    }

    private func header(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(Theme.font(28, .semibold))
            Text(subtitle).font(Theme.font(14)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 48)
    }

    // MARK: Шаги

    private var welcome: some View {
        VStack(spacing: 0) {
            Spacer()
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 112, height: 112)
            Text("Splitroute").font(Theme.font(34, .semibold)).padding(.top, 18)
            Text(L("Каждое приложение — своим путём")).font(Theme.font(15)).foregroundStyle(Theme.text2).padding(.top, 6)
            VStack(alignment: .leading, spacing: 16) {
                feature("arrow.triangle.branch", L("VPN — только тем, кому он нужен"),
                        L("WhatsApp, Chrome, Claude идут через VPN, остальное — напрямую. Одновременно, без переключений."))
                feature("checkmark.shield", L("Ваш VPN остаётся вашим"),
                        L("Работает поверх VPN-приложений (ZoogVPN, AIRLINK…) и своих конфигов: VLESS, WireGuard, OpenVPN."))
                feature("lock", L("Без утечек"),
                        L("Если VPN отключился, его приложения блокируются, а не уходят в интернет напрямую."))
            }
            .padding(.top, 36)
            Spacer()
            footer(primary: L("Начать")) { next() }
        }
    }

    private func feature(_ icon: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.system(size: 16)).foregroundStyle(Theme.lime)
                .frame(width: 36, height: 36).background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Theme.font(14, .semibold))
                Text(text).font(Theme.font(12)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var move: some View {
        VStack(spacing: 0) {
            header(L("Переместите в «Программы»"),
                   L("Оттуда Splitroute сможет сам обновляться и запускаться вместе с macOS. Сейчас приложение открыто из \((Bundle.main.bundlePath as NSString).deletingLastPathComponent.replacingOccurrences(of: NSHomeDirectory(), with: "~"))."))
            Spacer()
            Image(systemName: "folder.badge.plus").font(.system(size: 54)).foregroundStyle(Theme.lime)
            if let moveError { Text(moveError).font(Theme.font(12)).foregroundStyle(Theme.coral).padding(.top, 16) }
            Spacer()
            footer(primary: L("Переместить и перезапустить"), skip: L("Пропустить")) { moveToApplications() }
        }
    }

    private var component: some View {
        VStack(spacing: 0) {
            header(L("Системный компонент"),
                   L("Ядро sing-box перехватывает трафик и раскладывает его по выходам. Оно работает от администратора, поэтому macOS один раз спросит пароль."))
            Spacer()
            VStack(spacing: 14) {
                switch model.state {
                case .notInstalled, .needsUpdate:
                    Image(systemName: "lock.shield").font(.system(size: 54)).foregroundStyle(Theme.lime)
                    PrimaryButton(title: model.state == .needsUpdate ? L("Обновить компонент") : L("Установить компонент"), systemImage: "arrow.down.circle") {
                        Task { await model.installCore() }
                    }
                case .applying:
                    ProgressView().controlSize(.large)
                    Text(L("Устанавливаю…")).font(Theme.font(13)).foregroundStyle(Theme.text2)
                case .failed(let e):
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 44)).foregroundStyle(Theme.coral)
                    Text(e).font(Theme.font(12)).foregroundStyle(Theme.text2).multilineTextAlignment(.center)
                    PrimaryButton(title: L("Ещё раз"), systemImage: "arrow.clockwise") { Task { await model.installCore() } }
                case .running, .stopped:
                    Image(systemName: "checkmark.shield.fill").font(.system(size: 54)).foregroundStyle(Theme.lime)
                    Text(L("Компонент установлен")).font(Theme.font(15, .semibold))
                }
            }
            Spacer()
            footer(primary: L("Дальше"), enabled: model.state == .running || model.state == .stopped,
                   skip: HelperClient.runningFromBundle ? nil : L("Пропустить")) { next() }
        }
    }

    private var exits: some View {
        let vpns = model.vpnServices.filter { !$0.isMesh }
        return VStack(spacing: 0) {
            header(L("Куда направлять трафик"),
                   L("Splitroute не заменяет ваш VPN, а отправляет в него нужные приложения. Найдены VPN-приложения из Системных настроек; можно добавить и свой конфиг."))
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(vpns) { s in
                        HStack(spacing: 12) {
                            Image(systemName: "network.badge.shield.half.filled").foregroundStyle(s.isConnected ? Theme.lime : Theme.text3)
                            Text(s.name).font(Theme.font(14, .medium))
                            Spacer()
                            Text(s.isConnected ? L("Подключён") : L("Отключён")).font(Theme.font(12)).foregroundStyle(s.isConnected ? Theme.lime : Theme.text3)
                        }
                        .padding(14).background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
                    }
                    ForEach(model.tunnelExits.filter { if case .proxy = $0.kind { return true }; return false }) { e in
                        HStack(spacing: 12) {
                            Image(systemName: "doc.text").foregroundStyle(Theme.lime)
                            Text(e.name).font(Theme.font(14, .medium))
                            Spacer()
                            Text(model.subtitle(for: e)).font(Theme.font(12)).foregroundStyle(Theme.text3).lineLimit(1)
                        }
                        .padding(14).background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
                    }
                    if vpns.isEmpty && model.tunnelExits.isEmpty {
                        Text(L("VPN-приложений не найдено. Подключите VPN-приложение или импортируйте свой конфиг."))
                            .font(Theme.font(13)).foregroundStyle(Theme.text2).padding(.vertical, 20)
                    }
                    OutlineButton(title: L("Импортировать ссылку, подписку, .conf или .ovpn"), systemImage: "square.and.arrow.down") { showImport = true }
                        .padding(.top, 8)
                }
                .padding(.top, 24)
            }
            .scrollIndicators(.never)
            footer(primary: L("Дальше"), skip: model.tunnelExits.isEmpty ? L("Позже") : nil) { preparePicks(); next() }
        }
    }

    /// Популярные приложения и рекомендуемый маршрут (для пользователя в Китае).
    private static let suggestions: [(bundleID: String, kind: RouteKind)] = [
        ("net.whatsapp.WhatsApp", .tunnel), ("ru.keepcoder.Telegram", .tunnel), ("org.telegram.desktop", .tunnel),
        ("com.google.Chrome", .tunnel), ("org.mozilla.firefox", .tunnel), ("company.thebrowser.Browser", .tunnel),
        ("com.anthropic.claudefordesktop", .tunnel), ("com.openai.chat", .tunnel), ("com.hnc.Discord", .tunnel),
        ("com.spotify.client", .tunnel), ("com.tinyspeck.slackmacgap", .tunnel), ("notion.id", .tunnel),
        ("com.figma.Desktop", .tunnel), ("com.microsoft.VSCode", .tunnel), ("com.todesktop.230313mzl4w4u92", .tunnel),
        ("com.tencent.xinWeChat", .direct), ("com.tencent.qq", .direct), ("com.tencent.WeWorkMac", .direct),
        ("com.alibaba.DingTalkMac", .direct), ("com.bytedance.macos.feishu", .direct), ("com.netease.163music", .direct),
        ("com.baidu.BaiduNetdisk-mac", .direct), ("com.alipay.mobile.client", .direct),
    ]

    private var candidates: [(path: String, name: String, kind: RouteKind)] {
        var out: [(String, String, RouteKind)] = []
        for (id, kind) in Self.suggestions {
            if let app = model.installedApps.first(where: { $0.bundleID == id }) { out.append((app.path, app.name, kind)) }
        }
        for f in AppCatalog.installedVersionedFolders { out.append((f.path, f.name, .tunnel)) }
        return out
    }

    private func preparePicks() {
        let hasTunnel = !model.tunnelExits.isEmpty
        for c in candidates where picks[c.path] == nil {
            if let route = model.profile.routes.first(where: { $0.path == c.path }) {
                picks[c.path] = RouteKind(model.profile.exit(id: route.exitID) ?? .direct)
            } else {
                picks[c.path] = (c.kind == .tunnel && !hasTunnel) ? .some(nil) : c.kind
            }
        }
    }

    private var apps: some View {
        VStack(spacing: 0) {
            header(L("Приложения"),
                   L("Мы подобрали маршруты для установленных приложений. Поменять можно в любой момент на экране «Приложения»."))
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(candidates, id: \.path) { c in
                        HStack(spacing: 12) {
                            AppIcon(key: c.path, size: 30)
                            Text(c.name).font(Theme.font(13, .medium))
                            Spacer()
                            Picker("", selection: Binding(get: { picks[c.path] ?? nil }, set: { picks[c.path] = $0 })) {
                                Text("VPN").tag(RouteKind?.some(.tunnel))
                                Text(L("Напрямую")).tag(RouteKind?.some(.direct))
                                Text(L("Не трогать")).tag(RouteKind?.none)
                            }
                            .pickerStyle(.segmented).labelsHidden().frame(width: 260)
                        }
                        .padding(.vertical, 8)
                        Divider().overlay(Theme.line)
                    }
                    if candidates.isEmpty {
                        Text(L("Популярных приложений не нашлось — добавьте свои на экране «Приложения»."))
                            .font(Theme.font(13)).foregroundStyle(Theme.text2).padding(.vertical, 20)
                    }
                }
                .padding(.top, 20)
            }
            .scrollIndicators(.never)
            footer(primary: L("Дальше")) { applyPicks(); next() }
        }
    }

    private var finish: some View {
        @Bindable var model = model
        return VStack(spacing: 0) {
            header(L("Почти готово"), L("Последние настройки. Всё можно поменять позже в «Настройках»."))
            VStack(spacing: 0) {
                SettingRow(L("Остальные приложения"), L("Куда идут приложения без правила")) {
                    Picker("", selection: $model.profile.defaultExitID) {
                        ForEach(model.profile.allExits.filter { $0.kind != .block }) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden().frame(width: 180)
                }
                SettingRow(L("Китайские сервисы — всегда напрямую"), L("Банки, WeChat, Alipay, Baidu и другие — даже из браузера через VPN")) {
                    LimeToggle(isOn: $cnDirect)
                }
                SettingRow("Kill switch", L("Если VPN отключился и другого нет — блокировать его приложения")) {
                    LimeToggle(isOn: $model.profile.killSwitch)
                }
            }
            .padding(.top, 24)
            Spacer()
            footer(primary: L("Готово")) {
                Task {
                    if cnDirect, let info = PresetInfo.info("cn") { await model.setPreset(info, enabled: true) }
                    model.enabled = true
                    withAnimation { done = true }
                }
            }
        }
    }

    // MARK: Действия

    private func applyPicks() {
        for c in candidates {
            guard let kind = picks[c.path] ?? nil else { continue }
            let exitID: String
            switch kind {
            case .tunnel:
                guard let t = model.preferredTunnel else { continue }
                exitID = t.id
            case .direct: exitID = Exit.directID
            case .block: exitID = Exit.blockID
            }
            model.setRoute(appPath: c.path, exitID: exitID)
        }
    }

    private func moveToApplications() {
        let src = Bundle.main.bundleURL
        let dst = URL(fileURLWithPath: "/Applications/Splitroute.app")
        do {
            if FileManager.default.fileExists(atPath: dst.path) {
                try FileManager.default.trashItem(at: dst, resultingItemURL: nil)
            }
            try FileManager.default.copyItem(at: src, to: dst)
            let x = Process()
            x.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
            x.arguments = ["-dr", "com.apple.quarantine", dst.path]
            try? x.run(); x.waitUntilExit()
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/bin/sh")
            open.arguments = ["-c", "sleep 1; /usr/bin/open '\(dst.path)'"]
            try open.run()
            NSApp.terminate(nil)
        } catch {
            moveError = L("Не удалось переместить: \(error.localizedDescription). Перетащите Splitroute в «Программы» вручную.")
        }
    }
}
