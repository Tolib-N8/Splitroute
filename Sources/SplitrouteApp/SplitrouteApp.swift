import SplitrouteCore
import SwiftUI

@main
struct SplitrouteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @State private var updater = Updater()
    @AppStorage("showMenuBar") private var showMenuBar = true

    var body: some Scene {
        Window("Splitroute", id: "main") {
            RootView()
                .environment(model)
                .environment(updater)
                .frame(minWidth: 1180, minHeight: 760)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 960)

        // Проверка без клика по строке меню: SPLITROUTE_PANEL_PREVIEW=1 открывает мини-окно обычным окном.
        Window("Splitroute Panel", id: "panel-preview") {
            MenuBarPanel().environment(model).environment(updater)
        }
        .windowResizability(.contentSize)

        MenuBarExtra(isInserted: $showMenuBar) {
            MenuBarPanel().environment(model).environment(updater)
        } label: {
            Image(systemName: model.state == .running ? "arrow.triangle.branch" : "arrow.triangle.branch")
                .symbolRenderingMode(.hierarchical)
                .opacity(model.state == .running ? 1 : 0.5)
                .task { model.start() }
        }
        .menuBarExtraStyle(.window)
    }
}
