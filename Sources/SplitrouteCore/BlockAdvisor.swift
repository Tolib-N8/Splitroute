import Foundation

/// Находит то, что не открывается напрямую (провайдер или GFW рвёт соединения), и предлагает пустить через VPN.
/// Признак неудачи — соединение закрылось, не получив ни байта: так выглядят таймауты и сбросы к заблокированным адресам.
public enum BlockAdvisor {

    /// Итог одного завершённого соединения из журнала.
    public struct Outcome: Sendable {
        public var appKey: String
        public var host: String
        public var direct: Bool
        /// Ушло напрямую по маршруту приложения или по умолчанию, а не по явному правилу/набору.
        public var byAppRoute: Bool
        public var failed: Bool
        public var end: Date

        public init(appKey: String, host: String, direct: Bool, byAppRoute: Bool, failed: Bool, end: Date) {
            self.appKey = appKey
            self.host = host
            self.direct = direct
            self.byAppRoute = byAppRoute
            self.failed = failed
            self.end = end
        }
    }

    public enum Target: Hashable, Sendable {
        case app(key: String)
        case domain(String)

        /// Ключ для «Скрыть».
        public var id: String {
            switch self {
            case .app(let k): return "app:" + k
            case .domain(let d): return "domain:" + d
            }
        }
    }

    public struct Suggestion: Hashable, Sendable, Identifiable {
        public var target: Target
        public var failures: Int
        /// Домены (для приложения) или приложения (для домена), где были сбои — для пояснения.
        public var examples: [String]
        public var id: String { target.id }
    }

    public static let window: TimeInterval = 30 * 60
    static let minDomainFailures = 4
    /// Часть адресов домена может работать (update.googleapis.com из Китая открывается) — смотрим на долю.
    static let minDomainFailureShare = 0.8
    static let minAppFailures = 6
    static let minAppFailureShare = 0.7

    /// `systemKey` — ключ системных служб: им маршрут не поставить, только правило домена.
    /// `appEligible` — можно ли предлагать приложение целиком (не скрыто, маршрут ещё «напрямую»).
    public static func analyze(_ outcomes: [Outcome], now: Date = Date(), systemKey: String,
                               appEligible: (String) -> Bool = { _ in true }) -> [Suggestion] {
        struct Tally { var failed = 0, ok = 0; var examples: [String: Int] = [:] }
        var domains: [String: Tally] = [:]
        var apps: [String: Tally] = [:]
        let since = now.addingTimeInterval(-window)

        for o in outcomes where o.direct && o.byAppRoute && o.end >= since {
            let domain = registrableDomain(o.host)
            if let domain {
                if o.failed {
                    domains[domain, default: Tally()].failed += 1
                    domains[domain, default: Tally()].examples[o.appKey, default: 0] += 1
                } else {
                    domains[domain, default: Tally()].ok += 1
                }
            }
            guard o.appKey != systemKey else { continue }
            if o.failed {
                apps[o.appKey, default: Tally()].failed += 1
                if let domain { apps[o.appKey, default: Tally()].examples[domain, default: 0] += 1 }
            } else {
                apps[o.appKey, default: Tally()].ok += 1
            }
        }

        func top(_ examples: [String: Int]) -> [String] {
            examples.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(3).map(\.key)
        }

        var result: [Suggestion] = []
        var appsSuggested = Set<String>()
        for (key, t) in apps where t.failed >= minAppFailures && Double(t.failed) / Double(t.failed + t.ok) >= minAppFailureShare
            && appEligible(key) {
            appsSuggested.insert(key)
            result.append(Suggestion(target: .app(key: key), failures: t.failed, examples: top(t.examples)))
        }
        for (domain, t) in domains where t.failed >= minDomainFailures && Double(t.failed) / Double(t.failed + t.ok) >= minDomainFailureShare {
            // Если все сбои — у приложения, которое и так предложено целиком, домен отдельно не нужен.
            if t.examples.keys.allSatisfy(appsSuggested.contains) { continue }
            result.append(Suggestion(target: .domain(domain), failures: t.failed, examples: top(t.examples)))
        }
        return result.sorted { $0.failures != $1.failures ? $0.failures > $1.failures : $0.id < $1.id }
    }

    /// Вторые уровни, под которыми регистрируют домены: `example.com.cn`, `example.co.uk`.
    static let secondLevel: Set<String> = [
        "com.cn", "net.cn", "org.cn", "gov.cn", "edu.cn", "com.hk", "com.tw", "co.uk", "org.uk", "co.jp",
        "co.kr", "com.au", "com.br", "com.sg", "com.ru", "co.in", "com.tr",
    ]

    /// `www.googleapis.com:443` → `googleapis.com`. IP-адреса и локальные имена — nil.
    public static func registrableDomain(_ host: String) -> String? {
        var h = host.lowercased()
        if h.hasPrefix("[") { return nil }                                   // [IPv6]:порт
        if let colon = h.lastIndex(of: ":"), h.firstIndex(of: ":") == colon { h = String(h[..<colon]) }
        if h.hasSuffix(".") { h.removeLast() }
        let labels = h.split(separator: ".").map(String.init)
        guard labels.count >= 2, labels.last!.contains(where: \.isLetter) else { return nil }
        if ["lan", "local", "arpa", "localhost", "internal"].contains(labels.last!) { return nil }
        let n = labels.count >= 3 && secondLevel.contains(labels.suffix(2).joined(separator: ".")) ? 3 : 2
        return labels.suffix(n).joined(separator: ".")
    }
}
