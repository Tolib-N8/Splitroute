import Foundation
import Testing
@testable import SplitrouteCore

/// Резерв: отключённый VPN-выход уходит в другой подключённый VPN, а не сразу в kill switch.
struct FallbackTests {
    static let zoogID = "ZOOG-SERVICE"
    static let airlinkID = "AIRLINK-SERVICE"
    static let thirdID = "THIRD-SERVICE"
    static let whatsapp = #"^/Applications/WhatsApp\.app/"#

    static func profile(zoogFallback: String? = nil, killSwitch: Bool = true, defaultExit: String = Exit.directID, rules: [Rule] = []) -> Profile {
        Profile(
            exits: [
                Exit(id: "zoog", name: "ZoogVPN", kind: .vpnApp(serviceID: zoogID), fallbackID: zoogFallback),
                Exit(id: "airlink", name: "AIRLINK VPN", kind: .vpnApp(serviceID: airlinkID)),
                Exit(id: "third", name: "Third VPN", kind: .vpnApp(serviceID: thirdID)),
            ],
            routes: [AppRoute(bundleID: "net.whatsapp.WhatsApp", name: "WhatsApp", path: "/Applications/WhatsApp.app", exitID: "zoog")],
            defaultExitID: defaultExit,
            killSwitch: killSwitch,
            rules: rules
        )
    }

    static func env(_ connected: String...) -> NetworkEnvironment {
        var vpn: [String: NetworkEnvironment.VPNService] = [:]
        for (i, id) in connected.enumerated() { vpn[id] = .init(interface: "utun\(i + 1)") }
        return NetworkEnvironment(physicalInterface: "en0", vpnServices: vpn)
    }

    static let options = ConfigOptions(apiSecret: "test", cacheFilePath: "/tmp/splitroute-test-cache.db")

    func outbound(for pattern: String, _ profile: Profile, _ env: NetworkEnvironment) -> JSONValue? {
        let config = ConfigBuilder(profile: profile, environment: env, options: Self.options).build()
        guard case .array(let rules)? = config["route"]?["rules"] else { return nil }
        let r = rules.first { r in
            guard case .array(let p)? = r["process_path_regex"], r["ip_version"] == nil else { return false }
            return p.contains(.string(pattern))
        }
        return r?["outbound"] ?? r?["action"]
    }

    @Test func connectedExitIsUsedAsIs() {
        #expect(outbound(for: Self.whatsapp, Self.profile(), Self.env(Self.zoogID, Self.airlinkID)) == "exit-zoog")
    }

    @Test func autoFallbackPicksFirstConnectedVPN() {
        let p = Self.profile()
        #expect(outbound(for: Self.whatsapp, p, Self.env(Self.airlinkID)) == "exit-airlink")
        #expect(outbound(for: Self.whatsapp, p, Self.env(Self.thirdID)) == "exit-third")
        #expect(p.resolve(exitID: "zoog", in: Self.env(Self.airlinkID)) == .exit(p.exits[1], fallbackFrom: p.exits[0]))
    }

    @Test func assignedFallbackWinsOverListOrder() {
        let p = Self.profile(zoogFallback: "third")
        #expect(outbound(for: Self.whatsapp, p, Self.env(Self.airlinkID, Self.thirdID)) == "exit-third")
    }

    @Test func unavailableAssignedFallbackFallsToAnyConnected() {
        let p = Self.profile(zoogFallback: "third")
        #expect(outbound(for: Self.whatsapp, p, Self.env(Self.airlinkID)) == "exit-airlink")
    }

    @Test func noFallbackUsesKillSwitch() {
        #expect(outbound(for: Self.whatsapp, Self.profile(zoogFallback: Exit.noFallbackID), Self.env(Self.airlinkID)) == "reject")
        #expect(outbound(for: Self.whatsapp, Self.profile(zoogFallback: Exit.noFallbackID, killSwitch: false), Self.env(Self.airlinkID)) == "direct")
    }

    @Test func nothingConnectedUsesKillSwitch() {
        #expect(outbound(for: Self.whatsapp, Self.profile(), Self.env()) == "reject")
        #expect(outbound(for: Self.whatsapp, Self.profile(killSwitch: false), Self.env()) == "direct")
    }

    @Test func meshServicesAreNeverPicked() {
        // Tailscale подключён, но выходом не является (его нет в profile.exits).
        #expect(outbound(for: Self.whatsapp, Self.profile(), Self.env("TAILSCALE")) == "reject")
    }

    @Test func rulesAndDefaultExitFollowFallback() {
        let rule = Rule(kind: .domain, values: ["youtube.com"], exitID: "zoog")
        let p = Self.profile(defaultExit: "zoog", rules: [rule])
        let config = ConfigBuilder(profile: p, environment: Self.env(Self.airlinkID), options: Self.options).build()
        #expect(config["route"]?["final"] == "exit-airlink")
        guard case .array(let rules)? = config["route"]?["rules"] else { Issue.record("no rules"); return }
        let domain = rules.first { $0["domain_suffix"] != nil && $0["ip_version"] == nil }
        #expect(domain?["outbound"] == "exit-airlink")
    }

    @Test func oldProfilesDecodeAsAutoFallback() throws {
        let json = #"{"version":1,"exits":[{"id":"zoog","name":"ZoogVPN","kind":{"vpnApp":{"serviceID":"ZOOG-SERVICE"}}}],"routes":[],"defaultExitID":"direct","killSwitch":true,"tunnelDNS":"1.1.1.1"}"#
        let p = try JSONDecoder().decode(Profile.self, from: Data(json.utf8))
        #expect(p.exits.first?.fallbackID == nil)
    }
}
