import AppKit
import SwiftUI

struct JobInspectorView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if let detail = model.selectedJobDetail {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 14) {
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
                        LogsPanel()
                            .id(detail.id)
                    }
                    .padding(18)
                }
                .background(Color(nsColor: .windowBackgroundColor))
                .onChange(of: detail.id) { _, _ in
                    model.stopSelectedJobLogStreaming()
                }
            } else {
                EmptyView()
            }
        }
    }

    private func detailRows(_ detail: JobDetail) -> some View {
        VStack(spacing: 0) {
            InspectorDetailRow(
                icon: "number",
                color: .gray,
                title: "Job ID",
                value: detail.id,
                lineLimit: 1
            )
            Divider().padding(.leading, 42)
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

            InspectorCodeBlock(title: "Stack trace", copyText: stacktrace.joined(separator: "\n\n"), maxHeight: 126) {
                Text(visibleStacktrace.joined(separator: "\n\n"))
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
                InspectorLogsBlock(entries: model.selectedJobLogs.entries, copyText: logCopyText)
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

    private var logCopyText: String {
        model.selectedJobLogs.entries
            .map { "\($0.id) \($0.text)" }
            .joined(separator: "\n")
    }
}

private struct InspectorLogsBlock: View {
    let entries: [JobLogEntry]
    let copyText: String
    @State private var didCopy = false
    @State private var isFullViewPresented = false
    @State private var fullViewSize = CGSize(width: 760, height: 560)

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(entries) { entry in
                        InspectorLogRow(entry: entry, isCompact: true)
                    }
                }
                .padding(.trailing, 60)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .sectionScrollBounceDisabled()
            .frame(maxHeight: 260)

            HStack(spacing: 5) {
                Button {
                    openFullView()
                } label: {
                    InspectorCodeActionIcon(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary.opacity(0.82))
                .help("Open full view")
                .disabled(entries.isEmpty)

                Button {
                    copyToClipboard()
                } label: {
                    InspectorCodeActionIcon(systemName: didCopy ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.plain)
                .foregroundStyle(didCopy ? .green : .primary.opacity(0.82))
                .help(didCopy ? "Copied" : "Copy to clipboard")
                .disabled(copyText.isEmpty)
            }
            .padding(6)
        }
        .padding(10)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.9), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.07))
        }
        .sheet(isPresented: $isFullViewPresented) {
            InspectorLogsFullView(entries: entries)
                .frame(width: fullViewSize.width, height: fullViewSize.height)
        }
    }

    private func copyToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copyText, forType: .string)
        didCopy = true

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            didCopy = false
        }
    }

    private func openFullView() {
        if let contentSize = appWindowContentSize() {
            fullViewSize = inspectorFullViewSize(for: contentSize)
        }
        isFullViewPresented = true
    }
}

private struct InspectorLogsFullView: View {
    let entries: [JobLogEntry]
    @Environment(\.dismiss) private var dismiss
    @State private var expandedEntryIDs = Set<Int>()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Logs")
                    .font(.headline)
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }

            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(entries) { entry in
                        InspectorFullLogCard(
                            entry: entry,
                            isExpanded: expandedEntryIDs.contains(entry.id)
                        ) {
                            toggleEntry(entry.id)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .padding(18)
    }

    private func toggleEntry(_ id: Int) {
        if expandedEntryIDs.contains(id) {
            expandedEntryIDs.remove(id)
        } else {
            expandedEntryIDs.insert(id)
        }
    }
}

private struct InspectorFullLogCard: View {
    let entry: JobLogEntry
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        let content = LogEntryContent(entry.text)

