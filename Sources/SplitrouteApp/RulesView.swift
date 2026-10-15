import SplitrouteCore
import SwiftUI

struct RulesView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: Rule?
    @State private var creating = false

    private var todayMatches: Int {
        let presetTitles = Set(PresetInfo.catalog.map(\.title))
        return model.journal.entries.reduce(0) { n, e in e.reason.hasPrefix(L("Правило")) || presetTitles.contains(e.reason) ? n + 1 : n }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScreenHeader(
                title: L("Правила"),
                summary: L("\(model.profile.presets.filter(\.enabled).count) наборов · \(model.profile.rules.count) своих правил"),
                footnote: L("Совпадений сегодня: \(todayMatches)")
            ) {
                Text(L("Проверяются сверху вниз · первое совпадение побеждает"))
                    .font(Theme.font(13)).foregroundStyle(Theme.text2)
            }
            HStack(alignment: .top, spacing: 20) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(L("Готовые наборы")).font(Theme.font(13, .medium)).foregroundStyle(Theme.text2)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 10)], spacing: 10) {
                            ForEach(PresetInfo.catalog) { PresetCard(info: $0) }
                        }
                        .padding(.top, 12)

                        HStack {
                            Text(L("Свои правила")).font(Theme.font(13, .medium)).foregroundStyle(Theme.text2)
                            Spacer()
                            PrimaryButton(title: L("Новое правило")) { creating = true }
                        }
                        .padding(.top, 28)
                        RulesTable(onEdit: { editing = $0 })
                            .padding(.top, 14)
                    }
                }
                .scrollIndicators(.never)
                RouteTesterPanel().frame(width: 340)
            }
            .padding(.top, 28)
        }
        .sheet(isPresented: $creating) { RuleEditor(rule: nil) }
        .sheet(item: $editing) { RuleEditor(rule: $0) }
    }
}

struct PresetCard: View {
    @Environment(AppModel.self) private var model
    var info: PresetInfo

    private var preset: RulePreset? { model.profile.preset(info.id) }
    private var enabled: Bool { preset?.enabled == true }
    private var exit: Exit { model.profile.exit(id: preset?.exitID ?? model.defaultExitID(for: info)) ?? .direct }

    private var status: String {
        if info.ruleSets.isEmpty { return info.subtitle }
        switch model.ruleSetStatus[info.id] {
        case .downloading: return L("Загружаю базу…")
        case .failed(let e): return L("Не удалось скачать: \(e)")
        case .ready(let d): return info.subtitle + " · " + d.formatted(.relative(presentation: .named))
        case nil: return info.subtitle
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: info.icon)
                    .font(.system(size: 13))
                    .foregroundStyle(enabled ? model.color(for: exit) : Theme.text3)
                    .frame(width: 28, height: 28)
                    .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 7))
                Spacer()
                if case .downloading = model.ruleSetStatus[info.id] {
                    ProgressView().controlSize(.small)
                } else {
                    LimeToggle(isOn: Binding(
                        get: { enabled },
                        set: { on in Task { await model.setPreset(info, enabled: on) } }
                    ))
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(info.title).font(Theme.font(14, .semibold)).foregroundStyle(enabled ? Theme.text : Theme.text2)
                Text(status).font(Theme.font(11)).foregroundStyle(statusColor).lineLimit(2)
            }
            Menu {
                ForEach(model.profile.allExits) { e in
                    Button(e.name) { Task { await model.setPreset(info, enabled: enabled, exitID: e.id) } }
                }
            } label: {
                HStack(spacing: 6) {
                    StatusDot(color: model.color(for: exit))
                    Text("→ " + exit.name).font(Theme.font(11, .medium)).foregroundStyle(Theme.text2)
                    Image(systemName: "chevron.down").font(.system(size: 8)).foregroundStyle(Theme.text3)
                }
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(enabled ? model.color(for: exit).opacity(0.3) : Theme.line))
        .opacity(enabled ? 1 : 0.8)
    }

    private var statusColor: Color {
        if case .failed = model.ruleSetStatus[info.id] { return Theme.coral }
        return Theme.text3
    }
}

