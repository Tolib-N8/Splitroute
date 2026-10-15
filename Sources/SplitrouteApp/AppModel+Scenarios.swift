import Foundation
import SplitrouteCore

// MARK: - Сценарии

extension AppModel {
    var scenarios: [Scenario] { scenarioStore.scenarios }
    var activeScenario: Scenario? { scenarioStore.active }

    /// Правки маршрутов, правил и наборов сразу запоминаются в активном сценарии.
    func captureIntoActiveScenario() {
        guard let id = scenarioStore.activeID, let i = scenarioStore.scenarios.firstIndex(where: { $0.id == id }) else { return }
        scenarioStore.scenarios[i].capture(profile)
    }

    func activateScenario(_ id: String, automatically: Bool = false) {
        guard id != scenarioStore.activeID, let s = scenarioStore.scenarios.first(where: { $0.id == id }) else { return }
        scenarioStore.activeID = id          // раньше профиля: иначе его didSet запишет маршруты в старый сценарий
        profile = profile.applying(s)
        if automatically {
            let network = networkSignature.map(NetworkState.describe) ?? "сеть"
            Notifier.shared.post(.scenarios, key: "scenario:" + id, title: "Сценарий «\(s.name)»",
                                 body: "Включён автоматически: \(network)", screen: .apps, throttle: 60)
        }
    }

    /// Новый сценарий — копия текущих маршрутов. Первый раз текущие маршруты становятся сценарием «Основной».
    @discardableResult
    func createScenario() -> Scenario {
        if scenarioStore.scenarios.isEmpty {
            let base = Scenario(name: "Основной", capturing: profile)
            scenarioStore.scenarios.append(base)
            scenarioStore.activeID = base.id
        }
        var n = scenarioStore.scenarios.count + 1
        while scenarioStore.scenarios.contains(where: { $0.name == "Сценарий \(n)" }) { n += 1 }
        let s = Scenario(name: "Сценарий \(n)", capturing: profile)
        scenarioStore.scenarios.append(s)
        scenarioStore.activeID = s.id
        return s
    }

    func renameScenario(_ id: String, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let i = scenarioStore.scenarios.firstIndex(where: { $0.id == id }) else { return }
        scenarioStore.scenarios[i].name = name
    }

    /// Активный сценарий не удаляется — сначала переключитесь на другой.
    func deleteScenario(_ id: String) {
        guard id != scenarioStore.activeID else { return }
        scenarioStore.scenarios.removeAll { $0.id == id }
        if scenarioStore.scenarios.count == 1 { scenarioStore = ScenarioStore() }   // один сценарий — это просто настройки
    }

    func toggleCurrentNetwork(for id: String) {
        guard let networkSignature else { return }
        scenarioStore.toggle(network: networkSignature, for: id)
    }

    func switchScenario(forNetwork signature: String?) {
        guard let s = scenarioStore.scenario(forNetwork: signature) else { return }
        activateScenario(s.id, automatically: true)
    }
}

// MARK: - Уведомления о VPN

extension AppModel {
    /// VPN-приложение, через которое идут программы, отключилось или вернулось.
    func notifyVPNChanges(from old: [VPNServiceInfo], to new: [VPNServiceInfo]) {
        guard enabled, !old.isEmpty else { return }       // первый опрос после запуска — не событие
        let wasUp = Dictionary(old.map { ($0.id, $0.isConnected) }, uniquingKeysWith: { a, _ in a })
        for s in new where !s.isMesh {
            guard let before = wasUp[s.id], before != s.isConnected,
                  let exit = profile.exits.first(where: { $0.kind == .vpnApp(serviceID: s.id) }), isUsed(exit)
            else { continue }
            let apps = profile.routes.filter { $0.exitID == exit.id }.map(\.name)
            let who = apps.isEmpty ? "Его правила" : apps.prefix(2).joined(separator: ", ") + (apps.count > 2 ? " и ещё \(apps.count - 2)" : "")
            if s.isConnected {
                Notifier.shared.post(.vpn, key: "vpn-up:" + exit.id, title: "\(exit.name) снова подключён",
                                     body: "\(who) снова идут через него", screen: .servers)
            } else {
                Notifier.shared.post(.vpn, key: "vpn-down:" + exit.id, title: "\(exit.name) отключился",
                                     body: "\(who) — \(fallbackNote(for: exit))", screen: .servers)
            }
        }
    }

    /// Новые подсказки «не открывается напрямую» — одним уведомлением.
    func notifyNewSuggestions(_ fresh: [BlockAdvisor.Suggestion]) {
        let new = fresh.filter { !notifiedSuggestions.contains($0.id) }
        guard !new.isEmpty else { return }
        notifiedSuggestions.formUnion(new.map(\.id))
        let names = new.prefix(3).map(title(for:)).joined(separator: ", ")
        let via = suggestionExit.map { " — можно пустить через \($0.name)" } ?? ""
        Notifier.shared.post(.suggestions, key: "suggestions", title: "Не открывается напрямую",
                             body: names + (new.count > 3 ? " и ещё \(new.count - 3)" : "") + via,
                             screen: .apps, throttle: 600)
    }
}
