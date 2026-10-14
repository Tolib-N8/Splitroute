import Foundation

/// Своё правило: домены, IP или порты → выход. Проверяется раньше маршрутов приложений.
public struct Rule: Codable, Sendable, Equatable, Identifiable, Hashable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case domain, ip, port

        public var title: String {
            switch self {
            case .domain: return "Домен"
            case .ip: return "IP / подсеть"
            case .port: return "Порт"
            }
        }
    }

    public var id: String
    public var enabled: Bool
    public var kind: Kind
    /// Домены (`youtube.com`, `*.ytimg.com`), подсети (`10.8.0.0/16`) или порты (`443`, `UDP 27015-27050`).
    public var values: [String]
    /// Пути из маршрутов приложений; пусто — все приложения.
    public var appPaths: [String]
    public var exitID: String

    public init(id: String = UUID().uuidString.lowercased(), enabled: Bool = true, kind: Kind, values: [String], appPaths: [String] = [], exitID: String) {
        self.id = id
        self.enabled = enabled
        self.kind = kind
        self.values = values
        self.appPaths = appPaths
        self.exitID = exitID
    }

    /// Разбор ввода пользователя: через запятую, пробел или с новой строки.
    public static func splitValues(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

/// Готовый набор доменов/IP из sing-geosite / sing-geoip.
public struct RulePreset: Codable, Sendable, Equatable, Identifiable, Hashable {
    public var id: String
    public var enabled: Bool
    public var exitID: String

    public init(id: String, enabled: Bool, exitID: String) {
        self.id = id
        self.enabled = enabled
        self.exitID = exitID
    }
}

/// Описание готового набора: какие файлы правил он использует и куда по умолчанию направляет трафик.
public struct PresetInfo: Sendable, Identifiable {
    public enum DefaultExit: Sendable { case direct, tunnel, block }

    public var id: String
    public var title: String
    public var subtitle: String
    public var icon: String
    /// Теги rule-set; файлы `<tag>.srs`. Пусто — набор встроенный (локальная сеть).
    public var ruleSets: [String]
    public var defaultExit: DefaultExit

    /// Теги, которые helper разрешает копировать в системную папку.
    public static var allowedRuleSets: Set<String> { Set(catalog.flatMap(\.ruleSets)) }

    public static let catalog: [PresetInfo] = [
        PresetInfo(id: "cn", title: "Китайские сервисы", subtitle: "WeChat, Alipay, Baidu, банки · напрямую",
                   icon: "building.columns", ruleSets: ["geosite-cn", "geoip-cn"], defaultExit: .direct),
        PresetInfo(id: "gfw", title: "Заблокированное в Китае", subtitle: "Google, YouTube, Telegram… · через VPN",
                   icon: "globe.badge.chevron.backward", ruleSets: ["geosite-geolocation-!cn"], defaultExit: .tunnel),
        PresetInfo(id: "ads", title: "Блок рекламы и трекеров", subtitle: "Реклама, телеметрия",
                   icon: "hand.raised.slash", ruleSets: ["geosite-category-ads-all"], defaultExit: .block),
        PresetInfo(id: "lan", title: "Локальная сеть", subtitle: "192.168.0.0/16, 10.0.0.0/8, *.local",
                   icon: "house", ruleSets: [], defaultExit: .direct),
    ]

    public static func info(_ id: String) -> PresetInfo? { catalog.first { $0.id == id } }

    /// Адреса для скачивания: jsDelivr (обычно доступен из Китая), затем GitHub.
    public static func downloadURLs(tag: String) -> [URL] {
        let repo = tag.hasPrefix("geoip-") ? "sing-geoip" : "sing-geosite"
        let file = tag.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "!"))) ?? tag
        return [
            "https://cdn.jsdelivr.net/gh/SagerNet/\(repo)@rule-set/\(file).srs",
            "https://raw.githubusercontent.com/SagerNet/\(repo)/rule-set/\(file).srs",
        ].compactMap(URL.init(string:))
    }
}

// MARK: - Перевод правил в условия sing-box

