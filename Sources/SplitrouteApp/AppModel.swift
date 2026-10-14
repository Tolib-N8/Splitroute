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
            guard profile != oldValue else { return }
            try? profile.save(to: Paths.userProfile)
            scheduleApply()
        }
    }

    var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "enabled")
            if enabled { scheduleApply(immediately: true) } else { Task { await stopCore() } }
        }
    }

    private(set) var state: CoreState = .stopped
    private(set) var vpnServices: [VPNServiceInfo] = []
    private(set) var physicalInterface: String?
    private(set) var installedApps: [InstalledApp] = []
    private(set) var stats = TrafficStats.load()
    private(set) var speed = TrafficSample(up: 0, down: 0)
    /// Скорость потоков «приложение → выход», байт/с (сглаженная).
    private(set) var flowRates: [String: Double] = [:]
    /// Приложения, замеченные в соединениях, → время последней активности.
    private(set) var activeApps: [String: Date] = [:]
    private(set) var pings: [String: Int] = [:]
    private(set) var pingHistory: [String: [Int]] = [:]
    private(set) var lastUpdate: Date?
    var lastError: String?

    private var lastSeenBytes: [String: Int64] = [:]
    private var applyTask: Task<Void, Never>?
    private var appliedEnvironment: NetworkEnvironment?
    private var iconCache: [String: NSImage] = [:]
    private var started = false

    init() {
        profile = (try? Profile.load(from: Paths.userProfile)) ?? Profile()
        enabled = UserDefaults.standard.object(forKey: "enabled") as? Bool ?? true
    }

    // MARK: Запуск

    func start() {
        guard !started else { return }
        started = true
        Theme.registerFonts()
        refreshNetwork()
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
        if !HelperClient.isInstalled {
            state = .notInstalled
        } else if HelperClient.needsUpdate {
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
        guard HelperClient.isInstalled, state != .needsUpdate else { return }
        applyTask?.cancel()
        applyTask = Task {
            if !immediately { try? await Task.sleep(for: .milliseconds(400)) }
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
            appliedEnvironment = NetworkState.environment()
            state = .running
            lastError = nil
        } catch {
            state = .failed(error.localizedDescription)
            lastError = error.localizedDescription
        }
    }

    private func stopCore() async {
        applyTask?.cancel()
        guard HelperClient.isInstalled else { return }
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
            refreshNetwork()
        }
    }

    private func refreshNetwork() {
        vpnServices = NetworkState.vpnServices()
        physicalInterface = NetworkState.physicalInterface()
        ensureVPNExits()

        // Сменился utun у VPN-приложения или Wi‑Fi — пересобираем конфиг.
        let env = NetworkEnvironment(
            physicalInterface: physicalInterface,
            vpnServices: Dictionary(uniqueKeysWithValues: vpnServices.compactMap { s in
                s.interface.map { (s.id, NetworkEnvironment.VPNService(interface: $0, serverAddress: s.serverAddress)) }
            })
        )
        if state == .running, let applied = appliedEnvironment, applied != env {
            appliedEnvironment = env
            scheduleApply(immediately: true)
        }
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
        case .direct: return "Обычная сеть · \(physicalInterface ?? "нет сети")"
        case .block: return "Трафик отклонён"
        case .vpnApp:
            guard let s = vpnService(for: exit) else { return "VPN-приложение · не найдено" }
            if let iface = s.interface { return "VPN-приложение · \(iface)" }
            return profile.killSwitch ? "Отключён · трафик блокируется" : "Отключён · идёт напрямую"
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

    func renameExit(_ exit: Exit, to name: String) {
        guard let i = profile.exits.firstIndex(where: { $0.id == exit.id }) else { return }
        profile.exits[i].name = name
    }

    // MARK: Приложения

    func setRoute(appPath: String, exitID: String) {
        guard let app = AppCatalog.app(at: appPath) else { return }
        profile.setRoute(AppRoute(bundleID: app.bundleID, name: app.name, path: app.path, exitID: exitID))
    }

    func removeRoute(_ route: AppRoute) {
        profile.routes.removeAll { $0.bundleID == route.bundleID }
    }

    /// Настроенные приложения + замеченные в трафике за сутки.
    var appEntries: [AppEntry] {
        var result: [AppEntry] = profile.routes.map {
            AppEntry(key: $0.path, bundleID: $0.bundleID, name: $0.name, detail: $0.bundleID, route: $0)
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
            return AppEntry(key: key, name: "Системные службы", detail: "macOS", route: nil)
        }
        if let app = AppCatalog.app(at: key) {
            return AppEntry(key: key, bundleID: app.bundleID, name: app.name, detail: app.bundleID, route: profile.route(for: app.bundleID))
        }
        return AppEntry(key: key, name: (key as NSString).lastPathComponent, detail: key, route: nil)
    }

    func exit(for entry: AppEntry) -> Exit {
        profile.exit(id: entry.route?.exitID ?? profile.defaultExitID) ?? .direct
    }

    func icon(forKey key: String) -> NSImage {
        if let cached = iconCache[key] { return cached }
        let image: NSImage
        if key == AppKey.system {
            image = NSImage(systemSymbolName: "cpu", accessibilityDescription: nil) ?? NSImage()
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
            try? await Task.sleep(for: .seconds(2))
            guard state == .running, let api else {
                flowRates = flowRates.mapValues { $0 * 0.5 }.filter { $0.value > 1 }
                continue
            }
            guard let snapshot = try? await api.connections() else { continue }
            ingest(snapshot.connections ?? [], interval: 2)
            tick += 1
            if tick % 15 == 0 { stats.prune(); stats.save() }
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
            let key = AppKey.from(processPath: c.metadata.processPath)
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
