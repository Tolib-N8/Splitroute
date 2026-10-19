import Foundation

/// Куда фактически уходит трафик выхода при текущем состоянии сети.
public enum ExitResolution: Equatable, Sendable {
    /// `fallbackFrom` — исходный выход, если сработал резерв.
    case exit(Exit, fallbackFrom: Exit?)
    case reject

    public var tag: String {
        switch self {
        case .exit(let e, _): return e.tag
        case .reject: return Exit.block.tag
        }
    }
}

extension Profile {
    /// Работает ли выход прямо сейчас: VPN-приложение подключено, выход отвечает
    /// (не в `unhealthy`), у «Авто» есть хоть один рабочий туннель.
    public func isAvailable(_ exit: Exit, in env: NetworkEnvironment) -> Bool {
        if env.unhealthy.contains(exit.id) { return false }
        switch exit.kind {
        case .vpnApp(let id): return env.vpnServices[id] != nil
        case .auto: return !autoCandidates(in: env).isEmpty
        case .direct, .block, .proxy: return true
        }
    }

    /// Из чего «Авто» выбирает самый быстрый: подключённые и отвечающие VPN-приложения и свои конфиги.
    public func autoCandidates(in env: NetworkEnvironment) -> [Exit] {
        exits.filter { e in
            switch e.kind {
            case .vpnApp, .proxy: return isAvailable(e, in: env)
            case .direct, .block, .auto: return false
            }
        }
    }

    /// Выход → фактический выход с учётом резерва и kill switch.
    /// Недоступный туннель (VPN отключён или не отвечает, свой конфиг не отвечает, у «Авто» нет кандидатов):
    /// назначенный резерв, если доступен; иначе (если резерв не выключен) первый подключённый VPN
    /// из списка; иначе блок или напрямую по kill switch.
    public func resolve(exitID id: String, in env: NetworkEnvironment) -> ExitResolution {
        guard let exit = exit(id: id) else { return resolve(exitID: Exit.directID, in: env) }
        switch exit.kind {
        case .direct: return .exit(exit, fallbackFrom: nil)
        case .block: return .reject
        case .vpnApp, .proxy, .auto:
            if isAvailable(exit, in: env) { return .exit(exit, fallbackFrom: nil) }
            if exit.fallbackID != Exit.noFallbackID {
                if let fid = exit.fallbackID, fid != exit.id, let f = self.exit(id: fid), f.isTunnel, isAvailable(f, in: env) {
                    return .exit(f, fallbackFrom: exit)
                }
                if let f = exits.first(where: { e in
                    if case .vpnApp = e.kind { return e.id != exit.id && isAvailable(e, in: env) }
                    return false
                }) {
                    return .exit(f, fallbackFrom: exit)
                }
            }
            return killSwitch ? .reject : .exit(.direct, fallbackFrom: exit)
        }
    }
}
