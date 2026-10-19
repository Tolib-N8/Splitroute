import Foundation
import SplitrouteCore

// MARK: - Живость выходов

extension AppModel {
    /// Пока какой-то выход не отвечает или только что не ответил — проверяем чаще.
    var healthCheckInterval: TimeInterval {
        unhealthy.isEmpty && healthStreak.values.allSatisfy { $0 >= 0 } ? 55 : 15
    }

    /// Что сейчас выбрал «Авто».
    var autoCurrent: Exit? {
        autoNow.flatMap { tag in profile.exits.first { $0.tag == tag } }
    }

    /// Итог очередной проверки (id выхода → задержка или nil). Выход «не отвечает» после двух неудач подряд,
    /// «ожил» — после двух удач: один потерянный пакет не гоняет программы туда-сюда.
    func updateHealth(_ results: [String: Int?]) {
        var down = unhealthy
        var newlyDown: [String] = [], back: [String] = []
        for (id, ms) in results {
            var s = healthStreak[id] ?? 0
            s = ms != nil ? max(s, 0) + 1 : min(s, 0) - 1
            healthStreak[id] = s
            if s <= -2, !down.contains(id) { down.insert(id); newlyDown.append(id) }
            if s >= 2, down.contains(id) { down.remove(id); back.append(id) }
        }
        // Отключённый туннель — уже не «не отвечает», а просто отключён.
        for id in down where results[id] == nil {
            down.remove(id)
            healthStreak[id] = nil
        }
        guard down != unhealthy else { return }
        try? JSONEncoder().encode(HealthReport(unhealthy: down.sorted())).write(to: Paths.userHealth, options: .atomic)
        setUnhealthy(down)
        scheduleApply(immediately: true)
        notifyHealth(down: newlyDown, back: back)
    }

    private func notifyHealth(down: [String], back: [String]) {
        for id in down {
            guard let exit = profile.exit(id: id) else { continue }
            let apps = profile.routes.filter { $0.exitID == exit.id }.map(\.name)
            let who = apps.isEmpty ? L("Его правила") : apps.prefix(2).joined(separator: ", ") + (apps.count > 2 ? L(" и ещё \(apps.count - 2)") : "")
            Notifier.shared.post(.vpn, key: "vpn-dead:" + id, title: L("\(exit.name) не отвечает"),
                                 body: "\(who) — \(fallbackNote(for: exit))", screen: .servers)
        }
        for id in back {
            guard let exit = profile.exit(id: id) else { continue }
            Notifier.shared.post(.vpn, key: "vpn-alive:" + id, title: L("\(exit.name) снова отвечает"),
                                 body: L("Приложения вернулись на него"), screen: .servers)
        }
    }
}

// MARK: - Замер скорости

extension AppModel {
    /// Что меряем: напрямую, «Авто» и все подключённые туннели (даже неотвечающие — увидеть, что там 0).
    var speedTargets: [Exit] {
        var list: [Exit] = [.direct]
        if isAvailable(.auto) { list.append(.auto) }
        list += tunnelExits.filter(isPresent)
        return list
    }

    /// По очереди качаем тестовый файл через каждый выход (вход «probe-in» ядра).
    func runSpeedTest() async {
        guard speedTesting == nil, state == .running else { return }
        guard let creds = APICredentials.load(), let probe = creds.probe else {
            lastError = L("Обновите системный компонент — без него скорость не измерить")
            return
        }
        for exit in speedTargets {
            speedTesting = exit.id
            speedResults[exit.id] = await SpeedTest.run(tag: exit.tag, probe: probe, secret: creds.secret)
        }
        speedTesting = nil
    }
}
