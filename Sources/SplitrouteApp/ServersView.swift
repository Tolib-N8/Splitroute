import SplitrouteCore
import SwiftUI
import UniformTypeIdentifiers

struct ServersView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var onlyConfigs: Bool?
    @State private var selectedID: String?
    @State private var showImport = false

    private var exits: [Exit] {
        ([Exit.direct] + model.tunnelExits).filter { e in
            let isConfig: Bool = { if case .proxy = e.kind { return true }; return false }()
            return (query.isEmpty || e.name.localizedCaseInsensitiveContains(query))
                && (onlyConfigs == nil || onlyConfigs == isConfig)
        }
    }

    private var selected: Exit? {
        model.profile.allExits.first { $0.id == selectedID } ?? model.preferredTunnel ?? .direct
    }

    private var configs: [Exit] {
        model.tunnelExits.filter { if case .proxy = $0.kind { return true }; return false }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScreenHeader(
                title: "Серверы",
                summary: "\(model.vpnServices.filter { !$0.isMesh }.count) VPN-приложения · \(configs.count) своих конфигураций",
                footnote: model.pings.isEmpty ? "Пинг ещё не измерялся" : "Пинг обновляется раз в минуту"
            ) {
                Text("Выходы, через которые можно пустить приложения")
                    .font(Theme.font(13)).foregroundStyle(Theme.text2)
            }
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 10) {
                        SearchField(placeholder: "Название выхода", text: $query).frame(maxWidth: 280)
                        FilterPill(title: "Все", selected: onlyConfigs == nil) { onlyConfigs = nil }
                        FilterPill(title: "VPN-приложения", selected: onlyConfigs == false) { onlyConfigs = false }
                        FilterPill(title: "Свои конфигурации", selected: onlyConfigs == true) { onlyConfigs = true }
                        Spacer()
                    }
                    ServersTableHeader().padding(.top, 22)
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(exits) { e in
                                ServerRow(exit: e, selected: e.id == selected?.id)
                                    .onTapGesture { selectedID = e.id }
                                Divider().overlay(Theme.line)
                            }
                            if model.tunnelExits.isEmpty {
                                Text("VPN-приложения из Системных настроек появятся здесь сами. Можно также импортировать свой конфиг.")
                                    .font(Theme.font(12)).foregroundStyle(Theme.text2).padding(.vertical, 20)
                            }
                            ConfigCards(configs: configs, selectedID: $selectedID) { showImport = true }
                                .padding(.top, 28)
                        }
                    }
                    .scrollIndicators(.never)
                }
                if let selected {
                    ExitDetailPanel(exit: selected).frame(width: 400)
                }
            }
            .padding(.top, 28)
        }
        .sheet(isPresented: $showImport) { ImportSheet() }
    }
}

struct ServersTableHeader: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Text("Выход").frame(maxWidth: .infinity, alignment: .leading)
                Text("Приложения").frame(width: 120, alignment: .leading)
                Text("Трафик · 24 ч").frame(width: 110, alignment: .leading)
                Text("Пинг").frame(width: 80, alignment: .leading)
            }
            .font(Theme.font(11, .medium))
            .foregroundStyle(Theme.text2)
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
            Divider().overlay(Theme.line)
        }
    }
}

struct ExitBadge: View {
    var exit: Exit
    var color: Color

    private var letters: String {
        switch exit.kind {
        case .direct: return "→"
        case .block: return "×"
        default:
            let words = exit.name.split(separator: " ")
            let s = words.count > 1 ? String(words[0].prefix(1) + words[1].prefix(1)) : String(exit.name.prefix(2))
            return s.uppercased()
        }
    }

    var body: some View {
        Circle()
            .fill(Theme.surface2)
            .frame(width: 34, height: 34)
            .overlay(Text(letters).font(Theme.font(11, .bold)).foregroundStyle(color))
            .overlay(Circle().stroke(color.opacity(0.35)))
    }
}

struct ServerRow: View {
    @Environment(AppModel.self) private var model
    var exit: Exit
    var selected: Bool

