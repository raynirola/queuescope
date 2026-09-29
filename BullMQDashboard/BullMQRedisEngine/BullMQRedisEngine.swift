import Foundation

actor BullMQRedisEngine: BullMQEngine {
    private var sshTunnel: SSHTunnel?
    private var redis: RedisRESPClient?
    private var config: RedisConnectionConfig?
    private var connectionGeneration = UUID()
    private let mutationClient = BullMQMutationClient()
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
        await disconnect()
        let generation = connectionGeneration
        let client = RedisRESPClient()
        var transport = config
        let tunnel = config.ssh == nil ? nil : SSHTunnel()
        do {
            if let settings = config.ssh, let tunnel {
                transport.transportPort = try await tunnel.start(settings, redisHost: config.host, redisPort: config.port)
                transport.transportHost = "127.0.0.1"
            }
            guard generation == connectionGeneration else { throw CancellationError() }
            try await client.connect(transport)
            _ = try await client.command(["PING"])
            guard generation == connectionGeneration else { throw CancellationError() }
            self.redis = client
            self.config = transport
            self.sshTunnel = tunnel
        } catch {
            await client.disconnect()
            await tunnel?.stop()
            throw error
        }
    }

    func disconnect() async {
        connectionGeneration = UUID()
        let previousTunnel = sshTunnel
        sshTunnel = nil
        let previous = redis
        redis = nil
        config = nil
        await previous?.disconnect()
        await previousTunnel?.stop()
    }

    func discoverQueues(prefix: String, cursor: String = "0") async throws -> QueueDiscovery {
        let escaped = prefix.map { "\\*?[]".contains($0) ? "\\\($0)" : String($0) }.joined()
        let response = try await command(["SCAN", cursor, "MATCH", "\(escaped):*:meta", "COUNT", "500"])
        guard case .array(let values?) = response, values.count == 2 else {
            throw BullMQDashboardError.redis("Invalid queue discovery response.")
        }
        let names = arrayStrings(values[1]).compactMap { BullMQParsing.parseQueueName(fromMetaKey: $0, prefix: prefix) }
        return QueueDiscovery(names: Array(Set(names)).sorted(), nextCursor: values[0].string ?? "0")
    }

    func setQueuePaused(queueName: String, prefix: String, paused: Bool) async throws {
        guard let config else { throw BullMQDashboardError.notConnected }
        try await mutationClient.setQueuePaused(config: config, queueName: queueName, prefix: prefix, paused: paused)
    }

    func findJob(queueName: String, prefix: String, jobID: String) async throws -> JobSummary? {
        let generation = connectionGeneration
        let fields = try await hgetall(BullMQParsing.jobKey(prefix: prefix, queue: queueName, jobID: jobID))
        guard generation == connectionGeneration else { throw CancellationError() }
        guard !fields.isEmpty else { return nil }
        let states = BullMQState.allCases
        let responses = try await commands(states.map { state in
            let key = stateKey(prefix: prefix, queueName: queueName, state: state)
            return [.waiting, .active, .paused].contains(state) ? ["LPOS", key, jobID] : ["ZSCORE", key, jobID]
        })
        for (index, state) in states.enumerated() where responses[index].string != nil || responses[index].int != nil {
            return makeJobSummary(queueName: queueName, state: state, id: jobID, fields: fields,
                                  score: state == .delayed ? Double(responses[index].string ?? "") : nil)
        }
        throw BullMQDashboardError.jobStateUnavailable(jobID)
    }

    func searchJobs(queueName: String, prefix: String, state: BullMQState?, filter: JobFilter, cursor: JobSearchCursor) async throws -> JobSearchResult {
        let generation = connectionGeneration
        let states = state.map { [$0] } ?? BullMQState.allCases
        var cursor = cursor
        var matches: [JobSummary] = []
        var scanned = 0
        while cursor.stateIndex < states.count, scanned < 500, matches.count < 50 {
            try Task.checkCancellation()
            let state = states[cursor.stateIndex]
            let key = stateKey(prefix: prefix, queueName: queueName, state: state)
            let response = try await command(jobEntriesCommand(for: state, key: key, start: cursor.offset, stop: cursor.offset + 49))
            guard generation == connectionGeneration else { throw CancellationError() }
            let entries = jobEntries(for: state, response: response)
            guard !entries.isEmpty else { cursor.stateIndex += 1; cursor.offset = 0; continue }
            let jobs = try await jobSummaries(queueName: queueName, prefix: prefix, state: state, entries: entries)
            guard generation == connectionGeneration else { throw CancellationError() }
            matches.append(contentsOf: jobs.filter(filter.matches))
            scanned += entries.count
            cursor.offset += entries.count
            if entries.count < 50 { cursor.stateIndex += 1; cursor.offset = 0 }
        }
        return JobSearchResult(jobs: matches, next: cursor.stateIndex < states.count ? cursor : nil, scanned: scanned)
    }

    func getJobFlow(_ reference: JobReference) async throws -> JobFlow {
        let generation = connectionGeneration
        var root = reference
        var ancestors: [JobReference] = []
        var seenAncestors: Set<String> = [reference.id]
        var flow = JobFlow()
        for _ in 0..<8 {
            let fields = try await hgetall(root.id)
            guard generation == connectionGeneration else { throw CancellationError() }
            guard let key = fields["parentKey"], let parent = JobReference(key: key, preferredPrefix: root.prefix) else { break }
            guard seenAncestors.insert(parent.id).inserted else { flow.truncated = true; break }
            ancestors.append(parent)
            root = parent
        }
        if ancestors.count == 8 { flow.truncated = true }
        let chain = Array(ancestors.reversed())
        for (depth, ref) in chain.enumerated() {
            let fields = try await hgetall(ref.id)
            guard generation == connectionGeneration else { throw CancellationError() }
            let job: JobSummary?
            do { job = try await findJob(queueName: ref.queue, prefix: ref.prefix, jobID: ref.jobID) }
            catch BullMQDashboardError.jobStateUnavailable { job = nil }
            guard generation == connectionGeneration else { throw CancellationError() }
            flow.nodes.append(JobFlowNode(reference: ref, name: fields["name"] ?? "Missing job", state: job?.state, depth: depth))
            flow.edges.append(JobFlowEdge(parent: ref.id, child: depth + 1 < chain.count ? chain[depth + 1].id : reference.id))
        }
        var pending: [(JobReference, Int)] = [(reference, chain.count)]
        var seen = Set(chain.map(\.id))
        while !pending.isEmpty, flow.nodes.count < 80 {
            try Task.checkCancellation()
            let (ref, depth) = pending.removeFirst()
            guard seen.insert(ref.id).inserted else { continue }
            let fields = try await hgetall(ref.id)
            guard generation == connectionGeneration else { throw CancellationError() }
            let job: JobSummary?
            do { job = try await findJob(queueName: ref.queue, prefix: ref.prefix, jobID: ref.jobID) }
            catch BullMQDashboardError.jobStateUnavailable { job = nil }
            guard generation == connectionGeneration else { throw CancellationError() }
            flow.nodes.append(JobFlowNode(reference: ref, name: fields["name"] ?? "Missing job", state: job?.state, depth: depth))
            let responses = try await commands([
                ["SSCAN", "\(ref.id):dependencies", "0", "COUNT", "80"],
                ["HSCAN", "\(ref.id):processed", "0", "COUNT", "80"],
                ["HSCAN", "\(ref.id):failed", "0", "COUNT", "80"],
                ["ZRANGE", "\(ref.id):unsuccessful", "0", "80"]
            ])
            guard generation == connectionGeneration else { throw CancellationError() }
            var keys: [String] = []
            for index in 0..<3 {
                if case .array(let values?) = responses[index], values.count == 2 {
                    if values[0].string != "0" { flow.truncated = true }
                    let entries = arrayStrings(values[1])
                    keys += index == 0 ? entries : stride(from: 0, to: entries.count, by: 2).map { entries[$0] }
                }
            }
            keys += arrayStrings(responses[3])
            let unique = Array(Set(keys)).sorted()
            if unique.count > 80 || (depth - chain.count >= 6 && !unique.isEmpty) { flow.truncated = true }
            guard depth - chain.count < 6 else { continue }
            for key in unique.prefix(80) {
                guard let child = JobReference(key: key, preferredPrefix: ref.prefix) else { flow.truncated = true; continue }
                flow.edges.append(JobFlowEdge(parent: ref.id, child: child.id))
                if !seen.contains(child.id) { pending.append((child, depth + 1)) }
            }
        }
        if !pending.isEmpty { flow.truncated = true }
        let ids = Set(flow.nodes.map(\.id))
        flow.edges = flow.edges.filter { ids.contains($0.parent) && ids.contains($0.child) }
        return flow
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
            ["ZCARD", BullMQParsing.key(prefix: prefix, queue: queueName, suffix: "waiting-children")],
            ["HGET", BullMQParsing.key(prefix: prefix, queue: queueName, suffix: "meta"), "paused"]
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
        var summary = QueueSummary(
            name: queueName,
            prefix: prefix,
            counts: counts,
            health: BullMQParsing.health(from: counts)
        )
        summary.isPaused = responses[safe: 8]?.string == "1"
        return summary
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
        let jobKey = BullMQParsing.jobKey(prefix: prefix, queue: queueName, jobID: jobID)
        let fields = try await hgetall(jobKey)
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

    func getJobLogs(queueName: String, prefix: String, jobID: String, start: Int?, limit: Int) async throws -> JobLogs {
        let cappedLimit = max(1, limit)
        let logsKey = "\(BullMQParsing.jobKey(prefix: prefix, queue: queueName, jobID: jobID)):logs"
        let totalResponse = try await command(["LLEN", logsKey])
        let total = totalResponse.int ?? 0
        guard total > 0 else { return .empty }

        let lowerBound: Int
        let upperBound: Int
        if let start {
            lowerBound = max(0, min(start, total - 1))
            upperBound = min(total - 1, lowerBound + cappedLimit - 1)
        } else {
            lowerBound = max(0, total - cappedLimit)
            upperBound = total - 1
        }

        let response = try await command(["LRANGE", logsKey, String(lowerBound), String(upperBound)])
        return makeJobLogs(total: total, startIndex: lowerBound, response: response)
    }

    func retryJob(queueName: String, prefix: String, jobID: String, state: BullMQState) async throws {
        guard let config else { throw BullMQDashboardError.notConnected }
        try await mutationClient.retryJob(config: config, queueName: queueName, prefix: prefix, jobID: jobID, state: state)
    }

    func removeJob(queueName: String, prefix: String, jobID: String, removeChildren: Bool) async throws {
        guard let config else { throw BullMQDashboardError.notConnected }
        try await mutationClient.removeJob(config: config, queueName: queueName, prefix: prefix, jobID: jobID, removeChildren: removeChildren)
    }

    func promoteJob(queueName: String, prefix: String, jobID: String) async throws {
        guard let config else { throw BullMQDashboardError.notConnected }
        try await mutationClient.promoteJob(config: config, queueName: queueName, prefix: prefix, jobID: jobID)
    }

    func duplicateJob(queueName: String, prefix: String, name: String, data: AnySendableJSON, options: AnySendableJSON) async throws -> String {
        guard let config else { throw BullMQDashboardError.notConnected }
        return try await mutationClient.duplicateJob(config: config, queueName: queueName, prefix: prefix, name: name, data: data, options: options)
    }

    func addJob(queueName: String, prefix: String, name: String, data: AnySendableJSON, options: AnySendableJSON) async throws -> String {
        guard let config else { throw BullMQDashboardError.notConnected }
        return try await mutationClient.addJob(config: config, queueName: queueName, prefix: prefix, name: name, data: data, options: options)
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
            ["LRANGE", "\(completedKey):data", "0", "1439"],
            ["HMGET", failedKey, "count", "prevTS", "prevCount"],
            ["LRANGE", "\(failedKey):data", "0", "1439"]
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
        let response = try await command(["CLIENT", "LIST"])
        let clientName = "\(prefix):\(Data(queueName.utf8).base64EncodedString())"
        return (response.string ?? "").split(separator: "\n").compactMap { line in
            var fields: [String: String] = [:]
            for pair in line.split(separator: " ") {
                let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                if parts.count == 2 { fields[String(parts[0])] = String(parts[1]) }
            }
            guard let name = fields["name"], name == clientName || name.hasPrefix(clientName + ":w:"),
                  Int(fields["db"] ?? "") == (config?.database ?? 0) else { return nil }
            fields["source"] = "client-list"
            fields["status"] = "connected"
            return WorkerSummary(id: fields["id"] ?? name, queueName: queueName,
                                 name: name.hasPrefix(clientName + ":w:") ? String(name.dropFirst(clientName.count + 3)) : "Worker \(fields["id"] ?? "")", raw: fields)
        }
    }

    func getSchedulers(queueName: String, prefix: String) async throws -> [SchedulerSummary] {
        let repeatKey = BullMQParsing.key(prefix: prefix, queue: queueName, suffix: "repeat")
        let repeatSetResponse = try await command(["ZRANGE", repeatKey, "0", "-1", "WITHSCORES"])
        let repeatMembers = repeatMembers(from: repeatSetResponse)
        let repeatMetadata = try await repeatMetadataByMember(repeatMembers, repeatKey: repeatKey)
        let repeatSchedulers = schedulerSummariesFromRepeatSet(
            repeatSetResponse,
            queueName: queueName,
            repeatKey: repeatKey,
            metadataByMember: repeatMetadata
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
        return try await schedulerSummariesFromRepeatJobs(repeatJobs, queueName: queueName, repeatKey: repeatKey)
    }

    private func schedulerSummariesFromRepeatSet(
        _ response: RESPValue,
        queueName: String,
        repeatKey: String,
        metadataByMember: [String: [String: String]]
    ) -> [SchedulerSummary] {
        let values = arrayStrings(response)
        var schedulers: [SchedulerSummary] = []
        var index = 0
        while index < values.count {
            let repeatMember = values[index]
            let score = index + 1 < values.count ? values[index + 1] : nil
            let metadata = metadataByMember[repeatMember] ?? [:]
            schedulers.append(
                SchedulerSummary(
                    id: "\(repeatKey):\(repeatMember)",
                    queueName: queueName,
                    name: schedulerName(fromRepeatMember: repeatMember, metadata: metadata),
                    nextRun: BullMQParsing.dateFromMilliseconds(score),
                    raw: schedulerRawFields(metadata: metadata, base: [
                        "key": "\(repeatKey):\(repeatMember)",
                        "repeatKey": repeatMember,
                        "source": "repeat-set"
                    ])
                )
            )
            index += 2
        }
        return schedulers
    }

    private func schedulerSummariesFromRepeatJobs(_ jobs: [JobSummary], queueName: String, repeatKey: String) async throws -> [SchedulerSummary] {
        var schedulersByKey: [String: SchedulerSummary] = [:]
        var metadataByMember: [String: [String: String]] = [:]

        for job in jobs where job.id.hasPrefix("repeat:") {
            let parts = job.id.components(separatedBy: ":")
            guard parts.count >= 3 else { continue }
            let timestamp = parts.last
            let repeatMember = parts.dropFirst().dropLast().joined(separator: ":")
            guard !repeatMember.isEmpty else { continue }
            let id = "\(repeatKey):\(repeatMember)"
            let metadata: [String: String]
            if let cachedMetadata = metadataByMember[repeatMember] {
                metadata = cachedMetadata
            } else {
                metadata = try await hgetall("\(repeatKey):\(repeatMember)")
                metadataByMember[repeatMember] = metadata
            }

            if let existing = schedulersByKey[id],
               let existingRun = existing.nextRun,
               let nextRun = job.delayedUntil,
               existingRun <= nextRun {
                continue
            }

            schedulersByKey[id] = SchedulerSummary(
                id: id,
                queueName: queueName,
                name: schedulerName(fromRepeatMember: repeatMember, metadata: metadata),
                nextRun: job.delayedUntil ?? BullMQParsing.dateFromMilliseconds(timestamp),
                raw: schedulerRawFields(metadata: metadata, base: [
                    "key": "\(repeatKey):\(repeatMember):\(timestamp ?? "")",
                    "repeatKey": repeatMember,
                    "source": "repeat-job"
                ])
            )
        }
        return schedulersByKey.values.sorted { $0.name < $1.name }
    }

    private func repeatMembers(from response: RESPValue) -> [String] {
        let values = arrayStrings(response)
        var members: [String] = []
        var index = 0
        while index < values.count {
            members.append(values[index])
            index += 2
        }
        return members
    }

    private func repeatMetadataByMember(_ members: [String], repeatKey: String) async throws -> [String: [String: String]] {
        guard !members.isEmpty else { return [:] }
        let responses = try await commands(members.map { ["HGETALL", "\(repeatKey):\($0)"] })
        var metadataByMember: [String: [String: String]] = [:]
        for (index, member) in members.enumerated() {
            let fields = hgetallFields(responses[safe: index] ?? .array([]))
            if !fields.isEmpty {
                metadataByMember[member] = fields
            }
        }
        return metadataByMember
    }

    private func schedulerRawFields(metadata: [String: String], base: [String: String]) -> [String: String] {
        var raw = base
        for (key, value) in metadata {
            raw[key] = value
        }
        return raw
    }

    private func schedulerName(fromRepeatMember repeatMember: String, metadata: [String: String]) -> String {
        if let name = metadata["name"], !name.isEmpty {
            return name
        }

        return repeatMember
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

    private func makeJobLogs(total: Int, startIndex: Int, response: RESPValue) -> JobLogs {
        let lines = arrayStrings(response)
        let entries = lines.enumerated().map { offset, line in
            JobLogEntry(id: startIndex + offset + 1, text: line)
        }
        return JobLogs(entries: entries, total: total)
    }

    private func command(_ parts: [String]) async throws -> RESPValue {
        try await commands([parts])[0]
    }

    private func commands(_ batch: [[String]]) async throws -> [RESPValue] {
        guard let client = redis else { throw BullMQDashboardError.notConnected }
        do { return try await client.commands(batch) }
        catch {
            if let failure = error as? BullMQDashboardError, case .connectionLost = failure, redis === client {
                await disconnect()
            }
            throw error
        }
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
