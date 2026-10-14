import Foundation
import SplitrouteCore

/// Почасовая статистика трафика за последние 24 часа. Хранится только на этом Mac.
struct TrafficStats: Codable {
    /// Номер часа (unix / 3600) → ключ → байты.
    var hourly: [Int: [String: Int64]] = [:]

    static var url: URL {
        Paths.userProfile.deletingLastPathComponent().appendingPathComponent("stats.json")
    }

    static func load() -> TrafficStats {
        guard let data = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(TrafficStats.self, from: data) else {
            return TrafficStats()
        }
        return s
    }

    func save() {
        try? JSONEncoder().encode(self).write(to: Self.url, options: .atomic)
    }

    private static func hour(_ date: Date) -> Int { Int(date.timeIntervalSince1970) / 3600 }

    mutating func add(_ key: String, _ bytes: Int64, at date: Date = .now) {
        guard bytes > 0 else { return }
        hourly[Self.hour(date), default: [:]][key, default: 0] += bytes
    }

    mutating func prune(now: Date = .now) {
        let minHour = Self.hour(now) - 23
        hourly = hourly.filter { $0.key >= minHour }
    }

    func total(_ key: String, now: Date = .now) -> Int64 {
        let minHour = Self.hour(now) - 23
        return hourly.reduce(0) { $1.key >= minHour ? $0 + ($1.value[key] ?? 0) : $0 }
    }

    /// Последние 24 часа, сгруппированные в `count` столбиков (от старых к новым).
    func bars(_ key: String, count: Int = 8, now: Date = .now) -> [Int64] {
        let current = Self.hour(now)
        let per = max(1, 24 / count)
        return (0..<count).map { i in
            let start = current - 24 + 1 + i * per
            return (start..<(start + per)).reduce(Int64(0)) { $0 + (hourly[$1]?[key] ?? 0) }
        }
    }

    /// Все ключи с заданным префиксом за 24 часа.
    func keys(prefix: String) -> Set<String> {
        var s = Set<String>()
        for bucket in hourly.values { for k in bucket.keys where k.hasPrefix(prefix) { s.insert(k) } }
        return s
    }
}

/// Ключ «приложения» по пути процесса: бандл .app, системные службы или сам бинарник.
enum AppKey {
    static let system = "system"

    static func from(processPath path: String?) -> String {
        guard let path, !path.isEmpty else { return system }
        if let bundle = AppCatalog.bundlePath(forProcessPath: path), !bundle.hasPrefix("/System/Library") {
            return bundle
        }
        let systemPrefixes = ["/System/", "/usr/", "/Library/Apple/", "/sbin/", "/bin/"]
        if systemPrefixes.contains(where: path.hasPrefix) { return system }
        return path
    }
}
