import AppKit
import UserNotifications

/// Уведомления macOS: отключился VPN, найдена блокировка, сменился сценарий.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    enum Kind: String, CaseIterable {
        case vpn, suggestions, scenarios

        var defaultsKey: String { "notify." + rawValue }
    }

    static let shared = Notifier()

    /// Последнее уведомление по ключу — чтобы мигающий VPN не засыпал уведомлениями.
    private var lastSent: [String: Date] = [:]

    func start() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        // Проверка без ожидания события: SPLITROUTE_NOTIFY_TEST=1 — пробное уведомление при запуске.
        if ProcessInfo.processInfo.environment["SPLITROUTE_NOTIFY_TEST"] == "1" {
            post(.vpn, key: "test", title: "Splitroute", body: L("Уведомления работают"), screen: .settings, throttle: 0)
        }
    }

    static func isEnabled(_ kind: Kind) -> Bool {
        UserDefaults.standard.object(forKey: kind.defaultsKey) as? Bool ?? true
    }

    static func setEnabled(_ kind: Kind, _ on: Bool) {
        UserDefaults.standard.set(on, forKey: kind.defaultsKey)
    }

    /// `key` — что именно случилось (например, `vpn-down:<id>`); повтор того же ключа раньше `throttle` не показывается.
    /// `screen` — экран, который открыть по нажатию.
    func post(_ kind: Kind, key: String, title: String, body: String, screen: Screen? = nil, throttle: TimeInterval = 120) {
        guard Self.isEnabled(kind) || key == "test" else { return }
        let now = Date()
        if let last = lastSent[key], now.timeIntervalSince(last) < throttle { return }
        lastSent[key] = now
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let screen { content.userInfo = ["screen": screen.rawValue] }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: key, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let screen = response.notification.request.content.userInfo["screen"] as? String
        await MainActor.run {
            if let screen { UserDefaults.standard.set(screen, forKey: "screen") }
            NSApp.activate()
            for w in NSApp.windows where w.canBecomeMain { w.makeKeyAndOrderFront(nil) }
        }
    }
}