extension Rule {
    /// Условия sing-box для значений правила (без process_path_regex).
    public func matchers() -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        switch kind {
        case .domain:
            var suffix: [String] = [], regex: [String] = []
            for raw in values {
                let v = raw.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " ."))
                var body = v
                if body.hasPrefix("*.") { body.removeFirst(2) }
                if body.contains("*") {
                    regex.append(Self.wildcardRegex(v))
                } else if !body.isEmpty {
                    suffix.append(body)
                }
            }
            if !suffix.isEmpty { out["domain_suffix"] = .strings(suffix) }
            if !regex.isEmpty { out["domain_regex"] = .strings(regex) }
        case .ip:
            let cidrs = values.map { v -> String in
                if v.contains("/") { return v }
                return v.contains(":") ? "\(v)/128" : "\(v)/32"
            }
            out["ip_cidr"] = .strings(cidrs)
        case .port:
            var ports: [JSONValue] = [], ranges: [String] = []
            var networks = Set<String>()
            for raw in values {
                var v = raw.uppercased()
                for net in ["TCP", "UDP"] where v.hasPrefix(net) {
                    networks.insert(net.lowercased())
                    v = String(v.dropFirst(3))
                }
                v = v.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "–", with: "-")
                if v.contains("-") {
                    let parts = v.split(separator: "-").map { $0.trimmingCharacters(in: .whitespaces) }
                    if parts.count == 2, Int(parts[0]) != nil, Int(parts[1]) != nil { ranges.append("\(parts[0]):\(parts[1])") }
                } else if let p = Int(v) {
                    ports.append(.int(p))
                }
            }
            if !ports.isEmpty { out["port"] = .array(ports) }
            if !ranges.isEmpty { out["port_range"] = .strings(ranges) }
            if networks.count == 1 { out["network"] = .strings(Array(networks)) }
        }
        return out
    }

    static func wildcardRegex(_ pattern: String) -> String {
        var p = pattern
        let leadingAny = p.hasPrefix("*.")
        if leadingAny { p.removeFirst(2) }
        let body = p.split(separator: "*", omittingEmptySubsequences: false)
            .map { ConfigBuilder.escapeRegex(String($0)) }
            .joined(separator: "[^.]*")
        return "^" + (leadingAny ? "(.+\\.)?" : "") + body + "$"
    }

    /// Совпадает ли правило с доменом/IP/портом (для проверки маршрута и журнала).
    public func matches(host: String?, ip: String?, port: Int?, network: String?) -> Bool {
        guard enabled else { return false }
        switch kind {
        case .domain:
            guard let host = host?.lowercased(), !host.isEmpty else { return false }
            let m = matchers()
            if case .array(let suffixes)? = m["domain_suffix"] {
                for case .string(let s) in suffixes where host == s || host.hasSuffix("." + s) { return true }
            }
            if case .array(let regexes)? = m["domain_regex"] {
                for case .string(let r) in regexes where host.range(of: r, options: .regularExpression) != nil { return true }
            }
            return false
        case .ip:
            guard let ip else { return false }
            return values.contains { CIDR.contains($0, ip) }
        case .port:
            guard let port else { return false }
            let m = matchers()
            if case .array(let nets)? = m["network"], let network, !nets.contains(.string(network)) { return false }
            if case .array(let ps)? = m["port"], ps.contains(.int(port)) { return true }
            if case .array(let rs)? = m["port_range"] {
                for case .string(let r) in rs {
                    let b = r.split(separator: ":").compactMap { Int($0) }
                    if b.count == 2, (b[0]...b[1]).contains(port) { return true }
                }
            }
            return false
        }
    }
}

/// Простая проверка вхождения IPv4/IPv6 в подсеть.
public enum CIDR {
    public static func contains(_ cidr: String, _ ip: String) -> Bool {
        let parts = cidr.split(separator: "/", maxSplits: 1).map(String.init)
        guard let net = bytes(parts[0]), let addr = bytes(ip), net.count == addr.count else { return false }
        let bits = parts.count > 1 ? Int(parts[1]) ?? net.count * 8 : net.count * 8
        var remaining = bits
        for i in 0..<net.count where remaining > 0 {
            let take = min(8, remaining)
            let mask = UInt8(truncatingIfNeeded: 0xFF << (8 - take))
            if net[i] & mask != addr[i] & mask { return false }
            remaining -= take
        }
        return true
    }

    static func bytes(_ s: String) -> [UInt8]? {
        if s.contains(":") {
            var a = in6_addr()
            guard inet_pton(AF_INET6, s, &a) == 1 else { return nil }
            return withUnsafeBytes(of: a) { Array($0) }
        }
        var a = in_addr()
        guard inet_pton(AF_INET, s, &a) == 1 else { return nil }
        return withUnsafeBytes(of: a) { Array($0) }
    }
}
