import Foundation

/// Offline fixtures. No Redis client or mutation bridge is ever created by this engine.
struct DemoBullMQEngine: BullMQEngine {
    let createdAt = Date()
    let queueNames = ["email-delivery", "report-generation", "webhook-delivery"]

    private func jobs(_ queue: String) -> [JobSummary] {
        (0..<36).map { index in
            let state: BullMQState = index < 18 ? .failed : (index < 32 ? .completed : .active)
            let reason = index % 3 == 0 ? "HTTP 429: provider rate limit exceeded" : (index % 3 == 1 ? "Connection timed out after 30 seconds" : "ValidationError: recipient address is missing")
            return JobSummary(id: "demo-\(index)", queueName: queue, state: state, name: queue,
                              timestamp: createdAt.addingTimeInterval(Double(index * -120 - 90)),
                              processedOn: createdAt.addingTimeInterval(Double(index * -120 - 30)),
                              finishedOn: state == .active ? nil : createdAt.addingTimeInterval(Double(index * -120)),
                              delayedUntil: nil, attemptsMade: state == .failed ? 3 : 1, attempts: 3,
                              failedReason: state == .failed ? reason : nil,
                              payloadPreview: "{\"customerId\":\"customer-\(index % 5)\",\"orderId\":\"order-\(index)\"}")
        }
    }
    func connect(_ config: RedisConnectionConfig) async throws {}
    func disconnect() async {}
    func discoverQueues(prefix: String, cursor: String) async throws -> QueueDiscovery { QueueDiscovery(names: queueNames, nextCursor: "0") }
    func findJob(queueName: String, prefix: String, jobID: String) async throws -> JobSummary? { jobs(queueName).first { $0.id == jobID } }
    func searchJobs(queueName: String, prefix: String, state: BullMQState?, filter: JobFilter, cursor: JobSearchCursor) async throws -> JobSearchResult {
        let values = jobs(queueName).filter { state == nil || $0.state == state }
        return JobSearchResult(jobs: values.filter(filter.matches), next: nil, scanned: values.count)
    }
    func getQueueOverview(queueName: String, prefix: String) async throws -> QueueSummary {
        var counts = QueueCounts.empty
        counts.failed = 18; counts.completed = 14; counts.active = 4
        return QueueSummary(name: queueName, prefix: prefix, counts: counts, health: .failing)
    }
    func getJobs(queueName: String, prefix: String, state: BullMQState, page: Int, pageSize: Int) async throws -> JobPage {
        let values = jobs(queueName).filter { $0.state == state }
        return JobPage(jobs: Array(values.dropFirst(page * pageSize).prefix(pageSize)), total: values.count, page: page, pageSize: pageSize)
    }
    func getRecentJobs(queueName: String, prefix: String, states: [BullMQState], perStateLimit: Int, totalLimit: Int) async throws -> [JobSummary] {
        Array(states.flatMap { state in jobs(queueName).filter { $0.state == state }.prefix(perStateLimit) }.prefix(totalLimit))
    }
    func getJobDetail(queueName: String, prefix: String, jobID: String, state: BullMQState) async throws -> JobDetail {
        guard let job = jobs(queueName).first(where: { $0.id == jobID }) else { throw BullMQDashboardError.redis("Demo job not found.") }
        return JobDetail(id: job.id, queueName: queueName, state: job.state,
                         fields: ["name": job.name, "data": job.payloadPreview, "opts": "{\"attempts\":3}"],
                         data: .json(job.payloadPreview), options: .json("{\"attempts\":3}"), progress: .json("0"), returnValue: .json("null"),
                         failedReason: job.failedReason, stacktrace: job.failedReason.map { [$0 + "\n    at processJob (worker.js:42:10)"] } ?? [],
                         timestamp: job.timestamp, processedOn: job.processedOn, finishedOn: job.finishedOn, attemptsMade: job.attemptsMade)
    }
    func getJobLogs(queueName: String, prefix: String, jobID: String, start: Int?, limit: Int) async throws -> JobLogs { .empty }
    func getJobFlow(_ reference: JobReference) async throws -> JobFlow {
        let child = JobReference(prefix: reference.prefix, queue: "webhook-delivery", jobID: reference.jobID == "demo-1" ? "demo-2" : "demo-1")
        return JobFlow(nodes: [JobFlowNode(reference: reference, name: "Prepare order", state: .waitingChildren, depth: 0), JobFlowNode(reference: child, name: "Notify customer", state: .failed, depth: 1)], edges: [JobFlowEdge(parent: reference.id, child: child.id)])
    }
    func cleanJobs(queueName: String, prefix: String, state: BullMQState, grace: Int, limit: Int) async throws -> Int { throw readOnlyError }
    func removeScheduler(queueName: String, prefix: String, key: String, kind: String) async throws { throw readOnlyError }
    func getSchedulerPreview(queueName: String, prefix: String, key: String, timeZone: String? = nil) async throws -> SchedulerPreview {
        SchedulerPreview(fields: ["every": "60000", "tz": "UTC", "previewTimeZone": timeZone ?? "UTC", "previewTimeZoneSource": timeZone == nil ? "recorded" : "override"], kind: "scheduler", times: (1...5).map { Date().addingTimeInterval(Double($0 * 60)).timeIntervalSince1970 * 1000 }, message: "Offline sample schedule; estimated times.")
    }

    func getMetrics(queueName: String, prefix: String) async throws -> [QueueMetricSnapshot] { [] }
    func getWorkers(queueName: String, prefix: String) async throws -> [WorkerSummary] {
        [WorkerSummary(id: "demo-worker", queueName: queueName, name: "Demo worker", raw: ["addr": "127.0.0.1:5000", "age": "3600", "idle": "2", "cmd": "bzpopmin"])]
    }
    func getSchedulers(queueName: String, prefix: String) async throws -> [SchedulerSummary] {
        [SchedulerSummary(id: "daily", queueName: queueName, name: "Daily digest", nextRun: createdAt.addingTimeInterval(3600), raw: ["pattern": "0 9 * * *", "tz": "UTC"])]
    }
    private var readOnlyError: BullMQDashboardError { .redis("Demo workspace is read-only. Connect to your Redis instance to perform job actions.") }
    func setQueuePaused(queueName: String, prefix: String, paused: Bool) async throws { throw readOnlyError }
    func retryJob(queueName: String, prefix: String, jobID: String, state: BullMQState) async throws { throw readOnlyError }
    func removeJob(queueName: String, prefix: String, jobID: String, removeChildren: Bool) async throws { throw readOnlyError }
    func promoteJob(queueName: String, prefix: String, jobID: String) async throws { throw readOnlyError }
    func duplicateJob(queueName: String, prefix: String, name: String, data: AnySendableJSON, options: AnySendableJSON) async throws -> String { throw readOnlyError }
    func addJob(queueName: String, prefix: String, name: String, data: AnySendableJSON, options: AnySendableJSON) async throws -> String { throw readOnlyError }
}
