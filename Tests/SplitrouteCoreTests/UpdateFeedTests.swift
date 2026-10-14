import CryptoKit
import Foundation
import Testing
@testable import SplitrouteCore

struct UpdateFeedTests {
    static let key = Curve25519.Signing.PrivateKey()
    static var publicKey: String { key.publicKey.rawRepresentation.base64EncodedString() }

    static func appcast(for data: Data, signWith signer: Curve25519.Signing.PrivateKey = key) -> Appcast {
        let digest = Data(SHA256.hash(data: data))
        return Appcast(
            version: "1.0.1", build: 2, url: URL(string: "https://example.com/a.dmg")!, size: data.count,
            sha256: digest.map { String(format: "%02x", $0) }.joined(),
            signature: try! signer.signature(for: digest).base64EncodedString(), notes: "", date: "2026-10-15"
        )
    }

    @Test func acceptsSignedUpdate() throws {
        let data = Data("dmg".utf8)
        try UpdateFeed.verify(data, appcast: Self.appcast(for: data), publicKey: Self.publicKey)
    }

    @Test func rejectsTamperedFile() {
        let a = Self.appcast(for: Data("dmg".utf8))
        #expect(throws: UpdateFeed.Failure.checksum) { try UpdateFeed.verify(Data("evil".utf8), appcast: a, publicKey: Self.publicKey) }
    }

    @Test func rejectsForeignSignature() {
        let data = Data("dmg".utf8)
        let a = Self.appcast(for: data, signWith: Curve25519.Signing.PrivateKey())
        #expect(throws: UpdateFeed.Failure.signature) { try UpdateFeed.verify(data, appcast: a, publicKey: Self.publicKey) }
    }

    @Test func comparesVersions() {
        #expect(UpdateFeed.isNewer("1.0.1", than: "1.0.0"))
        #expect(UpdateFeed.isNewer("1.10.0", than: "1.9.9"))
        #expect(UpdateFeed.isNewer("2.0", than: "1.99.99"))
        #expect(!UpdateFeed.isNewer("1.0.0", than: "1.0.0"))
        #expect(!UpdateFeed.isNewer("1.0", than: "1.0.0"))
        #expect(!UpdateFeed.isNewer("0.9.9", than: "1.0.0"))
    }

    @Test func publicKeyIsValid() {
        #expect(Data(base64Encoded: UpdateFeed.publicKey).flatMap { try? Curve25519.Signing.PublicKey(rawRepresentation: $0) } != nil)
    }
}
