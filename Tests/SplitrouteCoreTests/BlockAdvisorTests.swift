import Foundation
import Testing
@testable import SplitrouteCore

struct BlockAdvisorTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    func o(_ app: String, _ host: String, failed: Bool, direct: Bool = true, byApp: Bool = true, ago: TimeInterval = 60) -> BlockAdvisor.Outcome {
        .init(appKey: app, host: host, direct: direct, byAppRoute: byApp, failed: failed, end: Self.now.addingTimeInterval(-ago))
    }

    func analyze(_ items: [BlockAdvisor.Outcome]) -> [BlockAdvisor.Suggestion] {
        BlockAdvisor.analyze(items, now: Self.now, systemKey: "system")
    }

    @Test func registrableDomains() {
        #expect(BlockAdvisor.registrableDomain("www.googleapis.com:443") == "googleapis.com")
        #expect(BlockAdvisor.registrableDomain("gateway.instagram.com") == "instagram.com")
        #expect(BlockAdvisor.registrableDomain("news.bbc.co.uk") == "bbc.co.uk")
        #expect(BlockAdvisor.registrableDomain("www.example.com.cn") == "example.com.cn")
        #expect(BlockAdvisor.registrableDomain("172.217.113.4:443") == nil)
        #expect(BlockAdvisor.registrableDomain("[2607:f8b0::54]:443") == nil)
        #expect(BlockAdvisor.registrableDomain("printer.local") == nil)
    }

    @Test func blockedDomainFromSystemServices() {
        let items = (0..<5).map { _ in o("system", "gateway.instagram.com:443", failed: true) }
        #expect(analyze(items).map(\.target) == [.domain("instagram.com")])
    }

    @Test func mostlyWorkingDomainIsNotSuggested() {
        var items = (0..<6).map { _ in o("system", "www.googleapis.com", failed: true) }
        items += (0..<4).map { _ in o("system", "fonts.googleapis.com", failed: false) }
        #expect(analyze(items).isEmpty)
    }

    @Test func domainWithRareSuccessIsStillSuggested() {
        var items = (0..<18).map { _ in o("system", "www.googleapis.com", failed: true) }
        items += (0..<2).map { _ in o("/Applications/Google Chrome.app", "update.googleapis.com", failed: false) }
        #expect(analyze(items).map(\.target) == [.domain("googleapis.com")])
    }

    @Test func ineligibleAppFallsBackToDomains() {
        let app = "/Applications/Telegram.app"
        let items = (0..<8).map { _ in o(app, "dc1.telegram.org", failed: true) }
        let s = BlockAdvisor.analyze(items, now: Self.now, systemKey: "system", appEligible: { $0 != app })
        #expect(s.map(\.target) == [.domain("telegram.org")])
    }

    @Test func mostlyFailingAppIsSuggestedAsApp() {
        let app = "/Applications/Telegram.app"
        var items = (0..<8).map { i in o(app, "dc\(i % 3).telegram.org", failed: true) }
        items.append(o(app, "cdn.telegram.org", failed: false))
        let s = analyze(items)
        #expect(s.map(\.target) == [.app(key: app)])        // домен telegram.org поглощён приложением
        #expect(s.first?.examples == ["telegram.org"])
    }

    @Test func appWithMostlyWorkingTrafficGetsDomainNotApp() {
        let chrome = "/Applications/Google Chrome.app"
        var items = (0..<5).map { _ in o(chrome, "www.youtube.com", failed: true) }
        items += (0..<20).map { _ in o(chrome, "www.baidu.com", failed: false) }
        #expect(analyze(items).map(\.target) == [.domain("youtube.com")])
    }

    @Test func ignoresVPNTrafficExplicitRulesAndOldEntries() {
        var items = (0..<6).map { _ in o("system", "x.blocked.com", failed: true, direct: false) }
        items += (0..<6).map { _ in o("system", "y.blocked.com", failed: true, byApp: false) }
        items += (0..<6).map { _ in o("system", "z.blocked.com", failed: true, ago: BlockAdvisor.window + 60) }
        #expect(analyze(items).isEmpty)
    }
}
