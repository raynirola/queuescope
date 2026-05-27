import Charts
import SwiftUI

enum QueueWorkspaceView: String, CaseIterable, Identifiable {
    case overview
    case runs
    case flowGraph
    case schedulers
    case workers
    case metrics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .runs: "Runs"
        case .flowGraph: "Flow graph"
        case .schedulers: "Schedulers"
        case .workers: "Workers"
        case .metrics: "Metrics"
        }
    }

    var icon: String {
        switch self {
        case .overview: "rectangle.3.group"
        case .runs: "list.bullet.rectangle"
        case .flowGraph: "point.3.connected.trianglepath.dotted"
        case .schedulers: "calendar.badge.clock"
        case .workers: "person.2.wave.2"
        case .metrics: "chart.xyaxis.line"
        }
    }

    var isComingSoon: Bool {
        self == .flowGraph
    }
}

struct QueueDashboardView: View {
    @EnvironmentObject private var model: AppModel
    let selectedView: QueueWorkspaceView

    var body: some View {
        Group {
            if let queue = model.selectedQueue {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header(queue)
                        content(for: queue)
                    }
                    .padding(.horizontal, 26)
                    .padding(.vertical, 24)
                }
                .background(Color(nsColor: .windowBackgroundColor))
            } else {
                emptyState
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.secondary.opacity(0.08))
                    .frame(width: 58, height: 58)

                if model.isLoading {
                    ProgressView()
                        .controlSize(.regular)
                } else {
                    Image(systemName: model.isConnected ? "server.rack" : "externaldrive.badge.plus")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 6) {
                Text(emptyStateTitle)
                    .font(.title2.weight(.semibold))
                Text(emptyStateDescription)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var emptyStateTitle: String {
        if model.isLoading { return "Loading Redis" }
        return model.isConnected ? "Select a queue" : "Connect to Redis"
    }

    private var emptyStateDescription: String {
        if model.isLoading { return model.statusMessage }
        return model.isConnected ? "Queue details will appear here once discovery finds a queue." : "Enter a Redis URL to discover BullMQ queues."
    }

    @ViewBuilder
    private func content(for queue: QueueSummary) -> some View {
        switch selectedView {
        case .overview:
            statusCards(queue)
            observabilityGrid(queue)
        case .runs:
            statusCards(queue)
            JobTableView()
        case .flowGraph:
            FlowGraphComingSoonView()
        case .schedulers:
            SchedulersPanel(style: .detailed)
        case .workers:
            WorkersPanel(style: .detailed)
        case .metrics:
            MetricsPanel(queueName: queue.name)
        }
    }

    private func header(_ queue: QueueSummary) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(selectedView.title)
                    .font(.system(size: 28, weight: .semibold, design: .default))
                    .tracking(-0.2)
                    .lineLimit(1)
                Text("\(queue.name.titleCasedQueueName) · \(queue.prefix):\(queue.name) · \(queue.health.label)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            HealthBadge(health: queue.health)
        }
        .padding(.top, 4)
    }

    private func statusCards(_ queue: QueueSummary) -> some View {
        MetricsGrid(
            queue: queue,
            selectedState: model.selectedState,
            selectState: model.selectState
        )
    }

    @ViewBuilder
    private func observabilityGrid(_ queue: QueueSummary) -> some View {
        let hasTrendData = model.snapshots.contains { $0.queueName == queue.name }
        let hasWorkers = !model.workers.isEmpty
        let hasFailures = model.jobs.contains { $0.state == .failed }
        let hasSchedulers = !model.schedulers.isEmpty

        VStack(spacing: 18) {
            if hasTrendData {
                MetricsPanel(queueName: queue.name)
            }

            if hasWorkers {
                WorkersPanel()
            }

            if hasFailures {
                FailedTriagePanel()
            }

            if hasSchedulers {
                SchedulersPanel()
            }
        }
    }

}

private struct FlowGraphComingSoonView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Flow graph coming soon", systemImage: "point.3.connected.trianglepath.dotted")
        } description: {
            Text("Parent and child jobs will be visualized here once FlowProducer support lands.")
        }
        .frame(maxWidth: .infinity, minHeight: 340)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.88), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.055))
        }
    }
}

