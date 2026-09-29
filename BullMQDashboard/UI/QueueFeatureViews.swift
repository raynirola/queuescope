import SwiftUI

struct QueueRefreshControls: View {
    @EnvironmentObject private var model: AppModel
    @State private var confirmPause = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                if !model.isConnected {
                    Label("Disconnected", systemImage: "bolt.slash").foregroundStyle(.red)
                } else if model.lastRefreshError != nil {
                    HStack(spacing: 4) {
                        Label("Refresh failed", systemImage: "exclamationmark.triangle")
                        if let date = model.lastRefreshedAt { Text("· last success"); Text(date, style: .relative); Text("ago") }
                    }.foregroundStyle(.orange)
                } else if let date = model.lastRefreshedAt {
                    let stale = context.date.timeIntervalSince(date) > Double(max(30, model.refreshInterval * 2))
                    HStack(spacing: 4) {
                        Image(systemName: stale ? "clock.badge.exclamationmark" : "checkmark.circle")
                        Text(stale ? "Stale · updated" : "Updated")
                        Text(date, style: .relative)
                        Text("ago")
                    }.foregroundStyle(stale ? Color.orange : Color.secondary)
                } else {
                    Text("Not refreshed yet").foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            HStack(spacing: 10) {
                if model.isReadOnly { Label("Read-only", systemImage: "lock").font(.caption) }
                Picker("Refresh", selection: Binding(get: { model.refreshInterval }, set: { model.setRefreshInterval($0) })) {
                    Text("Manual").tag(0)
                    Text("Every 5s").tag(5)
                    Text("Every 15s").tag(15)
                    Text("Every 30s").tag(30)
                    Text("Every 60s").tag(60)
                }.frame(width: 155)
                Spacer(minLength: 0)
                Button { Task { await model.refreshSelectedQueue() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh now").disabled(model.isLoading || !model.isConnected)
                if let queue = model.selectedQueue {
                    Button(queue.isPaused ? "Resume queue" : "Pause queue") { confirmPause = true }
                        .disabled(!model.canWrite || model.isLoading)
                        .alert(queue.isPaused ? "Resume this queue?" : "Pause this queue?", isPresented: $confirmPause) {
                            Button("Cancel", role: .cancel) {}
                            Button(queue.isPaused ? "Resume" : "Pause") { Task { await model.setSelectedQueuePaused(!queue.isPaused) } }
                        } message: {
                            Text(queue.isPaused ? "Waiting jobs can be processed again." : "Active jobs will finish. New jobs will wait until the queue is resumed.")
                        }
                }
            }
        }
        .controlSize(.small)
    }
}

struct JobSearchControls: View {
    @EnvironmentObject private var model: AppModel
    @State private var useDates = false
    @State private var from = Calendar.current.date(byAdding: .day, value: -1, to: .now)!
    @State private var through = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Job ID", text: $model.lookupJobID)
                    .onSubmit { Task { await model.inspectJob() } }
                Button("Open job") { Task { await model.inspectJob() } }
                    .disabled(model.lookupJobID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isLoading)
            }
            HStack {
                TextField("Filter by job name", text: $model.jobFilter.name)
                TextField("Filter by failure text", text: $model.jobFilter.error)
                Button("Search") {
                    model.jobFilter.createdAfter = useDates ? from : nil
                    model.jobFilter.createdBefore = useDates ? through : nil
                    Task { await model.applyJobSearch() }
                }.disabled(model.isLoading)
                Button("Clear") {
                    model.jobFilter = JobFilter(); useDates = false
                    Task { await model.applyJobSearch() }
                }.disabled(model.isLoading)
            }
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Created between", isOn: $useDates).toggleStyle(.checkbox)
                if useDates {
                    DatePicker("From", selection: $from)
                    DatePicker("Through", selection: $through)
                }
            }
            if model.appliedJobFilter != nil {
                HStack {
                    Text("\(model.jobs.count) matches · \(model.searchedJobCount) jobs scanned" + (model.searchCursor == nil ? " · search complete" : " · more jobs remain"))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if model.searchCursor != nil {
                        Button("Search more") { Task { await model.loadMoreSearchResults() } }.disabled(model.isLoading)
                    }
                }
                Text("Searches the selected states in batches. Auto refresh pauses while filtering; Refresh reruns the search. Jobs may move while scanning a live queue.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .dashboardSurface()
        .textFieldStyle(.roundedBorder)
        .controlSize(.small)
        .onAppear {
            useDates = model.jobFilter.createdAfter != nil || model.jobFilter.createdBefore != nil
            if let date = model.jobFilter.createdAfter { from = date }
            if let date = model.jobFilter.createdBefore { through = date }
        }
        .onChange(of: model.selectedQueue?.id) { _, _ in useDates = false }
    }
}

