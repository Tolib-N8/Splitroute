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
                title: L("Настройки"),
                summary: L("Изменения применяются сразу"),
                footnote: model.ruleSetsUpdated.map { L("Базы доменов: ") + $0.formatted(date: .abbreviated, time: .shortened) } ?? L("Базы доменов не загружены")
            ) {
                Text(L("Splitroute \(Updater.currentVersion) · ядро sing-box \(model.singBoxVersion)")).font(Theme.font(13)).foregroundStyle(Theme.text2)
            }
            HStack(alignment: .top, spacing: 20) {
                ScrollView {
                    HStack(alignment: .top, spacing: 32) {
                        VStack(alignment: .leading, spacing: 0) {
                            SectionTitle(L("Запуск"))
                            LanguageRow()
                            SettingRow(L("Открывать при входе в систему"), L("Splitroute стартует вместе с macOS")) {
                                LimeToggle(isOn: Binding(get: { loginItem }, set: setLoginItem))
                            }
                            SettingRow(L("Включать маршрутизацию при запуске"), L("Иначе — как было при выходе")) {
                                LimeToggle(isOn: $enableOnLaunch)
                            }
                            SettingRow(L("Значок в строке меню"), L("Переключать маршруты, не открывая окно")) {
                                LimeToggle(isOn: $showMenuBar)
                            }
                            SectionTitle(L("Обновления")).padding(.top, 28)
                            SettingRow(L("Проверять автоматически"), updateStatus) {
                                LimeToggle(isOn: Binding(get: { updater.autoCheck }, set: { updater.autoCheck = $0 }))
                            }
                            SettingRow(L("Версия \(Updater.currentVersion) (\(Updater.currentBuild))"), L("Обновления подписаны ключом разработчика и проверяются перед установкой")) {
                                if let a = updater.availableUpdate {
                                    Button(L("Установить \(a.version)")) { Task { await updater.install(a) } }
                                        .buttonStyle(.plain).font(Theme.font(12, .semibold)).foregroundStyle(Theme.lime)
                                } else {
                                    Button(updater.state == .checking ? L("Проверяю…") : L("Проверить")) { Task { await updater.check(userInitiated: true) } }
                                        .buttonStyle(.plain).font(Theme.font(12, .semibold)).foregroundStyle(Theme.lime)
                                        .disabled(updater.state == .checking)
                                }
                            }
                            SettingRow(L("Приветствие"), L("Пройти первую настройку ещё раз")) {
                                Button(L("Показать")) { onboardingDone = false }
                                    .buttonStyle(.plain).font(Theme.font(12, .semibold)).foregroundStyle(Theme.lime)
                            }
                            NotificationsSection().padding(.top, 28)
                            SectionTitle(L("Туннель")).padding(.top, 28)
                            SettingRow(L("Маршрут по умолчанию"), L("Для приложений и доменов без правил")) {
                                Menu {
                                    ForEach(model.profile.allExits) { e in Button(e.name) { model.profile.defaultExitID = e.id } }
                                } label: {
                                    menuLabel(model.profile.exit(id: model.profile.defaultExitID)?.name ?? L("Напрямую"))
                                }
                                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                            }
                            SettingRow("Kill switch", L("Если VPN-приложение отключилось и резервного VPN нет — блокировать его приложения, а не пускать напрямую. Резерв выбирается в «Серверах»")) {
                                LimeToggle(isOn: $model.profile.killSwitch)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        VStack(alignment: .leading, spacing: 0) {
                            SectionTitle(L("DNS и IPv6"))
                            VStack(alignment: .leading, spacing: 8) {
                                Text(L("DNS-сервер для VPN-выходов")).font(Theme.font(13, .semibold))
                                Text(L("Запросы, которые проходят через ядро, резолвятся через подключённый VPN"))
                                    .font(Theme.font(11)).foregroundStyle(Theme.text2)
                                HStack {
                                    TextField("", text: $dns, prompt: Text("1.1.1.1").foregroundStyle(Theme.text3))
                                        .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
                                        .onSubmit { saveDNS() }
                                    if dns != model.profile.tunnelDNS {
                                        Button(L("Сохранить")) { saveDNS() }.buttonStyle(.plain)
                                            .font(Theme.font(12, .semibold)).foregroundStyle(Theme.lime)
                                    }
                                }
                                .padding(.horizontal, 12).frame(height: 38)
                                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
                            }
                            .padding(.vertical, 14)
                            Divider().overlay(Theme.line)
                            SettingRow(L("Перехватывать системный DNS"), L("Ответы для VPN-приложений — через VPN, без подмены провайдером. Китайские и локальные домены — напрямую")) {
                                LimeToggle(isOn: $model.profile.hijackSystemDNS)
                            }
                            SettingRow(L("Отключить IPv6"), L("Даже если сеть его поддерживает. Сейчас IPv6 \(model.networkHasIPv6 ? L("есть") : L("нет")) — без него он и так отключён")) {
                                LimeToggle(isOn: $model.profile.disableIPv6)
                            }
                            SectionTitle(L("Базы доменов")).padding(.top, 28)
                            SettingRow(L("Обновить готовые наборы"), model.ruleSetsUpdated.map { L("Последнее обновление: ") + $0.formatted(.relative(presentation: .named)) } ?? L("Наборы ещё не скачивались")) {
                                Button(L("Обновить")) { Task { await model.updateAllRuleSets() } }
                                    .buttonStyle(.plain).font(Theme.font(12, .semibold)).foregroundStyle(Theme.lime)
                            }
                            ScenariosSection().padding(.top, 28)
                            LicenseSection().padding(.top, 28)
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
        .confirmationDialog(L("Сбросить все настройки?"), isPresented: $confirmReset) {
            Button(L("Сбросить"), role: .destructive) { model.resetProfile() }
        } message: {
            Text(L("Правила, маршруты приложений и свои конфигурации вернутся к исходным. Журнал сохранится."))
        }
        .confirmationDialog(L("Удалить системный компонент?"), isPresented: $confirmUninstall) {
            Button(L("Удалить"), role: .destructive) { Task { await model.uninstallCore() } }
        } message: {
            Text(L("Ядро остановится, маршрутизация выключится. Понадобится пароль администратора."))
        }
    }

    private var resetBox: some View {
        HStack(spacing: 14) {
            Image(systemName: "arrow.counterclockwise").foregroundStyle(Theme.coral)
            VStack(alignment: .leading, spacing: 4) {
                Text(L("Сбросить все настройки")).font(Theme.font(13, .semibold))
                Text(L("Правила, маршруты приложений и свои конфигурации вернутся к исходным. Журнал сохранится."))
                    .font(Theme.font(11)).foregroundStyle(Theme.text2)
            }
            Spacer()
            Button(L("Сбросить…")) { confirmReset = true }
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
        case .upToDate: return L("Установлена последняя версия")
        case .available(let a): return L("Доступна версия \(a.version)")
        case .checking: return L("Проверяю…")
        case .failed(let e): return e
        default: return updater.lastCheck.map { L("Последняя проверка: ") + $0.formatted(.relative(presentation: .named)) } ?? L("Раз в 6 часов, через GitHub")
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
            model.lastError = L("Автозапуск: \(error.localizedDescription)")
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
        case .running: return L("Работает")
        case .applying: return L("Применяю…")
        case .stopped: return L("Остановлено")
        case .notInstalled: return L("Не установлено")
        case .needsUpdate: return L("Нужно обновить")
        case .failed: return L("Ошибка")
        }
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 16) {
                Text(L("СИСТЕМНЫЙ КОМПОНЕНТ")).font(Theme.font(10, .bold)).foregroundStyle(Theme.lime).tracking(1)
                HStack(spacing: 10) {
                    Image(systemName: model.state == .running ? "checkmark.shield" : "shield.slash")
                        .font(.system(size: 20)).foregroundStyle(model.state == .running ? Theme.lime : Theme.text2)
                    Text(statusTitle).font(Theme.font(26, .semibold))
                }
                Text(L("Ядро sing-box работает от root через launchd и перехватывает трафик всех приложений через TUN."))
                    .font(Theme.font(12)).foregroundStyle(Theme.text2)
                Grid(horizontalSpacing: 1, verticalSpacing: 1) {
                    GridRow {
                        stat(L("Ядро"), "sing-box \(model.singBoxVersion)")
                        stat(L("Базы доменов"), model.ruleSetsUpdated?.formatted(date: .numeric, time: .omitted) ?? "—")
                    }
                    GridRow {
                        stat(L("Своих правил"), "\(model.profile.rules.count)")
                        stat(L("Выходов"), "\(model.profile.exits.count)")
                    }
                }
                .background(Theme.line)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line))

                Text(L("Горячие клавиши")).font(Theme.font(12, .medium)).foregroundStyle(Theme.text2).padding(.top, 4)
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
                    OutlineButton(title: L("Экспорт"), systemImage: "square.and.arrow.up") { exportProfile() }
                    OutlineButton(title: L("Импорт"), systemImage: "square.and.arrow.down") { importProfile() }
                }
                OutlineButton(title: copied ? L("Скопировано") : L("Скопировать диагностику"), systemImage: "stethoscope") {
                    Task {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(await model.diagnostics(), forType: .string)
                        copied = true
                    }
                }
                .frame(maxWidth: .infinity)
                if model.state != .notInstalled {
                    Button(L("Удалить системный компонент…")) { confirmUninstall = true }
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
            model.lastError = L("Не удалось импортировать профиль: \(error.localizedDescription)")
        }
    }
}

struct NotificationsSection: View {
    @State private var on: [Notifier.Kind: Bool] = Dictionary(uniqueKeysWithValues: Notifier.Kind.allCases.map { ($0, Notifier.isEnabled($0)) })

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SectionTitle(L("Уведомления"))
                Spacer()
                Button(L("Пробное")) {
                    Notifier.shared.post(.vpn, key: "test", title: "Splitroute", body: L("Уведомления работают"), throttle: 0)
                }
                .buttonStyle(.plain).font(Theme.font(12, .semibold)).foregroundStyle(Theme.lime)
                .help(L("Показать пробное уведомление. Если оно не появилось — разрешите уведомления Splitroute в Системных настройках"))
            }
            row(.vpn, L("VPN отключился или вернулся"), L("Куда пошли его приложения: в резерв, напрямую или блокируются"))
            row(.suggestions, L("Не открывается напрямую"), L("Найдены программы и сайты, которые похоже заблокированы"))
            row(.scenarios, L("Сценарий сменился сам"), L("При подключении к сети, привязанной к сценарию"))
        }
    }

    private func row(_ kind: Notifier.Kind, _ title: String, _ subtitle: String) -> some View {
        SettingRow(title, subtitle) {
            LimeToggle(isOn: Binding(get: { on[kind] ?? true }, set: { on[kind] = $0; Notifier.setEnabled(kind, $0) }))
        }
    }
}