private struct MetricsGrid: View {
    let queue: QueueSummary
    let selectedState: BullMQState?
    let selectState: (BullMQState) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            metricRow(BullMQState.allCases)
            VStack(spacing: 10) {
                metricRow(Array(BullMQState.allCases.prefix(4)))
                metricRow(Array(BullMQState.allCases.suffix(4)))
            }
        }
    }

    private func metricRow(_ states: [BullMQState]) -> some View {
        HStack(spacing: 10) {
            ForEach(states) { state in
                CompactMetric(
                    title: state.displayName,
                    value: queue.counts.count(for: state),
                    state: state,
                    isSelected: selectedState == state,
                    action: { selectState(state) }
                )
            }
        }
    }
}

private struct CompactMetric: View {
    let title: String
    let value: Int
    let state: BullMQState
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Text(value.formatted())
                    .font(.system(size: 24, weight: .semibold, design: .default).monospacedDigit())
                    .foregroundStyle(value > 0 ? .primary : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .padding(.trailing, 92)

                labelPill
            }
            .frame(minWidth: 150, maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(cardBackground, in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(cardBorder)
            }
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private var cardBorder: Color {
        if isSelected {
            return color.opacity(0.48)
        }
        return value > 0 ? color.opacity(0.18) : Color.primary.opacity(0.06)
    }

    private var color: Color {
        switch state {
        case .failed: .red
        case .active: .blue
        case .completed: .green
        case .delayed, .waitingChildren: .orange
        case .prioritized: .purple
        case .paused: .gray
        case .waiting: .teal
        }
    }

    private var labelPill: some View {
        Text(signal)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.10), in: Capsule())
    }

    private var signal: String {
        switch state {
        case .waiting: "queued"
        case .active: "active"
        case .delayed: "scheduled"
        case .prioritized: "priority"
        case .completed: "done"
        case .failed: "needs triage"
        case .paused: "paused"
        case .waitingChildren: "blocked"
        }
    }

    private var cardBackground: some ShapeStyle {
        AnyShapeStyle(Color(nsColor: .textBackgroundColor).opacity(0.92))
    }
}

private struct HealthBadge: View {
    let health: QueueHealth

    var body: some View {
        Label(health.label, systemImage: icon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(color.opacity(0.12), in: Capsule())
    }

    private var icon: String {
        switch health {
        case .healthy: "checkmark.circle.fill"
        case .busy: "speedometer"
        case .warning: "exclamationmark.triangle.fill"
        case .failing: "xmark.octagon.fill"
        case .unknown: "questionmark.circle"
        }
    }

    private var color: Color {
        switch health {
        case .healthy: .green
        case .busy: .blue
        case .warning: .orange
        case .failing: .red
        case .unknown: .secondary
        }
    }
}

private struct MetricsPanel: View {
    @EnvironmentObject private var model: AppModel
    let queueName: String

    var body: some View {
        let snapshots = model.snapshots
                .filter { $0.queueName == queueName }
                .sorted { $0.capturedAt < $1.capturedAt }
                .suffix(40)
        let points = throughputPoints(Array(snapshots))

        VStack(alignment: .leading, spacing: 12) {
            header(points: points)
            if snapshots.isEmpty {
                SectionEmptyState(
                    icon: "chart.line.uptrend.xyaxis",
                    message: "Refresh this queue to record local metric snapshots."
                )
            } else {
                throughputChart(points)
            }
        }
        .panelStyle(minHeight: 220)
    }

