import Foundation

enum LoadingPhase: String, Hashable {
    case connecting
    case discovery
    case overview
    case runs
    case workers
    case schedulers
    case metrics
    case jobDetail
}

@MainActor
final class AppModel: ObservableObject {
    @Published var redisURL = "redis://127.0.0.1:6379"
    @Published var prefix = "bull"
    @Published var connectionProfileName = "Local Redis"
    @Published var connectionProfileTag = "local"
    @Published var profiles: [RedisConnectionProfile] = []
    @Published var selectedQueue: QueueSummary?
    @Published var selectedView: QueueWorkspaceView = .overview
    @Published var queues: [QueueSummary] = []
    @Published var selectedState: BullMQState?
    @Published var jobs: [JobSummary] = []
    @Published var selectedJob: JobSummary?
    @Published var selectedJobDetail: JobDetail?
    @Published var workers: [WorkerSummary] = []
    @Published var schedulers: [SchedulerSummary] = []
    @Published var snapshots: [QueueMetricSnapshot] = []
    @Published var isConnected = false
    @Published var activeLoadingPhases: Set<LoadingPhase> = []
    @Published var statusMessage = "Not connected"
    @Published var lastError: String?

    var isLoading: Bool {
        !activeLoadingPhases.isEmpty
    }

    private let engine: BullMQEngine
    private let profileStore: ConnectionProfileStore
    private let credentialStore: KeychainCredentialStore
    private let snapshotStore: MetricSnapshotStore
    private let queueNameStore: QueueNameStore
    private var config: RedisConnectionConfig?
    private let pageSize = 50
    private var refreshRequestID = 0
    private var jobsByQueue: [String: [JobSummary]] = [:]
    private var workersByQueue: [String: [WorkerSummary]] = [:]
    private var schedulersByQueue: [String: [SchedulerSummary]] = [:]
    private var loadingPhaseCounts: [LoadingPhase: Int] = [:]

    init(
        engine: BullMQEngine = BullMQRedisEngine(),
        profileStore: ConnectionProfileStore = ConnectionProfileStore(),
        credentialStore: KeychainCredentialStore = KeychainCredentialStore(),
        snapshotStore: MetricSnapshotStore = MetricSnapshotStore(),
        queueNameStore: QueueNameStore = QueueNameStore()
    ) {
        self.engine = engine
        self.profileStore = profileStore
        self.credentialStore = credentialStore
        self.snapshotStore = snapshotStore
        self.queueNameStore = queueNameStore
        self.profiles = profileStore.load()
        self.snapshots = snapshotStore.load()
    }

    func connect() async {
        await runLoading(.connecting) {
            let parsed = try RedisURLParser.parse(redisURL, prefix: prefix)
            statusMessage = "Connecting to \(parsed.host):\(parsed.port)…"
            try await engine.connect(parsed)
            resetQueueStateForNewConnection()
            config = parsed
            isConnected = true
            statusMessage = "Connected to \(parsed.host):\(parsed.port)"
            loadSavedQueues(for: parsed)
            if selectedQueue != nil {
                Task { await refreshSelectedQueue(for: selectedView) }
            }
            Task { await refreshQueuesAfterConnect(prefix: parsed.prefix) }
        }
    }

    func refreshQueuesAfterConnect(prefix: String? = nil) async {
        await runLoading(.discovery) {
            if let prefix {
                statusMessage = "Checking \(prefix):*:meta for BullMQ queues…"
            }
            try await loadQueues()
        }
    }

    func disconnect() async {
        refreshRequestID += 1
        await engine.disconnect()
        isConnected = false
        statusMessage = "Not connected"
        queues = []
        jobs = []
        selectedState = nil
        selectedQueue = nil
        selectedJob = nil
        selectedJobDetail = nil
        activeLoadingPhases = []
        jobsByQueue = [:]
        workersByQueue = [:]
        schedulersByQueue = [:]
        loadingPhaseCounts = [:]
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
        statusMessage = "Checking \(prefix):*:meta for BullMQ queue metadata…"
        let queueSummaries = try await engine.discoverQueues(prefix: prefix)
        mergeQueues(queueSummaries)
        persistCurrentQueueNames()
        if queueSummaries.isEmpty, !queues.isEmpty {
            statusMessage = "Using saved queues. Discovery found no new \(prefix):*:meta keys."
        } else {
            statusMessage = queueSummaries.isEmpty ? "Discovery found no \(prefix):*:meta keys. Add a queue manually if you know its name." : "Found \(queueSummaries.count) queues"
        }
        if selectedQueue == nil || !queues.contains(where: { $0.name == selectedQueue?.name }) {
            selectedQueue = queues.first
            selectedState = nil
        }
        if selectedQueue != nil {
            Task { await refreshSelectedQueue(for: selectedView) }
        }
    }

