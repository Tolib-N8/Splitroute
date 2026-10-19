import Foundation
import Testing
@testable import SplitrouteCore

/// Выход «Авто», выходы, которые «не отвечают», и проба выходов через ядро.
struct AutoHealthTests {
    static let zoogID = "ZOOG", airlinkID = "AIRLINK"
    static let vless = try! LinkParser.parseLink(
        "vless://bf000d23-0752-40b4-affe-68f7707a9661@example.com:443?security=reality&sni=www.apple.com&fp=chrome&pbk=jNXHt1yRo0vDuchQlIP6Z0ZvjT3KtzVI-T4E7RoLJS0&sid=0123&flow=xtls-rprx-vision#NL"
    )
    static let whatsapp = #"^/Applications/WhatsApp\.app/"#

    static func profile(app exitID: String, killSwitch: Bool = true) -> Profile {
        Profile(
            exits: [
                Exit(id: "zoog", name: "ZoogVPN", kind: .vpnApp(serviceID: zoogID)),
                Exit(id: "airlink", name: "AIRLINK VPN", kind: .vpnApp(serviceID: airlinkID)),
                Exit(id: "nl", name: "NL", kind: .proxy(vless.config)),
            ],
            routes: [AppRoute(bundleID: "net.whatsapp.WhatsApp", name: "WhatsApp", path: "/Applications/WhatsApp.app", exitID: exitID)],
            killSwitch: killSwitch
        )
    }

    static func env(_ connected: [String], unhealthy: Set<String> = []) -> NetworkEnvironment {
        var vpn: [String: NetworkEnvironment.VPNService] = [:]
        for (i, id) in connected.enumerated() { vpn[id] = .init(interface: "utun\(i + 1)") }
        return NetworkEnvironment(physicalInterface: "en0", vpnServices: vpn, unhealthy: unhealthy)
    }

    static let options = ConfigOptions(apiSecret: "s3cret", cacheFilePath: "/tmp/splitroute-test-cache.db", probeListen: "127.0.0.1:9096")

    func build(_ p: Profile, _ e: NetworkEnvironment) -> JSONValue {
        ConfigBuilder(profile: p, environment: e, options: Self.options).build()
    }

    func appTarget(_ config: JSONValue) -> JSONValue? {
        guard case .array(let rules)? = config["route"]?["rules"] else { return nil }
        let r = rules.first { r in
            guard case .array(let p)? = r["process_path_regex"], r["ip_version"] == nil else { return false }
            return p.contains(.string(Self.whatsapp))
        }
        return r?["outbound"] ?? r?["action"]
    }

    func autoOutbound(_ config: JSONValue) -> JSONValue? {
        guard case .array(let outs)? = config["outbounds"] else { return nil }
        return outs.first { $0["tag"] == "auto" }
    }

    @Test func autoGroupsWorkingTunnels() {
        let config = build(Self.profile(app: Exit.autoID), Self.env([Self.zoogID, Self.airlinkID], unhealthy: ["zoog"]))
        #expect(appTarget(config) == "auto")
        #expect(autoOutbound(config)?["type"] == "urltest")
        #expect(autoOutbound(config)?["outbounds"] == .array(["exit-airlink", "exit-nl"]))   // zoog не отвечает
    }

    @Test func autoWithoutTunnelsFollowsKillSwitch() {
        let p = Profile(exits: [], routes: Self.profile(app: Exit.autoID).routes, killSwitch: true)
        #expect(appTarget(build(p, Self.env([]))) == "reject")
        var open = p
        open.killSwitch = false
        #expect(appTarget(build(open, Self.env([]))) == "direct")
        #expect(autoOutbound(build(p, Self.env([]))) == nil)
    }

    @Test func unhealthyVPNFallsBack() {
        let config = build(Self.profile(app: "zoog"), Self.env([Self.zoogID, Self.airlinkID], unhealthy: ["zoog"]))
        #expect(appTarget(config) == "exit-airlink")
        // Outbound больного выхода остаётся — его продолжают проверять.
        guard case .array(let outs)? = config["outbounds"] else { Issue.record("no outbounds"); return }
        #expect(outs.contains { $0["tag"] == "exit-zoog" })
    }

    @Test func unhealthyProxyFallsBack() {
        #expect(appTarget(build(Self.profile(app: "nl"), Self.env([Self.airlinkID], unhealthy: ["nl"]))) == "exit-airlink")
        #expect(appTarget(build(Self.profile(app: "nl"), Self.env([], unhealthy: ["nl"]))) == "reject")
    }

    @Test func probeInboundIsAuthenticatedPerExit() {
        let config = build(Self.profile(app: "zoog"), Self.env([Self.zoogID]))
        guard case .array(let inbounds)? = config["inbounds"],
              let probe = inbounds.first(where: { $0["tag"] == "probe-in" }),
              case .array(let users)? = probe["users"],
              case .array(let rules)? = config["route"]?["rules"]
        else { Issue.record("no probe inbound"); return }
        #expect(probe["listen"] == "127.0.0.1")
        #expect(probe["listen_port"] == .int(9096))
        #expect(users.map { $0["username"] } == ["direct", "auto", "exit-zoog", "exit-nl"])
        #expect(users.allSatisfy { $0["password"] == "s3cret" })
        // Правила пробы — до всех остальных, и в конце пробы — отказ.
        #expect(rules.first == ["inbound": ["probe-in"], "auth_user": ["direct"], "outbound": "direct"])
        #expect(rules[4] == ["inbound": ["probe-in"], "action": "reject"])
    }

    @Test func noProbeWithoutListen() {
        let config = ConfigBuilder(profile: Self.profile(app: "zoog"), environment: Self.env([Self.zoogID]),
                                   options: ConfigOptions(apiSecret: "s")).build()
        guard case .array(let inbounds)? = config["inbounds"] else { Issue.record("no inbounds"); return }
        #expect(inbounds.count == 1)
    }

    @Test func profileWithAutoRouteDecodes() throws {
        let json = #"{"version":1,"exits":[],"routes":[{"bundleID":"a","name":"A","path":"/Applications/A.app","exitID":"auto"}],"defaultExitID":"auto","killSwitch":true,"tunnelDNS":"1.1.1.1"}"#
        let p = try JSONDecoder().decode(Profile.self, from: Data(json.utf8))
        #expect(p.exit(id: p.defaultExitID) == .auto)
        #expect(p.exit(id: "auto")?.isTunnel == true)
    }

    @Test func healthReportRoundTrips() throws {
        let data = try JSONEncoder().encode(HealthReport(unhealthy: ["zoog"]))
        #expect(try JSONDecoder().decode(HealthReport.self, from: data).unhealthy == ["zoog"])
    }
}
