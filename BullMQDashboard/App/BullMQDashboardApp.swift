import AppKit
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
            CommandGroup(replacing: .appInfo) {
                Button("About QueueScope") {
                    showAboutPanel()
                }
            }

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

    private func showAboutPanel() {
        let credits = NSMutableAttributedString(string: "Built by Ray Nirola\nray@nirola.in\n")
        credits.append(NSAttributedString(
            string: "github.com/raynirola/queuescope",
            attributes: [.link: URL(string: "https://github.com/raynirola/queuescope") as Any]
        ))

        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "QueueScope",
            .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            .version: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            .credits: credits
        ])
    }
}