        VStack(alignment: .leading, spacing: isExpanded ? 8 : 0) {
            Button {
                onToggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)

                    Text("\(entry.id)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, alignment: .trailing)

                    Text(content.message)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded, !content.detailText.isEmpty {
                ScrollView(.horizontal, showsIndicators: true) {
                    Text(JSONSyntaxHighlighter.highlight(content.detailText))
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(.leading, 44)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(Color.primary.opacity(isExpanded ? 0.13 : 0.07))
        }
    }
}

private struct InspectorLogRow: View {
    let entry: JobLogEntry
    let isCompact: Bool

    var body: some View {
        let content = LogEntryContent(entry.text)

        HStack(alignment: .top, spacing: 10) {
            Text("\(entry.id)")
                .font(.system(size: isCompact ? 10 : 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: isCompact ? 34 : 42, alignment: .trailing)

            VStack(alignment: .leading, spacing: isCompact ? 3 : 8) {
                Text(content.message)
                    .font(.system(size: isCompact ? 10 : 12, weight: .medium, design: .monospaced))
                    .lineLimit(isCompact ? 1 : nil)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if !isCompact, !content.detailText.isEmpty {
                    Text(content.detailText)
                        .font(.system(size: isCompact ? 9 : 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

private struct LogEntryContent {
    let message: String
    let detailText: String

    init(_ text: String) {
        guard
            let data = text.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            message = text
            detailText = ""
            return
        }

        message = object["message"] as? String ?? text

        var details = object
        details.removeValue(forKey: "message")
        detailText = Self.prettyDetailText(details)
    }

    private static func prettyDetailText(_ details: [String: Any]) -> String {
        guard !details.isEmpty else { return "" }
        guard
            JSONSerialization.isValidJSONObject(details),
            let data = try? JSONSerialization.data(withJSONObject: details, options: [.prettyPrinted, .sortedKeys]),
            let text = String(data: data, encoding: .utf8)
        else {
            return details
                .map { "\($0.key): \($0.value)" }
                .sorted()
                .joined(separator: "\n")
        }
        return text
    }
}

private struct InspectorDetailRow: View {
    let icon: String
    let color: Color
    let title: String
    let value: String
    var lineLimit = 2

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
                .lineLimit(lineLimit)
                .truncationMode(.middle)
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
            InspectorSingleLineBlock(copyText: text) {
                Text(text)
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
    }
}

private struct JSONBlockSection: View {
    let title: String
    let value: DisplayValue

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            InspectorJSONBlock(title: title, value: value)
        }
    }
}

private struct InspectorJSONBlock: View {
    let title: String
    let value: DisplayValue
    @State private var contentHeight: CGFloat = 0
    @State private var didCopy = false
    @State private var isFullViewPresented = false
    @State private var fullViewSize = CGSize(width: 760, height: 560)

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ScrollView(.vertical, showsIndicators: false) {
                ScrollView(.horizontal, showsIndicators: false) {
                    contentText(size: 10)
                        .textSelection(.enabled)
                        .padding(.trailing, 60)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background {
                            GeometryReader { proxy in
                                Color.clear
                                    .preference(key: CodeBlockHeightPreferenceKey.self, value: proxy.size.height)
                            }
                        }
                }
                .sectionScrollBounceDisabled()
            }
            .sectionScrollBounceDisabled()
            .frame(height: blockHeight)
            .onPreferenceChange(CodeBlockHeightPreferenceKey.self) { height in
                contentHeight = height
            }

            HStack(spacing: 5) {
                Button {
                    openFullView()
                } label: {
                    InspectorCodeActionIcon(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary.opacity(0.82))
                .help("Open full view")
                .disabled(value.text.isEmpty)

                Button {
                    copyToClipboard()
                } label: {
                    InspectorCodeActionIcon(systemName: didCopy ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.plain)
                .foregroundStyle(didCopy ? .green : .primary.opacity(0.82))
                .help(didCopy ? "Copied" : "Copy to clipboard")
                .disabled(value.text.isEmpty)
            }
            .padding(6)
        }
        .padding(10)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.9), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.07))
        }
        .sheet(isPresented: $isFullViewPresented) {
            InspectorJSONFullView(title: title, value: value)
                .frame(width: fullViewSize.width, height: fullViewSize.height)
        }
    }

    private var blockHeight: CGFloat? {
        guard contentHeight > 0 else { return nil }
        return min(contentHeight, 240)
    }

    @ViewBuilder
    private func contentText(size: CGFloat) -> some View {
        switch value {
        case .json(let text):
            Text(JSONSyntaxHighlighter.highlight(text))
                .font(.system(size: size, weight: .regular, design: .monospaced))
        case .raw(let text):
            Text(text)
                .font(.system(size: size, weight: .regular, design: .monospaced))
        case .empty:
            EmptyView()
        }
    }

    private func copyToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value.text, forType: .string)
        didCopy = true

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            didCopy = false
        }
    }

    private func openFullView() {
        if let contentSize = appWindowContentSize() {
            fullViewSize = inspectorFullViewSize(for: contentSize)
        }
        isFullViewPresented = true
    }
}

private struct InspectorJSONFullView: View {
    let title: String
    let value: DisplayValue
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }

            ScrollView(.vertical, showsIndicators: true) {
                ScrollView(.horizontal, showsIndicators: true) {
                    contentText
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.primary.opacity(0.08))
            }
        }
        .padding(18)
    }

    @ViewBuilder
    private var contentText: some View {
        switch value {
        case .json(let text):
            Text(JSONSyntaxHighlighter.highlight(text))
                .font(.system(size: 11, weight: .regular, design: .monospaced))
        case .raw(let text):
            Text(text)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
        case .empty:
            EmptyView()
        }
    }
}