    private var pingColor: Color {
        guard let p = model.pings[exit.id] else { return Theme.text3 }
        return p < 80 ? Theme.lime : p < 180 ? Theme.amber : Theme.coral
    }

    var body: some View {
        let available = model.isAvailable(exit)
        HStack(spacing: 16) {
            HStack(spacing: 12) {
                ExitBadge(exit: exit, color: model.color(for: exit))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(exit.name).font(Theme.font(14, .medium))
                        if case .vpnApp = exit.kind {
                            Text(available ? "ПОДКЛЮЧЁН" : "ОТКЛЮЧЁН")
                                .font(Theme.font(9, .bold))
                                .foregroundStyle(available ? Theme.bg : Theme.text2)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(available ? Theme.lime : Theme.surface2, in: RoundedRectangle(cornerRadius: 4))
                        }
                    }
                    Text(model.subtitle(for: exit)).font(Theme.font(11)).foregroundStyle(Theme.text3).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            let n = model.appsCount(exitID: exit.id)
            Text(n == 0 ? "—" : Format.apps(n)).font(Theme.font(12)).foregroundStyle(Theme.text2).frame(width: 120, alignment: .leading)
            Text(Format.bytes(model.stats.total("exit:" + exit.tag))).font(Theme.font(12)).foregroundStyle(Theme.text2).frame(width: 110, alignment: .leading)
            HStack(spacing: 6) {
                StatusDot(color: pingColor)
                Text(model.pings[exit.id].map { "\($0) мс" } ?? "—").font(Theme.font(12))
            }
            .frame(width: 80, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .frame(height: 58)
        .background(selected ? Theme.surface : .clear, in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
    }
}

struct ConfigCards: View {
    @Environment(AppModel.self) private var model
    var configs: [Exit]
    @Binding var selectedID: String?
    var onImport: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Свои конфигурации").font(Theme.font(13, .medium)).foregroundStyle(Theme.text2)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 10)], spacing: 10) {
                ForEach(configs) { e in
                    HStack(spacing: 12) {
                        Image(systemName: "doc.text").frame(width: 34, height: 34)
                            .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 9))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(e.name).font(.system(size: 13, design: .monospaced)).lineLimit(1)
                            Text(model.subtitle(for: e)).font(Theme.font(11)).foregroundStyle(Theme.text3).lineLimit(1)
                        }
                        Spacer()
                        Menu {
                            Button("Удалить", role: .destructive) { model.removeExit(e) }
                        } label: { Image(systemName: "ellipsis").foregroundStyle(Theme.text2) }
                            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    }
                    .padding(14)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(selectedID == e.id ? Theme.lime.opacity(0.5) : Theme.line))
                    .onTapGesture { selectedID = e.id }
                }
                Button(action: onImport) {
                    Label("Импорт ссылки, подписки, .conf / .ovpn", systemImage: "square.and.arrow.down")
                        .font(Theme.font(13, .semibold))
                        .frame(maxWidth: .infinity, minHeight: 62)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.text.opacity(0.6)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct ExitDetailPanel: View {
    @Environment(AppModel.self) private var model
    var exit: Exit

    private var serverAddress: String {
        switch exit.kind {
        case .vpnApp: return model.vpnService(for: exit)?.serverAddress ?? "—"
        case .proxy(let p): return p.server
        case .direct: return model.physicalInterface ?? "—"
        case .block: return "—"
        }
    }

    var body: some View {
        @Bindable var model = model
        let apps = model.profile.routes.filter { $0.exitID == exit.id }
        Card {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("ВЫХОД").font(Theme.font(10, .bold)).foregroundStyle(model.color(for: exit)).tracking(1)
                    Text(exit.name).font(Theme.font(26, .semibold)).lineLimit(1)
                    Text(model.subtitle(for: exit)).font(Theme.font(12)).foregroundStyle(Theme.text2)
                }
                Grid(horizontalSpacing: 1, verticalSpacing: 1) {
                    GridRow {
                        stat("Пинг", model.pings[exit.id].map { "\($0) мс" } ?? "—")
                        stat("Статус", model.isAvailable(exit) ? "Доступен" : "Недоступен")
                    }
                    GridRow {
                        stat(exit.kind == .direct ? "Интерфейс" : "Сервер", serverAddress)
                        stat("За 24 ч", Format.bytes(model.stats.total("exit:" + exit.tag)))
                    }
                }
                .background(Theme.line)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line))

                if let history = model.pingHistory[exit.id], !history.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Задержка").font(Theme.font(12, .medium))
                            Spacer()
                            Text("\(history.min()!)–\(history.max()!) мс").font(Theme.font(11)).foregroundStyle(Theme.text2)
                        }
                        SparkBars(values: history.map(Int64.init), color: model.color(for: exit))
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Через этот выход").font(Theme.font(12, .medium))
                    if apps.isEmpty {
                        Text("Пока ни одного приложения").font(Theme.font(12)).foregroundStyle(Theme.text3)
                    } else {
                        FlowChips(items: apps.map { ($0.path, $0.name) })
                    }
                }

                if case .vpnApp = exit.kind {
                    Divider().overlay(Theme.line)
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Подключать автоматически").font(Theme.font(13, .semibold))
                            Text("Если \(exit.name) отключён, а через него идут приложения, Splitroute сам его включит. Не вышло — повторит позже, всё реже")
                                .font(Theme.font(11)).foregroundStyle(Theme.text2)
                        }
                        Spacer()
                        LimeToggle(isOn: Binding(get: { exit.autoConnect == true }, set: { model.setAutoConnect($0, for: exit) }))
                    }
                    fallbackSection
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Kill switch").font(Theme.font(13, .semibold))
                            Text("Если резерва нет — блокировать приложения, а не пускать напрямую")
                                .font(Theme.font(11)).foregroundStyle(Theme.text2)
                        }
                        Spacer()
                        LimeToggle(isOn: $model.profile.killSwitch)
                    }
                }
                Spacer(minLength: 0)
                if case .vpnApp = exit.kind {
                    Text("Подключение и смена сервера — в самом приложении \(exit.name). Splitroute только направляет в него нужные приложения.")
                        .font(Theme.font(11)).foregroundStyle(Theme.text3)
                }
                if case .proxy = exit.kind {
                    OutlineButton(title: "Удалить конфигурацию", systemImage: "trash") { model.removeExit(exit) }
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(22)
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private var fallbackTitle: String {
        switch exit.fallbackID {
        case nil: return "Любой доступный VPN"
        case Exit.noFallbackID: return "Без резерва"
        case let id?: return model.profile.exit(id: id)?.name ?? "Любой доступный VPN"
        }
    }

    /// Куда идут приложения выхода, пока VPN отключён.
    private var fallbackSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Резерв").font(Theme.font(13, .semibold))
                    Text("Если \(exit.name) отключён, его приложения и правила пойдут сюда")
                        .font(Theme.font(11)).foregroundStyle(Theme.text2)
                }
                Spacer()
                Menu {
                    Button("Любой доступный VPN") { model.setFallback(nil, for: exit) }
                    let others = model.tunnelExits.filter { $0.id != exit.id }
                    if !others.isEmpty {
                        Divider()
                        ForEach(others) { e in
                            Button(e.name + (model.isAvailable(e) ? "" : " — отключён")) { model.setFallback(e.id, for: exit) }
                        }
                    }
                    Divider()
                    Button("Без резерва") { model.setFallback(Exit.noFallbackID, for: exit) }
                } label: {
                    HStack(spacing: 6) {
                        Text(fallbackTitle).font(Theme.font(12, .medium)).lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 9)).foregroundStyle(Theme.text2)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
                }
                .menuStyle(.button).buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            if !model.isAvailable(exit) {
                let fallback = model.activeFallback(for: exit)
                Text("Сейчас: отключён, " + model.fallbackNote(for: exit))
                    .font(Theme.font(11, .medium)).foregroundStyle(fallback != nil ? Theme.amber : Theme.coral)
            }
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(Theme.font(11)).foregroundStyle(Theme.text2)
            Text(value).font(Theme.font(15, .semibold)).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.surface)
    }
}

