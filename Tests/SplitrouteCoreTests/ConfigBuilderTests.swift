import Foundation
import Testing
@testable import SplitrouteCore

struct ConfigBuilderTests {
    static let zoogID = "5346FEF3-2433-4A7E-AFD3-FCD86EEE3FAD"

    static func sampleProfile(killSwitch: Bool = true, defaultExit: String = Exit.directID) -> Profile {
        let zoog = Exit(id: "zoog", name: "ZoogVPN", kind: .vpnApp(serviceID: zoogID))
        let vless = try! LinkParser.parseLink(
            "vless://bf000d23-0752-40b4-affe-68f7707a9661@example.com:443?security=reality&sni=www.apple.com&fp=chrome&pbk=jNXHt1yRo0vDuchQlIP6Z0ZvjT3KtzVI-T4E7RoLJS0&sid=0123&flow=xtls-rprx-vision#NL"
        )
        let nl = Exit(id: "nl", name: vless.name, kind: .proxy(vless.config))
        return Profile(
            exits: [zoog, nl],
            routes: [
                AppRoute(bundleID: "net.whatsapp.WhatsApp", name: "WhatsApp", path: "/Applications/WhatsApp.app", exitID: "zoog"),
                AppRoute(bundleID: "com.tencent.xinWeChat", name: "WeChat", path: "/Applications/WeChat.app", exitID: Exit.directID),
                AppRoute(bundleID: "com.google.Chrome", name: "Google Chrome", path: "/Applications/Google Chrome.app", exitID: "nl"),
                AppRoute(bundleID: "com.adobe.acc", name: "Adobe Updater", path: "/Applications/Adobe Updater.app", exitID: Exit.blockID),
            ],
            defaultExitID: defaultExit,
            killSwitch: killSwitch
        )
    }

    static let connected = NetworkEnvironment(
        physicalInterface: "en0",
        vpnServices: [zoogID: .init(interface: "utun0", serverAddress: "5.180.78.36")]
    )
    static let disconnected = NetworkEnvironment(physicalInterface: "en0")
    static let options = ConfigOptions(apiSecret: "test-secret", cacheFilePath: "/tmp/splitroute-test-cache.db")

    func rules(_ config: JSONValue) -> [JSONValue] {
        guard case .array(let r)? = config["route"]?["rules"] else { return [] }
        return r
    }

    func rule(matching pattern: String, in config: JSONValue) -> JSONValue? {
        rules(config).first { r in
            guard case .array(let p)? = r["process_path_regex"] else { return false }
            return p.contains(.string(pattern))
        }
    }

    @Test func routesEachAppToItsExit() {
        let config = ConfigBuilder(profile: Self.sampleProfile(), environment: Self.connected, options: Self.options).build()

        #expect(rule(matching: #"^/Applications/WhatsApp\.app/"#, in: config)?["outbound"] == "exit-zoog")
        #expect(rule(matching: #"^/Applications/WeChat\.app/"#, in: config)?["outbound"] == "direct")
        #expect(rule(matching: #"^/Applications/Google Chrome\.app/"#, in: config)?["outbound"] == "exit-nl")
        #expect(rule(matching: #"^/Applications/Adobe Updater\.app/"#, in: config)?["action"] == "reject")
        #expect(config["route"]?["final"] == "direct")
        #expect(config["route"]?["default_interface"] == "en0")
    }

    @Test func vpnAppExitBindsToItsInterface() {
        let config = ConfigBuilder(profile: Self.sampleProfile(), environment: Self.connected, options: Self.options).build()
        guard case .array(let outbounds)? = config["outbounds"] else { Issue.record("no outbounds"); return }
        let zoog = outbounds.first { $0["tag"] == "exit-zoog" }
        #expect(zoog?["bind_interface"] == "utun0")
        #expect(zoog?["domain_resolver"]?["server"] == "dns-exit-zoog")
        let direct = outbounds.first { $0["tag"] == "direct" }
        #expect(direct?["bind_interface"] == "en0")
    }

    @Test func excludesVPNServerAddressFromTunnel() {
        let config = ConfigBuilder(profile: Self.sampleProfile(), environment: Self.connected, options: Self.options).build()
        guard case .array(let inbounds)? = config["inbounds"], case .array(let excluded)? = inbounds.first?["route_exclude_address"] else {
            Issue.record("no tun"); return
        }
        #expect(excluded.contains("5.180.78.36/32"))
        #expect(excluded.contains("100.64.0.0/10"))
    }

    @Test func killSwitchBlocksWhenVPNAppDisconnected() {
        let config = ConfigBuilder(profile: Self.sampleProfile(), environment: Self.disconnected, options: Self.options).build()
        #expect(rule(matching: #"^/Applications/WhatsApp\.app/"#, in: config)?["action"] == "reject")
        guard case .array(let outbounds)? = config["outbounds"] else { return }
        #expect(!outbounds.contains { $0["tag"] == "exit-zoog" })
    }

    @Test func withoutKillSwitchFallsBackToDirect() {
        let config = ConfigBuilder(profile: Self.sampleProfile(killSwitch: false), environment: Self.disconnected, options: Self.options).build()
        #expect(rule(matching: #"^/Applications/WhatsApp\.app/"#, in: config)?["outbound"] == "direct")
    }

    @Test func blockAsDefaultAddsCatchAllReject() {
        let config = ConfigBuilder(profile: Self.sampleProfile(defaultExit: Exit.blockID), environment: Self.connected, options: Self.options).build()
        #expect(rules(config).last == ["inbound": ["tun-in"], "action": "reject"])
    }

    @Test func processPatternEscapesRegex() {
        #expect(ConfigBuilder.processPattern(forBundlePath: "/Applications/C++ (beta).app/") == #"^/Applications/C\+\+ \(beta\)\.app/"#)
    }

    /// Прогоняет конфиги через настоящий `sing-box check`, если sing-box установлен.
    @Test(arguments: [true, false])
    func singBoxAcceptsConfig(connected: Bool) throws {
        let candidates = ["/opt/homebrew/bin/sing-box", "/usr/local/bin/sing-box", Paths.singBox]
        guard let bin = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return }

        var profile = Self.sampleProfile()
        let wg = try LinkParser.parseWireGuard(WireGuardFixture.conf, name: "home")
        let ovpn = try LinkParser.parseOpenVPN(OpenVPNFixture.ovpn, name: "work")
        profile.exits += [Exit(id: "wg", name: wg.name, kind: .proxy(wg.config)), Exit(id: "ovpn", name: ovpn.name, kind: .proxy(ovpn.config))]
        profile.routes.append(AppRoute(bundleID: "a.b", name: "B", path: "/Applications/B.app", exitID: "wg"))
        profile.routes.append(AppRoute(bundleID: "a.c", name: "C", path: "/Applications/C.app", exitID: "ovpn"))

        let env = connected ? Self.connected : NetworkEnvironment(physicalInterface: nil)
        let data = try ConfigBuilder(profile: profile, environment: env, options: Self.options).build().encoded()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("splitroute-check-\(connected).json")
        try data.write(to: url)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["check", "-c", url.path]
        let err = Pipe()
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        let message = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(p.terminationStatus == 0, "sing-box check: \(message)")
    }
}
