import AppKit
import Observation
import SplitrouteCore

/// Донаты: ссылки из appcast.json и одна ненавязчивая просьба через две недели пользования.
@MainActor
@Observable
final class Support {
    static let shared = Support()

    private(set) var links: SupportLinks
    private(set) var askDismissed: Bool {
        didSet { UserDefaults.standard.set(askDismissed, forKey: Keys.dismissed) }
    }
    private let firstUse: Date

    private enum Keys {
        static let links = "support.links"
        static let dismissed = "support.askDismissed"
        static let firstUse = "support.firstUse"
    }

    /// Просить один раз: после 14 дней пользования, если есть куда донатить.
    var shouldAsk: Bool {
        !askDismissed && !links.isEmpty && Date().timeIntervalSince(firstUse) > 14 * 86400
    }

    private init() {
        let d = UserDefaults.standard
        links = d.data(forKey: Keys.links).flatMap { try? JSONDecoder().decode(SupportLinks.self, from: $0) } ?? SupportLinks()
        askDismissed = d.bool(forKey: Keys.dismissed)
        if let date = d.object(forKey: Keys.firstUse) as? Date {
            firstUse = date
        } else {
            firstUse = Date()
            d.set(firstUse, forKey: Keys.firstUse)
        }
        // Платного режима (1.5.0) больше нет — его следы не нужны.
        for key in ["license.initialized", "license.earlyAdopter", "license.trialStart", "license.config"] { d.removeObject(forKey: key) }
        try? FileManager.default.removeItem(at: Paths.userProfile.deletingLastPathComponent().appendingPathComponent("license.json"))
    }

    private var started = false

    func start() {
        guard !started else { return }
        started = true
        Task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(6 * 3600))
            }
        }
    }

    private func refresh() async {
        struct Feed: Decodable { var support: SupportLinks? }
        let url = UserDefaults.standard.string(forKey: "updateFeedURL").flatMap(URL.init(string:)) ?? UpdateFeed.feedURL
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        req.setValue("Splitroute/\(Updater.currentVersion)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: req) else { return }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return }
        guard let feed = try? JSONDecoder().decode(Feed.self, from: data) else { return }
        let new = feed.support ?? SupportLinks()
        if new != links {
            links = new
            UserDefaults.standard.set(try? JSONEncoder().encode(new), forKey: Keys.links)
        }
    }

    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
        askDismissed = true
    }

    func dismissAsk() { askDismissed = true }
}
