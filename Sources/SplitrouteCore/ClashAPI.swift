import Foundation

/// Версия протокола между приложением и root-helper'ом. Повышается, только когда меняется то,
/// что делает helper (сборка конфига, команды, версия sing-box) — тогда приложение попросит обновить компонент.
public enum HelperProtocol {
    public static let version = 5
}

/// Пути, общие для приложения и root-helper'а.
public enum Paths {
    public static let daemonLabel = "com.splitroute.core"
    public static let installDir = "/Library/PrivilegedHelperTools/com.splitroute"
    public static let helper = installDir + "/splitroute-helper"
    public static let singBox = installDir + "/sing-box"
    public static let dataDir = "/Library/Application Support/Splitroute"
    public static let config = dataDir + "/config.json"
    public static let cacheFile = dataDir + "/cache.db"
    /// Адрес и секрет Clash API; владелец — пользователь, права 600.
    public static let apiCredentials = dataDir + "/api.json"
    public static let launchDaemonPlist = "/Library/LaunchDaemons/\(daemonLabel).plist"
    public static let sudoers = "/etc/sudoers.d/splitroute"
    public static let log = "/Library/Logs/Splitroute/core.log"
    /// Флаг: публиковать DNS ядра как системный резолвер (читает `helper run` при старте).
    public static let dnsHijackFlag = dataDir + "/dns-hijack"
    /// Ключ SCDynamicStore с DNS ядра — временный, живёт, пока жив `helper run`.
    public static let dnsStoreKey = "State:/Network/Service/com.splitroute.dns/DNS"
    /// Файлы готовых наборов (.srs), которые helper скопировал из папки пользователя.
    public static let ruleSetsDir = dataDir + "/rulesets"

    public static func userRuleSets(home: String) -> String {
        home + "/Library/Application Support/Splitroute/rulesets"
    }

    public static func profile(home: String) -> String {
        home + "/Library/Application Support/Splitroute/profile.json"
    }

    public static var userProfile: URL {
        URL(fileURLWithPath: profile(home: NSHomeDirectory()))
    }
}

public struct APICredentials: Codable, Sendable, Equatable {
    public var listen: String
    public var secret: String

    public init(listen: String, secret: String) {
        self.listen = listen
        self.secret = secret
    }

    public static func load() -> APICredentials? {
        guard let data = FileManager.default.contents(atPath: Paths.apiCredentials) else { return nil }
        return try? JSONDecoder().decode(APICredentials.self, from: data)
    }
}

/// Соединение из `/connections`.
public struct Connection: Decodable, Sendable, Identifiable, Equatable {
    public struct Metadata: Decodable, Sendable, Equatable {
        public var network: String?
        public var destinationIP: String?
        public var destinationPort: String?
        public var host: String?
        public var processPath: String?

        /// Путь без суффикса пользователя: Clash API отдаёт `"/path/to/bin (user)"`.
        public var executablePath: String? {
            guard var p = processPath, p.hasSuffix(")"), let open = p.range(of: " (", options: .backwards) else { return processPath }
            p.removeSubrange(open.lowerBound...)
            return p
        }
    }

    public var id: String
    public var metadata: Metadata
    public var upload: Int64
    public var download: Int64
    public var start: String?
    public var chains: [String]
    public var rule: String?

    /// Тег выхода, через который ушло соединение (`direct`, `exit-…`).
    public var outboundTag: String? { chains.first }
}

public struct ConnectionsSnapshot: Decodable, Sendable, Equatable {
    public var downloadTotal: Int64
    public var uploadTotal: Int64
    public var connections: [Connection]?
}

public struct TrafficSample: Decodable, Sendable, Equatable {
    public var up: Int64
    public var down: Int64

    public init(up: Int64, down: Int64) {
        self.up = up
        self.down = down
    }
}

/// Клиент Clash API, который поднимает sing-box.
public struct ClashAPI: Sendable {
    public let base: URL
    public let secret: String

    public init(credentials: APICredentials) {
        self.base = URL(string: "http://\(credentials.listen)")!
        self.secret = credentials.secret
    }

    private func request(_ path: String, query: [URLQueryItem] = []) -> URLRequest {
        var c = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { c.queryItems = query }
        var r = URLRequest(url: c.url!, timeoutInterval: 10)
        r.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        return r
    }

    public func connections() async throws -> ConnectionsSnapshot {
        let (data, _) = try await URLSession.shared.data(for: request("connections"))
        return try JSONDecoder().decode(ConnectionsSnapshot.self, from: data)
    }

    /// Поток скорости раз в секунду.
    public func traffic() -> AsyncThrowingStream<TrafficSample, Error> {
        let req = request("traffic")
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, _) = try await URLSession.shared.bytes(for: req)
                    for try await line in bytes.lines {
                        if let s = try? JSONDecoder().decode(TrafficSample.self, from: Data(line.utf8)) {
                            continuation.yield(s)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Задержка до выхода в миллисекундах.
    public func delay(tag: String, url: String = "https://www.gstatic.com/generate_204", timeoutMs: Int = 5000) async throws -> Int {
        struct R: Decodable { var delay: Int }
        let req = request("proxies/\(tag)/delay", query: [.init(name: "timeout", value: "\(timeoutMs)"), .init(name: "url", value: url)])
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.timedOut) }
        return try JSONDecoder().decode(R.self, from: data).delay
    }
}
