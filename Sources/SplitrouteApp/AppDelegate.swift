import AppKit

/// Splitroute живёт в строке меню: крестик прячет окно, а слежение за сетью, резерв, сценарии
/// и уведомления продолжают работать. Завершает приложение только «Выйти» / ⌘Q.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Клик по иконке в Dock или повторный запуск из Finder — вернуть окно.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainWindow.open() }
        return true
    }
}

/// Главное окно и иконка в Dock: иконка видна, только пока окно открыто.
@MainActor
enum MainWindow {
    /// `openWindow(id: "main")` — запоминают RootView и мини-окно (у AppKit нет доступа к сценам SwiftUI).
    static var opener: (() -> Void)?

    static func open() {
        NSApp.setActivationPolicy(.regular)
        opener?()
        NSApp.activate()
    }

    static func didOpen() {
        NSApp.setActivationPolicy(.regular)
    }

    /// Без значка в строке меню прятать Dock-иконку нельзя — приложение будет не открыть.
    static func didClose() {
        let menuBar = UserDefaults.standard.object(forKey: "showMenuBar") as? Bool ?? true
        if menuBar { NSApp.setActivationPolicy(.accessory) }
    }
}