struct RulesTable: View {
    @Environment(AppModel.self) private var model
    var onEdit: (Rule) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("#").frame(width: 24, alignment: .leading)
                Text(L("Тип")).frame(width: 92, alignment: .leading)
                Text(L("Условие")).frame(maxWidth: .infinity, alignment: .leading)
                Text(L("Для")).frame(width: 130, alignment: .leading)
                Text(L("Маршрут")).frame(width: 130, alignment: .leading)
                Text(L("Сегодня")).frame(width: 60, alignment: .leading)
                Color.clear.frame(width: 76, height: 1)
            }
            .font(Theme.font(11, .medium)).foregroundStyle(Theme.text2)
            .padding(.horizontal, 16).padding(.vertical, 12)
            Divider().overlay(Theme.line)
            if model.profile.rules.isEmpty {
                VStack(spacing: 6) {
                    Text(L("Своих правил пока нет")).font(Theme.font(13, .semibold))
                    Text(L("Например: youtube.com через VPN в любом браузере, или *.qq.com напрямую."))
                        .font(Theme.font(12)).foregroundStyle(Theme.text2)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 28)
            }
            ForEach(Array(model.profile.rules.enumerated()), id: \.element.id) { i, rule in
                RuleRow(index: i, rule: rule, onEdit: onEdit)
                if i < model.profile.rules.count - 1 { Divider().overlay(Theme.line) }
            }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.line))
    }
}

struct RuleRow: View {
    @Environment(AppModel.self) private var model
    var index: Int
    var rule: Rule
    var onEdit: (Rule) -> Void

    private var scope: String {
        if rule.appPaths.isEmpty { return L("Все приложения") }
        let names = rule.appPaths.map { p in model.profile.routes.first { $0.path == p }?.name ?? (p as NSString).lastPathComponent }
        return names.joined(separator: ", ")
    }

    var body: some View {
        let exit = model.profile.exit(id: rule.exitID) ?? .direct
        HStack(spacing: 12) {
            Text("\(index + 1)").font(Theme.font(12)).foregroundStyle(Theme.text3).frame(width: 24, alignment: .leading)
            Text(rule.kind.title)
                .font(Theme.font(11, .medium)).foregroundStyle(Theme.text2)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 6))
                .frame(width: 92, alignment: .leading)
            Text(rule.values.joined(separator: ", "))
                .font(.system(size: 12, design: .monospaced)).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(scope).font(Theme.font(12)).foregroundStyle(Theme.text2).lineLimit(1).frame(width: 130, alignment: .leading)
            HStack(spacing: 6) {
                StatusDot(color: model.color(for: exit))
                Text(exit.name).font(Theme.font(12, .medium)).lineLimit(1)
            }
            .frame(width: 130, alignment: .leading)
            Text(verbatim: "\(model.matchCount(reason: RouteExplainer.Reason.rule(index: index + 1).title))").font(Theme.font(12)).foregroundStyle(Theme.text2)
                .frame(width: 60, alignment: .leading)
            HStack(spacing: 10) {
                LimeToggle(isOn: Binding(get: { rule.enabled }, set: { var r = rule; r.enabled = $0; model.updateRule(r) }))
                Menu {
                    Button(L("Изменить…")) { onEdit(rule) }
                    Button(L("Выше")) { model.moveRule(rule, by: -1) }.disabled(index == 0)
                    Button(L("Ниже")) { model.moveRule(rule, by: 1) }.disabled(index == model.profile.rules.count - 1)
                    Divider()
                    Button(L("Удалить"), role: .destructive) { model.deleteRule(rule) }
                } label: { Image(systemName: "ellipsis").foregroundStyle(Theme.text2).frame(width: 20, height: 20) }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            }
            .frame(width: 76)
        }
        .padding(.horizontal, 16)
        .frame(height: 46)
        .opacity(rule.enabled ? 1 : 0.45)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onEdit(rule) }
    }
}

