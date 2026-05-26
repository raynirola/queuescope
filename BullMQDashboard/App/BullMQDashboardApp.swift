import SwiftUI

@main
struct BullMQDashboardApp: App {
    @StateObject private var appModel = AppModel()

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
        }
    }
}
