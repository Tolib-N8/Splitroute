import AppKit
import Observation
import SplitrouteCore
import SwiftUI

enum CoreState: Equatable {
    case notInstalled
    case needsUpdate
    case stopped
    case applying
    case running
    case failed(String)

    var isRunning: Bool { self == .running || self == .applying }
}

/// Приложение, которое показываем в таблицах: настроенное или замеченное в трафике.
struct AppEntry: Identifiable, Hashable {
    var key: String        // путь бандла или AppKey.system
    var bundleID: String?
    var name: String
    var detail: String
    var route: AppRoute?

    var id: String { key }
}

@MainActor
@Observable
final class AppModel {
    // MARK: Состояние

    var profile: Profile {
        didSet {
            guard profile != oldValue, !Demo.isOn else { return }
            try? profile.save(to: Paths.userProfile)
            captureIntoActiveScenario()
            scheduleApply()
        }
    }

    /// Сценарии («Дом», «Офис»); правки маршрутов сразу запоминаются в активном.
    var scenarioStore = Demo.isOn ? Demo.scenarios : ScenarioStore.load(from: AppModel.scenariosURL) {
        didSet { if scenarioStore != oldValue, !Demo.isOn { try? scenarioStore.save(to: AppModel.scenariosURL) } }
    }
    static var scenariosURL: URL { Paths.userProfile.deletingLastPathComponent().appendingPathComponent("scenarios.json") }
    /// Отпечаток текущей сети (роутер + MAC) — для автопереключения сценариев.
    private(set) var networkSignature: String?

    var enabled: Bool {
        didSet {
            if Demo.isOn { state = enabled ? .running : .stopped; return }
            UserDefaults.standard.set(enabled, forKey: "enabled")
            if enabled { scheduleApply(immediately: true) } else { Task { await stopCore() } }
        }
    }

    private(set) var state: CoreState = .stopped
    private(set) var vpnServices: [VPNServiceInfo] = []
    private(set) var physicalInterface: String?
    private(set) var installedApps: [InstalledApp] = []
    private(set) var stats = Demo.isOn ? Demo.stats : TrafficStats.load()
    private(set) var speed = TrafficSample(up: 0, down: 0)
    /// Скорость потоков «приложение → выход», байт/с (сглаженная).
    private(set) var flowRates: [String: Double] = [:]
    /// Приложения, замеченные в соединениях, → время последней активности.
    private(set) var activeApps: [String: Date] = [:]
    private(set) var pings: [String: Int] = [:]
    private(set) var pingHistory: [String: [Int]] = [:]
    private(set) var lastUpdate: Date?
    var lastError: String?
    private(set) var journal = Demo.isOn ? Journal() : Journal.load()
    /// «В реальном времени»: если выключено, журнал на экране не обновляется (запись продолжается).
    var journalLive = true
    private(set) var journalSnapshot: [JournalEntry] = []
    private(set) var ruleSetStatus: [String: RuleSetStatus] = [:]

    func setRuleSetStatus(_ id: String, _ status: RuleSetStatus?) { ruleSetStatus[id] = status }

    /// «Не открывается напрямую — пустить через VPN?» (см. AppModel+Suggestions).
    var suggestions: [BlockAdvisor.Suggestion] = []
    var dismissedSuggestions = Set(UserDefaults.standard.stringArray(forKey: "dismissedSuggestions") ?? []) {
        didSet { UserDefaults.standard.set(Array(dismissedSuggestions).sorted(), forKey: "dismissedSuggestions") }
    }
    /// Подсказки, о которых уже было уведомление (за этот запуск).
    @ObservationIgnored var notifiedSuggestions = Set<String>()
    /// Автоподключение VPN-приложений: когда пробовали в последний раз и сколько раз подряд не вышло.
    @ObservationIgnored var autoConnectAttempts: [String: (last: Date, failures: Int)] = [:]

    private var lastSeenBytes: [String: Int64] = [:]
    private var applyTask: Task<Void, Never>?
    private var appliedEnvironment: NetworkEnvironment?
    @ObservationIgnored private var iconCache: [String: NSImage] = [:]
    @ObservationIgnored private var appInfoCache: [String: InstalledApp?] = [:]

    /// `AppCatalog.app(at:)` с кэшем — читает Info.plist с диска только один раз.
    func appInfo(at path: String) -> InstalledApp? {
        if let cached = appInfoCache[path] { return cached }
        let info = AppCatalog.app(at: path)
        appInfoCache[path] = info
        return info
    }
    private var started = false