struct RuleEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var rule: Rule?

    @State private var kind: Rule.Kind = .domain
    @State private var text = ""
    @State private var appPaths: Set<String> = []
    @State private var exitID = Exit.directID

    private var placeholder: String {
        switch kind {
        case .domain: return "youtube.com, *.googlevideo.com"
        case .ip: return "10.8.0.0/16, 149.154.160.0/20"
        case .port: return "443, UDP 27015-27050"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(rule == nil ? L("Новое правило") : L("Правило")).font(Theme.font(20, .semibold))
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(Theme.text2)
            }
            Picker("", selection: $kind) {
                ForEach(Rule.Kind.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()

            VStack(alignment: .leading, spacing: 6) {
                Text(L("Условие")).font(Theme.font(12, .medium)).foregroundStyle(Theme.text2)
                TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(Theme.text3), axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 13, design: .monospaced))
                    .lineLimit(3...6)
                    .padding(10)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
                Text(kind == .domain ? L("Домен совпадает и со всеми поддоменами. Через запятую или с новой строки.")
                     : L("Через запятую или с новой строки."))
                    .font(Theme.font(11)).foregroundStyle(Theme.text3)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(L("Для каких приложений")).font(Theme.font(12, .medium)).foregroundStyle(Theme.text2)
                Toggle(L("Все приложения"), isOn: Binding(get: { appPaths.isEmpty }, set: { if $0 { appPaths = [] } }))
                    .toggleStyle(.checkbox).font(Theme.font(12))
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(model.profile.routes) { r in
                            Toggle(r.name, isOn: Binding(
                                get: { appPaths.contains(r.path) },
                                set: { if $0 { appPaths.insert(r.path) } else { appPaths.remove(r.path) } }
                            ))
                            .toggleStyle(.checkbox).font(Theme.font(12))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
                if model.profile.routes.isEmpty {
                    Text(L("Чтобы ограничить правило приложениями, сначала добавьте их на экране «Приложения»."))
                        .font(Theme.font(11)).foregroundStyle(Theme.text3)
                }
            }

            HStack {
                Text(L("Куда")).font(Theme.font(12, .medium)).foregroundStyle(Theme.text2)
                Picker("", selection: $exitID) {
                    ForEach(model.profile.allExits) { Text($0.name).tag($0.id) }
                }
                .labelsHidden().frame(width: 220)
            }
            Spacer()
            HStack {
                Spacer()
                PrimaryButton(title: L("Сохранить"), systemImage: "checkmark") { save() }
                    .disabled(Rule.splitValues(text).isEmpty)
                    .opacity(Rule.splitValues(text).isEmpty ? 0.4 : 1)
            }
        }
        .padding(24)
        .frame(width: 520, height: 600)
        .background(Theme.bg)
        .foregroundStyle(Theme.text)
        .onAppear {
            if let rule {
                kind = rule.kind
                text = rule.values.joined(separator: ", ")
                appPaths = Set(rule.appPaths)
                exitID = rule.exitID
            } else {
                exitID = model.preferredTunnel?.id ?? Exit.directID
            }
        }
    }

    private func save() {
        let values = Rule.splitValues(text)
        let paths = model.profile.routes.map(\.path).filter(appPaths.contains)
        if var r = rule {
            r.kind = kind
            r.values = values
            r.appPaths = paths
            r.exitID = exitID
            model.updateRule(r)
        } else {
            model.addRule(Rule(kind: kind, values: values, appPaths: paths, exitID: exitID))
        }
        dismiss()
    }
}

struct RouteTesterPanel: View {
    @Environment(AppModel.self) private var model
    @State private var host = "youtube.com"
    @State private var appPath: String?
    @State private var decision: RouteExplainer.Decision?
    @State private var checking = false

