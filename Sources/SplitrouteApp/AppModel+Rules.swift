import AppKit
import Carbon.HIToolbox
import SplitrouteCore

enum RuleSetStatus: Equatable {
    case ready(Date)
    case downloading
    case failed(String)
}

extension AppModel {
    // MARK: Свои правила

    func addRule(_ rule: Rule) { profile.rules.append(rule) }

    func updateRule(_ rule: Rule) {
        guard let i = profile.rules.firstIndex(where: { $0.id == rule.id }) else { return }
        profile.rules[i] = rule
    }

    func deleteRule(_ rule: Rule) { profile.rules.removeAll { $0.id == rule.id } }

    func moveRule(_ rule: Rule, by delta: Int) {
        guard let i = profile.rules.firstIndex(where: { $0.id == rule.id }) else { return }
        let j = i + delta
        guard profile.rules.indices.contains(j) else { return }
        profile.rules.swapAt(i, j)
    }

    /// Сколько соединений сегодня сработало по причине (по журналу в памяти).
    func matchCount(reason: String) -> Int {
        journal.entries.reduce(0) { $1.reason == reason ? $0 + 1 : $0 }
    }

    // MARK: Готовые наборы

    static var ruleSetsDir: URL { URL(fileURLWithPath: Paths.userRuleSets(home: NSHomeDirectory())) }

    func refreshRuleSetStatus() {
        for info in PresetInfo.catalog where !info.ruleSets.isEmpty {
            if case .downloading = ruleSetStatus[info.id] { continue }
            let dates = info.ruleSets.map { tag -> Date? in
                let path = Self.ruleSetsDir.appendingPathComponent("\(tag).srs").path
                return (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
            }
            if dates.allSatisfy({ $0 != nil }) {
                setRuleSetStatus(info.id, .ready(dates.compactMap { $0 }.min()!))
            } else if ruleSetStatus[info.id] != nil, case .failed = ruleSetStatus[info.id]! {
                continue
            } else {
                setRuleSetStatus(info.id, nil)
            }
        }
    }

    var ruleSetsUpdated: Date? {
        ruleSetStatus.values.compactMap { if case .ready(let d) = $0 { return d }; return nil }.min()
    }

    /// Включить/выключить набор. При включении сначала скачиваем файлы.
    func setPreset(_ info: PresetInfo, enabled: Bool, exitID: String? = nil) async {
        let current = profile.preset(info.id)
        let exit = exitID ?? current?.exitID ?? defaultExitID(for: info)
        if enabled && !info.ruleSets.isEmpty {
            if case .ready = ruleSetStatus[info.id] {} else {
                guard await downloadRuleSets(info) else { return }
            }
        }
        profile.setPreset(RulePreset(id: info.id, enabled: enabled, exitID: exit))
    }

    func defaultExitID(for info: PresetInfo) -> String {
        switch info.defaultExit {
        case .direct: return Exit.directID
        case .block: return Exit.blockID
        case .tunnel: return preferredTunnel?.id ?? Exit.directID
        }
    }

    @discardableResult
    func downloadRuleSets(_ info: PresetInfo) async -> Bool {
        setRuleSetStatus(info.id, .downloading)
        do {
            try FileManager.default.createDirectory(at: Self.ruleSetsDir, withIntermediateDirectories: true)
            for tag in info.ruleSets {
                let data = try await Self.fetchRuleSet(tag)
                try data.write(to: Self.ruleSetsDir.appendingPathComponent("\(tag).srs"), options: .atomic)
            }
            setRuleSetStatus(info.id, .ready(Date()))
            return true
        } catch {
            setRuleSetStatus(info.id, .failed(error.localizedDescription))
            return false
        }
    }

    /// Обновить все включённые наборы и применить.
    func updateAllRuleSets() async {
        for p in profile.presets where p.enabled {
            if let info = PresetInfo.info(p.id), !info.ruleSets.isEmpty { await downloadRuleSets(info) }
        }
        scheduleApply(immediately: true)
    }

    private static func fetchRuleSet(_ tag: String) async throws -> Data {
        var lastError: Error = URLError(.cannotLoadFromNetwork)
        for url in PresetInfo.downloadURLs(tag: tag) {
            do {
                let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 30))
                guard (response as? HTTPURLResponse)?.statusCode == 200, data.starts(with: Array("SRS".utf8)) else {
                    throw URLError(.badServerResponse)
                }
                return data
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    // MARK: Проверка маршрута

    /// Куда пойдёт запрос к `host` от приложения `appPath` (nil — «любое»).
    func testRoute(host: String, appPath: String?) async -> RouteExplainer.Decision {
        let profile = self.profile
        let processPath = appPath.map { $0.hasSuffix("/") ? $0 + "x" : $0 + "/Contents/MacOS/x" }
        let ip = CIDR.bytes(host) != nil ? host : nil
        var matched = Set<String>()
        for p in profile.presets where p.enabled {
            guard let info = PresetInfo.info(p.id), !info.ruleSets.isEmpty else { continue }
            for tag in info.ruleSets where await Self.ruleSetMatches(tag: tag, value: host) {
                matched.insert(p.id)
                break
            }
        }
        return RouteExplainer(profile: profile).explain(
            host: ip == nil ? host.lowercased() : nil, ip: ip, processPath: processPath, presetMatches: matched.contains
        )
    }

    static var singBoxBinary: String? {
        [Bundle.main.resourcePath.map { $0 + "/sing-box" }, Paths.singBox, "/opt/homebrew/bin/sing-box"]
            .compactMap { $0 }.first(where: FileManager.default.isExecutableFile)
    }

    private static func ruleSetMatches(tag: String, value: String) async -> Bool {
        guard let bin = singBoxBinary else { return false }
        let file = ruleSetsDir.appendingPathComponent("\(tag).srs").path
        guard FileManager.default.fileExists(atPath: file) else { return false }
        return await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: bin)
                p.arguments = ["rule-set", "match", "-f", "binary", file, value]
                let out = Pipe()
                p.standardOutput = out
                p.standardError = Pipe()
                do { try p.run() } catch { cont.resume(returning: false); return }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: String(data: data, encoding: .utf8)?.contains("match") == true)
            }
        }
    }
}