    init() {
        if Demo.isOn {
            profile = Demo.profile
            enabled = true
            return
        }
        var loaded = (try? Profile.load(from: Paths.userProfile)) ?? Profile()
        // Правила на папку из ранних версий назывались по имени папки («versions»).
        for i in loaded.routes.indices {
            if let folder = AppCatalog.versionedFolder(for: loaded.routes[i].path), loaded.routes[i].path == folder.path {
                loaded.routes[i].name = folder.name
            }
        }
        profile = loaded
        let enableOnLaunch = UserDefaults.standard.object(forKey: "enableOnLaunch") as? Bool ?? true
        enabled = enableOnLaunch || (UserDefaults.standard.object(forKey: "enabled") as? Bool ?? true)
    }

    func recheckInstall() async {
        await bootstrap()
    }

    // MARK: Запуск

    func start() {
        guard !started else { return }
        started = true
        Theme.registerFonts()
        if Demo.isOn { startDemo(); return }
        Notifier.shared.start()
        Support.shared.start()
        Task { await refreshNetwork() }
        Task.detached(priority: .utility) {
            let apps = AppCatalog.scan()
            await MainActor.run { self.installedApps = apps }
        }
        Task { await bootstrap() }
        Task { await networkLoop() }
        Task { await statsLoop() }
        Task { await trafficLoop() }
        Task { await pingLoop() }
    }

    private func bootstrap() async {
        journalSnapshot = journal.entries
        refreshRuleSetStatus()
        if !HelperClient.isInstalled {
            state = .notInstalled
        } else if await HelperClient.needsUpdate() {
            state = .needsUpdate
        } else if enabled {
            await applyNow()
        } else {
            state = .stopped
        }
    }

    func installCore() async {
        state = .applying
        do {
            try await HelperClient.install()
            if enabled { await applyNow() } else { state = .stopped }
        } catch {
            state = HelperClient.isInstalled ? .failed(error.localizedDescription) : .notInstalled
            lastError = error.localizedDescription
        }
    }

    // MARK: Применение профиля

    func scheduleApply(immediately: Bool = false) {
        guard !Demo.isOn, HelperClient.isInstalled, state != .needsUpdate else { return }
        applyTask?.cancel()
        applyTask = Task {
            if !immediately { try? await Task.sleep(for: .seconds(1)) }
            guard !Task.isCancelled else { return }
            await applyNow()
        }
    }

    private func applyNow() async {
        guard enabled else { return }
        state = .applying
        do {
            try profile.save(to: Paths.userProfile)
            try await HelperClient.call("apply")
            appliedEnvironment = await Task.detached(priority: .utility) { NetworkState.environment() }.value
            state = .running
            lastError = nil
        } catch {
            state = .failed(error.localizedDescription)
            lastError = error.localizedDescription
        }
    }