    private let steps: [(String, String)] = [
        (L("Свои правила"), L("Домены, IP, порты")),
        (L("Готовые наборы"), L("Если включены")),
        (L("Маршрут приложения"), L("Из раздела «Приложения»")),
        (L("По умолчанию"), ""),
    ]

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                Text(L("ПРОВЕРКА МАРШРУТА")).font(Theme.font(10, .bold)).foregroundStyle(Theme.lime).tracking(1)
                Text(L("Узнайте, куда пойдёт запрос, ещё до того как он случится"))
                    .font(Theme.font(13)).foregroundStyle(Theme.text2)
                HStack(spacing: 8) {
                    Image(systemName: "globe").foregroundStyle(Theme.text3)
                    TextField("", text: $host, prompt: Text(L("домен или IP")).foregroundStyle(Theme.text3))
                        .textFieldStyle(.plain).font(.system(size: 13, design: .monospaced))
                        .onSubmit { check() }
                }
                .padding(.horizontal, 12).frame(height: 40)
                .background(Theme.bg, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
                Menu {
                    Button(L("Любое приложение")) { appPath = nil; check() }
                    ForEach(model.profile.routes) { r in Button(r.name) { appPath = r.path; check() } }
                } label: {
                    HStack {
                        Image(systemName: "macwindow").foregroundStyle(Theme.text3)
                        Text(model.profile.routes.first { $0.path == appPath }?.name ?? L("Любое приложение")).font(Theme.font(13))
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 9)).foregroundStyle(Theme.text3)
                    }
                    .padding(.horizontal, 12).frame(height: 40)
                    .background(Theme.bg, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
                    .contentShape(Rectangle())
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)

                if let d = decision {
                    resultCard(d)
                } else if checking {
                    ProgressView().controlSize(.small)
                }

                Text(L("Порядок проверки")).font(Theme.font(12, .medium)).foregroundStyle(Theme.text2).padding(.top, 6)
                ForEach(Array(steps.enumerated()), id: \.offset) { i, s in
                    let hit = decision?.reason.step == i + 1
                    HStack(spacing: 12) {
                        Circle().fill(hit ? Theme.lime : Theme.surface2).frame(width: 24, height: 24)
                            .overlay(Text("\(i + 1)").font(Theme.font(11, .bold)).foregroundStyle(hit ? Theme.bg : Theme.text2))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.0).font(Theme.font(13, .medium)).foregroundStyle(hit ? Theme.text : Theme.text2)
                            Text(i == 3 ? (model.profile.exit(id: model.profile.defaultExitID)?.name ?? "") : s.1)
                                .font(Theme.font(11)).foregroundStyle(Theme.text3)
                        }
                        Spacer()
                        if hit { Text(L("совпало")).font(Theme.font(11, .semibold)).foregroundStyle(Theme.lime) }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(22)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .task { check() }
        .onChange(of: model.profile) { check() }
    }

    private func resultCard(_ d: RouteExplainer.Decision) -> some View {
        let exit = model.profile.exit(id: d.exitID) ?? .direct
        let color = model.color(for: exit)
        let available = model.isAvailable(exit)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: exit.kind == .block ? "xmark.shield" : "checkmark.shield").foregroundStyle(color)
                Text(exit.kind == .block ? L("Заблокировано") : exit.name).font(Theme.font(18, .semibold)).foregroundStyle(color)
            }
            Text(explanation(d)).font(Theme.font(12)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
            if !available {
                let fallback = model.activeFallback(for: exit)
                Text(L("Сейчас этот VPN отключён — ") + (fallback.map { L("запрос пойдёт через резерв \($0.name).") }
                    ?? (model.profile.killSwitch ? L("запрос будет заблокирован (kill switch).") : L("запрос пойдёт напрямую."))))
                    .font(Theme.font(11)).foregroundStyle(fallback != nil ? Theme.amber : Theme.coral)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(color.opacity(0.35)))
    }

    private func explanation(_ d: RouteExplainer.Decision) -> String {
        switch d.reason {
        case .rule(let i):
            let values = model.profile.rules[i - 1].values.prefix(3).joined(separator: ", ")
            return L("Сработало правило №\(i) — \(values). Маршрут приложения не учитывался.")
        case .preset(let id): return L("Сработал набор «\(PresetInfo.info(id)?.title ?? id)».")
        case .app(let name): return L("Своих правил и наборов для этого адреса нет — работает маршрут приложения \(name).")
        case .defaultRoute: return L("Ни одно правило не подошло — маршрут по умолчанию.")
        }
    }

    private func check() {
        let h = host.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty else { decision = nil; return }
        checking = true
        Task {
            decision = await model.testRoute(host: h, appPath: appPath)
            checking = false
        }
    }
}