struct FlowChips: View {
    var items: [(key: String, name: String)]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 8) {
            ForEach(items, id: \.key) { item in
                HStack(spacing: 6) {
                    AppIcon(key: item.key, size: 18)
                    Text(item.name).font(Theme.font(12)).lineLimit(1)
                }
                .padding(.horizontal, 8).frame(height: 30)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
            }
        }
    }
}

struct ImportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var fileName: String?
    @State private var parsed: [ParsedProxy] = []
    @State private var error: String?
    @State private var loading = false
    @State private var showFile = false
    @State private var username = ""
    @State private var password = ""

    private var needsCredentials: Bool {
        parsed.contains { if case .openvpn(let o) = $0.config { return o.needsCredentials }; return false }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Импорт конфигурации").font(Theme.font(20, .semibold))
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(Theme.text2)
            }
            Text("Вставьте ссылку vless://, ss://, trojan://, hysteria2://, ссылку-подписку https://… или содержимое WireGuard .conf / OpenVPN .ovpn.")
                .font(Theme.font(12)).foregroundStyle(Theme.text2)
            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(height: 160)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
                .onChange(of: text) { parse() }
            HStack {
                OutlineButton(title: "Выбрать файл…", systemImage: "doc") { showFile = true }
                if loading { ProgressView().controlSize(.small) }
                Spacer()
                if let error { Text(error).font(Theme.font(12)).foregroundStyle(Theme.coral).lineLimit(2) }
            }
            if !parsed.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Найдено: \(parsed.count)").font(Theme.font(12, .semibold))
                    ForEach(Array(parsed.prefix(6).enumerated()), id: \.offset) { _, p in
                        Text("• \(p.name) — \(p.config.protocolName) · \(p.config.server)").font(Theme.font(12)).foregroundStyle(Theme.text2)
                    }
                    if parsed.count > 6 { Text("…и ещё \(parsed.count - 6)").font(Theme.font(12)).foregroundStyle(Theme.text3) }
                }
            }
            if needsCredentials {
                HStack {
                    TextField("Логин OpenVPN", text: $username).textFieldStyle(.roundedBorder)
                    SecureField("Пароль", text: $password).textFieldStyle(.roundedBorder)
                }
            }
            Spacer()
            HStack {
                Spacer()
                PrimaryButton(title: "Добавить", systemImage: "checkmark") { add() }
                    .disabled(parsed.isEmpty && !isURL)
                    .opacity(parsed.isEmpty && !isURL ? 0.4 : 1)
            }
        }
        .padding(24)
        .frame(width: 600, height: 560)
        .background(Theme.bg)
        .foregroundStyle(Theme.text)
        .fileImporter(isPresented: $showFile, allowedContentTypes: [.data, .plainText]) { result in
            guard case .success(let url) = result else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            fileName = url.lastPathComponent
            text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }
    }

    private var isURL: Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasPrefix("http://") || t.hasPrefix("https://")
    }

    private func parse() {
        error = nil
        parsed = []
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !isURL else { return }
        do {
            parsed = try LinkParser.parseAny(t, fileName: fileName)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func add() {
        if isURL, parsed.isEmpty, let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            loading = true
            Task {
                defer { loading = false }
                do {
                    parsed = try await Subscription.fetch(url)
                    if parsed.isEmpty { error = "В подписке нет поддерживаемых ссылок" }
                } catch {
                    self.error = "Не удалось загрузить подписку: \(error.localizedDescription)"
                }
            }
            return
        }
        let items = parsed.map { p -> ParsedProxy in
            guard case .openvpn(var o) = p.config, o.needsCredentials else { return p }
            o.username = username
            o.password = password
            return ParsedProxy(name: p.name, config: .openvpn(o))
        }
        model.addProxies(items)
        dismiss()
    }
}
