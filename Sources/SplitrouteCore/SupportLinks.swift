import Foundation

/// Ссылки на донаты — блок `support` в appcast.json (из support.json, scripts/support.sh).
/// Меняются без нового релиза; пустые не показываются.
public struct SupportLinks: Codable, Sendable, Equatable {
    public var githubSponsors: URL?
    public var kofi: URL?
    public var buyMeACoffee: URL?

    public init(githubSponsors: URL? = nil, kofi: URL? = nil, buyMeACoffee: URL? = nil) {
        self.githubSponsors = githubSponsors
        self.kofi = kofi
        self.buyMeACoffee = buyMeACoffee
    }

    /// Только https-ссылки, в порядке показа.
    public var all: [(title: String, url: URL)] {
        [("GitHub Sponsors", githubSponsors), ("Ko-fi", kofi), ("Buy Me a Coffee", buyMeACoffee)]
            .compactMap { item in item.1.flatMap { $0.scheme == "https" ? (item.0, $0) : nil } }
    }

    public var isEmpty: Bool { all.isEmpty }
}