/// Сценарии: список, переименование, привязка к текущей сети.
struct ScenariosSection: View {
    @Environment(AppModel.self) private var model
    @State private var names: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(L("Сценарии"))
            if model.scenarios.isEmpty {
                SettingRow(L("Наборы маршрутов для разных мест"), L("«Дом», «Офис», «Поездка» — переключаются в верхней панели и в строке меню, а в знакомой сети сами")) {
                    Button(L("Создать")) { model.createScenario() }
                        .buttonStyle(.plain).font(Theme.font(12, .semibold)).foregroundStyle(Theme.lime)
                }
            } else {
                Text(L("Маршруты, правила и наборы у каждого сценария свои; выходы общие. Правки сохраняются в активном сценарии."))
                    .font(Theme.font(11)).foregroundStyle(Theme.text2).padding(.vertical, 10)
                ForEach(model.scenarios) { s in
                    row(s)
                    Divider().overlay(Theme.line)
                }
                HStack {
                    Button { model.createScenario() } label: { Label(L("Новый сценарий"), systemImage: "plus") }
                        .buttonStyle(.plain).font(Theme.font(12, .semibold)).foregroundStyle(Theme.lime)
                    Spacer()
                    Text(model.networkSignature.map { L("Сейчас: ") + NetworkState.describe(signature: $0) } ?? L("Сеть не определена"))
                        .font(Theme.font(11)).foregroundStyle(Theme.text3)
                }
                .padding(.vertical, 12)
            }
        }
    }

    private func row(_ s: Scenario) -> some View {
        let active = s.id == model.activeScenario?.id
        let here = model.networkSignature.map(s.networks.contains) ?? false
        return HStack(spacing: 10) {
            Button { model.activateScenario(s.id) } label: {
                Image(systemName: active ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(active ? Theme.lime : Theme.text2)
            }
            .buttonStyle(.plain).help(active ? L("Активный") : L("Включить"))
            TextField("", text: Binding(get: { names[s.id] ?? s.name }, set: { names[s.id] = $0 }))
                .textFieldStyle(.plain).font(Theme.font(13, active ? .semibold : .regular))
                .onSubmit { commit(s) }
                .onChange(of: model.activeScenario?.id) { commit(s) }
            Spacer()
            if model.networkSignature != nil {
                Button { model.toggleCurrentNetwork(for: s.id) } label: {
                    Label(here ? L("В этой сети") : L("Включать в этой сети"), systemImage: here ? "wifi" : "wifi.exclamationmark")
                        .font(Theme.font(11, here ? .semibold : .regular))
                        .foregroundStyle(here ? Theme.lime : Theme.text2)
                }
                .buttonStyle(.plain)
                .help(here ? L("Не включать автоматически в этой сети") : L("Включать этот сценарий при подключении к текущей сети"))
            }
            if s.networks.count > (here ? 1 : 0) {
                Text("+\(s.networks.count - (here ? 1 : 0))").font(Theme.font(10)).foregroundStyle(Theme.text3)
                    .help(L("Привязан ещё к другим сетям"))
            }
            Button { model.deleteScenario(s.id) } label: { Image(systemName: "trash").font(.system(size: 11)) }
                .buttonStyle(.plain).foregroundStyle(active ? Theme.text3 : Theme.text2)
                .disabled(active).help(active ? L("Сначала включите другой сценарий") : L("Удалить"))
        }
        .padding(.vertical, 10)
    }

    private func commit(_ s: Scenario) {
        if let n = names[s.id] { model.renameScenario(s.id, to: n); names[s.id] = nil }
    }
}

