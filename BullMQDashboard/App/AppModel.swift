import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var redisURL = "redis://127.0.0.1:6379"
    @Published var prefix = "bull"
    @Published var connectionProfileName = "Local Redis"
    @Published var connectionProfileTag = "local"
    @Published var profiles: [RedisConnectionProfile] = []
    @Published var selectedQueue: QueueSummary?
    @Published var queues: [QueueSummary] = []
    @Published var selectedState: BullMQState?
    @Published var jobs: [JobSummary] = []
    @Published var selectedJob: JobSummary?
    @Published var selectedJobDetail: JobDetail?
    @Published var workers: [WorkerSummary] = []
    @Published var schedulers: [SchedulerSummary] = []
    @Published var snapshots: [QueueMetricSnapshot] = []
    @Published var isConnected = false
    @Published var isLoading = false
    @Published var statusMessage = "Not connected"
    @Published var lastError: String?

    private let engine: BullMQEngine
    private let profileStore: ConnectionProfileStore
    private let credentialStore: KeychainCredentialStore
    private let snapshotStore: MetricSnapshotStore
    private var config: RedisConnectionConfig?
    private let pageSize = 50

    init(
        engine: BullMQEngine = BullMQRedisEngine(),
        profileStore: ConnectionProfileStore = ConnectionProfileStore(),
        credentialStore: KeychainCredentialStore = KeychainCredentialStore(),
        snapshotStore: MetricSnapshotStore = MetricSnapshotStore()
    ) {
        self.engine = engine
        self.profileStore = profileStore
        self.credentialStore = credentialStore
        self.snapshotStore = snapshotStore
        self.profiles = profileStore.load()
        self.snapshots = snapshotStore.load()
    }

    func connect() async {
        await runLoading {
            let parsed = try RedisURLParser.parse(redisURL, prefix: prefix)
            statusMessage = "Connecting to \(parsed.host):\(parsed.port)…"
            try await engine.connect(parsed)
            config = parsed
            isConnected = true
            statusMessage = "Connected to \(parsed.host):\(parsed.port)"
            Task { await refreshQueuesAfterConnect(prefix: parsed.prefix) }
        }
    }

    func refreshQueuesAfterConnect(prefix: String? = nil) async {
        await runLoading {
            if let prefix {
                statusMessage = "Discovering BullMQ queues with prefix \(prefix)…"
            }
            try await loadQueues()
        }
    }

    func disconnect() async {
        await engine.disconnect()
        isConnected = false
        statusMessage = "Not connected"
        queues = []
        jobs = []
        selectedState = nil
        selectedQueue = nil
        selectedJob = nil
        selectedJobDetail = nil
    }

    func saveCurrentProfile() {
        do {
            let parsed = try RedisURLParser.parse(redisURL, prefix: prefix)
            let profile = RedisConnectionProfile(
                name: connectionProfileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? parsed.name : connectionProfileName.trimmingCharacters(in: .whitespacesAndNewlines),
                tag: connectionProfileTag,
                urlWithoutSecret: RedisURLParser.redacted(redisURL),
                prefix: parsed.prefix
            )
            try credentialStore.save(secret: redisURL, for: profile.id)
            profiles.append(profile)
            profileStore.save(profiles)
            statusMessage = "Saved \(profile.name)"
        } catch {
            lastError = error.localizedDescription
        }
    }

    func connect(profile: RedisConnectionProfile) async {
        do {
            guard let secret = try credentialStore.read(for: profile.id) else {
                lastError = "No Keychain credential found for \(profile.name)."
                return
            }
            redisURL = secret
            prefix = profile.prefix
            connectionProfileName = profile.name
            connectionProfileTag = profile.tag
            await connect()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func deleteProfile(_ profile: RedisConnectionProfile) {
        profiles.removeAll { $0.id == profile.id }
        credentialStore.delete(for: profile.id)
        profileStore.save(profiles)
    }

    func loadQueues() async throws {
        statusMessage = "Scanning Redis for BullMQ queue metadata. Large databases can take a moment…"
        let queueSummaries = try await engine.discoverQueues(prefix: prefix)
        queues = queueSummaries
        statusMessage = queueSummaries.isEmpty ? "Connected, no queues found for prefix \(prefix)" : "Found \(queueSummaries.count) queues"
        if selectedQueue == nil || !queueSummaries.contains(where: { $0.name == selectedQueue?.name }) {
            selectedQueue = queueSummaries.first
            selectedState = nil
        }
        try await refreshSelectedQueueThrowing()
    }

    func selectQueue(_ queue: QueueSummary) {
        selectedQueue = queue
        selectedState = nil
        selectedJob = nil
        selectedJobDetail = nil
        Task { await refreshSelectedQueue() }
    }

    func addManualQueue(named rawName: String) async {
        let name = normalizedManualQueueName(rawName)
        guard !name.isEmpty else { return }

        await runLoading {
            statusMessage = "Loading queue \(name)…"
            let overview = try await engine.getQueueOverview(queueName: name, prefix: prefix)
            if let index = queues.firstIndex(where: { $0.name == name }) {
                queues[index] = overview
            } else {
                queues.append(overview)
                queues.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            }
            selectedQueue = overview
            selectedState = nil
            selectedJob = nil
            selectedJobDetail = nil
            try await refreshSelectedQueueThrowing()
        }
    }

    func refreshSelectedQueue() async {
        await runLoading {
            try await refreshSelectedQueueThrowing()
        }
    }

    func selectState(_ state: BullMQState) {
        selectedState = selectedState == state ? nil : state
        selectedJob = nil
        selectedJobDetail = nil
        Task { await refreshSelectedQueue() }
    }

    func selectJob(_ job: JobSummary) {
        selectedJob = job
        Task { await loadSelectedJobDetail() }
    }

    func clearSelectedJob() {
        selectedJob = nil
        selectedJobDetail = nil
    }

    private func refreshSelectedQueueThrowing() async throws {
        guard let selectedQueue else { return }
        statusMessage = "Loading \(selectedQueue.name) overview…"
        let overview = try await engine.getQueueOverview(queueName: selectedQueue.name, prefix: prefix)
        replaceQueue(overview)
        self.selectedQueue = overview

        statusMessage = "Loading \(selectedQueue.name) runs…"
        jobs = try await loadJobs(queueName: selectedQueue.name)
        statusMessage = "Loading \(selectedQueue.name) workers…"
        workers = try await engine.getWorkers(queueName: selectedQueue.name, prefix: prefix)
        statusMessage = "Loading \(selectedQueue.name) schedulers…"
        schedulers = try await engine.getSchedulers(queueName: selectedQueue.name, prefix: prefix)
        statusMessage = "Recording \(selectedQueue.name) metrics snapshot…"
        if let snapshot = try await engine.getMetrics(queueName: selectedQueue.name, prefix: prefix).first {
            snapshotStore.append(snapshot)
            snapshots = snapshotStore.load()
        }
        statusMessage = "Refreshed \(selectedQueue.name)"
    }

    private func loadSelectedJobDetail() async {
        await runLoading {
            guard let selectedJob else { return }
            selectedJobDetail = try await engine.getJobDetail(
                queueName: selectedJob.queueName,
                prefix: prefix,
                jobID: selectedJob.id,
                state: selectedJob.state
            )
        }
    }

    private func loadJobs(queueName: String) async throws -> [JobSummary] {
        if let selectedState {
            let page = try await engine.getJobs(
                queueName: queueName,
                prefix: prefix,
                state: selectedState,
                page: 0,
                pageSize: pageSize
            )
            return page.jobs
        }

        var allJobs: [JobSummary] = []
        for state in BullMQState.allCases {
            let page = try await engine.getJobs(
                queueName: queueName,
                prefix: prefix,
                state: state,
                page: 0,
                pageSize: pageSize
            )
            allJobs.append(contentsOf: page.jobs)
        }

        return allJobs
            .sorted { lhs, rhs in
                jobSortDate(lhs) > jobSortDate(rhs)
            }
            .prefix(pageSize)
            .map { $0 }
    }

    private func jobSortDate(_ job: JobSummary) -> Date {
        job.finishedOn ?? job.processedOn ?? job.delayedUntil ?? job.timestamp ?? .distantPast
    }

    private func replaceQueue(_ queue: QueueSummary) {
        if let index = queues.firstIndex(where: { $0.name == queue.name }) {
            queues[index] = queue
        }
    }

    private func normalizedManualQueueName(_ rawName: String) -> String {
        var name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixStart = "\(prefix):"
        if name.hasPrefix(prefixStart) {
            name.removeFirst(prefixStart.count)
        }
        if name.hasSuffix(":meta") {
            name.removeLast(":meta".count)
        }
        return name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func runLoading(_ operation: () async throws -> Void) async {
        isLoading = true
        lastError = nil
        defer { isLoading = false }
        do {
            try await operation()
        } catch {
            lastError = error.localizedDescription
            statusMessage = error.localizedDescription
        }
    }
}
