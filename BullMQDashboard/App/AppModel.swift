import Foundation

enum LoadingPhase: String, Hashable {
    case connecting
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
    @Published var runPage = 0
    @Published var runTotal = 0
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
    private let queueMetadataStore: QueueMetadataStore
    private var config: RedisConnectionConfig?
    private let runPageSize = 10
    private var refreshRequestID = 0
    private var jobsByQuery: [String: [JobSummary]] = [:]
    private var runTotalsByQuery: [String: Int] = [:]
    private var workersByQueue: [String: [WorkerSummary]] = [:]
    private var schedulersByQueue: [String: [SchedulerSummary]] = [:]
    private var loadingPhaseCounts: [LoadingPhase: Int] = [:]
    private var refreshTask: Task<Void, Never>?
    private var lastSnapshotCountsByQueue: [String: QueueCounts] = [:]

    init(
        engine: BullMQEngine = BullMQRedisEngine(),
        profileStore: ConnectionProfileStore = ConnectionProfileStore(),
        credentialStore: KeychainCredentialStore = KeychainCredentialStore(),
        snapshotStore: MetricSnapshotStore = MetricSnapshotStore(),
        queueNameStore: QueueNameStore = QueueNameStore(),
        queueMetadataStore: QueueMetadataStore = QueueMetadataStore()
    ) {
        self.engine = engine
        self.profileStore = profileStore
        self.credentialStore = credentialStore
        self.snapshotStore = snapshotStore
        self.queueNameStore = queueNameStore
        self.queueMetadataStore = queueMetadataStore
        self.profiles = profileStore.load()
        self.snapshots = snapshotStore.load()
    }

    var canGoToPreviousRunPage: Bool {
        runPage > 0
    }

    var canGoToNextRunPage: Bool {
        (runPage + 1) * runPageSize < runTotal
    }