    func selectQueue(_ queue: QueueSummary) {
        selectedQueue = queue
        selectedState = nil
        selectedJob = nil
        selectedJobDetail = nil
        applyCachedPanelData(for: queue.name)
        Task { await refreshSelectedQueue(for: selectedView) }
    }

    func selectWorkspaceView(_ view: QueueWorkspaceView) {
        selectedView = view
        selectedJob = nil
        selectedJobDetail = nil
        Task { await refreshSelectedQueue(for: view) }
    }

    func addManualQueue(named rawName: String) async {
        let name = normalizedManualQueueName(rawName)
        guard !name.isEmpty else { return }

        await runLoading(.overview) {
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
            persistCurrentQueueNames()
            applyCachedPanelData(for: name)
            Task { await refreshSelectedQueue(for: selectedView) }
        }
    }

    func refreshSelectedQueue() async {
        await refreshSelectedQueue(for: selectedView)
    }

    func refreshSelectedQueue(for view: QueueWorkspaceView) async {
        let requestID = nextRefreshRequestID()
        await runLoading(loadingPhase(for: view)) {
            try await refreshSelectedQueueThrowing(for: view, requestID: requestID)
        }
    }

    func selectState(_ state: BullMQState) {
        selectedState = selectedState == state ? nil : state
        selectedView = .runs
        selectedJob = nil
        selectedJobDetail = nil
        Task { await refreshSelectedQueue(for: .runs) }
    }

    func selectJob(_ job: JobSummary) {
        selectedJob = job
        Task { await loadSelectedJobDetail() }
    }

    func clearSelectedJob() {
        selectedJob = nil
        selectedJobDetail = nil
    }

    private func refreshSelectedQueueThrowing(for view: QueueWorkspaceView, requestID: Int) async throws {
        guard let selectedQueue else { return }
        let queueName = selectedQueue.name
        statusMessage = "Loading \(queueName) overview…"
        let overview = try await engine.getQueueOverview(queueName: queueName, prefix: prefix)
        guard isCurrentRefresh(requestID, queueName: queueName) else { return }
        replaceQueue(overview)
        self.selectedQueue = overview

        switch view {
        case .overview:
            recordSnapshot(queueName: queueName, counts: overview.counts)
            statusMessage = "Refreshed \(queueName)"
        case .runs:
            statusMessage = "Loading \(queueName) runs…"
            let loadedJobs = try await loadJobs(queueName: queueName)
            guard isCurrentRefresh(requestID, queueName: queueName) else { return }
            jobsByQueue[cacheKey(queueName)] = loadedJobs
            jobs = loadedJobs
            statusMessage = "Loaded \(loadedJobs.count) runs for \(queueName)"
        case .workers:
            statusMessage = "Loading \(queueName) workers…"
            let loadedWorkers = try await engine.getWorkers(queueName: queueName, prefix: prefix)
            guard isCurrentRefresh(requestID, queueName: queueName) else { return }
            workersByQueue[cacheKey(queueName)] = loadedWorkers
            workers = loadedWorkers
            statusMessage = "Loaded \(loadedWorkers.count) workers for \(queueName)"
        case .schedulers:
            statusMessage = "Loading \(queueName) schedulers…"
            let loadedSchedulers = try await engine.getSchedulers(queueName: queueName, prefix: prefix)
            guard isCurrentRefresh(requestID, queueName: queueName) else { return }
            schedulersByQueue[cacheKey(queueName)] = loadedSchedulers
            schedulers = loadedSchedulers
            statusMessage = "Loaded \(loadedSchedulers.count) schedulers for \(queueName)"
        case .metrics:
            recordSnapshot(queueName: queueName, counts: overview.counts)
            statusMessage = "Recorded \(queueName) metrics snapshot"
        case .flowGraph:
            statusMessage = "Refreshed \(queueName)"
        }
    }

