import ServiceManagement
import SplitrouteCore
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("showMenuBar") private var showMenuBar = true
    @AppStorage("enableOnLaunch") private var enableOnLaunch = true
    @State private var loginItem = SMAppService.mainApp.status == .enabled
    @State private var dns = ""
    @State private var confirmReset = false
    @State private var confirmUninstall = false
    @Environment(Updater.self) private var updater
    @AppStorage("onboardingDone") private var onboardingDone = true

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 0) {
            ScreenHeader(
                title: "Настройки",
                summary: "Изменения применяются сразу",
                footnote: model.ruleSetsUpdated.map { "Базы доменов: " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "Базы доменов не загружены"
            ) {
                Text("Splitroute \(Updater.currentVersion) · ядро sing-box \(model.singBoxVersion)").font(Theme.font(13)).foregroundStyle(Theme.text2)
            }
            HStack(alignment: .top, spacing: 20) {
                ScrollView {
                    HStack(alignment: .top, spacing: 32) {
                        VStack(alignment: .leading, spacing: 0) {
                            SectionTitle("Запуск")
                            SettingRow("Открывать при входе в систему", "Splitroute стартует вместе с macOS") {
                                LimeToggle(isOn: Binding(get: { loginItem }, set: setLoginItem))
                            }
                            SettingRow("Включать маршрутизацию при запуске", "Иначе — как было при выходе") {
                                LimeToggle(isOn: $enableOnLaunch)
                            }
                            SettingRow("Значок в строке меню", "Переключать маршруты, не открывая окно") {
                                LimeToggle(isOn: $showMenuBar)
                            }
                            SectionTitle("Обновления").padding(.top, 28)
                            SettingRow("Проверять автоматически", updateStatus) {
                                LimeToggle(isOn: Binding(get: { updater.autoCheck }, set: { updater.autoCheck = $0 }))
                            }
                            SettingRow("Версия \(Updater.currentVersion) (\(Updater.currentBuild))", "Обновления подписаны ключом разработчика и проверяются перед установкой") {
                                if let a = updater.availableUpdate {
                                    Button("Установить \(a.version)") { Task { await updater.install(a) } }
                                        .buttonStyle(.plain).font(Theme.font(12, .semibold)).foregroundStyle(Theme.lime)
                                } else {
                                    Button(updater.state == .checking ? "Проверяю…" : "Проверить") { Task { await updater.check(userInitiated: true) } }
                                        .buttonStyle(.plain).font(Theme.font(12, .semibold)).foregroundStyle(Theme.lime)
                                        .disabled(updater.state == .checking)
                                }
                            }
                            SettingRow("Приветствие", "Пройти первую настройку ещё раз") {
                                Button("Показать") { onboardingDone = false }
                                    .buttonStyle(.plain).font(Theme.font(12, .semibold)).foregroundStyle(Theme.lime)
                            }
                            SectionTitle("Туннель").padding(.top, 28)
                            SettingRow("Маршрут по умолчанию", "Для приложений и доменов без правил") {
                                Menu {
                                    ForEach(model.profile.allExits) { e in Button(e.name) { model.profile.defaultExitID = e.id } }
                                } label: {
                                    menuLabel(model.profile.exit(id: model.profile.defaultExitID)?.name ?? "Напрямую")
                                }
                                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                            }
                            SettingRow("Kill switch", "Если VPN-приложение отключилось — блокировать его приложения, а не пускать напрямую") {
                                LimeToggle(isOn: $model.profile.killSwitch)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        VStack(alignment: .leading, spacing: 0) {
                            SectionTitle("DNS и IPv6")
                            VStack(alignment: .leading, spacing: 8) {
                                Text("DNS-сервер для VPN-выходов").font(Theme.font(13, .semibold))
                                Text("Запросы, которые проходят через ядро, резолвятся через подключённый VPN")
                                    .font(Theme.font(11)).foregroundStyle(Theme.text2)
                                HStack {
                                    TextField("", text: $dns, prompt: Text("1.1.1.1").foregroundStyle(Theme.text3))
                                        .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
                                        .onSubmit { saveDNS() }
                                    if dns != model.profile.tunnelDNS {
                                        Button("Сохранить") { saveDNS() }.buttonStyle(.plain)
                                            .font(Theme.font(12, .semibold)).foregroundStyle(Theme.lime)
                                    }
                                }
                                .padding(.horizontal, 12).frame(height: 38)
                                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
                            }
                            .padding(.vertical, 14)
                            Divider().overlay(Theme.line)
                            SettingRow("Перехватывать системный DNS", "Ответы для VPN-приложений — через VPN, без подмены провайдером. Китайские и локальные домены — напрямую") {
                                LimeToggle(isOn: $model.profile.hijackSystemDNS)
                            }
                            SettingRow("Отключить IPv6", "Даже если сеть его поддерживает. Сейчас IPv6 \(model.networkHasIPv6 ? "есть" : "нет") — без него он и так отключён") {
                                LimeToggle(isOn: $model.profile.disableIPv6)
                            }
                            SectionTitle("Базы доменов").padding(.top, 28)
                            SettingRow("Обновить готовые наборы", model.ruleSetsUpdated.map { "Последнее обновление: " + $0.formatted(.relative(presentation: .named)) } ?? "Наборы ещё не скачивались") {
                                Button("Обновить") { Task { await model.updateAllRuleSets() } }
                                    .buttonStyle(.plain).font(Theme.font(12, .semibold)).foregroundStyle(Theme.lime)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    resetBox.padding(.top, 36)
                }
                .scrollIndicators(.never)
                SystemPanel(confirmUninstall: $confirmUninstall).frame(width: 340)
            }
            .padding(.top, 28)
        }
        .onAppear { dns = model.profile.tunnelDNS }
        .confirmationDialog("Сбросить все настройки?", isPresented: $confirmReset) {
            Button("Сбросить", role: .destructive) { model.resetProfile() }
        } message: {
            Text("Правила, маршруты приложений и свои конфигурации вернутся к исходным. Журнал сохранится.")
        }
        .confirmationDialog("Удалить системный компонент?", isPresented: $confirmUninstall) {
            Button("Удалить", role: .destructive) { Task { await model.uninstallCore() } }
        } message: {
            Text("Ядро остановится, маршрутизация выключится. Понадобится пароль администратора.")
        }
    }

    private var resetBox: some View {
        HStack(spacing: 14) {
            Image(systemName: "arrow.counterclockwise").foregroundStyle(Theme.coral)
            VStack(alignment: .leading, spacing: 4) {
                Text("Сбросить все настройки").font(Theme.font(13, .semibold))
                Text("Правила, маршруты приложений и свои конфигурации вернутся к исходным. Журнал сохранится.")
                    .font(Theme.font(11)).foregroundStyle(Theme.text2)
            }
            Spacer()
            Button("Сбросить…") { confirmReset = true }
                .buttonStyle(.plain).font(Theme.font(12, .semibold)).foregroundStyle(Theme.coral)
                .padding(.horizontal, 14).frame(height: 32)
                .overlay(Capsule().stroke(Theme.coral.opacity(0.6)))
        }
        .padding(16)
        .background(Theme.coral.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.coral.opacity(0.3)))
    }

    private var updateStatus: String {
        switch updater.state {
        case .upToDate: return "Установлена последняя версия"
        case .available(let a): return "Доступна версия \(a.version)"
        case .checking: return "Проверяю…"
        case .failed(let e): return e
        default: return updater.lastCheck.map { "Последняя проверка: " + $0.formatted(.relative(presentation: .named)) } ?? "Раз в 6 часов, через GitHub"
        }
    }

    private func menuLabel(_ title: String) -> some View {
        HStack(spacing: 8) {
            Text(title).font(Theme.font(12, .medium))
            Image(systemName: "chevron.down").font(.system(size: 9)).foregroundStyle(Theme.text2)
        }
        .padding(.horizontal, 12).frame(height: 32)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
        .contentShape(Rectangle())
    }

    private func saveDNS() {
        let v = dns.trimmingCharacters(in: .whitespaces)
        guard CIDR.bytes(v) != nil else { dns = model.profile.tunnelDNS; return }
        model.profile.tunnelDNS = v
    }

    private func setLoginItem(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            model.lastError = "Автозапуск: \(error.localizedDescription)"
        }
        loginItem = SMAppService.mainApp.status == .enabled
    }
}

struct SectionTitle: View {
    var title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title).font(Theme.font(13, .medium)).foregroundStyle(Theme.text2).padding(.bottom, 4)
    }
}

