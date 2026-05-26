import SwiftUI

struct DashboardRootView: View {
    @EnvironmentObject private var model: AppModel
    @State private var isSidebarVisible = true
    @State private var isInspectorVisible = false

    var body: some View {
        rootSplit
        .frame(minWidth: 980, minHeight: 640)
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
                    ProgressView()
                        .controlSize(.small)
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
        .onChange(of: model.selectedJobDetail?.id) { _, id in
            isInspectorVisible = id != nil
        }
    }

    private var rootSplit: some View {
        HSplitView {
            if isSidebarVisible {
                SidebarView()
                    .frame(minWidth: 260, idealWidth: 300, maxWidth: 360, maxHeight: .infinity)
                    .background(.regularMaterial)
            }

            mainPanel
        }
    }

    private var mainPanel: some View {
        ZStack(alignment: .trailing) {
            QueueDashboardView()
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