    private func loadSelectedJobDetail() async {
        await runLoading(.jobDetail) {
            guard let selectedJob else { return }
            let jobID = selectedJob.id
            let detail = try await engine.getJobDetail(
                queueName: selectedJob.queueName,
                prefix: prefix,
                jobID: selectedJob.id,
                state: selectedJob.state
            )
            guard self.selectedJob?.id == jobID else { return }
            selectedJobDetail = detail
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

        return try await engine.getRecentJobs(
            queueName: queueName,
            prefix: prefix,
            states: BullMQState.allCases,
            perStateLimit: 10,
            totalLimit: pageSize
        )
    }

    private func replaceQueue(_ queue: QueueSummary) {
        if let index = queues.firstIndex(where: { $0.name == queue.name }) {
            queues[index] = queue
        } else {
            queues.append(queue)
            queues.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    private func mergeQueues(_ summaries: [QueueSummary]) {
        for summary in summaries {
            replaceQueue(summary)
        }
    }

    private func loadSavedQueues(for config: RedisConnectionConfig) {
        let names = queueNameStore.load(scope: queueScope(for: config))
        guard !names.isEmpty else { return }
        queues = names.map {
            QueueSummary(name: $0, prefix: config.prefix, counts: .empty, health: .unknown)
        }
        if selectedQueue == nil {
            selectedQueue = queues.first
            selectedState = nil
        }
        if let selectedQueue {
            applyCachedPanelData(for: selectedQueue.name)
        }
        statusMessage = "Loaded \(names.count) saved queues"
    }

    private func resetQueueStateForNewConnection() {
        refreshRequestID += 1
        queues = []
        jobs = []
        workers = []
        schedulers = []
        selectedQueue = nil
        selectedState = nil
        selectedJob = nil
        selectedJobDetail = nil
        jobsByQueue = [:]
        workersByQueue = [:]
        schedulersByQueue = [:]
    }

    private func persistCurrentQueueNames() {
        guard let config else { return }
        queueNameStore.save(queues.map(\.name), scope: queueScope(for: config))
    }

    private func queueScope(for config: RedisConnectionConfig) -> String {
        "\(config.host):\(config.port)/\(config.database):\(config.prefix)"
    }

    private func cacheKey(_ queueName: String) -> String {
        "\(prefix):\(queueName)"
    }

    private func applyCachedPanelData(for queueName: String) {
        let key = cacheKey(queueName)
        jobs = jobsByQueue[key] ?? []
        workers = workersByQueue[key] ?? []
        schedulers = schedulersByQueue[key] ?? []
    }

    private func recordSnapshot(queueName: String, counts: QueueCounts) {
        let snapshot = QueueMetricSnapshot(
            queueName: queueName,
            capturedAt: Date(),
            counts: QueueCountsSnapshot(counts: counts)
        )
        snapshotStore.append(snapshot)
        snapshots = snapshotStore.load()
    }

    private func loadingPhase(for view: QueueWorkspaceView) -> LoadingPhase {
        switch view {
        case .overview: .overview
        case .runs: .runs
        case .flowGraph: .overview
        case .schedulers: .schedulers
        case .workers: .workers
        case .metrics: .metrics
        }
    }

    private func nextRefreshRequestID() -> Int {
        refreshRequestID += 1
        return refreshRequestID
    }

    private func isCurrentRefresh(_ requestID: Int, queueName: String) -> Bool {
        refreshRequestID == requestID && selectedQueue?.name == queueName
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

    private func runLoading(_ phase: LoadingPhase, _ operation: () async throws -> Void) async {
        beginLoading(phase)
        lastError = nil
        defer { endLoading(phase) }
        do {
            try await operation()
        } catch {
            lastError = error.localizedDescription
            statusMessage = error.localizedDescription
        }
    }

    private func beginLoading(_ phase: LoadingPhase) {
        loadingPhaseCounts[phase, default: 0] += 1
        activeLoadingPhases = Set(loadingPhaseCounts.keys)
    }

    private func endLoading(_ phase: LoadingPhase) {
        let nextCount = (loadingPhaseCounts[phase] ?? 0) - 1
        if nextCount > 0 {
            loadingPhaseCounts[phase] = nextCount
        } else {
            loadingPhaseCounts.removeValue(forKey: phase)
        }
        activeLoadingPhases = Set(loadingPhaseCounts.keys)
    }
}