    private func stopCore() async {
        applyTask?.cancel()
        guard !Demo.isOn, HelperClient.isInstalled else { return }
        do {
            try await HelperClient.call("stop")
            state = .stopped
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: Сеть

    private func networkLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3))
            await refreshNetwork()
        }
    }

    /// Последнее прочитанное окружение (для настроек и сравнения).
    private(set) var environment = NetworkEnvironment(physicalInterface: nil)

    /// Чтение SystemConfiguration занимает десятки миллисекунд — делаем его в фоне,
    /// иначе раз в 3 секунды подвисает анимация.
    private func refreshNetwork() async {
        let snap = await Task.detached(priority: .utility) { NetworkState.snapshot() }.value
        let previousServices = vpnServices
        if networkSignature != snap.signature {
            networkSignature = snap.signature
            switchScenario(forNetwork: snap.signature)
        }
        if vpnServices != snap.services { vpnServices = snap.services }
        if physicalInterface != snap.environment.physicalInterface { physicalInterface = snap.environment.physicalInterface }
        if environment != snap.environment { environment = snap.environment }
        notifyVPNChanges(from: previousServices, to: snap.services)
        ensureVPNExits()
        ensureSelfRoute()
        autoConnectVPNs()

        // Сменился utun у VPN-приложения или Wi‑Fi — пересобираем конфиг.
        let env = snap.environment
        if state == .running, let applied = appliedEnvironment, applied != env {
            appliedEnvironment = env
            scheduleApply(immediately: true)
        }
    }

    /// Сам Splitroute (скачивание баз и подписок) — через VPN, если он есть: напрямую из Китая
    /// GitHub и многие подписки недоступны. Это обычный маршрут приложения, его можно поменять.
    private func ensureSelfRoute() {
        guard HelperClient.runningFromBundle, let id = Bundle.main.bundleIdentifier else { return }
        // Приложение перенесли (например, из build/ или «Загрузок» в «Программы») — правило едет за ним.
        if var route = profile.route(for: id) {
            if route.path != Bundle.main.bundlePath {
                route.path = Bundle.main.bundlePath
                profile.setRoute(route)
            }
            return
        }
        guard let tunnel = tunnelExits.first(where: isAvailable) else { return }
        profile.setRoute(AppRoute(bundleID: id, name: "Splitroute", path: Bundle.main.bundlePath, exitID: tunnel.id))
    }

    /// Каждый VPN-сервис из Системных настроек (кроме Tailscale) доступен как выход.
    private func ensureVPNExits() {
        var p = profile
        for s in vpnServices where !s.isMesh {
            if let i = p.exits.firstIndex(where: { $0.kind == .vpnApp(serviceID: s.id) }) {
                if p.exits[i].name != s.name { p.exits[i].name = s.name }
            } else {
                p.exits.append(Exit(id: "vpn-" + s.id.lowercased(), name: s.name, kind: .vpnApp(serviceID: s.id)))
            }
        }
        if p != profile { profile = p }
    }

    // MARK: Выходы

    var tunnelExits: [Exit] { profile.exits }

    func vpnService(for exit: Exit) -> VPNServiceInfo? {
        guard case .vpnApp(let id) = exit.kind else { return nil }
        return vpnServices.first { $0.id == id }
    }

    /// Доступен ли выход прямо сейчас.
    func isAvailable(_ exit: Exit) -> Bool {
        switch exit.kind {
        case .direct, .block, .proxy: return true
        case .vpnApp: return vpnService(for: exit)?.isConnected == true
        }
    }

    func color(for exit: Exit) -> Color {
        switch exit.kind {
        case .direct: return Theme.blue
        case .block: return Theme.coral
        default:
            let i = profile.exits.firstIndex(of: exit) ?? 0
            return Theme.tunnelPalette[i % Theme.tunnelPalette.count]
        }
    }

    func color(forTag tag: String) -> Color {
        if let e = profile.allExits.first(where: { $0.tag == tag }) { return color(for: e) }
        return Theme.text3
    }

    func subtitle(for exit: Exit) -> String {
        switch exit.kind {
        case .direct: return L("Обычная сеть · \(physicalInterface ?? L("нет сети"))")
        case .block: return L("Трафик отклонён")
        case .vpnApp:
            guard let s = vpnService(for: exit) else { return L("VPN-приложение · не найдено") }
            if let iface = s.interface { return L("VPN-приложение · \(iface)") }
            return L("Отключён · ") + fallbackNote(for: exit)
        case .proxy(let p): return "\(p.protocolName) · \(p.server)"
        }
    }

    /// Лучший туннель для кнопки «VPN»: подключённый VPN-апп или свой конфиг.
    var preferredTunnel: Exit? {
        tunnelExits.first(where: isAvailable) ?? tunnelExits.first
    }

    func appsCount(exitID: String) -> Int { profile.routes.filter { $0.exitID == exitID }.count }

    func addProxies(_ parsed: [ParsedProxy]) {
        var p = profile
        for item in parsed {
            p.exits.append(Exit(name: item.name, kind: .proxy(item.config)))
        }
        profile = p
    }

    func removeExit(_ exit: Exit) {
        var p = profile
        p.removeExit(id: exit.id)
        profile = p
    }

    // MARK: Резерв

    /// Куда сейчас фактически идёт трафик выхода (резерв, kill switch).
    func resolution(for exit: Exit) -> ExitResolution {
        profile.resolve(exitID: exit.id, in: environment)
    }

    /// Работает резерв вместо отключённого VPN — выход, через который идёт трафик.
    func activeFallback(for exit: Exit) -> Exit? {
        if case .exit(let e, let from?) = resolution(for: exit), from.id == exit.id, e.isTunnel { return e }
        return nil
    }

    /// «идёт через AIRLINK VPN» / «трафик блокируется» / «идёт напрямую».
    func fallbackNote(for exit: Exit) -> String {
        switch resolution(for: exit) {
        case .reject: return L("трафик блокируется")
        case .exit(let e, _): return e.kind == .direct ? L("идёт напрямую") : L("идёт через \(e.name)")
        }
    }

    func setFallback(_ fallbackID: String?, for exit: Exit) {
        guard let i = profile.exits.firstIndex(where: { $0.id == exit.id }) else { return }
        profile.exits[i].fallbackID = fallbackID
    }

    func renameExit(_ exit: Exit, to name: String) {
        guard let i = profile.exits.firstIndex(where: { $0.id == exit.id }) else { return }
        profile.exits[i].name = name
    }

    // MARK: Приложения

    /// `appPath` — бандл .app, папка или путь к программе (для неё правило ставится на папку).
    func setRoute(appPath: String, exitID: String) {
        if AppCatalog.versionedFolder(for: appPath) == nil, let app = appInfo(at: appPath) {
            profile.setRoute(AppRoute(bundleID: app.bundleID, name: app.name, path: app.path, exitID: exitID))
            return
        }
        let target = AppCatalog.routeTarget(forProcessPath: appPath)
        profile.setRoute(AppRoute(bundleID: "path:" + target.path, name: target.name, path: target.path, exitID: exitID))
    }

    /// Ключ статистики для процесса: папка из правила, если процесс в ней, иначе бандл или бинарник.
    func appKey(forProcessPath path: String?) -> String {
        if let path {
            for r in profile.routes where r.path.hasSuffix("/") && path.hasPrefix(r.path) { return r.path }
        }
        return AppKey.from(processPath: path)
    }

    func removeRoute(_ route: AppRoute) {
        profile.routes.removeAll { $0.bundleID == route.bundleID }
    }

    /// Настроенные приложения + замеченные в трафике за сутки.
    var appEntries: [AppEntry] {
        var result: [AppEntry] = profile.routes.map {
            AppEntry(key: $0.path, bundleID: $0.bundleID, name: $0.name,
                     detail: $0.bundleID.hasPrefix("path:") ? $0.path : $0.bundleID, route: $0)
        }
        let configured = Set(result.map(\.key))
        let seen = Set(stats.keys(prefix: "app:").map { String($0.dropFirst(4)) }).union(activeApps.keys)
        for key in seen.sorted() where !configured.contains(key) {
            result.append(entry(forKey: key))
        }
        return result
    }

    var detectedCount: Int { appEntries.filter { $0.route == nil }.count }

    func entry(forKey key: String) -> AppEntry {
        if key == AppKey.system {
            return AppEntry(key: key, name: L("Системные службы"), detail: "macOS", route: nil)
        }
        if let route = profile.routes.first(where: { $0.path == key }) {
            return AppEntry(key: key, bundleID: route.bundleID, name: route.name, detail: key, route: route)
        }
        if AppCatalog.versionedFolder(for: key) == nil, let app = appInfo(at: key) {
            return AppEntry(key: key, bundleID: app.bundleID, name: app.name, detail: app.bundleID, route: profile.route(for: app.bundleID))
        }
        let target = AppCatalog.routeTarget(forProcessPath: key)
        return AppEntry(key: key, bundleID: "path:" + target.path, name: target.name, detail: key, route: nil)
    }

    func exit(for entry: AppEntry) -> Exit {
        profile.exit(id: entry.route?.exitID ?? profile.defaultExitID) ?? .direct
    }

    func icon(forKey key: String) -> NSImage {
        if let cached = iconCache[key] { return cached }
        let image: NSImage
        if key == AppKey.system {
            image = NSImage(systemSymbolName: "cpu", accessibilityDescription: nil) ?? NSImage()
        } else if key.contains("/.local/share/claude/") || key.contains("/Application Support/Claude/claude-code/"),
                  FileManager.default.fileExists(atPath: "/Applications/Claude.app") {
            image = NSWorkspace.shared.icon(forFile: "/Applications/Claude.app")
        } else {
            image = NSWorkspace.shared.icon(forFile: key)
        }
        iconCache[key] = image
        return image
    }

    // MARK: Статистика

    private var api: ClashAPI? { APICredentials.load().map(ClashAPI.init) }

    private func statsLoop() async {
        var tick = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            guard state == .running, let api else {
                flowRates = flowRates.mapValues { $0 * 0.5 }.filter { $0.value > 1 }
                continue
            }
            guard let snapshot = try? await api.connections() else { continue }
            let connections = snapshot.connections ?? []
            ingest(connections, interval: 1)
            let explainer = RouteExplainer(profile: profile)
            journal.update(with: connections) { c in
                (self.appKey(forProcessPath: c.metadata.executablePath), explainer.reason(clashRule: c.rule).title)
            }
            if journalLive { journalSnapshot = journal.entries }
            tick += 1
            if tick % 10 == 0 { refreshSuggestions() }
            if tick % 30 == 0 { stats.prune(); stats.save() }
        }
    }

    private func ingest(_ connections: [Connection], interval: Double) {
        var seen: [String: Int64] = [:]
        var rates: [String: Double] = [:]
        let now = Date()
        for c in connections {
            let total = c.upload + c.download
            let delta = total - (lastSeenBytes[c.id] ?? 0)
            seen[c.id] = total
            let key = appKey(forProcessPath: c.metadata.executablePath)
            activeApps[key] = now
            let tag = c.outboundTag ?? "direct"
            let flow = "flow:\(key)|\(tag)"
            rates[flow, default: 0] += Double(max(delta, 0)) / interval
            guard delta > 0 else { continue }
            stats.add("app:" + key, delta, at: now)
            stats.add("exit:" + tag, delta, at: now)
            stats.add(flow, delta, at: now)
        }
        lastSeenBytes = seen
        // Сглаживание, чтобы частицы на «Маршрутах» не дёргались.
        var merged: [String: Double] = [:]
        for k in Set(rates.keys).union(flowRates.keys) {
            merged[k] = 0.6 * (flowRates[k] ?? 0) + 0.4 * (rates[k] ?? 0)
        }
        flowRates = merged.filter { $0.value > 1 || rates[$0.key] != nil }
        lastUpdate = now
    }

    private func trafficLoop() async {
        while !Task.isCancelled {
            if state == .running, let api {
                do {
                    for try await sample in api.traffic() { speed = sample }
                } catch {}
            }
            speed = TrafficSample(up: 0, down: 0)
            try? await Task.sleep(for: .seconds(3))
        }
    }

    private func pingLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(state == .running ? 5 : 2))
            guard state == .running else { continue }
            await measurePings()
            try? await Task.sleep(for: .seconds(55))
        }
    }

    // MARK: Демо

    /// Живые придуманные данные: ядро и сеть не опрашиваются, ничего не сохраняется.
    private func startDemo() {
        state = .running
        vpnServices = Demo.vpnServices
        environment = Demo.environment
        physicalInterface = "en0"
        suggestions = [Demo.suggestion]
        pings = [Demo.tokyo.id: 64, Demo.hk.id: 38, Exit.directID: 12]
        pingHistory = [Demo.tokyo.id: [61, 66, 63, 70, 64, 62, 65, 64], Demo.hk.id: [36, 40, 38, 41, 37, 39, 38, 38]]
        Task.detached(priority: .utility) {
            let apps = AppCatalog.scan()
            await MainActor.run { self.installedApps = apps }
        }
        Task {
            let flows = Demo.flows
            var t = 0.0
            while !Task.isCancelled {
                let now = Date()
                var rates: [String: Double] = [:]
                var total = 0.0
                for (i, f) in flows.enumerated() {
                    // Средняя скорость за сутки ×8 и «дыхание», у каждого потока своё.
                    let base = Double(f.bytes) / 86_400 * 8
                    let r = base * (0.55 + 0.45 * sin(t * 0.9 + Double(i) * 1.7))
                    rates[f.key] = r
                    total += r
                    activeApps[String(f.key.dropFirst(5).split(separator: "|")[0])] = now
                }
                flowRates = rates
                speed = TrafficSample(up: Int64(total * 0.12), down: Int64(total))
                lastUpdate = now
                t += 1
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func measurePings() async {
        guard let api else { return }
        for exit in tunnelExits where isAvailable(exit) {
            let ms = try? await api.delay(tag: exit.tag)
            pings[exit.id] = ms
            if let ms {
                pingHistory[exit.id, default: []].append(ms)
                if pingHistory[exit.id]!.count > 30 { pingHistory[exit.id]!.removeFirst() }
            }
        }
        if let ms = try? await api.delay(tag: "direct") { pings[Exit.directID] = ms }
    }
}
