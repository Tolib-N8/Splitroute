import AppKit
import Observation
import SplitrouteCore

/// Лицензия этого Mac: настройки продаж из appcast.json, ранний пользователь, пробный период, ключ Lemon Squeezy.
@MainActor
@Observable
final class Licensing {
    static let shared = Licensing()

    private(set) var config: LicensingConfig
    private(set) var license: StoredLicense?
    private(set) var earlyAdopter: Bool {
        didSet { UserDefaults.standard.set(earlyAdopter, forKey: Keys.earlyAdopter) }
    }
    private(set) var trialStart: Date? {
        didSet { UserDefaults.standard.set(trialStart, forKey: Keys.trialStart) }
    }
    /// Тикает раз в час, чтобы пробный период заканчивался и без действий пользователя.
    private var now = Date()

    var status: LicenseStatus {
        LicenseStatus.evaluate(config: config, earlyAdopter: earlyAdopter, license: license, trialStart: trialStart, now: now)
    }

    private enum Keys {
        static let initialized = "license.initialized"
        static let earlyAdopter = "license.earlyAdopter"
        static let trialStart = "license.trialStart"
        static let config = "license.config"
    }

    static var fileURL: URL { Paths.userProfile.deletingLastPathComponent().appendingPathComponent("license.json") }

    /// Создаётся до AppModel: «уже пользовался» определяется по тому, что осталось от прошлых версий.
    private init() {
        let d = UserDefaults.standard
        config = d.data(forKey: Keys.config).flatMap { try? JSONDecoder().decode(LicensingConfig.self, from: $0) } ?? .closed
        trialStart = d.object(forKey: Keys.trialStart) as? Date
        license = (try? Data(contentsOf: Self.fileURL)).flatMap { try? Self.decoder.decode(StoredLicense.self, from: $0) }
        if d.bool(forKey: Keys.initialized) {
            earlyAdopter = d.bool(forKey: Keys.earlyAdopter)
        } else {
            // Первый запуск версии с лицензиями: настроенный Splitroute — значит, пользовался раньше.
            let existing = d.object(forKey: "onboardingDone") != nil || FileManager.default.fileExists(atPath: Paths.userProfile.path)
            earlyAdopter = existing
            d.set(existing, forKey: Keys.earlyAdopter)
            d.set(true, forKey: Keys.initialized)
        }
    }

    private var started = false

    func start() {
        guard !started else { return }
        started = true
        Task {
            while !Task.isCancelled {
                await refreshConfig()
                await revalidateIfNeeded()
                for _ in 0..<6 {                       // настройки — раз в 6 часов, «сейчас» — раз в час
                    try? await Task.sleep(for: .seconds(3600))
                    now = Date()
                }
            }
        }
    }

    // MARK: Настройки продаж

    private var feedURL: URL {
        UserDefaults.standard.string(forKey: "updateFeedURL").flatMap(URL.init(string:)) ?? UpdateFeed.feedURL
    }

    func refreshConfig() async {
        struct Feed: Decodable { var licensing: LicensingConfig? }
        var req = URLRequest(url: feedURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        req.setValue("Splitroute/\(Updater.currentVersion)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: req) else { return }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return }
        guard let feed = try? JSONDecoder().decode(Feed.self, from: data) else { return }
        apply(feed.licensing ?? .closed)
    }

    private func apply(_ new: LicensingConfig) {
        now = Date()
        if !new.sales {
            earlyAdopter = true                      // пользуется до начала продаж — бесплатно навсегда
        } else if trialStart == nil {
            trialStart = now                         // пробный период — с момента, как этот Mac увидел продажи
        }
        if new != config {
            config = new
            UserDefaults.standard.set(try? JSONEncoder().encode(new), forKey: Keys.config)
        }
    }

    // MARK: Ключ

    func activate(key: String) async throws {
        let name = Host.current().localizedName ?? "Mac"
        let stored = try await LemonSqueezy.activate(key: key, instanceName: name, config: config)
        try save(stored)
    }

    func deactivate() async throws {
        guard let license else { return }
        try await LemonSqueezy.deactivate(license)
        try? FileManager.default.removeItem(at: Self.fileURL)
        self.license = nil
    }

    /// Раз в неделю спрашиваем, действует ли ключ. Нет сети — ключ остаётся; сервер сказал «нет» (возврат) — снимаем.
    private func revalidateIfNeeded() async {
        guard let current = license, Date().timeIntervalSince(current.lastValidated) > 7 * 86400 else { return }
        guard let valid = try? await LemonSqueezy.validate(current, config: config) else { return }
        if valid {
            var updated = current
            updated.lastValidated = Date()
            try? save(updated)
        } else {
            try? FileManager.default.removeItem(at: Self.fileURL)
            license = nil
        }
    }

    private func save(_ stored: StoredLicense) throws {
        let data = try Self.encoder.encode(stored)
        try FileManager.default.createDirectory(at: Self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: Self.fileURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.fileURL.path)
        license = stored
    }

    func openStore() {
        if let url = config.buyURL { NSWorkspace.shared.open(url) }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