/// Язык интерфейса: как в системе, русский или английский. Меняется после перезапуска.
struct LanguageRow: View {
    @State private var choice = LanguageRow.current
    private let initial = LanguageRow.current

    /// nil — как в системе.
    static var current: String? {
        (UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["AppleLanguages"] as? [String])?.first
    }

    var body: some View {
        SettingRow(L("Язык интерфейса"), choice == initial ? (Lang.isRussian ? "Language" : "Язык") : L("Применится после перезапуска")) {
            HStack(spacing: 12) {
                if choice != initial {
                    Button(L("Перезапустить")) { relaunch() }
                        .buttonStyle(.plain).font(Theme.font(12, .semibold)).foregroundStyle(Theme.lime)
                }
                Menu {
                    Button(L("Как в системе")) { set(nil) }
                    Button { set("ru") } label: { Text(verbatim: "Русский") }
                    Button("English") { set("en") }
                } label: {
                    HStack(spacing: 6) {
                        Text(title(choice)).font(Theme.font(12, .medium))
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 9)).foregroundStyle(Theme.text2)
                    }
                    .padding(.horizontal, 10).frame(height: 30)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            }
        }
    }

    private func title(_ code: String?) -> String {
        switch code {
        case "ru": return "Русский"
        case "en": return "English"
        default: return L("Как в системе")
        }
    }

    private func set(_ code: String?) {
        choice = code
        if let code { UserDefaults.standard.set([code], forKey: "AppleLanguages") } else { UserDefaults.standard.removeObject(forKey: "AppleLanguages") }
    }

    private func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; open \"$0\"", Bundle.main.bundlePath]
        try? p.run()
        NSApp.terminate(nil)
    }
}
