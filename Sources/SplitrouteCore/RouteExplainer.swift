import Foundation

/// Объясняет, куда пойдёт соединение и почему — в том же порядке, что и правила sing-box:
/// свои правила → готовые наборы → маршрут приложения → по умолчанию.
public struct RouteExplainer: Sendable {
    public enum Reason: Equatable, Sendable {
        case rule(index: Int)          // номер с 1
        case preset(id: String)
        case app(name: String)
        case defaultRoute

        public var title: String {
            switch self {
            case .rule(let i): return "Правило №\(i)"
            case .preset(let id): return PresetInfo.info(id)?.title ?? id
            case .app: return "Приложение"
            case .defaultRoute: return "По умолчанию"
            }
        }

        /// Шаг в «Порядке проверки» (1…4).
        public var step: Int {
            switch self {
            case .rule: return 1
            case .preset: return 2
            case .app: return 3
            case .defaultRoute: return 4
            }
        }
    }

    public struct Decision: Equatable, Sendable {
        public var exitID: String
        public var reason: Reason
    }

    public let profile: Profile

    public init(profile: Profile) {
        self.profile = profile
    }

    /// `presetMatches(presetID)` — проверка готового набора (например, через `sing-box rule-set match`).
    public func explain(
        host: String?, ip: String? = nil, port: Int? = nil, network: String? = nil, processPath: String?,
        presetMatches: (String) -> Bool = { _ in false }
    ) -> Decision {
        for (i, rule) in profile.rules.enumerated() where rule.enabled {
            guard rule.appPaths.isEmpty || rule.appPaths.contains(where: { Self.path(processPath, isIn: $0) }) else { continue }
            if rule.matches(host: host, ip: ip, port: port, network: network) {
                return Decision(exitID: rule.exitID, reason: .rule(index: i + 1))
            }
        }
        for preset in profile.presets where preset.enabled {
            if preset.id == "lan" {
                if let ip, Self.isPrivate(ip) { return Decision(exitID: preset.exitID, reason: .preset(id: preset.id)) }
                if let host, ["local", "lan", "home.arpa"].contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
                    return Decision(exitID: preset.exitID, reason: .preset(id: preset.id))
                }
                continue
            }
            if presetMatches(preset.id) { return Decision(exitID: preset.exitID, reason: .preset(id: preset.id)) }
        }
        if let route = profile.routes.first(where: { Self.path(processPath, isIn: $0.path) }) {
            return Decision(exitID: route.exitID, reason: .app(name: route.name))
        }
        return Decision(exitID: profile.defaultExitID, reason: .defaultRoute)
    }

    /// Причина по строке `rule` из Clash API, например `domain_suffix=[youtube.com] => route(exit-…)`.
    public func reason(clashRule rule: String?) -> Reason {
        guard let rule, rule != "final" else { return .defaultRoute }
        if let r = rule.range(of: "rule_set=[") {
            let tags = rule[r.upperBound...].prefix { $0 != "]" }.split(separator: " ").map(String.init)
            if let preset = PresetInfo.catalog.first(where: { !Set($0.ruleSets).isDisjoint(with: tags) }) {
                return .preset(id: preset.id)
            }
        }
        if rule.contains("ip_is_private") { return .preset(id: "lan") }
        let isAppOnly = rule.hasPrefix("process_path_regex=") && !rule.contains(" ip_version") &&
            !["domain", "ip_cidr", "port"].contains(where: rule.contains)
        if !isAppOnly {
            for (i, r) in profile.rules.enumerated() where r.enabled {
                if let first = r.matchers().values.first, rule.contains(Self.describe(first)) { return .rule(index: i + 1) }
            }
        }
        return .app(name: "")
    }

    private static func describe(_ v: JSONValue) -> String {
        switch v {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .array(let a): return a.first.map(describe) ?? ""
        default: return ""
        }
    }

    /// Путь процесса внутри бандла/папки из правила.
    static func path(_ processPath: String?, isIn base: String) -> Bool {
        guard let p = processPath else { return false }
        if base.hasSuffix("/") { return p.hasPrefix(base) }
        return p == base || p.hasPrefix(base + "/")
    }

    static func isPrivate(_ ip: String) -> Bool {
        ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16", "fc00::/7", "fe80::/10"].contains { CIDR.contains($0, ip) }
    }
}
