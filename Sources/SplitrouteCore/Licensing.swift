import Foundation

/// Настройки продаж — блок `licensing` в appcast.json. Меняются без нового релиза (scripts/licensing.sh).
public struct LicensingConfig: Codable, Sendable, Equatable {
    /// Продаются ли лицензии. Пока нет — Splitroute бесплатен для всех (п. 3b LICENSE).
    public var sales: Bool
    public var trialDays: Int
    /// Магазин и товар Lemon Squeezy: ключ от чужого товара не примем.
    public var storeID: Int?
    public var productID: Int?
    /// Страница покупки.
    public var buyURL: URL?
    /// Цена для кнопки, например «$1».
    public var price: String?

    public init(sales: Bool = false, trialDays: Int = 7, storeID: Int? = nil, productID: Int? = nil, buyURL: URL? = nil, price: String? = nil) {
        self.sales = sales
        self.trialDays = trialDays
        self.storeID = storeID
        self.productID = productID
        self.buyURL = buyURL
        self.price = price
    }

    public static let closed = LicensingConfig()
}

/// Активированный на этом Mac ключ.
public struct StoredLicense: Codable, Sendable, Equatable {
    public var key: String
    public var instanceID: String
    public var customerEmail: String?
    public var activatedAt: Date
    public var lastValidated: Date

    public init(key: String, instanceID: String, customerEmail: String?, activatedAt: Date, lastValidated: Date) {
        self.key = key
        self.instanceID = instanceID
        self.customerEmail = customerEmail
        self.activatedAt = activatedAt
        self.lastValidated = lastValidated
    }

    /// `38b1…4d51` — чтобы показать ключ, не раскрывая его целиком.
    public var maskedKey: String {
        key.count > 8 ? "\(key.prefix(4))…\(key.suffix(4))" : key
    }
}

public enum LicenseStatus: Equatable, Sendable {
    /// Лицензии не продаются — бесплатно.
    case notForSale
    /// Пользовался Splitroute до начала продаж — бесплатно навсегда.
    case earlyAdopter
    case licensed(StoredLicense)
    case trial(daysLeft: Int)
    case expired

    /// Можно ли включать маршрутизацию.
    public var allowsRouting: Bool { self != .expired }

    /// Состояние по настройкам продаж и тому, что известно об этом Mac.
    /// `trialStart` — когда этот Mac впервые увидел открытые продажи.
    public static func evaluate(config: LicensingConfig, earlyAdopter: Bool, license: StoredLicense?,
                                trialStart: Date?, now: Date = Date()) -> LicenseStatus {
        if let license { return .licensed(license) }
        if earlyAdopter { return .earlyAdopter }
        guard config.sales else { return .notForSale }
        let start = trialStart ?? now
        let end = start.addingTimeInterval(Double(max(config.trialDays, 0)) * 86400)
        guard now < end else { return .expired }
        return .trial(daysLeft: max(1, Int(ceil(end.timeIntervalSince(now) / 86400))))
    }
}

/// License API Lemon Squeezy: активация, проверка и отвязка ключа. Ключ магазина не нужен.
public enum LemonSqueezy {
    public static let base = URL(string: "https://api.lemonsqueezy.com/v1/licenses/")!

    public struct Response: Decodable, Sendable {
        public struct Key: Decodable, Sendable { public var status: String? }
        public struct Instance: Decodable, Sendable { public var id: String }
        public struct Meta: Decodable, Sendable {
            public var store_id: Int?
            public var product_id: Int?
            public var customer_email: String?
        }
        public var activated: Bool?
        public var valid: Bool?
        public var deactivated: Bool?
        public var error: String?
        public var license_key: Key?
        public var instance: Instance?
        public var meta: Meta?
    }

    public struct Failure: LocalizedError, Equatable {
        public var message: String
        public init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }

    static func request(_ action: String, _ fields: [String: String]) -> URLRequest {
        var req = URLRequest(url: base.appendingPathComponent(action), timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        req.httpBody = fields.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").data(using: .utf8)
        return req
    }

    static func call(_ action: String, _ fields: [String: String]) async throws -> Response {
        let (data, _) = try await URLSession.shared.data(for: request(action, fields))
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw Failure(String(localized: "Сервер лицензий ответил непонятно"))
        }
    }

    /// Ключ от другого магазина или товара — не наш.
    static func checkProduct(_ r: Response, _ config: LicensingConfig) throws {
        if let store = config.storeID, r.meta?.store_id != store { throw Failure(String(localized: "Этот ключ не от Splitroute")) }
        if let product = config.productID, r.meta?.product_id != product { throw Failure(String(localized: "Этот ключ не от Splitroute")) }
    }

    public static func activate(key: String, instanceName: String, config: LicensingConfig, now: Date = Date()) async throws -> StoredLicense {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = try await call("activate", ["license_key": key, "instance_name": instanceName])
        guard r.activated == true, let instance = r.instance else {
            throw Failure(friendly(r.error) ?? String(localized: "Ключ не активирован"))
        }
        do {
            try checkProduct(r, config)
        } catch {
            _ = try? await call("deactivate", ["license_key": key, "instance_id": instance.id])
            throw error
        }
        return StoredLicense(key: key, instanceID: instance.id, customerEmail: r.meta?.customer_email, activatedAt: now, lastValidated: now)
    }

    /// Частые ответы сервера — понятным текстом; остальное как есть.
    static func friendly(_ error: String?) -> String? {
        guard let error else { return nil }
        let e = error.lowercased()
        if e.contains("not found") { return String(localized: "Ключ не найден — проверьте, что он скопирован целиком") }
        if e.contains("activation limit") { return String(localized: "Ключ уже активирован на максимуме Mac — отвяжите его на одном из них") }
        if e.contains("disabled") || e.contains("expired") { return String(localized: "Ключ отключён — возможно, покупка была возвращена") }
        return error
    }

    /// true — ключ действует; false — сервер ответил, что нет (возврат, отзыв). Сеть недоступна — ошибка.
    public static func validate(_ license: StoredLicense, config: LicensingConfig) async throws -> Bool {
        let r = try await call("validate", ["license_key": license.key, "instance_id": license.instanceID])
        guard r.valid == true else { return false }
        return (try? checkProduct(r, config)) != nil
    }

    public static func deactivate(_ license: StoredLicense) async throws {
        let r = try await call("deactivate", ["license_key": license.key, "instance_id": license.instanceID])
        if r.deactivated != true { throw Failure(r.error ?? String(localized: "Не удалось отвязать ключ")) }
    }
}