struct SettingRow<Control: View>: View {
    var title: String
    var subtitle: String
    @ViewBuilder var control: Control

    init(_ title: String, _ subtitle: String, @ViewBuilder control: () -> Control) {
        self.title = title
        self.subtitle = subtitle
        self.control = control()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(Theme.font(13, .semibold))
                    Text(subtitle).font(Theme.font(11)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                control
            }
            .padding(.vertical, 14)
            Divider().overlay(Theme.line)
        }
    }
}

struct SystemPanel: View {
    @Environment(AppModel.self) private var model
    @Binding var confirmUninstall: Bool
    @State private var copied = false

    private var statusTitle: String {
        switch model.state {
        case .running: return "Работает"
        case .applying: return "Применяю…"
        case .stopped: return "Остановлено"
        case .notInstalled: return "Не установлено"
        case .needsUpdate: return "Нужно обновить"
        case .failed: return "Ошибка"
        }
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 16) {
                Text("СИСТЕМНЫЙ КОМПОНЕНТ").font(Theme.font(10, .bold)).foregroundStyle(Theme.lime).tracking(1)
                HStack(spacing: 10) {
                    Image(systemName: model.state == .running ? "checkmark.shield" : "shield.slash")
                        .font(.system(size: 20)).foregroundStyle(model.state == .running ? Theme.lime : Theme.text2)
                    Text(statusTitle).font(Theme.font(26, .semibold))
                }
                Text("Ядро sing-box работает от root через launchd и перехватывает трафик всех приложений через TUN.")
                    .font(Theme.font(12)).foregroundStyle(Theme.text2)
                Grid(horizontalSpacing: 1, verticalSpacing: 1) {
                    GridRow {
                        stat("Ядро", "sing-box \(model.singBoxVersion)")
                        stat("Базы доменов", model.ruleSetsUpdated?.formatted(date: .numeric, time: .omitted) ?? "—")
                    }
                    GridRow {
                        stat("Своих правил", "\(model.profile.rules.count)")
                        stat("Выходов", "\(model.profile.exits.count)")
                    }
                }
                .background(Theme.line)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line))

                Text("Горячие клавиши").font(Theme.font(12, .medium)).foregroundStyle(Theme.text2).padding(.top, 4)
                ForEach(HotKeys.shared.bindings.indices, id: \.self) { i in
                    let b = HotKeys.shared.bindings[i]
                    HStack {
                        Text(b.title).font(Theme.font(13))
                        Spacer()
                        HStack(spacing: 4) {
                            ForEach(b.keys, id: \.self) { k in
                                Text(k).font(Theme.font(11, .semibold)).foregroundStyle(Theme.text2)
                                    .frame(width: 22, height: 22)
                                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.line))
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
                HStack(spacing: 10) {
                    OutlineButton(title: "Экспорт", systemImage: "square.and.arrow.up") { exportProfile() }
                    OutlineButton(title: "Импорт", systemImage: "square.and.arrow.down") { importProfile() }
                }
                OutlineButton(title: copied ? "Скопировано" : "Скопировать диагностику", systemImage: "stethoscope") {
                    Task {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(await model.diagnostics(), forType: .string)
                        copied = true
                    }
                }
                .frame(maxWidth: .infinity)
                if model.state != .notInstalled {
                    Button("Удалить системный компонент…") { confirmUninstall = true }
                        .buttonStyle(.plain).font(Theme.font(11)).foregroundStyle(Theme.text3)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(22)
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(Theme.font(11)).foregroundStyle(Theme.text2)
            Text(value).font(Theme.font(14, .semibold)).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.surface)
    }

    private func exportProfile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "splitroute-profile.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? model.profile.save(to: url)
    }

    private func importProfile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            model.profile = try Profile.load(from: url)
        } catch {
            model.lastError = "Не удалось импортировать профиль: \(error.localizedDescription)"
        }
    }
}
