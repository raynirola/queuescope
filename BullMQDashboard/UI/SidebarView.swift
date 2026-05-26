import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            connectionForm
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 12)

            Divider()

            List(selection: selectedQueueBinding) {
                if !model.profiles.isEmpty {
                    Section("Connections") {
                        ForEach(model.profiles) { profile in
                            HStack {
                                Button {
                                    Task { await model.connect(profile: profile) }
                                } label: {
                                    Label(profile.name, systemImage: "externaldrive.connected.to.line.below")
                                }
                                .buttonStyle(.plain)

                                Spacer()

                                Button {
                                    model.deleteProfile(profile)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .help("Delete profile")
                            }
                        }
                    }
                }

                Section("Queues") {
                    ForEach(model.queues) { queue in
                        QueueSidebarRow(queue: queue)
                            .tag(queue.name)
                            .listRowInsets(EdgeInsets(top: 7, leading: 10, bottom: 7, trailing: 10))
                            .onTapGesture {
                                model.selectQueue(queue)
                            }
                    }
                }
            }

            Divider()

            HStack {
                StatusDot(color: model.isConnected ? .green : .secondary)
                Text(model.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(12)
        }
    }

    private var connectionForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Connections", systemImage: "server.rack")
                    .font(.headline)
                Spacer()
            }

            TextField("Redis URL", text: $model.redisURL)
                .textFieldStyle(.roundedBorder)
                .font(.callout.monospaced())

            HStack {
                TextField("Prefix", text: $model.prefix)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
                    .frame(width: 82)

                Spacer()

                Button {
                    model.saveCurrentProfile()
                } label: {
                    Label("Save", systemImage: "key")
                }
                .labelStyle(.iconOnly)
                .help("Save connection")

                Button {
                    Task {
                        if model.isConnected {
                            await model.disconnect()
                        } else {
                            await model.connect()
                        }
                    }
                } label: {
                    Label(model.isConnected ? "Disconnect" : "Connect", systemImage: model.isConnected ? "bolt.slash" : "bolt")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
        }
    }

    private var selectedQueueBinding: Binding<String?> {
        Binding(
            get: { model.selectedQueue?.name },
            set: { name in
                guard let name, let queue = model.queues.first(where: { $0.name == name }) else { return }
                model.selectQueue(queue)
            }
        )
    }
}

private struct QueueSidebarRow: View {
    let queue: QueueSummary

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            QueueHealthIcon(color: color, icon: icon)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 6) {
                Text(queue.name.titleCasedQueueName)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(queue.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    if queue.counts.active > 0 {
                        QueueMiniCount(value: queue.counts.active, label: "active", color: .blue)
                    }
                    if queue.counts.waiting > 0 {
                        QueueMiniCount(value: queue.counts.waiting, label: "waiting", color: .teal)
                    }
                    if queue.counts.failed > 0 {
                        QueueMiniCount(value: queue.counts.failed, label: "failed", color: .red)
                    }
                    if queue.counts.active == 0, queue.counts.waiting == 0, queue.counts.failed == 0 {
                        QueueMiniCount(value: 0, label: "idle", color: .secondary)
                    }
                }
            }

            Spacer()
        }
        .padding(.vertical, 6)
    }

    private var color: Color {
        switch queue.health {
        case .healthy: .green
        case .busy: .blue
        case .warning: .orange
        case .failing: .red
        case .unknown: .secondary
        }
    }

    private var icon: String {
        switch queue.health {
        case .healthy: "waveform.path.ecg"
        case .busy: "speedometer"
        case .warning: "exclamationmark.triangle.fill"
        case .failing: "exclamationmark.triangle.fill"
        case .unknown: "questionmark"
        }
    }
}

private struct QueueHealthIcon: View {
    let color: Color
    let icon: String

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7)
                .fill(color.gradient)
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: 22, height: 22)
    }
}

private struct QueueMiniCount: View {
    let value: Int
    let label: String
    let color: Color

    var body: some View {
        Text(value > 0 ? "\(value) \(label)" : label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(value > 0 ? color : .secondary)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background((value > 0 ? color : Color.secondary).opacity(0.10), in: Capsule())
    }
}

struct StatusDot: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
    }
}

extension String {
    var titleCasedQueueName: String {
        split(separator: "-")
            .map { word in
                word.prefix(1).uppercased() + word.dropFirst()
            }
            .joined(separator: " ")
    }
}