    private func header(points: [ThroughputPoint]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.green.opacity(0.12))
                    Image(systemName: "gauge.with.dots.needle.67percent")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.green)
                }
                .frame(width: 22, height: 22)

                Text("Throughput")
                    .font(.subheadline.weight(.semibold))

                Spacer()

                Text("jobs/min")
                    .font(.caption.monospaced().weight(.medium))
                    .tracking(1.8)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                ThroughputLegend(color: .green, title: "Completed")
                ThroughputLegend(color: .red, title: "Failed")
                Spacer()
                Text("\(points.count.formatted()) samples")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func throughputChart(_ points: [ThroughputPoint]) -> some View {
        Chart(points) { point in
            AreaMark(
                x: .value("Time", point.date),
                yStart: .value("Baseline", 0),
                yEnd: .value("Completed", point.completedPerMinute)
            )
            .interpolationMethod(.catmullRom)
            .foregroundStyle(
                LinearGradient(
                    colors: [.green.opacity(0.22), .green.opacity(0.015)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )

            LineMark(
                x: .value("Time", point.date),
                y: .value("Completed", point.completedPerMinute)
            )
            .interpolationMethod(.catmullRom)
            .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
            .foregroundStyle(.green)

            LineMark(
                x: .value("Time", point.date),
                y: .value("Failed", point.failedPerMinute)
            )
            .interpolationMethod(.catmullRom)
            .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            .foregroundStyle(.red)

            if points.count < 3 {
                PointMark(
                    x: .value("Time", point.date),
                    y: .value("Completed", point.completedPerMinute)
                )
                .foregroundStyle(.green)
                PointMark(
                    x: .value("Time", point.date),
                    y: .value("Failed", point.failedPerMinute)
                )
                .foregroundStyle(.red)
            }
        }
        .chartYScale(domain: 0...throughputUpperBound(points))
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.6))
                    .foregroundStyle(Color.primary.opacity(0.08))
                AxisValueLabel()
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(height: 150)
        .padding(.top, 2)
    }

    private func throughputPoints(_ snapshots: [QueueMetricSnapshot]) -> [ThroughputPoint] {
        guard let first = snapshots.first else { return [] }
        var points = [
            ThroughputPoint(
                date: first.capturedAt,
                completedPerMinute: 0,
                failedPerMinute: 0
            )
        ]

        for index in snapshots.indices.dropFirst() {
            let current = snapshots[index]
            let previous = snapshots[snapshots.index(before: index)]
            let minutes = max(current.capturedAt.timeIntervalSince(previous.capturedAt) / 60, 1.0 / 60)
            let completedDelta = max(0, current.counts.completed - previous.counts.completed)
            let failedDelta = max(0, current.counts.failed - previous.counts.failed)
            points.append(
                ThroughputPoint(
                    date: current.capturedAt,
                    completedPerMinute: Double(completedDelta) / minutes,
                    failedPerMinute: Double(failedDelta) / minutes
                )
            )
        }

        return points
    }

    private func throughputUpperBound(_ points: [ThroughputPoint]) -> Double {
        let maxValue = points
            .map { max($0.completedPerMinute, $0.failedPerMinute) }
            .max() ?? 0
        return max(maxValue * 1.15, 1)
    }
}

private struct ThroughputPoint: Identifiable {
    let id = UUID()
    let date: Date
    let completedPerMinute: Double
    let failedPerMinute: Double
}

private struct ThroughputLegend: View {
    let color: Color
    let title: String

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 8, height: 8)
            Text(title)
                .font(.caption.monospaced().weight(.medium))
                .tracking(-0.2)
                .foregroundStyle(.secondary)
        }
    }
}

private struct WorkersPanel: View {
    @EnvironmentObject private var model: AppModel
    var style: WorkerPanelStyle = .compact

    var body: some View {
        if style == .detailed {
            detailedBody
        } else {
            compactBody
        }
    }

    private var compactBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if model.workers.isEmpty {
                SectionEmptyState(
                    icon: "person.2.slash",
                    message: "Worker metadata keys were not found for this queue."
                )
            } else {
                VStack(spacing: 8) {
                    ForEach(model.workers) { worker in
                        WorkerRow(worker: worker)
                    }
                }
            }
        }
        .panelStyle(minHeight: 220)
    }

    @ViewBuilder
    private var detailedBody: some View {
        if model.workers.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                header
                SectionEmptyState(
                    icon: "person.2.slash",
                    message: "Worker metadata keys were not found for this queue."
                )
            }
            .panelStyle(minHeight: 220)
        } else {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text(model.workers.count == 1 ? "1 worker" : "\(model.workers.count.formatted()) workers")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                }

                ForEach(model.workers) { worker in
                    WorkerDetailSection(worker: worker)
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.indigo.opacity(0.12))
                    Image(systemName: "person.2.wave.2")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.indigo)
                }
                .frame(width: 22, height: 22)

                Text("Workers")
                    .font(.subheadline.weight(.semibold))

                Spacer()

                Text(model.workers.count == 1 ? "1 worker" : "\(model.workers.count.formatted()) workers")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text("Processing presence and recent activity")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private enum WorkerPanelStyle {
    case compact
    case detailed
}