struct JobFlowPanel: View {
    @EnvironmentObject private var model: AppModel
    private let nodeSize = CGSize(width: 220, height: 90)
    private var columns: [[JobFlowNode]] {
        let maxDepth = model.jobFlow.nodes.map(\.depth).max() ?? 0
        return (0...maxDepth).map { depth in model.jobFlow.nodes.filter { $0.depth == depth } }
    }
    private var positions: [String: CGPoint] {
        var result: [String: CGPoint] = [:]
        for (column, nodes) in columns.enumerated() {
            for (row, node) in nodes.enumerated() {
                result[node.id] = CGPoint(x: CGFloat(column) * 280 + 120, y: CGFloat(row) * 115 + 55)
            }
        }
        return result
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Job ID in this queue", text: $model.flowJobID)
                    .textFieldStyle(.roundedBorder)
                Button("Load flow") {
                    model.clearSelectedJob()
                    Task { await model.loadFlow() }
                }.disabled(model.flowJobID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isLoading)
            }
            Text("Parents connect to their children. Select any job to inspect it, including jobs in other queues.")
                .font(.caption).foregroundStyle(.secondary)
            if model.jobFlow.truncated {
                Label("Partial graph: limited to 80 jobs and 6 child levels. Inspect a branch and open its flow to explore further.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            if model.jobFlow.nodes.isEmpty {
                ContentUnavailableView("Choose a job", systemImage: "point.3.connected.trianglepath.dotted", description: Text("Enter an ID or choose View flow from a job inspector."))
                    .frame(height: 300)
            } else {
                ScrollView([.horizontal, .vertical]) {
                    ZStack(alignment: .topLeading) {
                        Path { path in
                            for edge in model.jobFlow.edges {
                                guard let a = positions[edge.parent], let b = positions[edge.child] else { continue }
                                let start = CGPoint(x: a.x + nodeSize.width / 2, y: a.y)
                                let end = CGPoint(x: b.x - nodeSize.width / 2, y: b.y)
                                path.move(to: start)
                                path.addCurve(to: end, control1: CGPoint(x: start.x + 30, y: start.y), control2: CGPoint(x: end.x - 30, y: end.y))
                                path.move(to: CGPoint(x: end.x - 6, y: end.y - 4)); path.addLine(to: end)
                                path.addLine(to: CGPoint(x: end.x - 6, y: end.y + 4))
                            }
                        }.stroke(Color.secondary.opacity(0.5), lineWidth: 1.5)
                        ForEach(model.jobFlow.nodes) { node in
                            Button { Task { await model.inspectJob(node.reference) } } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(node.name).font(.callout.weight(.semibold)).lineLimit(1)
                                    Text("\(node.reference.queue) · \(node.reference.jobID)").font(.caption.monospaced()).lineLimit(1)
                                    Text(node.state?.displayName ?? "Missing or unknown state").font(.caption).foregroundStyle(.secondary)
                                }
                                .padding(10).frame(width: nodeSize.width, height: nodeSize.height, alignment: .leading)
                                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor.opacity(0.4)))
                            }
                            .buttonStyle(.plain)
                            .help(node.id)
                            .position(positions[node.id] ?? .zero)
                        }
                    }
                    .frame(width: CGFloat(columns.count) * 280, height: CGFloat(columns.map(\.count).max() ?? 1) * 115)
                }.frame(height: 480)
            }
        }
    }
}