// MARK: - Настройки и обслуживание

extension AppModel {
    var singBoxVersion: String { Self.cachedSingBoxVersion }

    private static let cachedSingBoxVersion: String = {
        guard let bin = singBoxBinary else { return "—" }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["version"]
        let out = Pipe()
        p.standardOutput = out
        guard (try? p.run()) != nil else { return "—" }
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        return text.split(separator: "\n").first?.split(separator: " ").last.map(String.init) ?? "—"
    }()

    var networkHasIPv6: Bool { environment.physicalIPv6 }

    /// Сброс правил, маршрутов и своих конфигов. VPN-приложения подхватятся заново, журнал не трогаем.
    func resetProfile() {
        profile = Profile()
    }

    func uninstallCore() async {
        do {
            try await HelperClient.uninstall()
            enabled = false
        } catch {
            lastError = error.localizedDescription
        }
        await recheckInstall()
    }

    /// Текст для поддержки: сеть, состояние ядра, профиль без секретов.
    func diagnostics() async -> String {
        var lines = ["Splitroute diagnostics \(Date().formatted(.iso8601))"]
        let env = NetworkState.environment()
        lines.append("physical: \(env.physicalInterface ?? "-") ipv6=\(env.physicalIPv6)")
        for s in vpnServices {
            lines.append("vpn: \(s.name) \(s.interface ?? "disconnected") server=\(s.serverAddress ?? "-") ipv6=\(s.ipv6)")
        }
        lines.append("state: \(state)")
        if let st = await HelperClient.status() { lines.append("core: running=\(st.running) pid=\(st.pid) protocol=\(st.protocol ?? 1)") }
        lines.append("sing-box: \(singBoxVersion)")
        lines.append("exits: " + profile.exits.map { "\($0.name)[\($0.kind.label)]" }.joined(separator: ", "))
        lines.append("routes: " + profile.routes.map { "\($0.name)→\(profile.exit(id: $0.exitID)?.name ?? $0.exitID)" }.joined(separator: ", "))
        lines.append("rules: \(profile.rules.count), presets: " + profile.presets.filter(\.enabled).map(\.id).joined(separator: ","))
        lines.append("default: \(profile.exit(id: profile.defaultExitID)?.name ?? "-"), killSwitch=\(profile.killSwitch), disableIPv6=\(profile.disableIPv6)")
        if let log = try? String(contentsOfFile: Paths.log, encoding: .utf8) {
            lines.append("--- core.log (последние строки)")
            lines += log.split(separator: "\n").suffix(30).map { String($0).replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression) }
        }
        return lines.joined(separator: "\n")
    }

    func registerHotKeys(openWindow: @escaping @MainActor () -> Void) {
        HotKeys.shared.register([
            .init(keyCode: kVK_ANSI_V, title: L("Вкл / выкл маршрутизацию"), keys: ["⌥", "⌘", "V"]) { [weak self] in
                guard let self, self.state != .notInstalled else { return }
                self.enabled.toggle()
            },
            .init(keyCode: kVK_ANSI_J, title: L("Открыть журнал"), keys: ["⌥", "⌘", "J"]) {
                UserDefaults.standard.set(Screen.journal.rawValue, forKey: "screen")
                openWindow()
            },
            .init(keyCode: kVK_ANSI_R, title: L("Открыть правила"), keys: ["⌥", "⌘", "R"]) {
                UserDefaults.standard.set(Screen.rules.rawValue, forKey: "screen")
                openWindow()
            },
        ])
    }
}

extension Exit.Kind {
    var label: String {
        switch self {
        case .direct: return "direct"
        case .block: return "block"
        case .vpnApp: return "vpn-app"
        case .proxy(let p): return p.protocolName
        }
    }
}