private struct WorkerRow: View {
    let worker: WorkerSummary

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(statusColor.opacity(0.14))
                Image(systemName: statusIcon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(statusColor)
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(worker.name.titleCasedQueueName)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)

                    Text(statusText)
                        .font(.caption2.monospaced().weight(.medium))
                        .tracking(-0.3)
                        .foregroundStyle(statusColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(statusColor.opacity(0.10), in: Capsule())
                }

                HStack(spacing: 8) {
                    if let activeJob = worker.raw["activeJobName"] ?? worker.raw["activeJobId"] {
                        Text(activeJob)
                            .lineLimit(1)
                    } else {
                        Text("No active job")
                    }

                    Text("·")
                        .foregroundStyle(.tertiary)

                    Text("heartbeat \(heartbeatText)")
                        .lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 10)

            HStack(spacing: 8) {
                metric("conc", worker.raw["concurrency"] ?? "—", color: .blue)
                metric("done", worker.raw["processed"] ?? "0", color: .green)
                metric("fail", worker.raw["failed"] ?? "0", color: .red)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.74), in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(statusColor.opacity(0.12))
        }
    }

    private func metric(_ label: String, _ value: String, color: Color) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(color)
                .lineLimit(1)
        }
        .frame(width: 38, alignment: .trailing)
    }

    private var statusText: String {
        (worker.raw["status"] ?? "unknown").lowercased()
    }

    private var statusColor: Color {
        switch statusText {
        case "processing", "active": .blue
        case "idle", "waiting": .green
        case "stalled", "unhealthy": .orange
        case "failed", "offline": .red
        default: .secondary
        }
    }

    private var statusIcon: String {
        switch statusText {
        case "processing", "active": "bolt.fill"
        case "idle", "waiting": "pause.fill"
        case "stalled", "unhealthy": "exclamationmark.triangle.fill"
        case "failed", "offline": "xmark"
        default: "questionmark"
        }
    }

    private var heartbeatText: String {
        guard let raw = worker.raw["lastHeartbeatAt"],
              let milliseconds = Double(raw) else {
            return "unknown"
        }

        let date = Date(timeIntervalSince1970: milliseconds / 1000)
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 {
            return "\(seconds)s ago"
        }
        if seconds < 3_600 {
            return "\(seconds / 60)m ago"
        }
        if seconds < 86_400 {
            return "\(seconds / 3_600)h ago"
        }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}

private struct WorkerDetailSection: View {
    let worker: WorkerSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(worker.name.titleCasedQueueName)
                    .font(.headline.weight(.semibold))
                    .lineLimit(1)

                Text(statusText)
                    .font(.caption.monospaced().weight(.medium))
                    .tracking(-0.3)
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(statusColor.opacity(0.10), in: Capsule())
            }

            VStack(spacing: 0) {
                WorkerDetailRow(icon: statusIcon, tint: statusColor, label: "Status", value: statusText)
                Divider().padding(.leading, 56)
                WorkerDetailRow(icon: "play.rectangle", tint: .blue, label: "Active job", value: activeJobText)
                Divider().padding(.leading, 56)
                WorkerDetailRow(icon: "waveform.path.ecg", tint: .green, label: "Heartbeat", value: heartbeatText)
                Divider().padding(.leading, 56)
                WorkerDetailRow(icon: "slider.horizontal.3", tint: .blue, label: "Concurrency", value: worker.raw["concurrency"] ?? "—")
                Divider().padding(.leading, 56)
                WorkerDetailRow(icon: "checkmark", tint: .green, label: "Processed", value: worker.raw["processed"] ?? "0")
                Divider().padding(.leading, 56)
                WorkerDetailRow(icon: "xmark", tint: .red, label: "Failed", value: worker.raw["failed"] ?? "0")
                Divider().padding(.leading, 56)
                WorkerDetailRow(icon: "number", tint: .gray, label: "Worker id", value: worker.id, isMonospaced: true)
            }
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.primary.opacity(0.06))
            }
        }
    }

    private var activeJobText: String {
        worker.raw["activeJobName"] ?? worker.raw["activeJobId"] ?? "No active job"
    }

    private var statusText: String {
        (worker.raw["status"] ?? "unknown").lowercased()
    }

    private var statusColor: Color {
        switch statusText {
        case "processing", "active": .blue
        case "idle", "waiting": .green
        case "stalled", "unhealthy": .orange
        case "failed", "offline": .red
        default: .secondary
        }
    }

    private var statusIcon: String {
        switch statusText {
        case "processing", "active": "bolt.fill"
        case "idle", "waiting": "pause.fill"
        case "stalled", "unhealthy": "exclamationmark.triangle.fill"
        case "failed", "offline": "xmark"
        default: "questionmark"
        }
    }

    private var heartbeatText: String {
        guard let raw = worker.raw["lastHeartbeatAt"],
              let milliseconds = Double(raw) else {
            return "unknown"
        }

        let date = Date(timeIntervalSince1970: milliseconds / 1000)
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 {
            return "\(seconds)s ago"
        }
        if seconds < 3_600 {
            return "\(seconds / 60)m ago"
        }
        if seconds < 86_400 {
            return "\(seconds / 3_600)h ago"
        }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}

