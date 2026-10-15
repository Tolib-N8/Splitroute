import Foundation
import SplitrouteCore

/// Демо-режим для роликов и скриншотов: `SPLITROUTE_DEMO=1`.
/// Придуманные VPN и трафик поверх настоящих установленных приложений. Профиль пользователя,
/// ядро, журнал и настройки не трогаются: ничего не пишется на диск и не уходит в helper.
/// `SPLITROUTE_DEMO_HK_DOWN=1` — Hong Kong VPN отключён (показать резерв).
enum Demo {
    static let isOn = ProcessInfo.processInfo.environment["SPLITROUTE_DEMO"] == "1"
    static let hkDown = ProcessInfo.processInfo.environment["SPLITROUTE_DEMO_HK_DOWN"] == "1"

    static let tokyoID = "DEMO-TOKYO", hkID = "DEMO-HK"
    static let tokyo = Exit(id: "tokyo", name: "Tokyo VPN", kind: .vpnApp(serviceID: tokyoID))
    static let hk = Exit(id: "hk", name: "Hong Kong VPN", kind: .vpnApp(serviceID: hkID))

    /// Путь, bundle ID, имя, выход, байт за сутки.
    static let apps: [(path: String, bundleID: String, name: String, exit: Exit, bytes: Int64)] = [
        ("/Applications/Google Chrome.app", "com.google.Chrome", "Google Chrome", tokyo, 2_150_000_000),
        ("/Applications/Telegram.app", "ru.keepcoder.Telegram", "Telegram", hk, 1_240_000_000),
        ("/Applications/WhatsApp.app", "net.whatsapp.WhatsApp", "WhatsApp", tokyo, 640_000_000),
        ("/Applications/Visual Studio Code.app", "com.microsoft.VSCode", "Visual Studio Code", tokyo, 520_000_000),
        ("/Applications/Claude.app", "com.anthropic.claudefordesktop", "Claude", hk, 380_000_000),
        ("/Applications/WeChat.app", "com.tencent.xinWeChat", "WeChat", .direct, 910_000_000),
        ("/Applications/Xcode.app", "com.apple.dt.Xcode", "Xcode", .direct, 1_600_000_000),
    ]

    static var profile: Profile {
        var p = Profile(exits: [tokyo, hk], defaultExitID: Exit.directID)
        for a in apps { p.setRoute(AppRoute(bundleID: a.bundleID, name: a.name, path: a.path, exitID: a.exit.id)) }
        return p
    }

    static var scenarios: ScenarioStore {
        let home = Scenario(id: "demo-home", name: "Home", capturing: profile)
        let office = Scenario(id: "demo-office", name: "Office", capturing: profile)
        return ScenarioStore(scenarios: [home, office], activeID: home.id)
    }

    static var vpnServices: [VPNServiceInfo] {
        [VPNServiceInfo(id: tokyoID, name: tokyo.name, interface: "utun4", serverAddress: "203.0.113.10"),
         VPNServiceInfo(id: hkID, name: hk.name, interface: hkDown ? nil : "utun6", serverAddress: "198.51.100.7")]
    }

    static var environment: NetworkEnvironment {
        var vpn: [String: NetworkEnvironment.VPNService] = [tokyoID: .init(interface: "utun4")]
        if !hkDown { vpn[hkID] = .init(interface: "utun6") }
        return NetworkEnvironment(physicalInterface: "en0", vpnServices: vpn)
    }

    /// Куда фактически идёт приложение (с учётом отключённого Hong Kong VPN → резерв).
    static func tag(for exit: Exit) -> String {
        profile.resolve(exitID: exit.id, in: environment).tag
    }

    /// Потоки «приложение → выход» и их доля. У Chrome часть трафика — китайские сайты напрямую.
    static var flows: [(key: String, tag: String, share: Double, bytes: Int64)] {
        apps.flatMap { a -> [(String, String, Double, Int64)] in
            let t = tag(for: a.exit)
            if a.name == "Google Chrome" {
                return [("flow:\(a.path)|\(t)", t, 0.8, a.bytes * 8 / 10), ("flow:\(a.path)|direct", "direct", 0.2, a.bytes * 2 / 10)]
            }
            return [("flow:\(a.path)|\(t)", t, 1, a.bytes)]
        }
    }

    /// Сутки трафика, разложенные по часам с «дыханием» дня.
    static var stats: TrafficStats {
        var s = TrafficStats()
        let now = Date()
        for h in 0..<24 {
            let at = now.addingTimeInterval(-Double(h) * 3600)
            let k = (0.55 + 0.45 * sin(Double(h) / 24 * 2 * .pi + 1)) / 24 * 1.6
            for a in apps { s.add("app:" + a.path, Int64(Double(a.bytes) * k), at: at) }
            for f in flows {
                s.add(f.key, Int64(Double(f.bytes) * k), at: at)
                s.add("exit:" + f.tag, Int64(Double(f.bytes) * k), at: at)
            }
        }
        return s
    }

    static let suggestion = BlockAdvisor.Suggestion(target: .domain("youtube.com"), failures: 23,
                                                    examples: ["/Applications/Google Chrome.app"])
}
