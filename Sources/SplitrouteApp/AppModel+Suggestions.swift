import Foundation
import SplitrouteCore

// MARK: - Подсказки «не открывается напрямую»

extension AppModel {
    /// Пересчёт по журналу: что за последние полчаса напрямую не получило ни байта.
    func refreshSuggestions() {
        guard !tunnelExits.isEmpty else {
            if !suggestions.isEmpty { suggestions = [] }
            return
        }
        let byApp: Set<String> = [RouteExplainer.Reason.app(name: "").title, RouteExplainer.Reason.defaultRoute.title]
        let outcomes = journal.entries.compactMap { e -> BlockAdvisor.Outcome? in
            guard let end = e.end, !e.rejected else { return nil }
            return .init(appKey: e.appKey, host: e.host, direct: e.exitTag == Exit.direct.tag,
                         byAppRoute: byApp.contains(e.reason), failed: (e.download ?? e.bytes) == 0, end: end)
        }
        // Приложение, которому маршрут уже поменяли или которое скрыли, не предлагаем — тогда его домены идут по одному.
        let appEligible = { (key: String) in
            !self.dismissedSuggestions.contains(BlockAdvisor.Target.app(key: key).id)
                && self.exit(for: self.entry(forKey: key)).kind == .direct
        }
        let fresh = BlockAdvisor.analyze(outcomes, systemKey: AppKey.system, appEligible: appEligible).filter { s in
            guard !dismissedSuggestions.contains(s.id) else { return false }
            if case .domain(let d) = s.target { return !ruleCovers(domain: d) }
            return true
        }
        if fresh != suggestions { suggestions = fresh }
    }

    /// Есть ли уже правило на этот домен (любой выход) — тогда он не наша забота.
    private func ruleCovers(domain: String) -> Bool {
        profile.rules.contains { r in
            r.kind == .domain && r.values.contains { v in
                let v = v.lowercased().replacingOccurrences(of: "*.", with: "")
                return domain == v || domain.hasSuffix("." + v) || v.hasSuffix("." + domain)
            }
        }
    }

    /// Куда предлагать: подключённый туннель, иначе первый из списка.
    var suggestionExit: Exit? { preferredTunnel }

    func title(for s: BlockAdvisor.Suggestion) -> String {
        switch s.target {
        case .app(let key): return entry(forKey: key).name
        case .domain(let d): return d
        }
    }

    func detail(for s: BlockAdvisor.Suggestion) -> String {
        let failures = "\(s.failures) \(Format.plural(s.failures, "неудачное соединение", "неудачных соединения", "неудачных соединений")) за 30 мин"
        switch s.target {
        case .app:
            return s.examples.isEmpty ? failures : failures + " · " + s.examples.joined(separator: ", ")
        case .domain:
            let apps = s.examples.map { entry(forKey: $0).name }
            return apps.isEmpty ? failures : failures + " · " + apps.joined(separator: ", ")
        }
    }

    func apply(_ s: BlockAdvisor.Suggestion, via exit: Exit) {
        switch s.target {
        case .app(let key): setRoute(appPath: key, exitID: exit.id)
        case .domain(let d): addRule(Rule(kind: .domain, values: [d], exitID: exit.id))
        }
        suggestions.removeAll { $0.id == s.id }
    }

    func dismiss(_ s: BlockAdvisor.Suggestion) {
        dismissedSuggestions.insert(s.id)
        suggestions.removeAll { $0.id == s.id }
    }
}

// MARK: - Автоподключение VPN-приложений

extension AppModel {
    /// Пауза перед следующей попыткой после N неудачных подряд: VPN, который не может подключиться
    /// (как ZoogVPN по OpenVPN из Китая), не дёргаем каждые 3 секунды.
    private static let autoConnectBackoff: [TimeInterval] = [0, 60, 120, 300, 600, 1800]

    /// Выход нужен, если через него что-то идёт: приложение, правило, набор, маршрут по умолчанию или резерв.
    func isUsed(_ exit: Exit) -> Bool {
        let p = profile
        return p.defaultExitID == exit.id
            || p.routes.contains { $0.exitID == exit.id }
            || p.rules.contains { $0.enabled && $0.exitID == exit.id }
            || p.presets.contains { $0.enabled && $0.exitID == exit.id }
            || p.exits.contains { $0.fallbackID == exit.id }
    }

    func setAutoConnect(_ on: Bool, for exit: Exit) {
        guard let i = profile.exits.firstIndex(where: { $0.id == exit.id }) else { return }
        profile.exits[i].autoConnect = on ? true : nil
        autoConnectAttempts[exit.id] = nil
    }

    /// Вызывается при каждом опросе сети (раз в 3 с).
    func autoConnectVPNs() {
        guard enabled else { return }
        let now = Date()
        for exit in profile.exits where exit.autoConnect == true {
            guard case .vpnApp(let serviceID) = exit.kind, let service = vpnService(for: exit) else { continue }
            if service.isConnected {
                autoConnectAttempts[exit.id] = nil
                continue
            }
            guard isUsed(exit) else { continue }
            let prev = autoConnectAttempts[exit.id]
            if let prev {
                let wait = Self.autoConnectBackoff[min(prev.failures, Self.autoConnectBackoff.count - 1)]
                guard now.timeIntervalSince(prev.last) >= max(wait, 30) else { continue }
            }
            NetworkState.startVPN(serviceID: serviceID)
            autoConnectAttempts[exit.id] = (now, (prev?.failures ?? -1) + 1)
        }
    }
}