private struct WorkerDetailRow: View {
    let icon: String
    let tint: Color
    let label: String
    let value: String
    var isMonospaced = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(tint.opacity(0.14))
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .frame(width: 32, height: 32)

            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 118, alignment: .leading)

            Text(value)
                .font(isMonospaced ? .callout.monospaced() : .callout)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

private struct FailedTriagePanel: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let failures = groupedFailures(model.jobs.filter { $0.state == .failed })

        VStack(alignment: .leading, spacing: 12) {
            header(total: failures.reduce(0) { $0 + $1.count })
            if failures.isEmpty {
                emptyState
            } else {
                VStack(spacing: 7) {
                    ForEach(Array(failures.prefix(4).enumerated()), id: \.element.reason) { index, group in
                        FailureTriageRow(
                            reason: group.reason,
                            count: group.count,
                            rank: index,
                            total: max(failures.first?.count ?? 1, 1)
                        )
                    }
                }
            }
        }
        .panelStyle(minHeight: 220)
    }

    private func header(total: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(.red.opacity(0.12))
                    Image(systemName: "exclamationmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.red)
                }
                .frame(width: 22, height: 22)

                Text("Top errors")
                    .font(.subheadline.weight(.semibold))

                Spacer()

                Text(total == 1 ? "1 event" : "\(total.formatted()) events")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text("Grouped by failure reason")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                Text("No failures in view")
                    .font(.callout.weight(.medium))
            }
            Text("Show all runs or select Failed to group recent errors by reason.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, 4)
    }

    private func groupedFailures(_ jobs: [JobSummary]) -> [(reason: String, count: Int)] {
        Dictionary(grouping: jobs) { job in
            normalizedReason(job.failedReason)
        }
        .map { ($0.key, $0.value.count) }
        .sorted {
            if $0.1 == $1.1 {
                return $0.0 < $1.0
            }
            return $0.1 > $1.1
        }
    }

    private func normalizedReason(_ reason: String?) -> String {
        guard let reason,
              let firstLine = reason.components(separatedBy: "\n").first?.trimmingCharacters(in: .whitespacesAndNewlines),
              !firstLine.isEmpty else {
            return "Unknown failure"
        }

        if let delimiter = firstLine.firstIndex(of: ":") {
            return String(firstLine[..<delimiter])
        }

        return firstLine
    }
}

private struct FailureTriageRow: View {
    let reason: String
    let count: Int
    let rank: Int
    let total: Int

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(reason)
                    .font(.callout.monospaced().weight(.medium))
                    .lineLimit(1)

                GeometryReader { proxy in
                    Capsule()
                        .fill(color.opacity(0.16))
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(color.opacity(0.72))
                                .frame(width: proxy.size.width * share)
                        }
                }
                .frame(height: 4)
            }

            Text(count.formatted())
                .font(.callout.monospacedDigit().weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 42, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(rowBackground, in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(color.opacity(rank == 0 ? 0.22 : 0.10))
        }
    }

    private var share: Double {
        min(1, Double(count) / Double(max(total, 1)))
    }

    private var color: Color {
        switch rank {
        case 0: .red
        case 1: .orange
        case 2: .pink
        default: .secondary
        }
    }

    private var rowBackground: Color {
        rank == 0 ? color.opacity(0.055) : Color(nsColor: .textBackgroundColor).opacity(0.74)
    }
}

