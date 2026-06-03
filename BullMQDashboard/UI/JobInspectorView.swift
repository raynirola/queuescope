import SwiftUI

struct JobInspectorView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedPanel: JobInspectorPanel = .details

    var body: some View {
        Group {
            if let detail = model.selectedJobDetail {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        header(detail)
                        Picker("Inspector panel", selection: $selectedPanel) {
                            ForEach(JobInspectorPanel.allCases) { panel in
                                Text(panel.title).tag(panel)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()

                        switch selectedPanel {
                        case .details:
                            detailRows(detail)
                            DisplaySection(title: "Payload", value: detail.data)
                            DisplaySection(title: "Options", value: detail.options)
                            DisplaySection(title: "Progress", value: detail.progress)
                            DisplaySection(title: "Return value", value: detail.returnValue)
                            if let failedReason = detail.failedReason, !failedReason.isEmpty {
                                TextBlockSection(title: "Failed reason", text: failedReason)
                            }
                            if !detail.stacktrace.isEmpty {
                                StackTraceSection(stacktrace: detail.stacktrace)
                                    .id(detail.id)
                            }
                        case .logs:
                            LogsPanel()
                        }
                    }
                    .padding(18)
                }
                .background(Color(nsColor: .windowBackgroundColor))
                .onChange(of: selectedPanel) { _, panel in
                    if panel == .details {
                        model.stopSelectedJobLogStreaming()
                    }
                }
                .onChange(of: detail.id) { _, _ in
                    selectedPanel = .details
                    model.stopSelectedJobLogStreaming()
                }
            } else {
                EmptyView()
            }
        }
    }

    private func header(_ detail: JobDetail) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(detail.id)
                    .font(.title3.monospaced().weight(.semibold))
                    .lineLimit(2)
                Text("\(detail.queueName) · \(detail.state.displayName)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func detailRows(_ detail: JobDetail) -> some View {
        VStack(spacing: 0) {
            InspectorDetailRow(
                icon: "arrow.counterclockwise",
                color: .orange,
                title: "Attempts",
                value: "\(detail.attemptsMade)"
            )
            Divider().padding(.leading, 42)
            InspectorDetailRow(
                icon: "plus",
                color: .blue,
                title: "Created",
                value: format(detail.timestamp)
            )
            Divider().padding(.leading, 42)
            InspectorDetailRow(
                icon: "play.fill",
                color: .purple,
                title: "Processed",
                value: format(detail.processedOn)
            )
            Divider().padding(.leading, 42)
            InspectorDetailRow(
                icon: "checkmark",
                color: .green,
                title: "Finished",
                value: format(detail.finishedOn)
            )
        }
        .padding(.vertical, 6)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.92), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.06))
        }
    }

    private func format(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(date: .abbreviated, time: .standard)
    }
}

private enum JobInspectorPanel: String, CaseIterable, Identifiable {
    case details
    case logs

    var id: String { rawValue }

    var title: String {
        switch self {
        case .details: "Details"
        case .logs: "Logs"
        }
    }
}

private struct StackTraceSection: View {
    let stacktrace: [String]
    @State private var visibleCount = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Stack trace")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if stacktrace.count > visibleCount {
                    Text("\(visibleCount) of \(stacktrace.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            ScrollView(.horizontal) {
                Text(visibleStacktrace.joined(separator: "\n\n"))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.88), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.primary.opacity(0.06))
            }

            if stacktrace.count > visibleCount {
                Button {
                    visibleCount = min(visibleCount + 5, stacktrace.count)
                } label: {
                    Text("Load more")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private var visibleStacktrace: [String] {
        Array(stacktrace.prefix(visibleCount))
    }
}

private struct LogsPanel: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Logs")
                    .font(.subheadline.weight(.semibold))
                if model.isStreamingSelectedJobLogs {
                    HStack(spacing: 5) {
                        ProgressView()
                            .controlSize(.mini)
                        Text("Streaming")
                            .font(.caption.weight(.medium))
                    }
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Text(countText(model.selectedJobLogs))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if model.selectedJobLogs.entries.first?.id ?? 1 > 1 {
                Button {
                    model.loadOlderSelectedJobLogs()
                } label: {
                    HStack(spacing: 6) {
                        if model.isLoadingSelectedJobLogs {
                            ProgressView()
                                .controlSize(.mini)
                        }
                        Text("Load older")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.isLoadingSelectedJobLogs)
            }

            if model.selectedJobLogs.entries.isEmpty {
                Text("No logs recorded for this run.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.88), in: RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.primary.opacity(0.06))
                    }
            } else {
                ScrollView(.horizontal) {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(model.selectedJobLogs.entries) { entry in
                            HStack(alignment: .top, spacing: 10) {
                                Text("\(entry.id)")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 34, alignment: .trailing)
                                Text(entry.text)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(10)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.88), in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.primary.opacity(0.06))
                }
            }
        }
        .onAppear {
            model.showSelectedJobLogs()
        }
        .onDisappear {
            model.stopSelectedJobLogStreaming()
        }
    }

    private func countText(_ logs: JobLogs) -> String {
        if logs.isTruncated {
            return "Showing \(logs.entries.count) of \(logs.total)"
        }
        return "\(logs.total) lines"
    }
}

private struct InspectorDetailRow: View {
    let icon: String
    let color: Color
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(color.gradient)
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 24, height: 24)

            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)

            Spacer(minLength: 12)

            Text(value)
                .font(.callout.weight(.medium))
                .foregroundStyle(value == "—" ? .secondary : .primary)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct DisplaySection: View {
    let title: String
    let value: DisplayValue

    var body: some View {
        if !value.text.isEmpty {
            JSONBlockSection(title: title, value: value)
        }
    }
}

private struct TextBlockSection: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            ScrollView(.horizontal) {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.88), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.primary.opacity(0.06))
            }
        }
    }
}

private struct JSONBlockSection: View {
    let title: String
    let value: DisplayValue

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }

            ScrollView(.horizontal) {
                contentText
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.primary.opacity(0.08))
            }
        }
    }

    @ViewBuilder
    private var contentText: some View {
        switch value {
        case .json(let text):
            Text(JSONSyntaxHighlighter.highlight(text))
        case .raw(let text):
            Text(text)
        case .empty:
            EmptyView()
        }
    }
}
