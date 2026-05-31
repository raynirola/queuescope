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
        return model.isConnected ? "Add a queue manually or select one from the queue list." : "Enter a Redis URL, then add BullMQ queues by name."
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
            MetricsPanel(queue: queue, style: .detailed)
        }
    }

    private func header(_ queue: QueueSummary) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(selectedView.title)
                    .font(.system(size: 28, weight: .semibold, design: .default))
                    .tracking(-0.2)
                    .lineLimit(1)
                Text("\(queue.resolvedDisplayName) · \(queue.prefix):\(queue.name) · \(queue.health.label)")
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
        let hasNativeMetrics = model.snapshots.contains { $0.queueName == queue.name && $0.nativeMetrics?.hasSamples == true }
        let hasWorkers = !model.workers.isEmpty
        let hasFailures = model.jobs.contains { $0.state == .failed }
        let hasSchedulers = !model.schedulers.isEmpty

        VStack(spacing: 18) {
            if hasNativeMetrics {
                MetricsPanel(queue: queue, style: .compact)
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
                Text(value.compactCountDisplay)
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
    let queue: QueueSummary
    var style: MetricsPanelStyle = .compact

    @ViewBuilder
    var body: some View {
        let snapshots = recentSnapshots
        let nativeMetrics = latestNativeMetrics(from: snapshots)
        let throughput = nativeMetrics.map(NativeThroughputSummary.init(metrics:))
        let terminalMetrics = nativeMetrics.map(NativeTerminalSummary.init(metrics:))
        let displayCounts = countsForMetrics(terminalMetrics)
        let sampleCount = nativeMetrics?.sampleCount ?? 0
        let timing = MetricTimingSummary(jobs: model.metricTimingJobs)

        if style == .detailed {
            VStack(alignment: .leading, spacing: 34) {
                MetricSettingsSection(
                    title: "Queue pressure",
                    subtitle: "Live queue shape and retry signals",
                    icon: "gauge.with.dots.needle.67percent",
                    tint: pressureSectionTint(terminalMetrics),
                    trailing: sampleCount == 1 ? "1 sample" : "\(sampleCount.formatted()) samples"
                ) {
                    VStack(spacing: 0) {
                        SignalMetricRow(
                            title: "Backlog",
                            value: backlog.compactCountDisplay,
                            caption: backlogCaption,
                            icon: "tray.full",
                            tint: backlog == 0 ? .green : .teal
                        )
                        Divider().padding(.leading, 58)
                        SignalMetricRow(
                            title: "Failure pressure",
                            value: percentText(failureRate(terminalMetrics)),
                            caption: failurePressureCaption(terminalMetrics),
                            icon: "exclamationmark.triangle",
                            tint: failureTint(terminalMetrics)
                        )
                        Divider().padding(.leading, 58)
                        SignalMetricRow(
                            title: "Work in flight",
                            value: queue.counts.active.compactCountDisplay,
                            caption: activeCaption,
                            icon: "bolt",
                            tint: queue.counts.active > 0 ? .blue : .secondary
                        )
                        Divider().padding(.leading, 58)
                        SignalMetricRow(
                            title: "Terminal jobs",
                            value: terminalTotal(terminalMetrics).compactCountDisplay,
                            caption: terminalTotalCaption(terminalMetrics),
                            icon: "sum",
                            tint: terminalTotal(terminalMetrics) > 0 ? .blue : .secondary
                        )
                    }
                }

                MetricSettingsSection(
                    title: "State mix",
                    subtitle: "Distribution across states",
                    icon: "chart.bar.xaxis",
                    tint: displayCounts.failed > 0 ? .red : .teal,
                    trailing: "\(totalKnownJobs(displayCounts).compactCountDisplay) known jobs"
                ) {
                    StateMixBar(counts: displayCounts, boxed: false)
                }

                MetricSettingsSection(
                    title: "Throughput",
                    subtitle: "Worker metrics per minute",
                    icon: "speedometer",
                    tint: throughput?.failedPerMinute ?? 0 > 0 ? .red : .blue,
                    trailing: ""
                ) {
                    if let throughput, let nativeMetrics {
                        VStack(spacing: 0) {
                            SignalMetricRow(
                                title: "Completed throughput",
                                value: throughput.completedPerMinute.compactRateDisplay,
                                caption: "Completed jobs per minute",
                                icon: "checkmark",
                                tint: .green
                            )
                            Divider().padding(.leading, 58)
                            SignalMetricRow(
                                title: "Failed throughput",
                                value: throughput.failedPerMinute.compactRateDisplay,
                                caption: "Failed jobs per minute",
                                icon: "xmark",
                                tint: .red
                            )
                            Divider().padding(.leading, 58)
                            SignalMetricRow(
                                title: "Terminal throughput",
                                value: throughput.totalPerMinute.compactRateDisplay,
                                caption: "\(throughput.sampleCount.formatted()) buckets sampled",
                                icon: "sum",
                                tint: throughput.totalPerMinute > 0 ? .blue : .secondary
                            )
                            Divider().padding(.leading, 58)
                            ThroughputMetricChart(metrics: nativeMetrics, timing: timing, compact: false)
                                .padding(14)
                        }
                    } else {
                        SectionEmptyState(
                            icon: "speedometer",
                            message: "Worker metrics are not enabled for this queue."
                        )
                        .frame(minHeight: 120, alignment: .topLeading)
                        .padding(14)
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 14) {
                MetricOverviewCard {
                    metricsHeader(sampleCount: sampleCount, usesNativeMetrics: nativeMetrics != nil)
                }

                MetricOverviewCard {
                    LazyVGrid(columns: metricColumns, spacing: 10) {
                        SignalMetricCard(
                            title: "Backlog",
                            value: backlog.compactCountDisplay,
                            caption: backlogCaption,
                            icon: "tray.full",
                            tint: backlog == 0 ? .green : .teal
                        )

                        SignalMetricCard(
                            title: "Failure pressure",
                            value: percentText(failureRate(terminalMetrics)),
                            caption: failurePressureCaption(terminalMetrics),
                            icon: "exclamationmark.triangle",
                            tint: failureTint(terminalMetrics)
                        )

                        SignalMetricCard(
                            title: "Work in flight",
                            value: queue.counts.active.compactCountDisplay,
                            caption: activeCaption,
                            icon: "bolt",
                            tint: queue.counts.active > 0 ? .blue : .secondary
                        )

                        SignalMetricCard(
                            title: "Terminal jobs",
                            value: terminalTotal(terminalMetrics).compactCountDisplay,
                            caption: terminalTotalCaption(terminalMetrics),
                            icon: "sum",
                            tint: terminalTotal(terminalMetrics) > 0 ? .blue : .secondary
                        )
                    }
                }

                MetricOverviewCard {
                    MetricsSection(title: "State mix", detail: "\(totalKnownJobs(displayCounts).compactCountDisplay) known jobs") {
                        StateMixBar(counts: displayCounts)
                    }
                }

                MetricOverviewCard {
                    MetricsSection(title: "Throughput", detail: "") {
                        if let throughput, let nativeMetrics {
                            VStack(spacing: 12) {
                                LazyVGrid(columns: metricColumns, spacing: 10) {
                                    SignalMetricCard(
                                        title: "Completed/min",
                                        value: throughput.completedPerMinute.compactRateDisplay,
                                        caption: "",
                                        icon: "checkmark",
                                        tint: .green
                                    )
                                    SignalMetricCard(
                                        title: "Failed/min",
                                        value: throughput.failedPerMinute.compactRateDisplay,
                                        caption: "",
                                        icon: "xmark",
                                        tint: .red
                                    )
                                }
                                ThroughputMetricChart(metrics: nativeMetrics, timing: timing, compact: true)
                            }
                        } else {
                            SectionEmptyState(
                                icon: "speedometer",
                                message: "Worker metrics are not enabled for this queue."
                            )
                            .frame(minHeight: 92, alignment: .topLeading)
                        }
                    }
                }
            }
        }
    }

    private var metricColumns: [GridItem] {
        [
            GridItem(.flexible(), spacing: 10),
            GridItem(.flexible(), spacing: 10)
        ]
    }

    private var recentSnapshots: [QueueMetricSnapshot] {
        Array(model.snapshots
            .filter { $0.queueName == queue.name }
            .sorted { $0.capturedAt < $1.capturedAt }
            .suffix(40))
    }

    private func latestNativeMetrics(from snapshots: [QueueMetricSnapshot]) -> BullMQNativeMetrics? {
        snapshots.last(where: { $0.nativeMetrics?.hasSamples == true })?.nativeMetrics
    }

    private var backlog: Int {
        queue.counts.waiting + queue.counts.delayed + queue.counts.prioritized + queue.counts.waitingChildren
    }

    private var backlogCaption: String {
        let parts = [
            queue.counts.waiting > 0 ? "\(queue.counts.waiting.compactCountDisplay) queued" : nil,
            queue.counts.delayed > 0 ? "\(queue.counts.delayed.compactCountDisplay) delayed" : nil,
            queue.counts.prioritized > 0 ? "\(queue.counts.prioritized.compactCountDisplay) priority" : nil
        ].compactMap(\.self)
        return parts.isEmpty ? "No queued work" : parts.joined(separator: " · ")
    }

    private var activeCaption: String {
        guard queue.counts.active > 0 else { return "No active jobs right now" }
        return queue.counts.active == 1 ? "1 job currently processing" : "\(queue.counts.active.compactCountDisplay) jobs currently processing"
    }

    private func countsForMetrics(_ terminalMetrics: NativeTerminalSummary?) -> QueueCounts {
        guard let terminalMetrics else { return queue.counts }
        var counts = queue.counts
        counts.completed = terminalMetrics.completed
        counts.failed = terminalMetrics.failed
        return counts
    }

    private func failureRate(_ terminalMetrics: NativeTerminalSummary?) -> Double {
        let failed = terminalMetrics?.failed ?? queue.counts.failed
        let terminal = terminalMetrics?.total ?? (queue.counts.completed + queue.counts.failed)
        guard terminal > 0 else { return 0 }
        return Double(failed) / Double(terminal)
    }

    private func failureTint(_ terminalMetrics: NativeTerminalSummary?) -> Color {
        let failed = terminalMetrics?.failed ?? queue.counts.failed
        return failed > 0 ? .red : .secondary
    }

    private func pressureSectionTint(_ terminalMetrics: NativeTerminalSummary?) -> Color {
        let failed = terminalMetrics?.failed ?? queue.counts.failed
        if failed > 0 { return .red }
        if backlog > 0 { return .teal }
        return .blue
    }

    private func failurePressureCaption(_ terminalMetrics: NativeTerminalSummary?) -> String {
        let failed = terminalMetrics?.failed ?? queue.counts.failed
        let terminal = terminalMetrics?.total ?? (queue.counts.completed + queue.counts.failed)
        guard terminalMetrics != nil else {
            return "\(failed.compactCountDisplay) failed / \(terminal.compactCountDisplay) retained terminal"
        }
        return "\(failed.compactCountDisplay) failed / \(terminal.compactCountDisplay) terminal"
    }

    private func terminalTotal(_ terminalMetrics: NativeTerminalSummary?) -> Int {
        terminalMetrics?.total ?? (queue.counts.completed + queue.counts.failed)
    }

    private func terminalTotalCaption(_ terminalMetrics: NativeTerminalSummary?) -> String {
        let completed = terminalMetrics?.completed ?? queue.counts.completed
        let failed = terminalMetrics?.failed ?? queue.counts.failed
        guard terminalMetrics != nil else {
            return "\(completed.compactCountDisplay) completed / \(failed.compactCountDisplay) failed retained"
        }
        return "\(completed.compactCountDisplay) completed / \(failed.compactCountDisplay) failed"
    }

    private func totalKnownJobs(_ counts: QueueCounts) -> Int {
        counts.waiting
            + counts.active
            + counts.delayed
            + counts.prioritized
            + counts.completed
            + counts.failed
            + counts.paused
            + counts.waitingChildren
    }

    private func metricsHeader(sampleCount: Int, usesNativeMetrics: Bool) -> some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.green.opacity(0.12))
                Image(systemName: "gauge.with.dots.needle.67percent")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.green)
            }
            .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text("Metrics")
                    .font(.subheadline.weight(.semibold))
                Text(usesNativeMetrics ? "Worker metrics and live queue pressure" : "Live queue pressure; worker metrics unavailable")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(sampleCount == 1 ? "1 sample" : "\(sampleCount.formatted()) samples")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func percentText(_ value: Double) -> String {
        let percent = value * 100
        if percent >= 10 || percent.rounded(.down) == percent {
            return "\(Int(percent.rounded()))%"
        }
        return String(format: "%.1f%%", percent)
    }
}