private struct SchedulersPanel: View {
    @EnvironmentObject private var model: AppModel
    var style: SchedulerPanelStyle = .compact

    var body: some View {
        let schedules = scheduleItems

        if style == .detailed {
            detailedBody(schedules)
        } else {
            compactBody(schedules)
        }
    }

    private func compactBody(_ schedules: [SchedulerDisplayItem]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header(count: schedules.count)
            if schedules.isEmpty {
                emptyState
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(schedules.prefix(4).enumerated()), id: \.element.id) { index, schedule in
                        SchedulerRow(schedule: schedule, tint: tint(for: index))
                    }
                }
            }
        }
        .panelStyle(minHeight: 220)
    }

    @ViewBuilder
    private func detailedBody(_ schedules: [SchedulerDisplayItem]) -> some View {
        if schedules.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                header(count: schedules.count)
                emptyState
            }
            .panelStyle(minHeight: 220)
        } else {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text(schedules.count == 1 ? "1 schedule" : "\(schedules.count.formatted()) schedules")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                }

                ForEach(Array(schedules.enumerated()), id: \.element.id) { index, schedule in
                    SchedulerDetailSection(schedule: schedule, tint: tint(for: index))
                }
            }
        }
    }

    private func header(count: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.blue.opacity(0.12))
                    Image(systemName: "calendar.badge.clock")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.blue)
                }
                .frame(width: 22, height: 22)

                Text("Schedulers")
                    .font(.subheadline.weight(.semibold))

                Spacer()

                Text(count == 1 ? "1 schedule" : "\(count.formatted()) schedules")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text("Repeatable jobs and next run hints")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "calendar.badge.exclamationmark")
                    .foregroundStyle(.secondary)
                Text("No schedulers")
                    .font(.callout.weight(.medium))
            }
            Text("Repeatable or scheduled job keys were not found for this queue.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, 4)
    }

    private var scheduleItems: [SchedulerDisplayItem] {
        model.schedulers
            .map(makeScheduleItem)
            .sorted { lhs, rhs in
                switch (lhs.nextRun, rhs.nextRun) {
                case (.some(let left), .some(let right)):
                    return left < right
                case (.some, .none):
                    return true
                case (.none, .some):
                    return false
                case (.none, .none):
                    return lhs.title < rhs.title
                }
            }
    }

    private func makeScheduleItem(_ scheduler: SchedulerSummary) -> SchedulerDisplayItem {
        let rawKey = scheduler.raw["key"] ?? scheduler.id
        let parts = rawKey.components(separatedBy: ":")
        let repeatIndex = parts.firstIndex(of: "repeat")

        let keyParts: ArraySlice<String>
        if let repeatIndex {
            keyParts = parts.dropFirst(repeatIndex + 1)
        } else {
            keyParts = [scheduler.name]
        }

        let nextRun = scheduler.nextRun ?? keyParts.reversed().compactMap(dateFromMilliseconds).first
        let title = keyParts.first(where: { !isMilliseconds($0) }) ?? scheduler.name
        let cadence = cadenceText(from: title)

        return SchedulerDisplayItem(
            id: scheduler.id,
            title: title.titleCasedQueueName,
            rawTitle: title,
            cadence: cadence,
            nextRun: nextRun,
            rawKey: rawKey
        )
    }

    private func cadenceText(from rawTitle: String) -> String {
        if rawTitle.hasPrefix("every-") {
            let value = rawTitle
                .replacingOccurrences(of: "every-", with: "")
                .components(separatedBy: "-")
                .first ?? "interval"
            return "Every \(value)"
        }

        if rawTitle.hasPrefix("cron-") {
            return "Cron"
        }

        if rawTitle == "repeat" {
            return "Registry"
        }

        return "Repeatable"
    }

    private func dateFromMilliseconds(_ value: String) -> Date? {
        guard let milliseconds = Double(value), milliseconds > 1_000_000_000_000 else {
            return nil
        }
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }

    private func isMilliseconds(_ value: String) -> Bool {
        dateFromMilliseconds(value) != nil
    }

    private func tint(for index: Int) -> Color {
        switch index {
        case 0: .blue
        case 1: .purple
        case 2: .teal
        default: .orange
        }
    }
}

