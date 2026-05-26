import Foundation

protocol BullMQEngine: Sendable {
    func connect(_ config: RedisConnectionConfig) async throws
    func disconnect() async
    func discoverQueues(prefix: String) async throws -> [QueueSummary]
    func getQueueOverview(queueName: String, prefix: String) async throws -> QueueSummary
    func getJobs(queueName: String, prefix: String, state: BullMQState, page: Int, pageSize: Int) async throws -> JobPage
    func getJobDetail(queueName: String, prefix: String, jobID: String, state: BullMQState) async throws -> JobDetail
    func getMetrics(queueName: String, prefix: String) async throws -> [QueueMetricSnapshot]
    func getWorkers(queueName: String, prefix: String) async throws -> [WorkerSummary]
    func getSchedulers(queueName: String, prefix: String) async throws -> [SchedulerSummary]
}

enum BullMQDashboardError: LocalizedError, Equatable {
    case invalidRedisURL
    case missingHost
    case unsupportedURLScheme(String)
    case redis(String)
    case notConnected

    var errorDescription: String? {
        switch self {
        case .invalidRedisURL: "Enter a valid Redis URL."
        case .missingHost: "The Redis URL is missing a host."
        case .unsupportedURLScheme(let scheme): "Unsupported Redis URL scheme: \(scheme)."
        case .redis(let message): message
        case .notConnected: "Connect to Redis before loading queues."
        }
    }
}
