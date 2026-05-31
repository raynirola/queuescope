import Foundation

actor BullMQRedisEngine: BullMQEngine {
    private var redis: RedisRESPClient?
    private var config: RedisConnectionConfig?
    private let scanLimit = 2_000
    private let scanPageLimit = 500
    private let jobSummaryFields = [
        "name",
        "timestamp",
        "processedOn",
        "finishedOn",
        "opts",
        "atm",
        "attemptsMade",
        "failedReason",
        "data"
    ]

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

    func getQueueOverview(queueName: String, prefix: String) async throws -> QueueSummary {
        makeQueueSummary(
            queueName: queueName,
            prefix: prefix,
            responses: try await commands(overviewCommands(queueName: queueName, prefix: prefix))
        )
    }

    private func overviewCommands(queueName: String, prefix: String) -> [[String]] {
        [
            ["LLEN", BullMQParsing.key(prefix: prefix, queue: queueName, suffix: "wait")],
            ["LLEN", BullMQParsing.key(prefix: prefix, queue: queueName, suffix: "active")],
            ["ZCARD", BullMQParsing.key(prefix: prefix, queue: queueName, suffix: "delayed")],
            ["ZCARD", BullMQParsing.key(prefix: prefix, queue: queueName, suffix: "prioritized")],
            ["ZCARD", BullMQParsing.key(prefix: prefix, queue: queueName, suffix: "completed")],
            ["ZCARD", BullMQParsing.key(prefix: prefix, queue: queueName, suffix: "failed")],
            ["LLEN", BullMQParsing.key(prefix: prefix, queue: queueName, suffix: "paused")],
            ["ZCARD", BullMQParsing.key(prefix: prefix, queue: queueName, suffix: "waiting-children")]
        ]
    }

    private func makeQueueSummary(queueName: String, prefix: String, responses: [RESPValue]) -> QueueSummary {
        let counts = QueueCounts(
            waiting: responses[safe: 0]?.int ?? 0,
            active: responses[safe: 1]?.int ?? 0,
            delayed: responses[safe: 2]?.int ?? 0,
            prioritized: responses[safe: 3]?.int ?? 0,
            completed: responses[safe: 4]?.int ?? 0,
            failed: responses[safe: 5]?.int ?? 0,
            paused: responses[safe: 6]?.int ?? 0,
            waitingChildren: responses[safe: 7]?.int ?? 0
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
        let responses = try await commands([
            countCommand(for: state, key: key),
            jobEntriesCommand(for: state, key: key, start: start, stop: stop)
        ])
        let total = responses[safe: 0]?.int ?? 0
        let entries = jobEntries(for: state, response: responses[safe: 1] ?? .array([]))
        let jobs = try await jobSummaries(queueName: queueName, prefix: prefix, state: state, entries: entries)
        return JobPage(jobs: jobs, total: total, page: page, pageSize: pageSize)
    }

    func getRecentJobs(queueName: String, prefix: String, states: [BullMQState], perStateLimit: Int, totalLimit: Int) async throws -> [JobSummary] {
        let cappedPerStateLimit = max(1, perStateLimit)
        let stop = cappedPerStateLimit - 1
        var batch: [[String]] = []

        for state in states {
            let key = stateKey(prefix: prefix, queueName: queueName, state: state)
            batch.append(jobEntriesCommand(for: state, key: key, start: 0, stop: stop))
        }

        let responses = try await commands(batch)
        var allJobs: [JobSummary] = []
        for (index, state) in states.enumerated() {
            let entries = jobEntries(for: state, response: responses[safe: index] ?? .array([]))
            let jobs = try await jobSummaries(queueName: queueName, prefix: prefix, state: state, entries: entries)
            allJobs.append(contentsOf: jobs)
        }

        return allJobs
            .sorted { lhs, rhs in
                jobSortDate(lhs) > jobSortDate(rhs)
            }
            .prefix(totalLimit)
            .map { $0 }
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
        let nativeMetrics = try await getNativeMetrics(queueName: queueName, prefix: prefix)
        return [
            QueueMetricSnapshot(
                queueName: queueName,
                capturedAt: Date(),
                counts: QueueCountsSnapshot(counts: overview.counts),
                nativeMetrics: nativeMetrics
            )
        ]
    }

    private func getNativeMetrics(queueName: String, prefix: String) async throws -> BullMQNativeMetrics? {
        let completedKey = BullMQParsing.key(prefix: prefix, queue: queueName, suffix: "metrics:completed")
        let failedKey = BullMQParsing.key(prefix: prefix, queue: queueName, suffix: "metrics:failed")
        let responses = try await commands([
            ["HMGET", completedKey, "count", "prevTS", "prevCount"],
            ["LRANGE", "\(completedKey):data", "0", "-1"],
            ["HMGET", failedKey, "count", "prevTS", "prevCount"],
            ["LRANGE", "\(failedKey):data", "0", "-1"]
        ])
        let completed = metricSeries(meta: responses[safe: 0] ?? .array([]), data: responses[safe: 1] ?? .array([]))
        let failed = metricSeries(meta: responses[safe: 2] ?? .array([]), data: responses[safe: 3] ?? .array([]))
        let metrics = BullMQNativeMetrics(completed: completed, failed: failed)
        return metrics.hasSamples ? metrics : nil
    }

    private func metricSeries(meta: RESPValue, data: RESPValue) -> BullMQMetricSeries {
        let values = responseArray(meta)
        return BullMQMetricSeries(
            count: metricInt(values[safe: 0] ?? nil),
            previousTimestamp: BullMQParsing.dateFromMilliseconds(values[safe: 1] ?? nil),
            previousCount: metricInt(values[safe: 2] ?? nil),
            data: arrayStrings(data).compactMap(Int.init)
        )
    }

    private func metricInt(_ raw: String?) -> Int {
        guard let raw else { return 0 }
        return Int(raw) ?? 0
    }

    func getWorkers(queueName: String, prefix: String) async throws -> [WorkerSummary] {
        let keys = try await scan(match: "\(prefix):\(queueName):*worker*", limit: 250, maxPages: scanPageLimit)
        let sortedKeys = keys.sorted()
        if sortedKeys.isEmpty {
            return try await inferredWorkersFromActiveJobs(queueName: queueName, prefix: prefix)
        }

        let responses = try await commands(sortedKeys.map { ["HGETALL", $0] })
        var workers: [WorkerSummary] = []
        for (index, key) in sortedKeys.enumerated() {
            var fields = hgetallFields(responses[safe: index] ?? .array([]))
            fields["key"] = key
            workers.append(
                WorkerSummary(
                    id: key,
                    queueName: queueName,
                    name: fields["name"] ?? key.components(separatedBy: ":").last ?? key,
                    raw: fields
                )
            )
        }
        return workers
    }

    private func inferredWorkersFromActiveJobs(queueName: String, prefix: String) async throws -> [WorkerSummary] {
        let overview = try await getQueueOverview(queueName: queueName, prefix: prefix)
        guard overview.counts.active > 0 else { return [] }

        let activeJobs = try await getJobs(queueName: queueName, prefix: prefix, state: .active, page: 0, pageSize: 8).jobs
        let activeJobSummary: String
        if let firstJob = activeJobs.first {
            let remainingCount = max(0, overview.counts.active - 1)
            activeJobSummary = remainingCount == 0 ? firstJob.name : "\(firstJob.name) + \(remainingCount) more"
        } else {
            activeJobSummary = "\(overview.counts.active.formatted()) active jobs"
        }

        return [
            WorkerSummary(
                id: "\(prefix):\(queueName):active-processing",
                queueName: queueName,
                name: "Active processing",
                raw: [
                    "status": "processing",
                    "activeJobName": activeJobSummary,
                    "concurrency": String(overview.counts.active),
                    "processed": String(overview.counts.completed),
                    "failed": String(overview.counts.failed),
                    "source": "active-list"
                ]
            )
        ]
    }

    func getSchedulers(queueName: String, prefix: String) async throws -> [SchedulerSummary] {
        let repeatKey = BullMQParsing.key(prefix: prefix, queue: queueName, suffix: "repeat")
        let repeatSchedulers = schedulerSummariesFromRepeatSet(
            try await command(["ZRANGE", repeatKey, "0", "-1", "WITHSCORES"]),
            queueName: queueName,
            repeatKey: repeatKey
        )
        if !repeatSchedulers.isEmpty {
            return repeatSchedulers
        }

        let repeatJobs = try await getRecentJobs(
            queueName: queueName,
            prefix: prefix,
            states: [.delayed, .waiting, .completed, .failed],
            perStateLimit: 25,
            totalLimit: 100
        )
        return schedulerSummariesFromRepeatJobs(repeatJobs, queueName: queueName, repeatKey: repeatKey)
    }

    private func schedulerSummariesFromRepeatSet(_ response: RESPValue, queueName: String, repeatKey: String) -> [SchedulerSummary] {
        let values = arrayStrings(response)
        var schedulers: [SchedulerSummary] = []
        var index = 0
        while index < values.count {
            let repeatMember = values[index]
            let score = index + 1 < values.count ? values[index + 1] : nil
            schedulers.append(
                SchedulerSummary(
                    id: "\(repeatKey):\(repeatMember)",
                    queueName: queueName,
                    name: schedulerName(fromRepeatMember: repeatMember),
                    nextRun: BullMQParsing.dateFromMilliseconds(score),
                    raw: [
                        "key": "\(repeatKey):\(repeatMember)",
                        "repeatKey": repeatMember,
                        "source": "repeat-set"
                    ]
                )
            )
            index += 2
        }
        return schedulers
    }

    private func schedulerSummariesFromRepeatJobs(_ jobs: [JobSummary], queueName: String, repeatKey: String) -> [SchedulerSummary] {
        var schedulersByKey: [String: SchedulerSummary] = [:]

        for job in jobs where job.id.hasPrefix("repeat:") {
            let parts = job.id.components(separatedBy: ":")
            guard parts.count >= 3 else { continue }
            let timestamp = parts.last
            let repeatMember = parts.dropFirst().dropLast().joined(separator: ":")
            guard !repeatMember.isEmpty else { continue }
            let id = "\(repeatKey):\(repeatMember)"

            if let existing = schedulersByKey[id],
               let existingRun = existing.nextRun,
               let nextRun = job.delayedUntil,
               existingRun <= nextRun {
                continue
            }

            schedulersByKey[id] = SchedulerSummary(
                id: id,
                queueName: queueName,
                name: schedulerName(fromRepeatMember: repeatMember),
                nextRun: job.delayedUntil ?? BullMQParsing.dateFromMilliseconds(timestamp),
                raw: [
                    "key": "\(repeatKey):\(repeatMember):\(timestamp ?? "")",
                    "repeatKey": repeatMember,
                    "source": "repeat-job"
                ]
            )
        }
        return schedulersByKey.values.sorted { $0.name < $1.name }
    }

    private func schedulerName(fromRepeatMember repeatMember: String) -> String {
        repeatMember
            .components(separatedBy: ":")
            .first(where: { !$0.isEmpty && !isMilliseconds($0) }) ?? repeatMember
    }

    private func isMilliseconds(_ value: String) -> Bool {
        guard let number = Double(value) else { return false }
        return number > 1_000_000_000_000
    }

    private func stateKey(prefix: String, queueName: String, state: BullMQState) -> String {
        let suffix = state == .waiting ? "wait" : state.rawValue
        return BullMQParsing.key(prefix: prefix, queue: queueName, suffix: suffix)
    }

    private func countCommand(for state: BullMQState, key: String) -> [String] {
        switch state {
        case .waiting, .active, .paused:
            ["LLEN", key]
        case .delayed, .prioritized, .completed, .failed, .waitingChildren:
            ["ZCARD", key]
        }
    }

    private func jobEntriesCommand(for state: BullMQState, key: String, start: Int, stop: Int) -> [String] {
        switch state {
        case .waiting, .active, .paused:
            ["LRANGE", key, String(start), String(stop)]
        case .delayed:
            ["ZREVRANGE", key, String(start), String(stop), "WITHSCORES"]
        case .prioritized, .completed, .failed, .waitingChildren:
            ["ZREVRANGE", key, String(start), String(stop)]
        }
    }

    private func jobEntries(for state: BullMQState, response: RESPValue) -> [(id: String, score: Double?)] {
        switch state {
        case .waiting, .active, .paused:
            return arrayStrings(response).map { (id: $0, score: nil) }
        case .delayed:
            let values = arrayStrings(response)
            var entries: [(id: String, score: Double?)] = []
            var index = 0
            while index + 1 < values.count {
                entries.append((id: values[index], score: Double(values[index + 1])))
                index += 2
            }
            return entries
        case .prioritized, .completed, .failed, .waitingChildren:
            return arrayStrings(response).map { (id: $0, score: nil) }
        }
    }

    private func jobSummaries(queueName: String, prefix: String, state: BullMQState, entries: [(id: String, score: Double?)]) async throws -> [JobSummary] {
        guard !entries.isEmpty else { return [] }
        let batch = entries.map { entry in
            ["HMGET", BullMQParsing.jobKey(prefix: prefix, queue: queueName, jobID: entry.id)] + jobSummaryFields
        }
        let responses = try await commands(batch)
        var jobs: [JobSummary] = []

        for (index, response) in responses.enumerated() {
            let values = responseArray(response)
            guard values.contains(where: { $0 != nil }) else { continue }
            var fields: [String: String] = [:]
            for (fieldIndex, fieldName) in jobSummaryFields.enumerated() {
                if let value = values[safe: fieldIndex] ?? nil {
                    fields[fieldName] = value
                }
            }
            let entry = entries[index]
            jobs.append(makeJobSummary(queueName: queueName, state: state, id: entry.id, fields: fields, score: entry.score))
        }

        return jobs
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

    private func jobSortDate(_ job: JobSummary) -> Date {
        job.finishedOn ?? job.processedOn ?? job.delayedUntil ?? job.timestamp ?? .distantPast
    }

    private func scan(match: String, limit: Int, maxPages: Int? = nil, stopAfterFirstResultPage: Bool = false) async throws -> [String] {
        var cursor = "0"
        var keys: [String] = []
        var pages = 0
        repeat {
            pages += 1
            let response = try await command(["SCAN", cursor, "MATCH", match, "COUNT", "1000"])
            guard case .array(let values?) = response, values.count == 2 else { break }
            cursor = values[0].string ?? "0"
            let pageKeys = arrayStrings(values[1])
            keys.append(contentsOf: pageKeys)
            if stopAfterFirstResultPage, !pageKeys.isEmpty {
                return Array(keys.prefix(limit))
            }
            if keys.count >= limit {
                return Array(keys.prefix(limit))
            }
            if let maxPages, pages >= maxPages {
                break
            }
        } while cursor != "0"
        return keys
    }

    private func hgetall(_ key: String) async throws -> [String: String] {
        hgetallFields(try await command(["HGETALL", key]))
    }

    private func hgetallFields(_ response: RESPValue) -> [String: String] {
        let values = arrayStrings(response)
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

    private func commands(_ batch: [[String]]) async throws -> [RESPValue] {
        guard let redis else { throw BullMQDashboardError.notConnected }
        return try await redis.commands(batch)
    }

    private func arrayStrings(_ value: RESPValue) -> [String] {
        guard case .array(let values?) = value else { return [] }
        return values.compactMap(\.string)
    }

    private func responseArray(_ value: RESPValue) -> [String?] {
        guard case .array(let values?) = value else { return [] }
        return values.map(\.string)
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
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
