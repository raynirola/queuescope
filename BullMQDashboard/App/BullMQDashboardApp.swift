import SwiftUI

@main
struct BullMQDashboardApp: App {
    @StateObject private var appModel = AppModel()
    @StateObject private var appUpdater = AppUpdater()

    var body: some Scene {
        WindowGroup {
            DashboardRootView()
                .environmentObject(appModel)
                .frame(minWidth: 1280, minHeight: 780)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Refresh") {
                    Task { await appModel.refreshSelectedQueue() }
                }
                .keyboardShortcut("r", modifiers: [.command])
            }

            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    appUpdater.checkForUpdates()
                }
                .disabled(!appUpdater.canCheckForUpdates)
            }
        }
    }
}