private enum MetricsPanelStyle {
    case compact
    case detailed
}

private struct NativeThroughputSummary {
    let completedPerMinute: Double
    let failedPerMinute: Double
    let totalPerMinute: Double
    let sampleCount: Int

    init(metrics: BullMQNativeMetrics) {
        sampleCount = metrics.sampleCount
        let denominator = Double(max(sampleCount, 1))
        completedPerMinute = Double(metrics.completed.data.reduce(0, +)) / denominator
        failedPerMinute = Double(metrics.failed.data.reduce(0, +)) / denominator
        totalPerMinute = completedPerMinute + failedPerMinute
    }
}

private struct NativeTerminalSummary {
    let completed: Int
    let failed: Int
    let total: Int

    init(metrics: BullMQNativeMetrics) {
        completed = metrics.completed.count
        failed = metrics.failed.count
        total = completed + failed
    }
}

private enum ThroughputMetricSeries: String, CaseIterable, Identifiable {
    case completed = "Completed"
    case failed = "Failed"

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .completed: .green
        case .failed: .red
        }
    }
}

private struct ThroughputMetricPoint: Identifiable {
    let bucketIndex: Int
    let completedPerMinute: Double
    let failedPerMinute: Double

    var id: Int { bucketIndex }
    var hasActivity: Bool { completedPerMinute > 0 || failedPerMinute > 0 }
}

