import AppKit
import SwiftUI

@main
struct BullMQDashboardApp: App {
    @FocusedObject private var appModel: AppModel?
    @StateObject private var appUpdater = AppUpdater()

    var body: some Scene {
        WindowGroup {
            if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
               NSClassFromString("XCTestCase") == nil {
                QueueScopeWindow()
                    .frame(minWidth: 1120, minHeight: 720)
            }
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About QueueScope") {
                    showAboutPanel()
                }
            }

            CommandGroup(after: .newItem) {
                Button("Refresh") {
                    Task { await appModel?.refreshSelectedQueue() }
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(appModel?.isConnected != true)
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

// Each scene owns its engine, connection, selection and refresh lifecycle.
struct QueueScopeWindow: View {
    @StateObject private var model = AppModel()

    var body: some View {
        DashboardRootView()
            .environmentObject(model)
            .focusedSceneObject(model)
            .navigationTitle(model.activeConnection.map { "QueueScope — \($0.name)" } ?? "QueueScope")
            .onDisappear { model.closeWindow() }
    }
}
