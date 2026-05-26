import Foundation

enum BullMQState: String, CaseIterable, Identifiable, Sendable {
    case waiting
    case active
    case delayed
    case prioritized
    case completed
    case failed
    case paused
    case waitingChildren = "waiting-children"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .waiting: "Waiting"
        case .active: "Active"
        case .delayed: "Delayed"
        case .prioritized: "Prioritized"
        case .completed: "Completed"
        case .failed: "Failed"
        case .paused: "Paused"
        case .waitingChildren: "Waiting children"
        }
    }
}

struct RedisConnectionProfile: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var tag: String
    var urlWithoutSecret: String
    var prefix: String

    init(id: UUID = UUID(), name: String, tag: String = "local", urlWithoutSecret: String, prefix: String = "bull") {
        self.id = id
        self.name = name
        self.tag = tag
        self.urlWithoutSecret = urlWithoutSecret
        self.prefix = prefix
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        tag = try container.decodeIfPresent(String.self, forKey: .tag) ?? "local"
        urlWithoutSecret = try container.decode(String.self, forKey: .urlWithoutSecret)
        prefix = try container.decode(String.self, forKey: .prefix)
    }
}

struct RedisConnectionConfig: Equatable, Sendable {
    var profileID: UUID?
    var name: String
    var host: String
    var port: Int
    var username: String?
    var password: String?
    var database: Int
    var useTLS: Bool
    var prefix: String
}

struct QueueSummary: Identifiable, Equatable, Sendable {
    var id: String { name }
    var name: String
    var prefix: String
    var counts: QueueCounts
    var health: QueueHealth
}

struct QueueCounts: Equatable, Sendable {
    var waiting: Int
    var active: Int
    var delayed: Int
    var prioritized: Int
    var completed: Int
    var failed: Int
    var paused: Int
    var waitingChildren: Int

    static let empty = QueueCounts(
        waiting: 0,
        active: 0,
        delayed: 0,
        prioritized: 0,
        completed: 0,
        failed: 0,
        paused: 0,
        waitingChildren: 0
    )

    func count(for state: BullMQState) -> Int {
        switch state {
        case .waiting: waiting
        case .active: active
        case .delayed: delayed
        case .prioritized: prioritized
        case .completed: completed
        case .failed: failed
        case .paused: paused
        case .waitingChildren: waitingChildren
        }
    }
}

enum QueueHealth: String, Sendable {
    case healthy
    case busy
    case warning
    case failing
    case unknown

    var label: String {
        switch self {
        case .healthy: "Healthy"
        case .busy: "Busy"
        case .warning: "Warning"
        case .failing: "Failing"
        case .unknown: "Unknown"
        }
    }
}

struct JobSummary: Identifiable, Equatable, Sendable {
    var id: String
    var queueName: String
    var state: BullMQState
    var name: String
    var timestamp: Date?
    var processedOn: Date?
    var finishedOn: Date?
    var delayedUntil: Date?
    var attemptsMade: Int
    var attempts: Int?
    var failedReason: String?
    var payloadPreview: String

    var duration: TimeInterval? {
        guard let processedOn, let finishedOn else { return nil }
        return finishedOn.timeIntervalSince(processedOn)
    }
}

struct JobDetail: Identifiable, Equatable, Sendable {
    var id: String
    var queueName: String
    var state: BullMQState
    var fields: [String: String]
    var data: DisplayValue
    var options: DisplayValue
    var progress: DisplayValue
    var returnValue: DisplayValue
    var failedReason: String?
    var stacktrace: [String]
    var timestamp: Date?
    var processedOn: Date?
    var finishedOn: Date?
    var attemptsMade: Int
}

struct QueueMetricSnapshot: Identifiable, Equatable, Codable, Sendable {
    var id = UUID()
    var queueName: String
    var capturedAt: Date
    var counts: QueueCountsSnapshot
}

struct QueueCountsSnapshot: Equatable, Codable, Sendable {
    var waiting: Int
    var active: Int
    var delayed: Int
    var prioritized: Int
    var completed: Int
    var failed: Int
    var paused: Int
    var waitingChildren: Int
}

struct WorkerSummary: Identifiable, Equatable, Sendable {
    var id: String
    var queueName: String
    var name: String
    var raw: [String: String]
}

struct SchedulerSummary: Identifiable, Equatable, Sendable {
    var id: String
    var queueName: String
    var name: String
    var nextRun: Date?
    var raw: [String: String]
}

enum DisplayValue: Equatable, Sendable {
    case empty
    case json(String)
    case raw(String)

    var text: String {
        switch self {
        case .empty: ""
        case .json(let value), .raw(let value): value
        }
    }
}

struct JobPage: Equatable, Sendable {
    var jobs: [JobSummary]
    var total: Int
    var page: Int
    var pageSize: Int
}
