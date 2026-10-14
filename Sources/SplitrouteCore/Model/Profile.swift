import Foundation

/// Куда может уйти трафик приложения.
public struct Exit: Codable, Sendable, Equatable, Identifiable, Hashable {
    public enum Kind: Codable, Sendable, Equatable, Hashable {
        /// Напрямую через физический интерфейс (Wi‑Fi / Ethernet).
        case direct
        /// Отклонить соединение.
        case block
        /// Через туннель уже запущенного VPN-приложения (ZoogVPN, AIRLINK…), по ID его сетевого сервиса.
        case vpnApp(serviceID: String)
        /// Свой конфиг, который поднимает sing-box.
        case proxy(ProxyConfig)
    }

    public static let directID = "direct"
    public static let blockID = "block"

    public var id: String
    public var name: String
    public var kind: Kind

    public init(id: String = UUID().uuidString.lowercased(), name: String, kind: Kind) {
        self.id = id
        self.name = name
        self.kind = kind
    }

    public static let direct = Exit(id: directID, name: "Напрямую", kind: .direct)
    public static let block = Exit(id: blockID, name: "Блок", kind: .block)

    /// Тег outbound/endpoint в конфиге sing-box.
    public var tag: String {
        switch kind {
        case .direct: return "direct"
        case .block: return "block"
        default: return "exit-\(id)"
        }
    }

    /// Выход, который считается «VPN» в фильтрах и цветах интерфейса.
    public var isTunnel: Bool {
        switch kind {
        case .vpnApp, .proxy: return true
        case .direct, .block: return false
        }
    }
}

/// Маршрут одного приложения.
public struct AppRoute: Codable, Sendable, Equatable, Identifiable, Hashable {
    public var bundleID: String
    public var name: String
    /// Путь к бандлу, например `/Applications/WhatsApp.app`.
    public var path: String
    public var exitID: String

    public var id: String { bundleID }

    public init(bundleID: String, name: String, path: String, exitID: String) {
        self.bundleID = bundleID
        self.name = name
        self.path = path
        self.exitID = exitID
    }
}

/// Всё, что настраивает пользователь. Это единственное, что приложение передаёт root-helper'у.
public struct Profile: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    /// Свои выходы: VPN-приложения и конфиги. `direct` и `block` встроены и здесь не хранятся.
    public var exits: [Exit]
    public var routes: [AppRoute]
    /// Куда идут приложения без правила.
    public var defaultExitID: String
    /// Если туннель выхода недоступен — блокировать, а не пускать напрямую.
    public var killSwitch: Bool
    /// DNS-сервер, который опрашивается через VPN-выходы.
    public var tunnelDNS: String
    /// Свои правила по доменам/IP/портам, сверху вниз.
    public var rules: [Rule]
    /// Включённые готовые наборы и их выходы.
    public var presets: [RulePreset]
    /// Не пускать IPv6 никуда, даже если сеть его поддерживает.
    public var disableIPv6: Bool
    /// Сделать DNS ядра системным: ответы для VPN-приложений будут без подмены провайдером.
    public var hijackSystemDNS: Bool

    public init(
        exits: [Exit] = [],
        routes: [AppRoute] = [],
        defaultExitID: String = Exit.directID,
        killSwitch: Bool = true,
        tunnelDNS: String = "1.1.1.1",
        rules: [Rule] = [],
        presets: [RulePreset] = [],
        disableIPv6: Bool = false,
        hijackSystemDNS: Bool = true
    ) {
        self.version = Self.currentVersion
        self.exits = exits
        self.routes = routes
        self.defaultExitID = defaultExitID
        self.killSwitch = killSwitch
        self.tunnelDNS = tunnelDNS
        self.rules = rules
        self.presets = presets
        self.disableIPv6 = disableIPv6
        self.hijackSystemDNS = hijackSystemDNS
    }

    private enum CodingKeys: String, CodingKey {
        case version, exits, routes, defaultExitID, killSwitch, tunnelDNS, rules, presets, disableIPv6, hijackSystemDNS
    }

    /// Новые поля необязательны — профили прошлых версий читаются без ошибок.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        exits = try c.decodeIfPresent([Exit].self, forKey: .exits) ?? []
        routes = try c.decodeIfPresent([AppRoute].self, forKey: .routes) ?? []
        defaultExitID = try c.decodeIfPresent(String.self, forKey: .defaultExitID) ?? Exit.directID
        killSwitch = try c.decodeIfPresent(Bool.self, forKey: .killSwitch) ?? true
        tunnelDNS = try c.decodeIfPresent(String.self, forKey: .tunnelDNS) ?? "1.1.1.1"
        rules = try c.decodeIfPresent([Rule].self, forKey: .rules) ?? []
        presets = try c.decodeIfPresent([RulePreset].self, forKey: .presets) ?? []
        disableIPv6 = try c.decodeIfPresent(Bool.self, forKey: .disableIPv6) ?? false
        hijackSystemDNS = try c.decodeIfPresent(Bool.self, forKey: .hijackSystemDNS) ?? true
    }

    /// Все выходы, включая встроенные.
    public var allExits: [Exit] { [.direct] + exits + [.block] }

    public func exit(id: String) -> Exit? { allExits.first { $0.id == id } }

    public func route(for bundleID: String) -> AppRoute? { routes.first { $0.bundleID == bundleID } }

    public mutating func setRoute(_ route: AppRoute) {
        if let i = routes.firstIndex(where: { $0.bundleID == route.bundleID }) {
            routes[i] = route
        } else {
            routes.append(route)
        }
    }

    public mutating func removeExit(id: String) {
        exits.removeAll { $0.id == id }
        routes.removeAll { $0.exitID == id }
        rules.removeAll { $0.exitID == id }
        for i in presets.indices where presets[i].exitID == id { presets[i].enabled = false; presets[i].exitID = Exit.directID }
        if defaultExitID == id { defaultExitID = Exit.directID }
    }

    public func preset(_ id: String) -> RulePreset? { presets.first { $0.id == id } }

    public mutating func setPreset(_ preset: RulePreset) {
        if let i = presets.firstIndex(where: { $0.id == preset.id }) { presets[i] = preset } else { presets.append(preset) }
    }
}

extension Profile {
    public static func load(from url: URL) throws -> Profile {
        try JSONDecoder().decode(Profile.self, from: Data(contentsOf: url))
    }

    public func save(to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try enc.encode(self).write(to: url, options: .atomic)
    }
}
