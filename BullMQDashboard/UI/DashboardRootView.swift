import SwiftUI

struct DashboardRootView: View {
    @EnvironmentObject private var model: AppModel
    @State private var isSidebarVisible = true
    @State private var isInspectorVisible = false
    @State private var isConnectionManagerVisible = false
    @State private var didPresentInitialConnectionManager = false
    @State private var selectedView: QueueWorkspaceView = .overview

    var body: some View {
        rootSplit
        .frame(minWidth: 1120, minHeight: 640)
        .animation(.snappy(duration: 0.18), value: isInspectorVisible)
        .animation(.snappy(duration: 0.18), value: model.selectedJobDetail?.id)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    isSidebarVisible.toggle()
                } label: {
                    Label("Toggle Queue List", systemImage: "sidebar.left")
                }
                .help(isSidebarVisible ? "Hide queue list" : "Show queue list")
            }

            ToolbarItemGroup {
                if model.isLoading {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(model.statusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: 280, alignment: .trailing)
                }
                Button {
                    Task { await model.refreshSelectedQueue() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(!model.isConnected || model.selectedQueue == nil)
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    isInspectorVisible.toggle()
                } label: {
                    Label("Toggle Inspector", systemImage: "sidebar.right")
                }
                .disabled(model.selectedJobDetail == nil)
                .help(isInspectorVisible ? "Hide inspector" : "Show inspector")
            }
        }
        .alert("Dashboard error", isPresented: errorBinding) {
            Button("OK") {
                model.lastError = nil
            }
        } message: {
            Text(model.lastError ?? "")
        }
        .sheet(isPresented: $isConnectionManagerVisible) {
            ConnectionManagerView()
                .environmentObject(model)
        }
        .onAppear {
            guard !didPresentInitialConnectionManager, (!model.isConnected || model.profiles.isEmpty) else { return }
            didPresentInitialConnectionManager = true
            isConnectionManagerVisible = true
        }
        .onChange(of: model.selectedJobDetail?.id) { _, id in
            isInspectorVisible = id != nil
        }
    }

    private var rootSplit: some View {
        HSplitView {
            if isSidebarVisible {
                SidebarView {
                    isConnectionManagerVisible = true
                }
                    .frame(minWidth: 260, idealWidth: 290, maxWidth: 330, maxHeight: .infinity)
                    .background(sidebarBackground)
            }

            WorkspaceViewSidebar(selectedView: $selectedView)
                .frame(minWidth: 205, idealWidth: 220, maxWidth: 250, maxHeight: .infinity)
                .background(sidebarBackground)

            mainPanel
        }
    }

    private var sidebarBackground: Color {
        Color(nsColor: .windowBackgroundColor)
    }

    private var mainPanel: some View {
        ZStack(alignment: .trailing) {
            QueueDashboardView(selectedView: selectedView)
                .frame(minWidth: 620, maxWidth: .infinity, maxHeight: .infinity)

            inspectorDrawer
        }
        .frame(minWidth: 620, maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var inspectorDrawer: some View {
        if isInspectorVisible, model.selectedJobDetail != nil {
            JobInspectorView()
                .frame(width: 400)
                .frame(maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .shadow(color: .black.opacity(0.18), radius: 22, x: -8, y: 0)
                .padding(.vertical, 10)
                .padding(.trailing, 10)
                .transition(.move(edge: .trailing).combined(with: .opacity))
                .zIndex(2)
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { model.lastError != nil },
            set: { if !$0 { model.lastError = nil } }
        )
    }
}

private struct WorkspaceViewSidebar: View {
    @EnvironmentObject private var model: AppModel
    @Binding var selectedView: QueueWorkspaceView

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 18)
                .frame(height: 88)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    WorkspaceSectionHeader(title: "Views")
                        .padding(.horizontal, 18)
                        .padding(.top, 12)
                        .padding(.bottom, 8)

                    ForEach(QueueWorkspaceView.allCases) { view in
                        WorkspaceViewRow(view: view, isSelected: selectedView == view)
                            .contentShape(RoundedRectangle(cornerRadius: 10))
                            .onTapGesture {
                                selectedView = view
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 3)
                    }
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.grid.1x2")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text("Workspace")
                    .font(.headline)
            }
            Text(model.selectedQueue?.name.titleCasedQueueName ?? "Select a queue")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

}

private struct WorkspaceSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct WorkspaceViewRow: View {
    let view: QueueWorkspaceView
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(isSelected ? Color.accentColor.opacity(0.14) : tint.opacity(0.10))
                Image(systemName: view.icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.accentColor : tint)
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(view.title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(isSelected ? .primary : .primary)
                    .lineLimit(1)
                if view.isComingSoon {
                    Text("Coming soon")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.accentColor.opacity(0.10))
            }
        }
    }

    private var tint: Color {
        switch view {
        case .overview: .blue
        case .runs: .teal
        case .flowGraph: .purple
        case .schedulers: .orange
        case .workers: .indigo
        case .metrics: .green
        }
    }
}