private enum ThroughputMetricTimeframe: String, CaseIterable, Identifiable {
    case oneHour = "1h"
    case oneDay = "1d"
    case oneWeek = "1w"
    case fourWeeks = "4w"

    var id: String { rawValue }

    var bucketCount: Int {
        switch self {
        case .oneHour: 60
        case .oneDay: 1_440
        case .oneWeek: 10_080
        case .fourWeeks: 40_320
        }
    }

    var label: String {
        switch self {
        case .oneHour: "Last hour"
        case .oneDay: "Last day"
        case .oneWeek: "Last week"
        case .fourWeeks: "Last 4 weeks"
        }
    }
}

private struct MetricTimingSummary {
    let p50Wait: TimeInterval?
    let p95Duration: TimeInterval?

    init(jobs: [JobSummary]) {
        p50Wait = Self.percentile(
            jobs.compactMap { job in
                guard let timestamp = job.timestamp, let processedOn = job.processedOn else { return nil }
                return max(0, processedOn.timeIntervalSince(timestamp))
            },
            percentile: 0.50
        )
        p95Duration = Self.percentile(
            jobs.compactMap(\.duration),
            percentile: 0.95
        )
    }

    private static func percentile(_ values: [TimeInterval], percentile: Double) -> TimeInterval? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * percentile).rounded(.up))))
        return sorted[index]
    }
}

