import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var model: AppModel
    @State private var queueSearch = ""
    let showConnectionManager: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            sidebarHeader
                .padding(.horizontal, 18)
                .frame(height: 88)

            Divider()

            queueList
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var queueList: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SidebarSectionHeader(title: "Queues")
                        .padding(.horizontal, 18)
                        .padding(.top, 12)
                        .padding(.bottom, 8)

                    if filteredQueues.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("No queues found")
                                .font(.callout.weight(.medium))
                            Text("Try another queue name.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                    } else {
                        ForEach(filteredQueues) { queue in
                            QueueSidebarRow(
                                queue: queue,
                                isSelected: model.selectedQueue?.name == queue.name
                            )
                                .contentShape(RoundedRectangle(cornerRadius: 10))
                                .onTapGesture {
                                    model.selectQueue(queue)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 3)
                        }
                    }
                }
                .padding(.bottom, 74)
            }
            .background(Color(nsColor: .windowBackgroundColor))

            QueueSearchBar(text: $queueSearch)
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
        }
    }

    private var sidebarHeader: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Button(action: showConnectionManager) {
                    Image(systemName: "externaldrive.connected.to.line.below")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                }
                .buttonStyle(.plain)
                .help("Manage Redis connections")

                Text(connectionTitle)
                    .font(.headline)
            }

            HStack(spacing: 6) {
                StatusDot(color: model.isConnected ? .green : .secondary)
                Text(connectionLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
            }
        }
    }

    private var connectionLabel: String {
        model.isConnected ? "\(model.prefix) · \(model.redisURL.redactedRedisDisplay)" : "Open Connections to connect"
    }

    private var connectionTitle: String {
        model.isConnected ? model.connectionProfileName : "No connection"
    }

    private var filteredQueues: [QueueSummary] {
        let query = queueSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.queues }
        return model.queues.filter { queue in
            queue.name.localizedCaseInsensitiveContains(query) ||
                queue.name.titleCasedQueueName.localizedCaseInsensitiveContains(query)
        }
    }
}

private struct QueueSearchBar: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            TextField("Search queues", text: $text)
                .textFieldStyle(.plain)
                .font(.callout)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(0.10))
        }
        .shadow(color: .black.opacity(0.10), radius: 14, x: 0, y: 8)
    }
}

struct ConnectionManagerView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    private let profileTags = ["local", "production", "staging", "testing", "preview"]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            HStack(alignment: .top, spacing: 0) {
                connectionEditor
                    .frame(width: 330)
                    .padding(16)

                Divider()

                savedProfiles
                    .frame(width: 300)
                    .padding(16)
            }

            Divider()

            footer
        }
        .frame(width: 695, height: 520)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.blue.opacity(0.14))
                Image(systemName: "server.rack")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.blue)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 3) {
                Text("Connection Manager")
                    .font(.headline)
                Text("Connect to Redis and manage saved BullMQ profiles.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.secondary)
            .help("Close")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var connectionEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Current connection")
                    .font(.headline)
                Text(model.isConnected ? model.statusMessage : "Enter a Redis URL or choose a saved profile.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Name")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                TextField("Local Redis", text: $model.connectionProfileName)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Tag")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Picker("Tag", selection: $model.connectionProfileTag) {
                    ForEach(profileTags, id: \.self) { tag in
                        Text(tag.titleCasedQueueName).tag(tag)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Redis URL")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                TextField("redis://127.0.0.1:6379", text: $model.redisURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
            }

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.top, 1)
                Text("Passwords stay in macOS Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .background(.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("BullMQ prefix")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    TextField("bull", text: $model.prefix)
                        .textFieldStyle(.roundedBorder)
                        .font(.callout.monospaced())
                        .frame(width: 120)
                }

                Spacer()
            }

            HStack(spacing: 10) {
                Button {
                    model.saveCurrentProfile()
                } label: {
                    Label("Save", systemImage: "key")
                }
                .help("Save profile and store the full URL securely in Keychain")

                Button {
                    Task {
                        if model.isConnected {
                            await model.disconnect()
                        } else {
                            await model.connect()
                            if model.isConnected {
                                dismiss()
                            }
                        }
                    }
                } label: {
                    Label(model.isConnected ? "Disconnect" : "Connect", systemImage: model.isConnected ? "bolt.slash" : "bolt")
                }
                .buttonStyle(.borderedProminent)
            }

            Spacer()
        }
    }

    private var savedProfiles: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Saved profiles")
                    .font(.headline)
                Spacer()
                Text(model.profiles.count.formatted())
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if model.profiles.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.secondary.opacity(0.10))
                        Image(systemName: "externaldrive.badge.plus")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 34, height: 34)

                    Text("No saved profiles")
                        .font(.callout.weight(.semibold))
                    Text("Save the current Redis URL to reuse it later.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.primary.opacity(0.06))
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(model.profiles) { profile in
                            ProfileRow(profile: profile)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            StatusDot(color: model.isConnected ? .green : .secondary)
            Text(model.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            if model.isLoading {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

private struct ProfileRow: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let profile: RedisConnectionProfile

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(.blue.opacity(0.12))
                Image(systemName: "externaldrive.connected.to.line.below")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.blue)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(profile.name)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text(profile.tag)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(tagColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(tagColor.opacity(0.10), in: Capsule())
                }
                Text("\(profile.prefix) · \(profile.urlWithoutSecret)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Image(systemName: "bolt.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.blue)

            Button {
                model.deleteProfile(profile)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Delete")
        }
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture {
            connect()
        }
        .padding(10)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.78), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.06))
        }
    }

    private func connect() {
        Task {
            await model.connect(profile: profile)
            if model.isConnected {
                dismiss()
            }
        }
    }

    private var tagColor: Color {
        switch profile.tag {
        case "production": .red
        case "staging": .orange
        case "testing": .purple
        case "preview": .blue
        default: .green
        }
    }
}

private struct SidebarSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct QueueSidebarRow: View {
    let queue: QueueSummary
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            QueueHealthIcon(color: color, icon: icon)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 6) {
                Text(queue.name.titleCasedQueueName)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(isSelected ? .white : .primary)
                    .lineLimit(1)
                Text(queue.name)
                    .font(.caption)
                    .foregroundStyle(isSelected ? .white.opacity(0.72) : .secondary)
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
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.accentColor)
            }
        }
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

    var redactedRedisDisplay: String {
        guard let atIndex = firstIndex(of: "@") else {
            return self
        }
        let schemeEnd = range(of: "://")?.upperBound ?? startIndex
        return String(self[..<schemeEnd]) + "••••@" + String(self[index(after: atIndex)...])
    }
}