private struct InspectorCodeBlock<Content: View>: View {
    let title: String
    let copyText: String
    let maxHeight: CGFloat
    let content: Content
    @State private var contentHeight: CGFloat = 0
    @State private var didCopy = false
    @State private var isFullViewPresented = false
    @State private var fullViewSize = CGSize(width: 760, height: 560)

    init(title: String, copyText: String, maxHeight: CGFloat = 240, @ViewBuilder content: () -> Content) {
        self.title = title
        self.copyText = copyText
        self.maxHeight = maxHeight
        self.content = content()
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ScrollView(.vertical, showsIndicators: false) {
                ScrollView(.horizontal, showsIndicators: false) {
                    content
                        .padding(.trailing, 60)
                        .background {
                            GeometryReader { proxy in
                                Color.clear
                                    .preference(key: CodeBlockHeightPreferenceKey.self, value: proxy.size.height)
                            }
                        }
                }
                .sectionScrollBounceDisabled()
            }
            .sectionScrollBounceDisabled()
            .frame(height: blockHeight)
            .onPreferenceChange(CodeBlockHeightPreferenceKey.self) { height in
                contentHeight = height
            }

            HStack(spacing: 5) {
                Button {
                    openFullView()
                } label: {
                    InspectorCodeActionIcon(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary.opacity(0.82))
                .help("Open full view")
                .disabled(copyText.isEmpty)

                Button {
                    copyToClipboard()
                } label: {
                    InspectorCodeActionIcon(systemName: didCopy ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.plain)
                .foregroundStyle(didCopy ? .green : .primary.opacity(0.82))
                .help(didCopy ? "Copied" : "Copy to clipboard")
                .disabled(copyText.isEmpty)
            }
            .padding(6)
        }
        .padding(10)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.9), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.07))
        }
        .sheet(isPresented: $isFullViewPresented) {
            InspectorFullCodeView(title: title, text: copyText)
                .frame(width: fullViewSize.width, height: fullViewSize.height)
        }
    }

    private var blockHeight: CGFloat? {
        guard contentHeight > 0 else { return nil }
        return min(contentHeight, maxHeight)
    }

    private func copyToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copyText, forType: .string)
        didCopy = true

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            didCopy = false
        }
    }

    private func openFullView() {
        if let contentSize = appWindowContentSize() {
            fullViewSize = inspectorFullViewSize(for: contentSize)
        }
        isFullViewPresented = true
    }
}

@MainActor
private func appWindowContentSize() -> CGSize? {
    let window = NSApp.mainWindow ?? NSApp.keyWindow
    return window?.contentView?.bounds.size
}

private func inspectorFullViewSize(for contentSize: CGSize) -> CGSize {
    CGSize(
        width: max(620, contentSize.width * 0.8),
        height: max(420, contentSize.height * 0.76)
    )
}

private struct InspectorCodeActionIcon: View {
    let systemName: String

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
        }
        .frame(width: 24, height: 24)
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.primary.opacity(0.14))
        }
        .contentShape(Rectangle())
    }
}

private struct InspectorFullCodeView: View {
    let title: String
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }

            ScrollView(.vertical, showsIndicators: true) {
                ScrollView(.horizontal, showsIndicators: true) {
                    Text(text)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.primary.opacity(0.08))
            }
        }
        .padding(18)
    }
}

private struct InspectorSingleLineBlock<Content: View>: View {
    let copyText: String
    let content: Content
    @State private var didCopy = false

    init(copyText: String, @ViewBuilder content: () -> Content) {
        self.copyText = copyText
        self.content = content()
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            ScrollView(.horizontal, showsIndicators: false) {
                content
                    .padding(.trailing, 28)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .sectionScrollBounceDisabled()

            Button {
                copyToClipboard()
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
                    Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .semibold))
                }
                .frame(width: 24, height: 24)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.primary.opacity(0.14))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(didCopy ? .green : .primary.opacity(0.82))
            .help(didCopy ? "Copied" : "Copy to clipboard")
            .disabled(copyText.isEmpty)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.9), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.07))
        }
    }

    private func copyToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copyText, forType: .string)
        didCopy = true

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            didCopy = false
        }
    }
}

private extension View {
    func sectionScrollBounceDisabled() -> some View {
        background(SectionScrollBounceDisabler())
    }
}

private struct SectionScrollBounceDisabler: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            disableBounce(from: view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            disableBounce(from: nsView)
        }
    }

    private func disableBounce(from view: NSView) {
        var current = view.superview
        while let candidate = current {
            if let scrollView = candidate as? NSScrollView {
                scrollView.verticalScrollElasticity = .none
                scrollView.horizontalScrollElasticity = .none
                return
            }
            current = candidate.superview
        }
    }
}

private struct CodeBlockHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
