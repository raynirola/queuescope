import Foundation

protocol BullMQEngine: Sendable {
    func connect(_ config: RedisConnectionConfig) async throws
    func disconnect() async
    func discoverQueues(prefix: String, cursor: String) async throws -> QueueDiscovery
    func findJob(queueName: String, prefix: String, jobID: String) async throws -> JobSummary?
    func searchJobs(queueName: String, prefix: String, state: BullMQState?, filter: JobFilter, cursor: JobSearchCursor) async throws -> JobSearchResult
    func getJobFlow(_ reference: JobReference) async throws -> JobFlow
    func setQueuePaused(queueName: String, prefix: String, paused: Bool) async throws
    func getQueueOverview(queueName: String, prefix: String) async throws -> QueueSummary
    func getJobs(queueName: String, prefix: String, state: BullMQState, page: Int, pageSize: Int) async throws -> JobPage
    func getRecentJobs(queueName: String, prefix: String, states: [BullMQState], perStateLimit: Int, totalLimit: Int) async throws -> [JobSummary]
    func getJobDetail(queueName: String, prefix: String, jobID: String, state: BullMQState) async throws -> JobDetail
    func getJobLogs(queueName: String, prefix: String, jobID: String, start: Int?, limit: Int) async throws -> JobLogs
    func retryJob(queueName: String, prefix: String, jobID: String, state: BullMQState) async throws
    func removeJob(queueName: String, prefix: String, jobID: String, removeChildren: Bool) async throws
    func promoteJob(queueName: String, prefix: String, jobID: String) async throws
    func duplicateJob(queueName: String, prefix: String, name: String, data: AnySendableJSON, options: AnySendableJSON) async throws -> String
    func addJob(queueName: String, prefix: String, name: String, data: AnySendableJSON, options: AnySendableJSON) async throws -> String
    func cleanJobs(queueName: String, prefix: String, state: BullMQState, grace: Int, limit: Int) async throws -> Int
    func getSchedulerPreview(queueName: String, prefix: String, key: String, timeZone: String?) async throws -> SchedulerPreview
    func removeScheduler(queueName: String, prefix: String, key: String, kind: String) async throws
    func getMetrics(queueName: String, prefix: String) async throws -> [QueueMetricSnapshot]
    func getWorkers(queueName: String, prefix: String) async throws -> [WorkerSummary]
    func getSchedulers(queueName: String, prefix: String) async throws -> [SchedulerSummary]
}

enum BullMQDashboardError: LocalizedError, Equatable {
    case invalidRedisURL
    case missingHost
    case unsupportedURLScheme(String)
    case redis(String)
    case connectionLost(String)
    case jobStateUnavailable(String)
    case notConnected

    var errorDescription: String? {
        switch self {
        case .invalidRedisURL: "Enter a valid Redis URL."
        case .missingHost: "The Redis URL is missing a host."
        case .unsupportedURLScheme(let scheme): "Unsupported Redis URL scheme: \(scheme)."
        case .redis(let message): message
        case .connectionLost(let message): "Redis disconnected: \(message)"
        case .jobStateUnavailable(let id): "Job \(id) exists but its state is changing or unknown. Refresh to try again."
        case .notConnected: "Connect to Redis before loading queues."
        }
    }
}