struct FailureInboxView: View {
    @EnvironmentObject private var model: AppModel
    @State private var search = ""
    @State private var selectedGroup: String?
    private var groups: [FailureGroup] {
        model.failureGroups.filter { search.isEmpty || $0.id.localizedCaseInsensitiveContains(search) || $0.queues.contains { $0.localizedCaseInsensitiveContains(search) } }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Failure inbox").font(.system(size: 28, weight: .semibold))
                Text("Related failures across all discovered and saved queues in this connection.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Scan failures") { Task { await model.scanFailures() } }
                        .disabled(!model.isConnected || model.isScanningFailures)
                    if model.failureScanHasMore {
                        Button("Scan more") { Task { await model.scanFailures(restart: false) } }
                            .disabled(model.isScanningFailures)
                    }
                    if model.isScanningFailures { ProgressView().controlSize(.small) }
                    Spacer()
                    Text("\(model.failureJobs.count) failures · \(model.failureGroups.count) groups")
                        .font(.caption.monospacedDigit())
                }
                if let date = model.failureScanDate {
                    Text("Scan started \(date.formatted(date: .omitted, time: .standard)) · \(model.failureQueuesCompleted)/\(model.failureQueueNames.count) queues scanned" + (model.failureScanHasMore ? " · partial results" : " · scan complete"))
                        .font(.caption).foregroundStyle(.secondary)
                    if !model.newlyObservedFailures.isEmpty {
                        Label("\(model.newlyObservedFailures.count) newly observed since the previous completed scan", systemImage: "sparkle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                Text("Scans retained failed jobs in batches of up to 500. Live queues can change during a scan. Counts cover scanned jobs, not lifetime failures. Discovery may have more queues; use Discover queues / Scan more in the sidebar. Refresh manually to check for new failures.")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = model.failureScanError {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled)
                }
                TextField("Filter error groups or queue names", text: $search).textFieldStyle(.roundedBorder)
                if groups.isEmpty {
                    ContentUnavailableView(model.failureScanDate == nil ? "Scan to find failures" : "No matching failures in scanned jobs", systemImage: "checkmark.bubble", description: Text("Connect to Redis and discover queues, then scan their retained failures."))
                }
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 12) {
                        Button {
                            selectedGroup = selectedGroup == group.id ? nil : group.id
                        } label: {
                            HStack(alignment: .top) {
                                Image(systemName: selectedGroup == group.id ? "chevron.down" : "chevron.right")
                                Text(group.id).font(.subheadline.weight(.semibold)).multilineTextAlignment(.leading)
                                Spacer(minLength: 8)
                                Text(group.jobs.count.formatted()).monospacedDigit()
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        Text(group.queues.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                        if let first = model.failureFirstObserved[group.id], let last = model.failureLastObserved[group.id] {
                            Text("Observed in this session: \(first.formatted(date: .omitted, time: .shortened)) – \(last.formatted(date: .omitted, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        let newCount = group.jobs.filter { model.newlyObservedFailures.contains("\($0.queueName):\($0.id)") }.count
                        if newCount > 0 {
                            Text("\(newCount) newly observed since the previous completed scan").font(.caption).foregroundStyle(.orange)
                        }
                        if let first = group.firstFailure, let last = group.lastFailure {
                            Text("First failure \(first.formatted()) · Last failure \(last.formatted())")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let example = group.jobs.first {
                            Text(example.payloadPreview).font(.caption.monospaced()).lineLimit(2).textSelection(.enabled)
                        }
                        if selectedGroup == group.id {
                            Text("UUIDs and long hex identifiers are grouped together. Inspect individual jobs to compare full errors and payloads.")
                                .font(.caption).foregroundStyle(.secondary)
                            ForEach(Array(group.jobs.prefix(50).enumerated()), id: \.offset) { _, job in
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(job.name).font(.subheadline)
                                        Text("\(job.queueName) · \(job.id)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                    }
                                    Spacer()
                                    Button("Inspect") { Task { await model.inspectJob(JobReference(prefix: model.activePrefix, queue: job.queueName, jobID: job.id)) } }
                                        .disabled(model.isLoading)
                                }
                            }
                            if group.jobs.count > 50 { Text("Showing 50 representative jobs.").font(.caption).foregroundStyle(.secondary) }
                        }
                    }.padding(16).dashboardSurface()
                }
            }.padding(24)
        }
    }
}
