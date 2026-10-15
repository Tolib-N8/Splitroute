import AppKit
import SwiftUI

extension View {
    /// Видно ли окно с этим видом на самом деле: не закрыто, не свёрнуто, не перекрыто целиком.
    /// SwiftUI не снимает содержимое скрытого мини-окна и закрытого главного окна, и анимация
    /// без этого крутилась бы в фоне (~30% CPU).
    func onWindowVisibility(_ action: @escaping (Bool) -> Void) -> some View {
        background(WindowVisibilityReader(onChange: action))
    }
}

private struct WindowVisibilityReader: NSViewRepresentable {
    var onChange: (Bool) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: TrackingView, context: Context) {
        view.onChange = onChange
    }

    final class TrackingView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []
        private var last: Bool?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { report(false); return }
            let names: [Notification.Name] = [NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification,
                                              NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification]
            for name in names {
                let closing = name == NSWindow.willCloseNotification
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, let window = self.window else { return }
                        self.report(!closing && Self.isVisible(window))
                    }
                })
            }
            report(Self.isVisible(window))
        }

        private static func isVisible(_ window: NSWindow) -> Bool {
            window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
        }

        private func report(_ visible: Bool) {
            guard visible != last else { return }
            last = visible
            onChange?(visible)
        }
    }
}
