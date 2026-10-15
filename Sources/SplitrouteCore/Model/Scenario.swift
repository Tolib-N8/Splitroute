import Foundation

/// Сценарий — набор маршрутов под ситуацию («Дом», «Офис», «Поездка»). Выходы (VPN-приложения
/// и свои конфиги) общие для всех сценариев, переключаются только маршруты, правила и наборы.
public struct Scenario: Codable, Sendable, Equatable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var routes: [AppRoute]
    public var rules: [Rule]
    public var presets: [RulePreset]
    public var defaultExitID: String
    public var killSwitch: Bool
    /// `NetworkSignature` сетей (роутер + его MAC), в которых сценарий включается сам.
    public var networks: [String]

    public init(id: String = UUID().uuidString.lowercased(), name: String, capturing profile: Profile, networks: [String] = []) {
        self.id = id
        self.name = name
        self.routes = profile.routes
        self.rules = profile.rules
        self.presets = profile.presets
        self.defaultExitID = profile.defaultExitID
        self.killSwitch = profile.killSwitch
        self.networks = networks
    }

    /// Запомнить текущие маршруты профиля в этом сценарии.
    public mutating func capture(_ profile: Profile) {
        routes = profile.routes
        rules = profile.rules
        presets = profile.presets
        defaultExitID = profile.defaultExitID
        killSwitch = profile.killSwitch
    }
}

extension Profile {
    /// Профиль с маршрутами сценария; выходы, DNS и IPv6 не трогаем.
    public func applying(_ scenario: Scenario) -> Profile {
        var p = self
        p.routes = scenario.routes
        p.rules = scenario.rules
        p.presets = scenario.presets
        p.defaultExitID = exit(id: scenario.defaultExitID) != nil ? scenario.defaultExitID : Exit.directID
        p.killSwitch = scenario.killSwitch
        return p
    }
}

/// Все сценарии и активный. Хранится рядом с профилем, только для приложения — helper его не читает.
public struct ScenarioStore: Codable, Sendable, Equatable {
    public var scenarios: [Scenario] = []
    public var activeID: String?

    public init(scenarios: [Scenario] = [], activeID: String? = nil) {
        self.scenarios = scenarios
        self.activeID = activeID
    }

    public var active: Scenario? { scenarios.first { $0.id == activeID } }

    /// Сценарий, привязанный к сети.
    public func scenario(forNetwork signature: String?) -> Scenario? {
        guard let signature else { return nil }
        return scenarios.first { $0.networks.contains(signature) }
    }

    /// Сеть может вести только в один сценарий: привязка к новому снимает её с остальных.
    public mutating func toggle(network signature: String, for id: String) {
        guard let i = scenarios.firstIndex(where: { $0.id == id }) else { return }
        if scenarios[i].networks.contains(signature) {
            scenarios[i].networks.removeAll { $0 == signature }
        } else {
            for j in scenarios.indices { scenarios[j].networks.removeAll { $0 == signature } }
            scenarios[i].networks.append(signature)
        }
    }

    public static func load(from url: URL) -> ScenarioStore {
        guard let data = try? Data(contentsOf: url) else { return ScenarioStore() }
        return (try? JSONDecoder().decode(ScenarioStore.self, from: data)) ?? ScenarioStore()
    }

    public func save(to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try enc.encode(self).write(to: url, options: .atomic)
    }
}
