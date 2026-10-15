import Foundation
import Testing
@testable import SplitrouteCore

struct SupportLinksTests {
    @Test func onlyHTTPSLinksInOrder() throws {
        let json = #"{"githubSponsors":null,"kofi":"https://ko-fi.com/x","buyMeACoffee":"http://buymeacoffee.com/x"}"#
        let links = try JSONDecoder().decode(SupportLinks.self, from: Data(json.utf8))
        #expect(links.all.map(\.title) == ["Ko-fi"])
        #expect(!links.isEmpty)
        #expect(SupportLinks().isEmpty)
    }

    @Test func feedWithoutSupportBlockDecodes() throws {
        struct Feed: Decodable { var support: SupportLinks? }
        #expect(try JSONDecoder().decode(Feed.self, from: Data(#"{"version":"1.6.0"}"#.utf8)).support == nil)
    }
}
