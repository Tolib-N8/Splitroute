import Foundation
import Testing
@testable import SplitrouteCore

struct RuleTests {
    static let env = ConfigBuilderTests.connected
    static let options = ConfigOptions(apiSecret: "t", ruleSetsDir: "/tmp/sr-rs", availableRuleSets: ["geosite-cn", "geoip-cn"])

    static func profile() -> Profile {
        var p = ConfigBuilderTests.sampleProfile()
        p.rules = [
            Rule(kind: .domain, values: ["youtube.com", "*.googlevideo.com"], exitID: "zoog"),
            Rule(kind: .domain, values: ["*.adservice.*"], exitID: Exit.blockID),
            Rule(kind: .ip, values: ["10.8.0.0/16"], exitID: Exit.directID),
            Rule(kind: .port, values: ["UDP 27015-27050"], appPaths: ["/Applications/Steam.app"], exitID: Exit.directID),
            Rule(enabled: false, kind: .domain, values: ["netflix.com"], exitID: "zoog"),
        ]
        p.presets = [
            RulePreset(id: "cn", enabled: true, exitID: Exit.directID),
            RulePreset(id: "ads", enabled: true, exitID: Exit.blockID),  // файла нет — пропускается
        ]
        return p
    }

    func rules(_ c: JSONValue) -> [JSONValue] {
        guard case .array(let r)? = c["route"]?["rules"] else { return [] }
        return r
    }

    @Test func customRulesComeBeforeAppRoutes() {
        let config = ConfigBuilder(profile: Self.profile(), environment: Self.env, options: Self.options).build()
        let r = rules(config)
        let yt = r.firstIndex { $0["domain_suffix"] == ["youtube.com", "googlevideo.com"] && $0["outbound"] != nil }
        let app = r.firstIndex { $0["process_path_regex"] != nil && $0["domain_suffix"] == nil && $0["port_range"] == nil }
        #expect(yt != nil && app != nil && yt! < app!)
        #expect(r[yt!]["outbound"] == "exit-zoog")
        #expect(r.contains { $0["domain_regex"] == [#"^(.+\.)?adservice\.[^.]*$"#] && $0["action"] == "reject" })
        #expect(r.contains { $0["ip_cidr"] == ["10.8.0.0/16"] && $0["outbound"] == "direct" })
        #expect(r.contains {
            $0["port_range"] == ["27015:27050"] && $0["network"] == ["udp"] && $0["process_path_regex"] == [#"^/Applications/Steam\.app/"#]
        })
        #expect(!r.contains { $0["domain_suffix"] == ["netflix.com"] })
    }

    @Test func presetsUseAvailableRuleSetsOnly() {
        let config = ConfigBuilder(profile: Self.profile(), environment: Self.env, options: Self.options).build()
        #expect(rules(config).contains { $0["rule_set"] == ["geosite-cn", "geoip-cn"] && $0["outbound"] == "direct" })
        #expect(!rules(config).contains { $0["rule_set"] == ["geosite-category-ads-all"] })
        guard case .array(let sets)? = config["route"]?["rule_set"] else { Issue.record("no rule_set"); return }
        #expect(sets.compactMap { $0["tag"]?.stringValue } == ["geoip-cn", "geosite-cn"])
        #expect(sets.first?["path"] == "/tmp/sr-rs/geoip-cn.srs")
    }

    @Test func explainerFollowsOrder() {
        let e = RouteExplainer(profile: Self.profile())
        let chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        #expect(e.explain(host: "www.youtube.com", processPath: chrome) == .init(exitID: "zoog", reason: .rule(index: 1)))
        #expect(e.explain(host: "pagead2.adservice.google", processPath: chrome).exitID == Exit.blockID)
        #expect(e.explain(host: "weixin.qq.com", processPath: chrome, presetMatches: { $0 == "cn" }) == .init(exitID: Exit.directID, reason: .preset(id: "cn")))
        #expect(e.explain(host: "example.com", processPath: chrome) == .init(exitID: "nl", reason: .app(name: "Google Chrome")))
        #expect(e.explain(host: "example.com", processPath: "/usr/bin/curl").reason == .defaultRoute)
        #expect(e.explain(host: nil, port: 27020, network: "udp", processPath: "/Applications/Steam.app/Contents/MacOS/steam").reason == .rule(index: 4))
        #expect(e.explain(host: nil, port: 27020, network: "udp", processPath: chrome).reason != .rule(index: 4))
    }

    @Test func reasonFromClashRule() {
        let e = RouteExplainer(profile: Self.profile())
        #expect(e.reason(clashRule: "final") == .defaultRoute)
        #expect(e.reason(clashRule: "rule_set=[geosite-cn geoip-cn] => route(direct)") == .preset(id: "cn"))
        #expect(e.reason(clashRule: "domain_suffix=[youtube.com googlevideo.com] => route(exit-zoog)") == .rule(index: 1))
        #expect(e.reason(clashRule: #"process_path_regex=[^/Applications/WhatsApp\.app/] => route(exit-zoog)"#) == .app(name: ""))
    }

    @Test func oldProfileWithoutNewFieldsDecodes() throws {
        let json = #"{"version":1,"exits":[],"routes":[],"defaultExitID":"direct","killSwitch":true,"tunnelDNS":"1.1.1.1"}"#
        let p = try JSONDecoder().decode(Profile.self, from: Data(json.utf8))
        #expect(p.rules.isEmpty && p.presets.isEmpty && !p.disableIPv6)
    }

    @Test func cidrContains() {
        #expect(CIDR.contains("10.8.0.0/16", "10.8.200.1"))
        #expect(!CIDR.contains("10.8.0.0/16", "10.9.0.1"))
        #expect(CIDR.contains("fd7a:115c:a1e0::/48", "fd7a:115c:a1e0:ab12::1"))
    }

    /// Конфиг с правилами и локальными наборами проходит `sing-box check`.
    @Test func singBoxAcceptsRules() throws {
        guard let bin = ["/opt/homebrew/bin/sing-box", Paths.singBox].first(where: FileManager.default.isExecutableFile) else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sr-rs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for tag in ["geosite-cn", "geoip-cn"] {
            let src = dir.appendingPathComponent("\(tag).json")
            try Data(#"{"version":3,"rules":[{"domain_suffix":["example.cn"]}]}"#.utf8).write(to: src)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: bin)
            p.arguments = ["rule-set", "compile", src.path, "-o", dir.appendingPathComponent("\(tag).srs").path]
            try p.run(); p.waitUntilExit()
            #expect(p.terminationStatus == 0)
        }
        var options = Self.options
        options.ruleSetsDir = dir.path
        let url = dir.appendingPathComponent("config.json")
        try ConfigBuilder(profile: Self.profile(), environment: Self.env, options: options).build().encoded().write(to: url)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["check", "-c", url.path]
        let err = Pipe()
        p.standardError = err
        try p.run(); p.waitUntilExit()
        let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(p.terminationStatus == 0, "sing-box check: \(msg)")
    }
}
