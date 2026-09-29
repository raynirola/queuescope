import Foundation

struct AnySendableJSON: @unchecked Sendable {
    var value: Any

    init(_ value: Any) {
        self.value = value
    }
}

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
    var redisURL: String
    var isReadOnly = false
    var credentialsInKeychain = false
    var prefix: String

    var displayURL: String {
        RedisURLParser.redacted(redisURL)
    }

    init(id: UUID = UUID(), name: String, tag: String = "local", redisURL: String, prefix: String = "bull", isReadOnly: Bool = false) {
        self.isReadOnly = isReadOnly
        self.id = id
        self.name = name
        self.tag = tag
        self.redisURL = redisURL
        self.prefix = prefix
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        isReadOnly = try container.decodeIfPresent(Bool.self, forKey: .isReadOnly) ?? false
        tag = try container.decodeIfPresent(String.self, forKey: .tag) ?? "local"
        credentialsInKeychain = try container.decodeIfPresent(Bool.self, forKey: .credentialsInKeychain) ?? false
        redisURL = try container.decodeIfPresent(String.self, forKey: .redisURL)
            ?? container.decode(String.self, forKey: .urlWithoutSecret)
        prefix = try container.decode(String.self, forKey: .prefix)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isReadOnly, forKey: .isReadOnly)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(tag, forKey: .tag)
        guard var url = URLComponents(string: redisURL) else { throw BullMQDashboardError.invalidRedisURL }
        url.user = nil
        url.password = nil
        try container.encode(url.string, forKey: .urlWithoutSecret)
        try container.encode(true, forKey: .credentialsInKeychain)
        try container.encode(prefix, forKey: .prefix)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case tag
        case redisURL
        case urlWithoutSecret
        case isReadOnly
        case credentialsInKeychain
        case prefix
    }
}

struct RedisConnectionConfig: Equatable, Sendable {
    var isReadOnly = false
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

struct QueueSummary: Identifiable, Codable, Equatable, Sendable {
    var id: String { name }
    var name: String
    var displayName: String?
    var groupName: String?
    var prefix: String
    var counts: QueueCounts
    var isPaused = false
    var health: QueueHealth

    var resolvedDisplayName: String {
        let trimmed = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? name.titleCasedQueueName : trimmed
    }

    var resolvedGroupName: String {
        let trimmed = groupName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Ungrouped" : trimmed
    }

    init(name: String, displayName: String? = nil, groupName: String? = nil, prefix: String, counts: QueueCounts, health: QueueHealth) {
        self.name = name
        self.displayName = displayName
        self.groupName = groupName
        self.prefix = prefix
        self.counts = counts
        self.health = health
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        groupName = try container.decodeIfPresent(String.self, forKey: .groupName)
        prefix = try container.decode(String.self, forKey: .prefix)
        counts = try container.decode(QueueCounts.self, forKey: .counts)
        isPaused = try container.decodeIfPresent(Bool.self, forKey: .isPaused) ?? false
        health = try container.decode(QueueHealth.self, forKey: .health)
    }
}

struct QueueCounts: Codable, Equatable, Sendable {
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

enum QueueHealth: String, Codable, Sendable {
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

struct JobLogs: Equatable, Sendable {
    var entries: [JobLogEntry]
    var total: Int

    static let empty = JobLogs(entries: [], total: 0)

    var isTruncated: Bool {
        total > entries.count
    }
}

struct JobLogEntry: Identifiable, Equatable, Sendable {
    var id: Int
    var text: String
}

struct QueueMetricSnapshot: Identifiable, Equatable, Codable, Sendable {
    var id = UUID()
    var connectionScope: String? = nil
    var queueName: String
    var capturedAt: Date
    var counts: QueueCountsSnapshot
    var nativeMetrics: BullMQNativeMetrics?
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

struct BullMQNativeMetrics: Equatable, Codable, Sendable {
    var completed: BullMQMetricSeries
    var failed: BullMQMetricSeries

    var hasSamples: Bool {
        !completed.data.isEmpty || !failed.data.isEmpty
    }

    var sampleCount: Int {
        max(completed.data.count, failed.data.count)
    }

    func throughputRate(windowBucketCount: Int) -> BullMQThroughputRate {
        let bucketCount = min(sampleCount, max(windowBucketCount, 1))
        let denominator = Double(max(bucketCount, 1))
        let completedPerMinute = Double(completed.data.prefix(bucketCount).reduce(0, +)) / denominator
        let failedPerMinute = Double(failed.data.prefix(bucketCount).reduce(0, +)) / denominator

        return BullMQThroughputRate(
            completedPerMinute: completedPerMinute,
            failedPerMinute: failedPerMinute,
            bucketCount: bucketCount
        )
    }
}

struct BullMQMetricSeries: Equatable, Codable, Sendable {
    var count: Int
    var previousTimestamp: Date?
    var previousCount: Int
    var data: [Int]
}

struct BullMQThroughputRate: Equatable, Sendable {
    var completedPerMinute: Double
    var failedPerMinute: Double
    var bucketCount: Int

    var totalPerMinute: Double {
        completedPerMinute + failedPerMinute
    }
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

struct JobFilter: Equatable, Sendable {
    var name = ""
    var error = ""
    var createdAfter: Date?
    var createdBefore: Date?
    var isEmpty: Bool { name.isEmpty && error.isEmpty && createdAfter == nil && createdBefore == nil }
    func matches(_ job: JobSummary) -> Bool {
        if !name.isEmpty && !job.name.localizedCaseInsensitiveContains(name) { return false }
        if !error.isEmpty && !(job.failedReason?.localizedCaseInsensitiveContains(error) ?? false) { return false }
        if let createdAfter, (job.timestamp ?? .distantPast) < createdAfter { return false }
        if let createdBefore, (job.timestamp ?? .distantFuture) > createdBefore { return false }
        return true
    }
}

struct JobSearchCursor: Equatable, Sendable {
    var stateIndex = 0
    var offset = 0
}

struct JobSearchResult: Sendable {
    var jobs: [JobSummary]
    var next: JobSearchCursor?
    var scanned: Int
}

struct QueueDiscovery: Sendable {
    var names: [String]
    var nextCursor: String
}

struct JobReference: Hashable, Identifiable, Sendable {
    var prefix: String
    var queue: String
    var jobID: String
    var id: String { "\(prefix):\(queue):\(jobID)" }
    init(prefix: String, queue: String, jobID: String) {
        self.prefix = prefix; self.queue = queue; self.jobID = jobID
    }
    init?(key: String, preferredPrefix: String) {
        let known = key.hasPrefix(preferredPrefix + ":")
        let parts = (known ? String(key.dropFirst(preferredPrefix.count + 1)) : key).split(separator: ":", maxSplits: known ? 1 : 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == (known ? 2 : 3), parts.allSatisfy({ !$0.isEmpty }) else { return nil }
        prefix = known ? preferredPrefix : parts[0]
        queue = parts[known ? 0 : 1]
        jobID = parts[known ? 1 : 2]
    }
}

struct JobFlowNode: Identifiable, Sendable {
    var reference: JobReference
    var name: String
    var state: BullMQState?
    var depth: Int
    var id: String { reference.id }
}

struct JobFlowEdge: Identifiable, Sendable {
    var parent: String
    var child: String
    var id: String { parent + "→" + child }
}

struct JobFlow: Sendable {
    var nodes: [JobFlowNode] = []
    var edges: [JobFlowEdge] = []
    var truncated = false
}
