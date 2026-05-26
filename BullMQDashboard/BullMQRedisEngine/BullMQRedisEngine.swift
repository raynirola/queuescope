import Foundation

actor BullMQRedisEngine: BullMQEngine {
    private var redis: RedisRESPClient?
    private var config: RedisConnectionConfig?
    private let scanLimit = 2_000

    func connect(_ config: RedisConnectionConfig) async throws {
        let client = RedisRESPClient()
        try await client.connect(config)
        self.redis = client
        self.config = config
    }

    func disconnect() async {
        await redis?.disconnect()
        redis = nil
        config = nil
    }

    func discoverQueues(prefix: String) async throws -> [QueueSummary] {
        let keys = try await scan(match: "\(prefix):*:meta", limit: scanLimit)
        let names = keys.compactMap { BullMQParsing.parseQueueName(fromMetaKey: $0, prefix: prefix) }
        var summaries: [QueueSummary] = []
        for name in Set(names).sorted() {
            summaries.append(try await getQueueOverview(queueName: name, prefix: prefix))
        }
        return summaries
    }

    func getQueueOverview(queueName: String, prefix: String) async throws -> QueueSummary {
        let counts = QueueCounts(
            waiting: try await llen(BullMQParsing.key(prefix: prefix, queue: queueName, suffix: "wait")),
            active: try await llen(BullMQParsing.key(prefix: prefix, queue: queueName, suffix: "active")),
            delayed: try await zcard(BullMQParsing.key(prefix: prefix, queue: queueName, suffix: "delayed")),
            prioritized: try await zcard(BullMQParsing.key(prefix: prefix, queue: queueName, suffix: "prioritized")),
            completed: try await zcard(BullMQParsing.key(prefix: prefix, queue: queueName, suffix: "completed")),
            failed: try await zcard(BullMQParsing.key(prefix: prefix, queue: queueName, suffix: "failed")),
            paused: try await llen(BullMQParsing.key(prefix: prefix, queue: queueName, suffix: "paused")),
            waitingChildren: try await zcard(BullMQParsing.key(prefix: prefix, queue: queueName, suffix: "waiting-children"))
        )
        return QueueSummary(
            name: queueName,
            prefix: prefix,
            counts: counts,
            health: BullMQParsing.health(from: counts)
        )
    }

    func getJobs(queueName: String, prefix: String, state: BullMQState, page: Int, pageSize: Int) async throws -> JobPage {
        let start = max(0, page * pageSize)
        let stop = start + pageSize - 1
        let key = stateKey(prefix: prefix, queueName: queueName, state: state)
        let total = try await count(for: state, key: key)
        let entries = try await jobEntries(for: state, key: key, start: start, stop: stop)
        var jobs: [JobSummary] = []
        for entry in entries {
            let id = entry.id
            let fields = try await hgetall(BullMQParsing.jobKey(prefix: prefix, queue: queueName, jobID: id))
            if fields.isEmpty {
                continue
            }
            jobs.append(makeJobSummary(queueName: queueName, state: state, id: id, fields: fields, score: entry.score))
        }
        return JobPage(jobs: jobs, total: total, page: page, pageSize: pageSize)
    }

    func getJobDetail(queueName: String, prefix: String, jobID: String, state: BullMQState) async throws -> JobDetail {
        let fields = try await hgetall(BullMQParsing.jobKey(prefix: prefix, queue: queueName, jobID: jobID))
        return JobDetail(
            id: jobID,
            queueName: queueName,
            state: state,
            fields: fields,
            data: BullMQParsing.displayValue(fields["data"]),
            options: BullMQParsing.displayValue(fields["opts"]),
            progress: BullMQParsing.displayValue(fields["progress"]),
            returnValue: BullMQParsing.displayValue(fields["returnvalue"]),
            failedReason: fields["failedReason"],
            stacktrace: BullMQParsing.stacktrace(fields["stacktrace"]),
            timestamp: BullMQParsing.dateFromMilliseconds(fields["timestamp"]),
            processedOn: BullMQParsing.dateFromMilliseconds(fields["processedOn"]),
            finishedOn: BullMQParsing.dateFromMilliseconds(fields["finishedOn"]),
            attemptsMade: BullMQParsing.int(fields["atm"] ?? fields["attemptsMade"])
        )
    }

    func getMetrics(queueName: String, prefix: String) async throws -> [QueueMetricSnapshot] {
        let overview = try await getQueueOverview(queueName: queueName, prefix: prefix)
        return [
            QueueMetricSnapshot(
                queueName: queueName,
                capturedAt: Date(),
                counts: QueueCountsSnapshot(counts: overview.counts)
            )
        ]
    }

    func getWorkers(queueName: String, prefix: String) async throws -> [WorkerSummary] {
        let keys = try await scan(match: "\(prefix):\(queueName):*worker*", limit: 250)
        return keys.map {
            WorkerSummary(id: $0, queueName: queueName, name: $0.components(separatedBy: ":").last ?? $0, raw: ["key": $0])
        }
    }

    func getSchedulers(queueName: String, prefix: String) async throws -> [SchedulerSummary] {
        let repeatKeys = try await scan(match: "\(prefix):\(queueName):repeat*", limit: 250)
        return repeatKeys.map {
            SchedulerSummary(id: $0, queueName: queueName, name: $0.components(separatedBy: ":").last ?? $0, nextRun: nil, raw: ["key": $0])
        }
    }

    private func stateKey(prefix: String, queueName: String, state: BullMQState) -> String {
        let suffix = state == .waiting ? "wait" : state.rawValue
        return BullMQParsing.key(prefix: prefix, queue: queueName, suffix: suffix)
    }

    private func count(for state: BullMQState, key: String) async throws -> Int {
        switch state {
        case .waiting, .active, .paused:
            try await llen(key)
        case .delayed, .prioritized, .completed, .failed, .waitingChildren:
            try await zcard(key)
        }
    }

    private func jobEntries(for state: BullMQState, key: String, start: Int, stop: Int) async throws -> [(id: String, score: Double?)] {
        let response: RESPValue
        switch state {
        case .waiting, .active, .paused:
            response = try await command(["LRANGE", key, String(start), String(stop)])
            return arrayStrings(response).map { (id: $0, score: nil) }
        case .delayed:
            response = try await command(["ZREVRANGE", key, String(start), String(stop), "WITHSCORES"])
            let values = arrayStrings(response)
            var entries: [(id: String, score: Double?)] = []
            var index = 0
            while index + 1 < values.count {
                entries.append((id: values[index], score: Double(values[index + 1])))
                index += 2
            }
            return entries
        case .prioritized, .completed, .failed, .waitingChildren:
            response = try await command(["ZREVRANGE", key, String(start), String(stop)])
            return arrayStrings(response).map { (id: $0, score: nil) }
        }
    }

    private func makeJobSummary(queueName: String, state: BullMQState, id: String, fields: [String: String], score: Double? = nil) -> JobSummary {
        JobSummary(
            id: id,
            queueName: queueName,
            state: state,
            name: fields["name"] ?? "(unnamed)",
            timestamp: BullMQParsing.dateFromMilliseconds(fields["timestamp"]),
            processedOn: BullMQParsing.dateFromMilliseconds(fields["processedOn"]),
            finishedOn: BullMQParsing.dateFromMilliseconds(fields["finishedOn"]),
            delayedUntil: delayedUntil(state: state, score: score, timestamp: fields["timestamp"], options: fields["opts"]),
            attemptsMade: BullMQParsing.int(fields["atm"] ?? fields["attemptsMade"]),
            attempts: BullMQParsing.attempts(from: fields["opts"]),
            failedReason: fields["failedReason"],
            payloadPreview: BullMQParsing.preview(fields["data"])
        )
    }

    private func delayedUntil(state: BullMQState, score: Double?, timestamp: String?, options: String?) -> Date? {
        if state == .delayed, let score {
            let delayedTimestamp = floor(score / 4096)
            if delayedTimestamp > 0 {
                return Date(timeIntervalSince1970: delayedTimestamp / 1000)
            }
        }

        guard let addedAt = BullMQParsing.dateFromMilliseconds(timestamp),
              let delay = BullMQParsing.delay(from: options),
              delay > 0 else {
            return nil
        }
        return addedAt.addingTimeInterval(Double(delay) / 1000)
    }

    private func scan(match: String, limit: Int) async throws -> [String] {
        var cursor = "0"
        var keys: [String] = []
        repeat {
            let response = try await command(["SCAN", cursor, "MATCH", match, "COUNT", "100"])
            guard case .array(let values?) = response, values.count == 2 else { break }
            cursor = values[0].string ?? "0"
            keys.append(contentsOf: arrayStrings(values[1]))
            if keys.count >= limit {
                return Array(keys.prefix(limit))
            }
        } while cursor != "0"
        return keys
    }

    private func llen(_ key: String) async throws -> Int {
        try await command(["LLEN", key]).int ?? 0
    }

    private func zcard(_ key: String) async throws -> Int {
        try await command(["ZCARD", key]).int ?? 0
    }

    private func hgetall(_ key: String) async throws -> [String: String] {
        let values = arrayStrings(try await command(["HGETALL", key]))
        var fields: [String: String] = [:]
        var index = 0
        while index + 1 < values.count {
            fields[values[index]] = values[index + 1]
            index += 2
        }
        return fields
    }

    private func command(_ parts: [String]) async throws -> RESPValue {
        guard let redis else { throw BullMQDashboardError.notConnected }
        return try await redis.command(parts)
    }

    private func arrayStrings(_ value: RESPValue) -> [String] {
        guard case .array(let values?) = value else { return [] }
        return values.compactMap(\.string)
    }
}

extension QueueCountsSnapshot {
    init(counts: QueueCounts) {
        self.init(
            waiting: counts.waiting,
            active: counts.active,
            delayed: counts.delayed,
            prioritized: counts.prioritized,
            completed: counts.completed,
            failed: counts.failed,
            paused: counts.paused,
            waitingChildren: counts.waitingChildren
        )
    }
}