private struct ThroughputMetricChart: View {
    let metrics: BullMQNativeMetrics
    let timing: MetricTimingSummary
    var compact = false

    @State private var timeframe: ThroughputMetricTimeframe = .oneHour

    private var visibleBucketCount: Int {
        min(metrics.sampleCount, timeframe.bucketCount)
    }

    private var points: [ThroughputMetricPoint] {
        let bucketCount = visibleBucketCount
        guard bucketCount > 0 else { return [] }

        let groupSize = max(1, Int(ceil(Double(bucketCount) / Double(compact ? 48 : 64))))
        return stride(from: 0, to: bucketCount, by: groupSize).map { start in
            let end = min(start + groupSize, bucketCount)
            let completed = (start..<end).reduce(0) { total, bucketIndex in
                total + bucketValue(metrics.completed.data, bucketIndex: bucketIndex, bucketCount: bucketCount)
            }
            let failed = (start..<end).reduce(0) { total, bucketIndex in
                total + bucketValue(metrics.failed.data, bucketIndex: bucketIndex, bucketCount: bucketCount)
            }
            return ThroughputMetricPoint(
                bucketIndex: start,
                completedPerMinute: Double(completed) / Double(end - start),
                failedPerMinute: Double(failed) / Double(end - start)
            )
        }
    }

    private var activePoints: [ThroughputMetricPoint] {
        points.filter(\.hasActivity)
    }

