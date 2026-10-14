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

    public init(
        exits: [Exit] = [],
        routes: [AppRoute] = [],
        defaultExitID: String = Exit.directID,
        killSwitch: Bool = true,
        tunnelDNS: String = "1.1.1.1"
    ) {
        self.version = Self.currentVersion
        self.exits = exits
        self.routes = routes
        self.defaultExitID = defaultExitID
        self.killSwitch = killSwitch
        self.tunnelDNS = tunnelDNS
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
        if defaultExitID == id { defaultExitID = Exit.directID }
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
