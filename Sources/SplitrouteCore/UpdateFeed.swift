import CryptoKit
import Foundation

/// Описание релиза — `appcast.json`, который лежит в каждом GitHub-релизе.
public struct Appcast: Codable, Sendable, Equatable {
    public var version: String
    public var build: Int
    public var url: URL
    public var size: Int
    public var sha256: String
    /// Подпись Ed25519 над SHA-256 образа (base64).
    public var signature: String
    public var notes: String
    public var minimumSystemVersion: String
    public var date: String

    public init(version: String, build: Int, url: URL, size: Int, sha256: String, signature: String, notes: String,
                minimumSystemVersion: String = "15.0", date: String) {
        self.version = version
        self.build = build
        self.url = url
        self.size = size
        self.sha256 = sha256
        self.signature = signature
        self.notes = notes
        self.minimumSystemVersion = minimumSystemVersion
        self.date = date
    }
}

public enum UpdateFeed {
    public static let repository = "Tolib-N8/Splitroute"
    /// Всегда указывает на appcast.json последнего релиза.
    public static let feedURL = URL(string: "https://github.com/\(repository)/releases/latest/download/appcast.json")!
    /// Публичный ключ подписи обновлений (приватный — в связке ключей у того, кто выпускает релизы).
    public static let publicKey = "Phh7ugeefERzR55zXqSSjp39gxdHtxodEbWmOomJbqQ="

    public enum Failure: Error, Equatable, LocalizedError {
        case checksum
        case signature

        public var errorDescription: String? {
            switch self {
            case .checksum: return "Контрольная сумма обновления не совпадает"
            case .signature: return "Подпись обновления недействительна"
            }
        }
    }

    /// Проверяет, что файл — тот самый, что описан в appcast, и подписан нашим ключом.
    public static func verify(_ data: Data, appcast: Appcast, publicKey: String = publicKey) throws {
        let digest = Data(SHA256.hash(data: data))
        guard digest.map({ String(format: "%02x", $0) }).joined() == appcast.sha256.lowercased() else { throw Failure.checksum }
        guard let keyData = Data(base64Encoded: publicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              let sig = Data(base64Encoded: appcast.signature),
              key.isValidSignature(sig, for: digest)
        else { throw Failure.signature }
    }

    /// Сравнение версий вида 1.2.10 (числовое, по компонентам).
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