    private var yDomain: ClosedRange<Double> {
        let peak = activePoints.map { max($0.completedPerMinute, $0.failedPerMinute) }.max() ?? 0
        return 0...Double(max(1, peak))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            chartHeader

            if activePoints.isEmpty {
                SectionEmptyState(
                    icon: "chart.bar",
                    message: "No completed or failed jobs in this timeframe."
                )
                .frame(height: compact ? 72 : 118, alignment: .topLeading)
            } else {
                Chart(points) { point in
                    BarMark(
                        x: .value("Bucket", point.bucketIndex),
                        y: .value("Completed", point.completedPerMinute)
                    )
                    .foregroundStyle(.green)
                    .position(by: .value("Series", ThroughputMetricSeries.completed.rawValue))

                    BarMark(
                        x: .value("Bucket", point.bucketIndex),
                        y: .value("Failed", point.failedPerMinute)
                    )
                    .foregroundStyle(.red)
                    .position(by: .value("Series", ThroughputMetricSeries.failed.rawValue))
                }
                .chartXScale(domain: 0...max(visibleBucketCount - 1, 1))
                .chartYScale(domain: yDomain)
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks(position: .trailing, values: .automatic(desiredCount: compact ? 2 : 4)) { value in
                        AxisGridLine()
                            .foregroundStyle(Color.primary.opacity(0.06))
                        AxisValueLabel {
                            if let intValue = value.as(Int.self) {
                                Text(intValue.compactCountDisplay)
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .frame(height: compact ? 118 : 190)
            }

            TimingStatGrid(timing: timing, compact: compact)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var chartHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Throughput · jobs/min")
                        .font(.caption.weight(.semibold))
                        .textCase(.uppercase)
                        .tracking(2.6)
                        .foregroundStyle(.secondary)
                    Text("\(timeframe.label) · \(visibleBucketCount.formatted()) buckets")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 9) {
                    chartLegend
                    timeframePicker
                }
            }
            VStack(alignment: .leading, spacing: 9) {
                Text("Throughput · jobs/min")
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .tracking(2.6)
                    .foregroundStyle(.secondary)
                chartLegend
                timeframePicker
                Text("\(timeframe.label) · \(visibleBucketCount.formatted()) buckets")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var chartLegend: some View {
        HStack(spacing: 12) {
            ThroughputMetricLegend(series: .completed)
            ThroughputMetricLegend(series: .failed)
        }
    }

    private var timeframePicker: some View {
        Picker("Timeframe", selection: $timeframe) {
            ForEach(ThroughputMetricTimeframe.allCases) { timeframe in
                Text(timeframe.rawValue).tag(timeframe)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: compact ? 154 : 192)
    }

    private func bucketValue(_ data: [Int], bucketIndex: Int, bucketCount: Int) -> Int {
        let dataIndex = bucketCount - bucketIndex - 1
        guard data.indices.contains(dataIndex) else { return 0 }
        return data[dataIndex]
    }
}

private struct TimingStatGrid: View {
    let timing: MetricTimingSummary
    var compact = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                TimingStatBox(title: "P50 wait", value: timing.p50Wait?.compactDurationDisplay ?? "—")
                TimingStatBox(title: "P95 duration", value: timing.p95Duration?.compactDurationDisplay ?? "—")
            }
            VStack(spacing: 8) {
                TimingStatBox(title: "P50 wait", value: timing.p50Wait?.compactDurationDisplay ?? "—")
                TimingStatBox(title: "P95 duration", value: timing.p95Duration?.compactDurationDisplay ?? "—")
            }
        }
    }
}

private struct TimingStatBox: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .tracking(1.9)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.callout.monospacedDigit().weight(.semibold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 4))
        .overlay {
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(Color.primary.opacity(0.08))
        }
    }
}

private struct ThroughputMetricLegend: View {
    let series: ThroughputMetricSeries

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(series.color)
                .frame(width: 6, height: 6)
            Text(series.rawValue)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }
}

private struct SignalMetricCard: View {
    let title: String
    let value: String
    let caption: String
    let icon: String
    let tint: Color

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(tint.opacity(0.12))
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                if !caption.isEmpty {
                    Text(caption)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
    }
}

private struct SignalMetricRow: View {
    let title: String
    let value: String
    let caption: String
    let icon: String
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(tint.opacity(0.12))
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 16)

            Text(value)
                .font(.callout.monospacedDigit().weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }
}