private enum SchedulerPanelStyle {
    case compact
    case detailed
}

private struct SchedulerDisplayItem: Identifiable {
    let id: String
    let title: String
    let rawTitle: String
    let cadence: String
    let nextRun: Date?
    let rawKey: String
}

private struct SchedulerDetailSection: View {
    let schedule: SchedulerDisplayItem
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(schedule.title)
                    .font(.headline.weight(.semibold))
                    .lineLimit(1)

                Text(schedule.cadence)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(tint.opacity(0.10), in: Capsule())
            }

            VStack(spacing: 0) {
                SchedulerDetailRow(icon: icon, tint: tint, label: "Next run", value: nextRunText)
                Divider().padding(.leading, 56)
                SchedulerDetailRow(icon: "number", tint: .gray, label: "Job key", value: schedule.rawTitle, isMonospaced: true)
                Divider().padding(.leading, 56)
                SchedulerDetailRow(icon: "clock", tint: .gray, label: "Next timestamp", value: nextTimestampText)
                Divider().padding(.leading, 56)
                SchedulerDetailRow(icon: "key.horizontal", tint: .gray, label: "Redis key", value: schedule.rawKey, isMonospaced: true)
            }
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.primary.opacity(0.06))
            }
        }
    }

    private var icon: String {
        schedule.cadence == "Cron" ? "timer" : "repeat"
    }

    private var nextRunText: String {
        guard let nextRun = schedule.nextRun else { return "Unknown" }
        let interval = nextRun.timeIntervalSince(Date())
        if interval <= 0 {
            return "Due now"
        }
        if interval < 60 {
            return "in \(Int(interval))s"
        }
        if interval < 3_600 {
            return "in \(Int(interval / 60))m"
        }
        if interval < 86_400 {
            return "in \(Int(interval / 3_600))h"
        }
        return nextRun.formatted(date: .abbreviated, time: .shortened)
    }

    private var nextTimestampText: String {
        guard let nextRun = schedule.nextRun else { return "—" }
        return nextRun.formatted(date: .abbreviated, time: .standard)
    }
}

private struct SchedulerDetailRow: View {
    let icon: String
    let tint: Color
    let label: String
    let value: String
    var isMonospaced = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(tint.opacity(0.14))
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .frame(width: 32, height: 32)

            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 118, alignment: .leading)

            Text(value)
                .font(isMonospaced ? .callout.monospaced() : .callout)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

private struct SchedulerRow: View {
    let schedule: SchedulerDisplayItem
    let tint: Color

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(tint.opacity(0.14))
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(schedule.title)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text(schedule.cadence)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(tint)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(tint.opacity(0.10), in: Capsule())
                }

                Text(schedule.rawTitle)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 10)

            VStack(alignment: .trailing, spacing: 2) {
                Text("Next")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(nextRunText)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(schedule.nextRun == nil ? .secondary : .primary)
                    .lineLimit(1)
            }
            .frame(width: 70, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.74), in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(tint.opacity(0.12))
        }
    }

    private var icon: String {
        schedule.cadence == "Cron" ? "timer" : "repeat"
    }

    private var nextRunText: String {
        guard let nextRun = schedule.nextRun else { return "—" }
        let interval = nextRun.timeIntervalSince(Date())
        if interval <= 0 {
            return "due"
        }
        if interval < 60 {
            return "in \(Int(interval))s"
        }
        if interval < 3_600 {
            return "in \(Int(interval / 60))m"
        }
        if interval < 86_400 {
            return "in \(Int(interval / 3_600))h"
        }
        return nextRun.formatted(date: .abbreviated, time: .omitted)
    }
}

private struct SectionEmptyState: View {
    let icon: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.callout)
                .foregroundStyle(.tertiary)
                .frame(width: 18)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, 4)
    }
}

private extension View {
    func panelStyle(minHeight: CGFloat = 168) -> some View {
        self
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
            .padding(14)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.88), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.primary.opacity(0.055))
            }
    }
}
