import Foundation
import Testing
@testable import SplitrouteCore

struct ScenarioTests {
    static let vpn = Exit(id: "vpn", name: "AIRLINK VPN", kind: .vpnApp(serviceID: "A"))
    static let whatsapp = AppRoute(bundleID: "net.whatsapp.WhatsApp", name: "WhatsApp", path: "/Applications/WhatsApp.app", exitID: "vpn")
    static let home = "IPv4.Router=192.168.18.1;IPv4.RouterHardwareAddress=e4:f3:e8:af:05:67"
    static let office = "IPv4.Router=10.0.0.1;IPv4.RouterHardwareAddress=00:11:22:33:44:55"

    @Test func applyingSwapsRoutesButKeepsExitsAndDNS() {
        var p = Profile(exits: [Self.vpn], routes: [Self.whatsapp], tunnelDNS: "8.8.8.8")
        let withVPN = Scenario(name: "Дом", capturing: p)
        p.routes = []
        p.killSwitch = false
        let restored = p.applying(withVPN)
        #expect(restored.routes == [Self.whatsapp])
        #expect(restored.killSwitch == true)
        #expect(restored.exits == [Self.vpn])
        #expect(restored.tunnelDNS == "8.8.8.8")
    }

    @Test func missingDefaultExitFallsBackToDirect() {
        var s = Scenario(name: "Офис", capturing: Profile())
        s.defaultExitID = "deleted-exit"
        #expect(Profile().applying(s).defaultExitID == Exit.directID)
    }

    @Test func networkBelongsToOneScenario() {
        var store = ScenarioStore(scenarios: [Scenario(id: "h", name: "Дом", capturing: Profile()), Scenario(id: "o", name: "Офис", capturing: Profile())])
        store.toggle(network: Self.home, for: "h")
        #expect(store.scenario(forNetwork: Self.home)?.id == "h")
        store.toggle(network: Self.home, for: "o")
        #expect(store.scenario(forNetwork: Self.home)?.id == "o")
        #expect(store.scenarios[0].networks.isEmpty)
        store.toggle(network: Self.home, for: "o")
        #expect(store.scenario(forNetwork: Self.home) == nil)
        #expect(store.scenario(forNetwork: Self.office) == nil)
    }

    @Test func describesSignature() {
        #expect(NetworkState.describe(signature: Self.home) == "роутер 192.168.18.1")
    }
}