    var runPageRangeText: String {
        guard runTotal > 0 else { return "0 loaded" }
        let start = runPage * runPageSize + 1
        let end = min((runPage + 1) * runPageSize, runTotal)
        if runTotal > end, selectedState == nil {
            return "\(start)-\(end) of many"
        }
        return "\(start)-\(end) of \(runTotal)"
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
                scheduleRefresh(for: selectedView)
            } else {
                statusMessage = "Connected. Add a BullMQ queue by name."
            }
        }
    }

    func disconnect() async {
        refreshRequestID += 1
        refreshTask?.cancel()
        refreshTask = nil
        await engine.disconnect()
        isConnected = false
        statusMessage = "Not connected"
        queues = []
        jobs = []
        runPage = 0
        runTotal = 0
        selectedState = nil
        selectedQueue = nil
        selectedJob = nil
        selectedJobDetail = nil
        activeLoadingPhases = []
        jobsByQuery = [:]
        runTotalsByQuery = [:]
        workersByQueue = [:]
        schedulersByQueue = [:]
        loadingPhaseCounts = [:]
        lastSnapshotCountsByQueue = [:]
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

    func selectQueue(_ queue: QueueSummary) {
        selectedQueue = queue
        selectedState = nil
        selectedJob = nil
        selectedJobDetail = nil
        runPage = 0
        applyCachedPanelData(for: queue.name)
        scheduleRefresh(for: selectedView)
    }

    func selectWorkspaceView(_ view: QueueWorkspaceView) {
        selectedView = view
        selectedJob = nil
        selectedJobDetail = nil
        if view == .runs, let selectedQueue {
            applyCachedRuns(for: selectedQueue.name)
        } else if let selectedQueue {
            applyCachedPanelData(for: selectedQueue.name)
        }
        scheduleRefresh(for: view)
    }

    func addManualQueue(named rawName: String, displayName rawDisplayName: String? = nil) async {
        let name = normalizedManualQueueName(rawName)
        guard !name.isEmpty else { return }
        let displayName = normalizedManualQueueDisplayName(rawDisplayName)

        await runLoading(.overview) {
            statusMessage = "Loading queue \(name)…"
            var overview = try await engine.getQueueOverview(queueName: name, prefix: prefix)
            overview.displayName = displayName
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
            runPage = 0
            persistCurrentQueueNames()
            persistCurrentQueueMetadata()
            applyCachedPanelData(for: name)
            scheduleRefresh(for: selectedView)
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
        runPage = 0
        if let selectedQueue {
            applyCachedRuns(for: selectedQueue.name)
        }
        scheduleRefresh(for: .runs)
    }

    func goToPreviousRunPage() {
        guard canGoToPreviousRunPage else { return }
        runPage -= 1
        selectedJob = nil
        selectedJobDetail = nil
        if let selectedQueue {
            applyCachedRuns(for: selectedQueue.name)
        }
        scheduleRefresh(for: .runs)
    }

    func goToNextRunPage() {
        guard canGoToNextRunPage else { return }
        runPage += 1
        selectedJob = nil
        selectedJobDetail = nil
        if let selectedQueue {
            applyCachedRuns(for: selectedQueue.name)
        }
        scheduleRefresh(for: .runs)
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
        try Task.checkCancellation()
        guard isCurrentRefresh(requestID, queueName: queueName) else { return }
        var updatedOverview = overview
        updatedOverview.displayName = overview.displayName ?? selectedQueue.displayName
        replaceQueue(updatedOverview)
        persistCurrentQueueMetadata()
        self.selectedQueue = updatedOverview

        switch view {
        case .overview:
            recordSnapshot(queueName: queueName, counts: updatedOverview.counts)
            statusMessage = "Refreshed \(queueName)"
        case .runs:
            statusMessage = "Loading \(queueName) runs…"
            let loadedPage = try await loadJobs(queueName: queueName)
            try Task.checkCancellation()
            guard isCurrentRefresh(requestID, queueName: queueName) else { return }
            let queryKey = runCacheKey(queueName)
            jobsByQuery[queryKey] = loadedPage.jobs
            runTotalsByQuery[queryKey] = loadedPage.total
            jobs = loadedPage.jobs
            runTotal = loadedPage.total
            statusMessage = "Loaded \(loadedPage.jobs.count) runs for \(queueName)"
        case .workers:
            statusMessage = "Loading \(queueName) workers…"
            let loadedWorkers = try await engine.getWorkers(queueName: queueName, prefix: prefix)
            try Task.checkCancellation()
            guard isCurrentRefresh(requestID, queueName: queueName) else { return }
            workersByQueue[cacheKey(queueName)] = loadedWorkers
            workers = loadedWorkers
            statusMessage = "Loaded \(loadedWorkers.count) workers for \(queueName)"
        case .schedulers:
            statusMessage = "Loading \(queueName) schedulers…"
            let loadedSchedulers = try await engine.getSchedulers(queueName: queueName, prefix: prefix)
            try Task.checkCancellation()
            guard isCurrentRefresh(requestID, queueName: queueName) else { return }
            schedulersByQueue[cacheKey(queueName)] = loadedSchedulers
            schedulers = loadedSchedulers
            statusMessage = "Loaded \(loadedSchedulers.count) schedulers for \(queueName)"
        case .metrics:
            recordSnapshot(queueName: queueName, counts: updatedOverview.counts)
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
            try Task.checkCancellation()
            guard self.selectedJob?.id == jobID else { return }
            selectedJobDetail = detail
        }
    }

    private func loadJobs(queueName: String) async throws -> JobPage {
        if let selectedState {
            let page = try await engine.getJobs(
                queueName: queueName,
                prefix: prefix,
                state: selectedState,
                page: runPage,
                pageSize: runPageSize
            )
            return page
        }

        let fetchLimit = (runPage + 1) * runPageSize + 1
        let jobs = try await engine.getRecentJobs(
            queueName: queueName,
            prefix: prefix,
            states: BullMQState.allCases,
            perStateLimit: fetchLimit,
            totalLimit: fetchLimit
        )
        let pageStart = runPage * runPageSize
        let pageEnd = min(pageStart + runPageSize, jobs.count)
        let pageJobs = pageStart < jobs.count ? Array(jobs[pageStart..<pageEnd]) : []
        let total = jobs.count > pageEnd ? pageEnd + 1 : jobs.count
        return JobPage(jobs: pageJobs, total: total, page: runPage, pageSize: runPageSize)
    }

    private func replaceQueue(_ queue: QueueSummary) {
        var queue = queue
        if let index = queues.firstIndex(where: { $0.name == queue.name }) {
            queue.displayName = queue.displayName ?? queues[index].displayName
            queues[index] = queue
        } else {
            queues.append(queue)
            queues.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    private func loadSavedQueues(for config: RedisConnectionConfig) {
        let scope = queueScope(for: config)
        let cachedQueues = queueMetadataStore.load(scope: scope)
        let names = queueNameStore.load(scope: scope)
        guard !cachedQueues.isEmpty || !names.isEmpty else { return }
        if cachedQueues.isEmpty {
            queues = names.map {
                QueueSummary(name: $0, prefix: config.prefix, counts: .empty, health: .unknown)
            }
        } else {
            queues = cachedQueues
        }
        if selectedQueue == nil {
            selectedQueue = queues.first
            selectedState = nil
        }
        if let selectedQueue {
            applyCachedPanelData(for: selectedQueue.name)
        }
        statusMessage = "Loaded \(queues.count) cached queues"
    }

    private func resetQueueStateForNewConnection() {
        refreshRequestID += 1
        queues = []
        jobs = []
        runPage = 0
        runTotal = 0
        workers = []
        schedulers = []
        selectedQueue = nil
        selectedState = nil
        selectedJob = nil
        selectedJobDetail = nil
        jobsByQuery = [:]
        runTotalsByQuery = [:]
        workersByQueue = [:]
        schedulersByQueue = [:]
    }

    private func persistCurrentQueueNames() {
        guard let config else { return }
        queueNameStore.save(queues.map(\.name), scope: queueScope(for: config))
    }

    private func persistCurrentQueueMetadata() {
        guard let config else { return }
        queueMetadataStore.save(queues, scope: queueScope(for: config))
    }

    private func queueScope(for config: RedisConnectionConfig) -> String {
        "\(config.host):\(config.port)/\(config.database):\(config.prefix)"
    }

    private func cacheKey(_ queueName: String) -> String {
        "\(prefix):\(queueName)"
    }

    private func runCacheKey(_ queueName: String) -> String {
        let stateKey = selectedState?.rawValue ?? "all"
        return "\(cacheKey(queueName)):runs:\(stateKey):\(runPage)"
    }

    private func applyCachedPanelData(for queueName: String) {
        let key = cacheKey(queueName)
        applyCachedRuns(for: queueName)
        workers = workersByQueue[key] ?? []
        schedulers = schedulersByQueue[key] ?? []
    }

    private func applyCachedRuns(for queueName: String) {
        let key = runCacheKey(queueName)
        jobs = jobsByQuery[key] ?? []
        runTotal = runTotalsByQuery[key] ?? 0
    }

    private func recordSnapshot(queueName: String, counts: QueueCounts) {
        guard lastSnapshotCountsByQueue[queueName] != counts else { return }
        lastSnapshotCountsByQueue[queueName] = counts
        let snapshot = QueueMetricSnapshot(
            queueName: queueName,
            capturedAt: Date(),
            counts: QueueCountsSnapshot(counts: counts)
        )
        snapshotStore.append(snapshot)
        snapshots = snapshotStore.load()
    }

    private func scheduleRefresh(for view: QueueWorkspaceView) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            await self?.refreshSelectedQueue(for: view)
        }
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

    private func normalizedManualQueueDisplayName(_ rawName: String?) -> String? {
        let name = rawName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? nil : name
    }

    private func runLoading(_ phase: LoadingPhase, _ operation: () async throws -> Void) async {
        beginLoading(phase)
        lastError = nil
        defer { endLoading(phase) }
        do {
            try await operation()
        } catch is CancellationError {
            return
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
