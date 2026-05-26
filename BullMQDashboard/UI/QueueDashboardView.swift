import Charts
import SwiftUI

struct QueueDashboardView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if let queue = model.selectedQueue {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header(queue)
                        statusCards(queue)
                        JobTableView()
                        observabilityGrid(queue)
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 18)
                }
                .background(Color(nsColor: .windowBackgroundColor))
            } else {
                ContentUnavailableView(
                    "Connect to Redis",
                    systemImage: "server.rack",
                    description: Text("Enter a Redis URL to discover BullMQ queues.")
                )
            }
        }
    }

    private func header(_ queue: QueueSummary) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(queue.name.titleCasedQueueName)
                    .font(.system(size: 28, weight: .semibold, design: .default))
                    .tracking(-0.2)
                    .lineLimit(1)
                Text("\(queue.prefix):\(queue.name) · \(queue.health.label)")
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

    private func observabilityGrid(_ queue: QueueSummary) -> some View {
        Grid(horizontalSpacing: 14, verticalSpacing: 14) {
            GridRow {
                MetricsPanel(queueName: queue.name)
                WorkersPanel()
            }
            GridRow {
                FailedTriagePanel()
                SchedulersPanel()
            }
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
        VStack(alignment: .leading, spacing: 10) {
            Label("Queue trend", systemImage: "chart.line.uptrend.xyaxis")
                .font(.subheadline.weight(.semibold))
            let snapshots = model.snapshots
                .filter { $0.queueName == queueName }
                .sorted { $0.capturedAt < $1.capturedAt }
                .suffix(40)
            if snapshots.isEmpty {
                SectionEmptyState(
                    icon: "chart.line.uptrend.xyaxis",
                    message: "Refresh this queue to record local metric snapshots."
                )
            } else {
                trendChart(Array(snapshots))
            }
        }
        .panelStyle()
    }

    private func trendChart(_ snapshots: [QueueMetricSnapshot]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TrendLegend(color: .teal, title: "Waiting")
                TrendLegend(color: .red, title: "Failed")
                Spacer()
                Text("\(snapshots.count) snapshots")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Chart(snapshots) { snapshot in
                AreaMark(
                    x: .value("Time", snapshot.capturedAt),
                    yStart: .value("Baseline", 0),
                    yEnd: .value("Waiting", snapshot.counts.waiting)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(
                    LinearGradient(
                        colors: [.teal.opacity(0.24), .teal.opacity(0.03)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                LineMark(
                    x: .value("Time", snapshot.capturedAt),
                    y: .value("Waiting", snapshot.counts.waiting)
                )
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                .foregroundStyle(.teal)

                AreaMark(
                    x: .value("Time", snapshot.capturedAt),
                    yStart: .value("Baseline", 0),
                    yEnd: .value("Failed", snapshot.counts.failed)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(
                    LinearGradient(
                        colors: [.red.opacity(0.18), .red.opacity(0.02)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                LineMark(
                    x: .value("Time", snapshot.capturedAt),
                    y: .value("Failed", snapshot.counts.failed)
                )
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                .foregroundStyle(.red)

                if snapshots.count < 3 {
                    PointMark(
                        x: .value("Time", snapshot.capturedAt),
                        y: .value("Waiting", snapshot.counts.waiting)
                    )
                    .foregroundStyle(.teal)
                    PointMark(
                        x: .value("Time", snapshot.capturedAt),
                        y: .value("Failed", snapshot.counts.failed)
                    )
                    .foregroundStyle(.red)
                }
            }
            .chartYScale(domain: 0...trendUpperBound(snapshots))
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.6))
                        .foregroundStyle(Color.primary.opacity(0.08))
                    AxisValueLabel()
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 150)
        }
    }

    private func trendUpperBound(_ snapshots: [QueueMetricSnapshot]) -> Int {
        let maxValue = snapshots
            .map { max($0.counts.waiting, $0.counts.failed) }
            .max() ?? 0
        return max(maxValue + 1, 2)
    }
}

private struct TrendLegend: View {
    let color: Color
    let title: String

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.75), in: Capsule())
    }
}

private struct WorkersPanel: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Workers", systemImage: "person.2.wave.2")
                .font(.subheadline.weight(.semibold))
            if model.workers.isEmpty {
                SectionEmptyState(
                    icon: "person.2.slash",
                    message: "Worker metadata keys were not found for this queue."
                )
            } else {
                ForEach(model.workers) { worker in
                    Text(worker.name)
                        .font(.callout.monospaced())
                        .lineLimit(1)
                }
            }
        }
        .panelStyle()
    }
}

private struct FailedTriagePanel: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Failed triage", systemImage: "stethoscope")
                .font(.subheadline.weight(.semibold))
            let failed = model.jobs.filter { $0.state == .failed }
            if failed.isEmpty {
                SectionEmptyState(
                    icon: "checkmark.seal",
                    message: "Select Failed to group recent errors by reason."
                )
            } else {
                ForEach(groupedFailures(failed), id: \.reason) { group in
                    HStack {
                        Text(group.reason)
                            .lineLimit(1)
                        Spacer()
                        Text(group.count.formatted())
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .panelStyle()
    }

    private func groupedFailures(_ jobs: [JobSummary]) -> [(reason: String, count: Int)] {
        Dictionary(grouping: jobs) { job in
            job.failedReason?.components(separatedBy: "\n").first ?? "Unknown failure"
        }
        .map { ($0.key, $0.value.count) }
        .sorted { $0.1 > $1.1 }
    }
}

private struct SchedulersPanel: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Schedulers", systemImage: "calendar.badge.clock")
                .font(.subheadline.weight(.semibold))
            if model.schedulers.isEmpty {
                SectionEmptyState(
                    icon: "calendar.badge.clock",
                    message: "Repeatable or scheduled job keys were not found."
                )
            } else {
                ForEach(model.schedulers) { scheduler in
                    Text(scheduler.name)
                        .font(.callout.monospaced())
                        .lineLimit(1)
                }
            }
        }
        .panelStyle()
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
    func panelStyle() -> some View {
        self
            .frame(maxWidth: .infinity, minHeight: 168, alignment: .topLeading)
            .padding(14)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.88), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.primary.opacity(0.055))
            }
    }
}
