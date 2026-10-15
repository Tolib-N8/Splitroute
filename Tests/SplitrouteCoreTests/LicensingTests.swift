import Foundation
import Testing
@testable import SplitrouteCore

struct LicensingTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let open = LicensingConfig(sales: true, trialDays: 7, storeID: 1, productID: 4)
    static let license = StoredLicense(key: "38b1460a-5104-4067-a91d-77b872934d51", instanceID: "i", customerEmail: nil,
                                       activatedAt: now, lastValidated: now)

    func status(_ config: LicensingConfig, early: Bool = false, license: StoredLicense? = nil, trialStart: Date? = nil) -> LicenseStatus {
        LicenseStatus.evaluate(config: config, earlyAdopter: early, license: license, trialStart: trialStart, now: Self.now)
    }

    @Test func freeWhileNotForSale() {
        #expect(status(.closed) == .notForSale)
        #expect(status(.closed).allowsRouting)
    }

    @Test func earlyAdoptersStayFree() {
        #expect(status(Self.open, early: true) == .earlyAdopter)
        #expect(status(.closed, early: true) == .earlyAdopter)            // видно и до начала продаж
    }

    @Test func trialCountsDownAndExpires() {
        #expect(status(Self.open) == .trial(daysLeft: 7))                                     // только что увидел продажи
        #expect(status(Self.open, trialStart: Self.now.addingTimeInterval(-6.5 * 86400)) == .trial(daysLeft: 1))
        let expired = status(Self.open, trialStart: Self.now.addingTimeInterval(-7 * 86400))
        #expect(expired == .expired)
        #expect(!expired.allowsRouting)
    }

    @Test func licenseWinsOverEverything() {
        #expect(status(Self.open, license: Self.license, trialStart: .distantPast) == .licensed(Self.license))
    }

    @Test func serverErrorsAreReadable() {
        #expect(LemonSqueezy.friendly("license_key not found.")?.contains("не найден") == true)
        #expect(LemonSqueezy.friendly("Something else") == "Something else")
        #expect(LemonSqueezy.friendly(nil) == nil)
    }

    @Test func maskedKey() {
        #expect(Self.license.maskedKey == "38b1…4d51")
    }

    @Test func formEncodedRequest() throws {
        let req = LemonSqueezy.request("activate", ["license_key": "a b+c", "instance_name": "Mac mini"])
        #expect(req.url?.absoluteString == "https://api.lemonsqueezy.com/v1/licenses/activate")
        #expect(req.httpMethod == "POST")
        #expect(String(data: req.httpBody ?? Data(), encoding: .utf8) == "instance_name=Mac%20mini&license_key=a%20b%2Bc")
    }

    @Test func rejectsKeysOfOtherProducts() throws {
        let json = #"{"activated":true,"error":null,"instance":{"id":"x"},"meta":{"store_id":1,"product_id":99}}"#
        let r = try JSONDecoder().decode(LemonSqueezy.Response.self, from: Data(json.utf8))
        #expect(throws: LemonSqueezy.Failure.self) { try LemonSqueezy.checkProduct(r, Self.open) }
        let ours = #"{"valid":true,"meta":{"store_id":1,"product_id":4,"customer_email":"a@b.c"}}"#
        let r2 = try JSONDecoder().decode(LemonSqueezy.Response.self, from: Data(ours.utf8))
        try LemonSqueezy.checkProduct(r2, Self.open)
    }

    @Test func feedWithoutLicensingBlockDecodes() throws {
        struct Feed: Decodable { var licensing: LicensingConfig? }
        let f = try JSONDecoder().decode(Feed.self, from: Data(#"{"version":"1.4.0"}"#.utf8))
        #expect(f.licensing == nil)
    }
}
