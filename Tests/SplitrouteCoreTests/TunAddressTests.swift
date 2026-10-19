import Foundation
import Testing
@testable import SplitrouteCore

/// Адрес TUN не должен пересекаться с чужими туннелями (ZoogVPN на Xray занимает 198.18.0.0/16).
struct TunAddressTests {
    func ip(_ s: String) -> UInt32 { ConfigBuilder.parseCIDR(s)!.0 }

    @Test func defaultWhenNothingConflicts() {
        #expect(ConfigBuilder.chooseTunAddress(occupied: [(ip("192.168.18.104"), 24), (ip("100.110.183.86"), 32)]) == "198.18.0.1/30")
    }

    @Test func skipsForeignNetwork() {
        #expect(ConfigBuilder.chooseTunAddress(occupied: [(ip("198.18.0.1"), 16)]) == "198.19.254.1/30")
        #expect(ConfigBuilder.chooseTunAddress(occupied: [(ip("198.18.0.1"), 15)]) == "203.0.113.1/30")
    }

    @Test func keepsOwnAddress() {
        // Наш TUN уже на запасном адресе, чужой VPN рядом — остаёмся, не прыгаем.
        #expect(ConfigBuilder.chooseTunAddress(occupied: [(ip("198.18.0.1"), 16), (ip("198.19.254.1"), 30)]) == "198.19.254.1/30")
        // Чужой VPN ушёл, наш TUN на запасном — всё равно остаёмся на нём.
        #expect(ConfigBuilder.chooseTunAddress(occupied: [(ip("198.19.254.1"), 30)]) == "198.19.254.1/30")
        // Наш TUN на основном адресе — это не конфликт с самим собой.
        #expect(ConfigBuilder.chooseTunAddress(occupied: [(ip("198.18.0.1"), 30)]) == "198.18.0.1/30")
    }

    @Test func dnsFollowsTun() {
        #expect(ConfigBuilder.dnsAddress(forTun: "198.18.0.1/30") == "198.18.0.2")
        #expect(ConfigBuilder.dnsAddress(forTun: "198.19.254.1/30") == "198.19.254.2")
    }

    @Test func configUsesChosenAddress() {
        let env = NetworkEnvironment(physicalInterface: "en0", tunAddress: "198.19.254.1/30")
        let config = ConfigBuilder(profile: Profile(), environment: env, options: ConfigOptions(apiSecret: "s")).build()
        guard case .array(let inbounds)? = config["inbounds"] else { Issue.record("no inbounds"); return }
        #expect(inbounds.first?["address"] == .array(["198.19.254.1/30"]))
    }
}