private struct MetricOverviewCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(14)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.88), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.primary.opacity(0.055))
            }
    }
}

private struct MetricSettingsSection<Content: View>: View {
    let title: String
    let subtitle: String
    let icon: String
    let tint: Color
    let trailing: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(tint.opacity(0.12))
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(tint)
                }
                .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline.weight(.semibold))
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                if !trailing.isEmpty {
                    Text(trailing)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            content
                .background(Color(nsColor: .textBackgroundColor).opacity(0.94), in: RoundedRectangle(cornerRadius: 11))
                .overlay {
                    RoundedRectangle(cornerRadius: 11)
                        .strokeBorder(Color.primary.opacity(0.08))
                }
        }
        .padding(.bottom, 2)
    }
}

private struct MetricsSection<Content: View>: View {
    let title: String
    let detail: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if !detail.isEmpty {
                    Text(detail)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            content
        }
    }
}

private struct StateMixBar: View {
    let counts: QueueCounts
    var boxed = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geometry in
                HStack(spacing: 2) {
                    ForEach(nonEmptySegments) { segment in
                        RoundedRectangle(cornerRadius: 4)
                            .fill(segment.color.opacity(0.82))
                            .frame(width: segmentWidth(segment, in: geometry.size.width))
                    }
                }
            }
            .frame(height: 18)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    ForEach(nonEmptySegments) { segment in
                        StateMixLegend(segment: segment)
                    }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8)], alignment: .leading, spacing: 6) {
                    ForEach(nonEmptySegments) { segment in
                        StateMixLegend(segment: segment)
                    }
                }
            }
        }
        .padding(boxed ? 10 : 14)
        .background {
            if boxed {
                RoundedRectangle(cornerRadius: 9)
                    .fill(Color(nsColor: .controlBackgroundColor))
            }
        }
    }

    private var segments: [StateMixSegment] {
        BullMQState.allCases.map {
            StateMixSegment(state: $0, value: counts.count(for: $0), color: color(for: $0))
        }
    }

    private var nonEmptySegments: [StateMixSegment] {
        let nonEmpty = segments.filter { $0.value > 0 }
        return nonEmpty.isEmpty ? [StateMixSegment(state: .waiting, value: 1, color: .secondary)] : nonEmpty
    }

    private var total: Int {
        max(nonEmptySegments.reduce(0) { $0 + $1.value }, 1)
    }

    private func segmentWidth(_ segment: StateMixSegment, in width: CGFloat) -> CGFloat {
        max(6, width * CGFloat(segment.value) / CGFloat(total))
    }

    private func color(for state: BullMQState) -> Color {
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
}

private struct StateMixSegment: Identifiable {
    var id: BullMQState { state }
    let state: BullMQState
    let value: Int
    let color: Color
}

private struct StateMixLegend: View {
    let segment: StateMixSegment

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(segment.color)
                .frame(width: 6, height: 6)
            Text(segment.state.displayName)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(segment.value.compactCountDisplay)
                .font(.caption2.monospacedDigit().weight(.semibold))
        }
        .lineLimit(1)
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

                    Text(workerSignalText)
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

    private var workerSignalText: String {
        worker.raw["source"] == "active-list" ? "inferred from active jobs" : "heartbeat \(heartbeatText)"
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
                WorkerDetailRow(icon: "waveform.path.ecg", tint: .green, label: workerSignalLabel, value: workerSignalText)
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

    private var workerSignalLabel: String {
        worker.raw["source"] == "active-list" ? "Signal" : "Heartbeat"
    }

    private var workerSignalText: String {
        worker.raw["source"] == "active-list" ? "Inferred from active jobs" : heartbeatText
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
                            rank: index
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

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(reason)
                    .font(.callout.monospaced().weight(.medium))
                    .lineLimit(1)
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

private extension BullMQNativeMetrics {
    var sampleCount: Int {
        max(completed.data.count, failed.data.count)
    }
}

private extension Double {
    var compactRateDisplay: String {
        if self > 0, self < 0.1 {
            return "<0.1"
        }
        if self < 10, rounded(.down) != self {
            return String(format: "%.1f", self)
        }
        return Int(rounded()).compactCountDisplay
    }
}
