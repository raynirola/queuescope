import Foundation

enum LoadingPhase: String, Hashable {
    case connecting
    case overview
    case runs
    case workers
    case schedulers
    case metrics
    case jobDetail
    case jobAction
}

enum JobActionKind: String, Sendable {
    case retry
    case remove
    case promote
    case duplicate
    case add
    case pause
    case resume
}

struct JobDuplicateDraft: Equatable, Sendable {
    var name: String
    var dataJSON: String
    var optionsJSON: String
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
    @Published var selectedJobIDs: Set<String> = []
    @Published private(set) var inspectorRevision = 0
    @Published var selectedJobDetail: JobDetail? {
        didSet { if selectedJobDetail != nil { inspectorRevision += 1 } }
    }
    var inspectedJobKey: String? {
        selectedJobDetail.map { "\(selectedJobPrefix ?? activePrefix):\($0.queueName):\($0.id)" }
    }
    @Published var selectedJobLogs: JobLogs = .empty
    @Published var isLoadingSelectedJobLogs = false
    @Published var isStreamingSelectedJobLogs = false
    @Published var activeJobAction: JobActionKind?
    @Published var workers: [WorkerSummary] = []
    @Published var schedulers: [SchedulerSummary] = []
    @Published var metricTimingJobs: [JobSummary] = []
    @Published var snapshots: [QueueMetricSnapshot] = []
    @Published var isConnected = false
    @Published var activeLoadingPhases: Set<LoadingPhase> = []
    @Published var statusMessage = "Not connected"
    @Published var lastError: String?

    @Published var connectionReadOnly = false
    @Published var refreshInterval = 15
    @Published var lastRefreshedAt: Date?
    @Published var lastRefreshError: String?
    @Published var jobFilter = JobFilter()
    @Published private(set) var appliedJobFilter: JobFilter?
    @Published private(set) var searchCursor: JobSearchCursor?
    @Published private(set) var searchedJobCount = 0
    @Published private(set) var discoveryCursor = "0"
    @Published private(set) var hasDiscoveredQueues = false
    @Published var lookupJobID = ""
    @Published var flowJobID = ""
    @Published private(set) var jobFlow = JobFlow()
    private var flowReference: JobReference?
    private var selectedJobPrefix: String?
    private var inspectionRequestID = 0
    var isReadOnly: Bool { activeConnection?.isReadOnly ?? false }
    var canWrite: Bool { (activeConnection == nil || isConnected) && !isReadOnly && (selectedJobPrefix == nil || selectedJobPrefix == activePrefix) }

    func discoverMoreQueues() async {
        guard isConnected, !isLoading else { return }
        let generation = connectionGeneration
        await runLoading(.overview) {
            var cursor = discoveryCursor
            var names: Set<String> = []
            for _ in 0..<10 {
                let page = try await engine.discoverQueues(prefix: activePrefix, cursor: cursor)
                guard generation == connectionGeneration else { return }
                names.formUnion(page.names)
                cursor = page.nextCursor
                if cursor == "0" { break }
            }
            for name in names where !queues.contains(where: { $0.name == name }) {
                queues.append(QueueSummary(name: name, prefix: activePrefix, counts: .empty, health: .unknown))
            }
            queues.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            discoveryCursor = cursor
            hasDiscoveredQueues = true
            persistCurrentQueueNames()
            persistCurrentQueueMetadata()
            statusMessage = "Found \(names.count) queues. " + (cursor == "0" ? "Scan complete." : "More keys remain; scan more to continue.")
        }
    }

    func setRefreshInterval(_ seconds: Int) {
        guard [0, 5, 15, 30, 60].contains(seconds) else { return }
        refreshInterval = seconds
        persistCurrentWorkspacePreference()
    }

    func refreshAutomatically() async {
        guard isConnected, selectedQueue != nil, appliedJobFilter == nil, !isLoading, lastRefreshError == nil, refreshInterval > 0 else { return }
        await refreshSelectedQueue()
    }

    func applyJobSearch() async {
        guard jobFilter.createdAfter == nil || jobFilter.createdBefore == nil || jobFilter.createdAfter! <= jobFilter.createdBefore! else {
            lastError = "The start date must be before the end date."; return
        }
        appliedJobFilter = jobFilter.isEmpty ? nil : jobFilter
        runPage = 0
        searchCursor = nil
        searchedJobCount = 0
        resetSelectedJob()
        clearSelectedJobSelection()
        await refreshSelectedQueue(for: .runs)
    }

    func loadMoreSearchResults() async {
        guard !isLoading, let queue = selectedQueue, let filter = appliedJobFilter, let cursor = searchCursor else { return }
        let generation = connectionGeneration
        let requestID = refreshRequestID
        let state = selectedState
        await runLoading(.runs) {
            let result = try await engine.searchJobs(queueName: queue.name, prefix: activePrefix, state: state, filter: filter, cursor: cursor)
            guard generation == connectionGeneration, selectedState == state, appliedJobFilter == filter, isCurrentRefresh(requestID, queueName: queue.name) else { return }
            var ids = Set(jobs.map(\.id))
            jobs.append(contentsOf: result.jobs.filter { ids.insert($0.id).inserted })
            searchCursor = result.next
            searchedJobCount += result.scanned
            runTotal = jobs.count
        }
    }

    func inspectJob(_ reference: JobReference? = nil) async {
        guard let queue = selectedQueue else { return }
        let ref = reference ?? JobReference(prefix: activePrefix, queue: queue.name, jobID: lookupJobID.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !ref.jobID.isEmpty else { return }
        let generation = connectionGeneration
        resetSelectedJob()
        let inspection = inspectionRequestID
        await runLoading(.jobDetail) {
            let found = try await engine.findJob(queueName: ref.queue, prefix: ref.prefix, jobID: ref.jobID)
            guard generation == connectionGeneration, inspection == inspectionRequestID else { return }
            guard let job = found else {
                throw BullMQDashboardError.redis("Job \(ref.jobID) was not found in \(ref.queue).")
            }
            let detail = try await engine.getJobDetail(queueName: ref.queue, prefix: ref.prefix, jobID: ref.jobID, state: job.state)
            guard generation == connectionGeneration, inspection == inspectionRequestID else { return }
            selectedJobPrefix = ref.prefix
            selectedJob = job
            selectedJobDetail = detail
        }
    }

    func loadFlow(showGraph: Bool = true) async {
        guard let queue = selectedQueue else { return }
        let ref: JobReference
        if let job = selectedJob {
            ref = JobReference(prefix: selectedJobPrefix ?? activePrefix, queue: job.queueName, jobID: job.id)
        } else {
            ref = JobReference(prefix: activePrefix, queue: queue.name, jobID: flowJobID.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard !ref.jobID.isEmpty else { return }
        flowReference = ref
        jobFlow = JobFlow()
        lastRefreshedAt = nil
        lastRefreshError = nil
        flowJobID = ref.jobID
        if showGraph { selectedView = .flowGraph; selectedJobDetail = nil; persistCurrentWorkspacePreference() }
        let generation = connectionGeneration
        await runLoading(.overview) {
            do {
                let flow = try await engine.getJobFlow(ref)
                guard generation == connectionGeneration, flowReference == ref else { return }
                jobFlow = flow
                lastRefreshedAt = Date()
            } catch {
                guard generation == connectionGeneration, flowReference == ref else { return }
                lastRefreshError = error.localizedDescription
                throw error
            }
        }
    }

    func setSelectedQueuePaused(_ paused: Bool) async {
        guard let queue = selectedQueue, !isReadOnly, activeJobAction == nil else { return }
        await performJobAction(paused ? .pause : .resume, queueName: queue.name) {
            try await engine.setQueuePaused(queueName: queue.name, prefix: activePrefix, paused: paused)
            return paused ? "Queue paused. Active jobs will finish." : "Queue resumed."
        }
    }

    var isLoading: Bool {
        !activeLoadingPhases.isEmpty
    }

    private let engine: BullMQEngine
    private let profileStore: ConnectionProfileStore
    private let snapshotStore: MetricSnapshotStore
    private let queueNameStore: QueueNameStore
    private let queueMetadataStore: QueueMetadataStore
    private let workspacePreferenceStore: QueueWorkspacePreferenceStore
    @Published private(set) var activeConnection: RedisConnectionConfig?
    var activePrefix: String { activeConnection?.prefix ?? prefix }
    private let runPageSize = 10
    private var refreshRequestID = 0
    private var connectionGeneration = 0
    private var jobsByQuery: [String: [JobSummary]] = [:]
    private var runTotalsByQuery: [String: Int] = [:]
    private var workersByQueue: [String: [WorkerSummary]] = [:]
    private var schedulersByQueue: [String: [SchedulerSummary]] = [:]
    private var metricTimingJobsByQueue: [String: [JobSummary]] = [:]
    private var loadingPhaseCounts: [LoadingPhase: Int] = [:]
    private var refreshTask: Task<Void, Never>?
    private var selectedJobDetailTask: Task<Void, Never>?
    private var selectedJobLogTask: Task<Void, Never>?
    private var lastSnapshotCountsByQueue: [String: QueueCounts] = [:]
    private var lastSnapshotNativeMetricsByQueue: [String: BullMQNativeMetrics] = [:]
    private let activeJobLogRefreshInterval: UInt64 = 2_000_000_000
    private let jobLogPageSize = 50

    init(
        engine: BullMQEngine = BullMQRedisEngine(),
        profileStore: ConnectionProfileStore = ConnectionProfileStore(),
        snapshotStore: MetricSnapshotStore = MetricSnapshotStore(),
        queueNameStore: QueueNameStore = QueueNameStore(),
        queueMetadataStore: QueueMetadataStore = QueueMetadataStore(),
        workspacePreferenceStore: QueueWorkspacePreferenceStore = QueueWorkspacePreferenceStore()
    ) {
        self.engine = engine
        self.profileStore = profileStore
        self.snapshotStore = snapshotStore
        self.queueNameStore = queueNameStore
        self.queueMetadataStore = queueMetadataStore
        self.workspacePreferenceStore = workspacePreferenceStore
        do { self.profiles = try profileStore.load() }
        catch { self.lastError = error.localizedDescription }
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

    var selectedVisibleJobCount: Int {
        jobs.filter { selectedJobIDs.contains($0.id) }.count
    }

    var allVisibleJobsSelected: Bool {
        !jobs.isEmpty && selectedVisibleJobCount == jobs.count
    }

    var selectedBulkRetryCount: Int {
        selectedVisibleJobs.filter(Self.canRetry).count
    }

    var selectedBulkPromoteCount: Int {
        selectedVisibleJobs.filter(Self.canPromote).count
    }

    var selectedBulkRemoveCount: Int {
        selectedVisibleJobs.filter(Self.canRemove).count
    }

    private var selectedVisibleJobs: [JobSummary] {
        jobs.filter { selectedJobIDs.contains($0.id) }
    }

    func connect() async {
        guard !activeLoadingPhases.contains(.connecting), activeJobAction == nil else { return }
        let requestedURL = redisURL
        let requestedPrefix = prefix
        let requestedName = connectionProfileName
        let requestedReadOnly = connectionReadOnly
        await runLoading(.connecting) {
            isConnected = false
            activeConnection = nil
            resetQueueStateForNewConnection()
            await engine.disconnect()
            var parsed = try RedisURLParser.parse(requestedURL, defaultName: requestedName, prefix: requestedPrefix)
            parsed.isReadOnly = requestedReadOnly
            statusMessage = "Connecting to \(parsed.host):\(parsed.port)…"
            try await engine.connect(parsed)
            activeConnection = parsed
            do { snapshots = try snapshotStore.load(scope: queueScope(for: parsed)) }
            catch { lastError = "Could not load metric history: \(error.localizedDescription)" }
            isConnected = true
            statusMessage = "Connected to \(parsed.host):\(parsed.port)"
            loadSavedQueues(for: parsed)
            if selectedQueue != nil {
                scheduleRefresh(for: selectedView)
            } else {
                statusMessage = "Connected. Discover queues or add one by name."
            }
        }
    }

    func disconnect() async {
        guard !activeLoadingPhases.contains(.connecting), activeJobAction == nil else { return }
        await runLoading(.connecting) {
            isConnected = false
            activeConnection = nil
            resetQueueStateForNewConnection()
            await engine.disconnect()
            statusMessage = "Not connected"
        }
    }

    func saveCurrentProfile() {
        do {
            let parsed = try RedisURLParser.parse(redisURL, prefix: prefix)
            let profile = RedisConnectionProfile(
                name: connectionProfileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? parsed.name : connectionProfileName.trimmingCharacters(in: .whitespacesAndNewlines),
                tag: connectionProfileTag,
                redisURL: redisURL,
                prefix: parsed.prefix,
                isReadOnly: connectionReadOnly
            )
            let savedProfiles = try profileStore.load()
            try profileStore.save(savedProfiles + [profile])
            profiles = savedProfiles + [profile]
            statusMessage = "Saved \(profile.name)"
        } catch {
            lastError = error.localizedDescription
        }
    }

    func connect(profile: RedisConnectionProfile) async {
        guard !activeLoadingPhases.contains(.connecting), activeJobAction == nil else { return }
        guard !profile.credentialsInKeychain else {
            lastError = "Credentials for \(profile.name) are missing from Keychain. Remove this profile and save it again with its complete Redis URL."
            return
        }
        connectionReadOnly = profile.isReadOnly
        redisURL = profile.redisURL
        prefix = profile.prefix
        connectionProfileName = profile.name
        connectionProfileTag = profile.tag
        await connect()
        if isConnected {
            activeConnection?.profileID = profile.id
            profileStore.saveLastActiveProfileID(profile.id)
        }
    }

    func connectToLastActiveProfileIfAvailable() async -> Bool {
        guard !isConnected, let profile = lastActiveProfile() else { return false }
        statusMessage = "Connecting to \(profile.name)…"
        await connect(profile: profile)
        if !isConnected {
            statusMessage = "Not connected"
            profileStore.clearLastActiveProfileID()
        }
        return isConnected
    }

    func deleteProfile(_ profile: RedisConnectionProfile) {
        do { try profileStore.delete(profile) }
        catch { lastError = error.localizedDescription; return }
        profiles.removeAll { $0.id == profile.id }
        if profileStore.loadLastActiveProfileID() == profile.id {
            if let replacementProfile = profiles.last {
                profileStore.saveLastActiveProfileID(replacementProfile.id)
            } else {
                profileStore.clearLastActiveProfileID()
            }
        }
    }

    func selectQueue(_ queue: QueueSummary) {
        appliedJobFilter = nil
        jobFilter = JobFilter()
        jobFlow = JobFlow()
        flowReference = nil
        flowJobID = ""
        lastRefreshedAt = nil
        lastRefreshError = nil
        selectedQueue = queue
        selectedState = nil
        resetSelectedJob()
        clearSelectedJobSelection()
        runPage = 0
        applyCachedPanelData(for: queue.name)
        persistCurrentWorkspacePreference()
        scheduleRefresh(for: selectedView)
    }

    func selectWorkspaceView(_ view: QueueWorkspaceView) {
        lastRefreshedAt = nil
        lastRefreshError = nil
        selectedView = view
        resetSelectedJob()
        clearSelectedJobSelection()
        if view == .runs, let selectedQueue {
            applyCachedRuns(for: selectedQueue.name)
        } else if let selectedQueue {
            applyCachedPanelData(for: selectedQueue.name)
        }
        persistCurrentWorkspacePreference()
        scheduleRefresh(for: view)
    }

    func addManualQueue(named rawName: String, displayName rawDisplayName: String? = nil) async {
        let name = normalizedManualQueueName(rawName)
        guard !name.isEmpty else { return }
        let displayName = normalizedManualQueueDisplayName(rawDisplayName)

        guard !activeLoadingPhases.contains(.connecting) else { return }
        let generation = connectionGeneration
        await runLoading(.overview) {
            statusMessage = "Loading queue \(name)…"
            var overview = try await engine.getQueueOverview(queueName: name, prefix: activePrefix)
            guard generation == connectionGeneration else { return }
            overview.displayName = displayName
            if let index = queues.firstIndex(where: { $0.name == name }) {
                queues[index] = overview
            } else {
                queues.append(overview)
                queues.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            }
            selectedQueue = overview
            selectedState = nil
            resetSelectedJob()
            clearSelectedJobSelection()
            runPage = 0
            persistCurrentQueueNames()
            persistCurrentQueueMetadata()
            persistCurrentWorkspacePreference()
            applyCachedPanelData(for: name)
            scheduleRefresh(for: selectedView)
        }
    }

    func removeQueue(_ queue: QueueSummary) {
        removeQueue(named: queue.name)
    }

    func removeQueue(named queueName: String) {
        guard queues.contains(where: { $0.name == queueName }) else { return }
        let queueCacheKey = cacheKey(queueName)
        queues.removeAll { $0.name == queueName }

        jobsByQuery = jobsByQuery.filter { query, _ in !query.hasPrefix("\(queueCacheKey):runs:") }
        runTotalsByQuery = runTotalsByQuery.filter { query, _ in !query.hasPrefix("\(queueCacheKey):runs:") }
        workersByQueue[queueCacheKey] = nil
        schedulersByQueue[queueCacheKey] = nil
        metricTimingJobsByQueue[queueCacheKey] = nil
        lastSnapshotCountsByQueue[queueName] = nil
        lastSnapshotNativeMetricsByQueue[queueName] = nil

        if selectedQueue?.name == queueName {
            selectedQueue = queues.first
            selectedState = nil
            resetSelectedJob()
            clearSelectedJobSelection()
            jobs = []
            runPage = 0
            runTotal = 0
            workers = []
            schedulers = []
            metricTimingJobs = []
            if let selectedQueue {
                applyCachedPanelData(for: selectedQueue.name)
                scheduleRefresh(for: selectedView)
            }
            persistCurrentWorkspacePreference()
        }

        persistCurrentQueueNames()
        persistCurrentQueueMetadata()
    }

    func assignQueue(_ queue: QueueSummary, toGroup rawGroupName: String?) {
        assignQueue(named: queue.name, toGroup: rawGroupName)
    }

    func assignQueue(named queueName: String, toGroup rawGroupName: String?) {
        let groupName = normalizedQueueGroupName(rawGroupName)
        guard let index = queues.firstIndex(where: { $0.name == queueName }) else { return }
        queues[index].groupName = groupName
        if selectedQueue?.name == queueName {
            selectedQueue = queues[index]
        }
        persistCurrentQueueMetadata()
    }

    func assignQueues(named queueNames: [String], toGroup rawGroupName: String?) {
        let groupName = normalizedQueueGroupName(rawGroupName)
        let queueNameSet = Set(queueNames)
        guard !queueNameSet.isEmpty else { return }
        var changed = false
        for index in queues.indices where queueNameSet.contains(queues[index].name) {
            queues[index].groupName = groupName
            changed = true
        }
        if let selectedQueue, queueNameSet.contains(selectedQueue.name),
           let updatedQueue = queues.first(where: { $0.name == selectedQueue.name }) {
            self.selectedQueue = updatedQueue
        }
        if changed {
            persistCurrentQueueMetadata()
        }
    }

    func refreshSelectedQueue() async {
        await refreshSelectedQueue(for: selectedView)
    }

    func refreshSelectedQueue(for view: QueueWorkspaceView) async {
        let requestID = nextRefreshRequestID()
        await runLoading(loadingPhase(for: view)) {
            do {
                try await refreshSelectedQueueThrowing(for: view, requestID: requestID)
                if requestID == refreshRequestID { lastRefreshedAt = Date(); lastRefreshError = nil }
            } catch {
                if requestID == refreshRequestID, !(error is CancellationError) { lastRefreshError = error.localizedDescription }
                throw error
            }
        }
    }

    func selectState(_ state: BullMQState) {
        selectedState = selectedState == state ? nil : state
        selectedView = .runs
        resetSelectedJob()
        clearSelectedJobSelection()
        runPage = 0
        if let selectedQueue {
            applyCachedRuns(for: selectedQueue.name)
        }
        persistCurrentWorkspacePreference()
        scheduleRefresh(for: .runs)
    }

    func goToPreviousRunPage() {
        guard canGoToPreviousRunPage else { return }
        runPage -= 1
        resetSelectedJob()
        clearSelectedJobSelection()
        if let selectedQueue {
            applyCachedRuns(for: selectedQueue.name)
        }
        scheduleRefresh(for: .runs)
    }

    func goToNextRunPage() {
        guard canGoToNextRunPage else { return }
        runPage += 1
        resetSelectedJob()
        clearSelectedJobSelection()
        if let selectedQueue {
            applyCachedRuns(for: selectedQueue.name)
        }
        scheduleRefresh(for: .runs)
    }

    func selectJob(_ job: JobSummary) {
        inspectionRequestID += 1
        selectedJobPrefix = nil
        selectedJobDetailTask?.cancel()
        selectedJobLogTask?.cancel()
        selectedJob = job
        selectedJobDetail = nil
        selectedJobLogs = .empty
        isLoadingSelectedJobLogs = false
        isStreamingSelectedJobLogs = false
        selectedJobDetailTask = Task { [weak self] in
            await self?.loadSelectedJobDetail()
        }
    }

    func clearSelectedJob() {
        resetSelectedJob()
    }

    func isJobSelectedForBulk(_ job: JobSummary) -> Bool {
        selectedJobIDs.contains(job.id)
    }

    func toggleJobSelection(_ job: JobSummary) {
        if selectedJobIDs.contains(job.id) {
            selectedJobIDs.remove(job.id)
        } else {
            selectedJobIDs.insert(job.id)
        }
    }

    func toggleAllVisibleJobSelection() {
        if allVisibleJobsSelected {
            selectedJobIDs.removeAll()
        } else {
            selectedJobIDs = Set(jobs.map(\.id))
        }
    }

    func clearSelectedJobSelection() {
        selectedJobIDs.removeAll()
    }

    func showSelectedJobLogs() {
        selectedJobLogTask?.cancel()
        selectedJobLogTask = Task { [weak self] in
            guard let self else { return }
            await self.loadSelectedJobLogs(streamIfActive: self.selectedJob?.state == .active)
        }
    }

    func stopSelectedJobLogStreaming() {
        selectedJobLogTask?.cancel()
        selectedJobLogTask = nil
        isStreamingSelectedJobLogs = false
    }

    func loadOlderSelectedJobLogs() {
        guard !isLoadingSelectedJobLogs, let firstLogID = selectedJobLogs.entries.first?.id, firstLogID > 1 else { return }
        selectedJobLogTask?.cancel()
        selectedJobLogTask = Task { [weak self] in
            guard let self else { return }
            let shouldResumeStreaming = self.selectedJob?.state == .active
            await self.loadOlderSelectedJobLogs(before: firstLogID)
            if shouldResumeStreaming {
                await self.loadSelectedJobLogs(streamIfActive: true)
            }
        }
    }

    func retrySelectedJob() {
        guard let selectedJob else { return }
        Task { [weak self] in
            await self?.retryJob(selectedJob)
        }
    }

    func removeSelectedJob(removeChildren: Bool = true) {
        guard let selectedJob else { return }
        Task { [weak self] in
            await self?.removeJob(selectedJob, removeChildren: removeChildren)
        }
    }

    func promoteSelectedJob() {
        guard let selectedJob else { return }
        Task { [weak self] in
            await self?.promoteJob(selectedJob)
        }
    }

    func duplicateSelectedJob(from draft: JobDuplicateDraft) {
        guard let selectedQueue else { return }
        Task { [weak self] in
            await self?.duplicateJob(queueName: selectedQueue.name, draft: draft)
        }
    }

    func retrySelectedJobs() {
        let jobs = selectedVisibleJobs.filter(Self.canRetry)
        Task { [weak self] in
            await self?.retryJobs(jobs)
        }
    }

    func removeSelectedJobs(removeChildren: Bool = true) {
        let jobs = selectedVisibleJobs.filter(Self.canRemove)
        Task { [weak self] in
            await self?.removeJobs(jobs, removeChildren: removeChildren)
        }
    }

    func promoteSelectedJobs() {
        let jobs = selectedVisibleJobs.filter(Self.canPromote)
        Task { [weak self] in
            await self?.promoteJobs(jobs)
        }
    }

    func addJob(to queueName: String, draft: JobDuplicateDraft) {
        Task { [weak self] in
            await self?.addJob(queueName: queueName, draft: draft)
        }
    }

    func retryJob(_ job: JobSummary) async {
        guard Self.canRetry(job) else { return }
        await performJobAction(.retry, job: job) {
            try await engine.retryJob(queueName: job.queueName, prefix: selectedJobPrefix ?? activePrefix, jobID: job.id, state: job.state)
            return "Retried job \(job.id)"
        }
    }

    func removeJob(_ job: JobSummary, removeChildren: Bool = true) async {
        guard Self.canRemove(job) else { return }
        await performJobAction(.remove, job: job, clearsSelection: true) {
            try await engine.removeJob(queueName: job.queueName, prefix: selectedJobPrefix ?? activePrefix, jobID: job.id, removeChildren: removeChildren)
            return "Removed job \(job.id)"
        }
    }

    func promoteJob(_ job: JobSummary) async {
        guard Self.canPromote(job) else { return }
        await performJobAction(.promote, job: job) {
            try await engine.promoteJob(queueName: job.queueName, prefix: selectedJobPrefix ?? activePrefix, jobID: job.id)
            return "Promoted job \(job.id)"
        }
    }

    func duplicateJob(queueName: String, draft: JobDuplicateDraft) async {
        await performJobAction(.duplicate, queueName: queueName) {
            let data = try Self.parseDuplicateJSON(draft.dataJSON, label: "Data")
            let options = try Self.parseDuplicateJSON(draft.optionsJSON, label: "Options")
            let jobID = try await engine.duplicateJob(
                queueName: queueName,
                prefix: activePrefix,
                name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
                data: data,
                options: options
            )
            return "Duplicated job \(jobID)"
        }
    }

    func addJob(queueName: String, draft: JobDuplicateDraft) async {
        await performJobAction(.add, queueName: queueName) {
            let data = try Self.parseDuplicateJSON(draft.dataJSON, label: "Data")
            let options = try Self.parseDuplicateJSON(draft.optionsJSON, label: "Options")
            let jobID = try await engine.addJob(
                queueName: queueName,
                prefix: activePrefix,
                name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
                data: data,
                options: options
            )
            return "Added job \(jobID)"
        }
    }

    func duplicateDraft(for detail: JobDetail) -> JobDuplicateDraft {
        Self.duplicateDraft(for: detail)
    }

    static func canRetry(_ job: JobSummary?) -> Bool {
        guard let job else { return false }
        return job.state == .failed || job.state == .completed
    }

    static func canPromote(_ job: JobSummary?) -> Bool {
        job?.state == .delayed
    }

    static func canRemove(_ job: JobSummary?) -> Bool {
        guard let job else { return false }
        return job.state != .active
    }

    static func duplicateDraft(for detail: JobDetail) -> JobDuplicateDraft {
        JobDuplicateDraft(
            name: detail.fields["name"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? detail.fields["name"]! : "(unnamed)",
            dataJSON: prettyDuplicateJSON(detail.fields["data"], fallback: "{}"),
            optionsJSON: duplicateOptionsJSON(detail.fields["opts"])
        )
    }

    static func parseDuplicateJSON(_ rawValue: String, label: String) throws -> AnySendableJSON {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw BullMQDashboardError.redis("\(label) must be valid JSON.")
        }
        do {
            let data = Data(trimmed.utf8)
            return AnySendableJSON(try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
        } catch {
            throw BullMQDashboardError.redis("\(label) must be valid JSON: \(error.localizedDescription)")
        }
    }

    private func refreshSelectedQueueThrowing(for view: QueueWorkspaceView, requestID: Int) async throws {
        guard let selectedQueue else { return }
        let queueName = selectedQueue.name
        statusMessage = "Loading \(queueName) overview…"
        let overview = try await engine.getQueueOverview(queueName: queueName, prefix: activePrefix)
        try Task.checkCancellation()
        guard isCurrentRefresh(requestID, queueName: queueName) else { return }
        var updatedOverview = overview
        updatedOverview.displayName = overview.displayName ?? selectedQueue.displayName
        updatedOverview.groupName = overview.groupName ?? selectedQueue.groupName
        replaceQueue(updatedOverview)
        persistCurrentQueueMetadata()
        self.selectedQueue = updatedOverview

        switch view {
        case .overview:
            let loadedSnapshots = try await engine.getMetrics(queueName: queueName, prefix: activePrefix)
            let timingJobs = try await loadMetricTimingJobs(queueName: queueName)
            try Task.checkCancellation()
            guard isCurrentRefresh(requestID, queueName: queueName) else { return }
            if let loadedSnapshot = loadedSnapshots.last {
                try recordSnapshot(queueName: queueName, counts: updatedOverview.counts, nativeMetrics: loadedSnapshot.nativeMetrics)
            } else {
                try recordSnapshot(queueName: queueName, counts: updatedOverview.counts)
            }
            metricTimingJobsByQueue[cacheKey(queueName)] = timingJobs
            metricTimingJobs = timingJobs
            statusMessage = "Refreshed \(queueName)"
        case .runs:
            statusMessage = "Loading \(queueName) runs…"
            let loadedPage = try await loadJobs(queueName: queueName)
            try Task.checkCancellation()
            guard isCurrentRefresh(requestID, queueName: queueName) else { return }
            let queryKey = runCacheKey(queueName)
            if appliedJobFilter == nil {
                jobsByQuery[queryKey] = loadedPage.jobs
                runTotalsByQuery[queryKey] = loadedPage.total
            }
            jobs = loadedPage.jobs
            runTotal = loadedPage.total
            pruneSelectedJobSelection()
            statusMessage = "Loaded \(loadedPage.jobs.count) runs for \(queueName)"
        case .workers:
            statusMessage = "Loading \(queueName) workers…"
            let loadedWorkers = try await engine.getWorkers(queueName: queueName, prefix: activePrefix)
            try Task.checkCancellation()
            guard isCurrentRefresh(requestID, queueName: queueName) else { return }
            workersByQueue[cacheKey(queueName)] = loadedWorkers
            workers = loadedWorkers
            statusMessage = "Loaded \(loadedWorkers.count) workers for \(queueName)"
        case .schedulers:
            statusMessage = "Loading \(queueName) schedulers…"
            let loadedSchedulers = try await engine.getSchedulers(queueName: queueName, prefix: activePrefix)
            try Task.checkCancellation()
            guard isCurrentRefresh(requestID, queueName: queueName) else { return }
            schedulersByQueue[cacheKey(queueName)] = loadedSchedulers
            schedulers = loadedSchedulers
            statusMessage = "Loaded \(loadedSchedulers.count) schedulers for \(queueName)"
        case .metrics:
            let loadedSnapshots = try await engine.getMetrics(queueName: queueName, prefix: activePrefix)
            let timingJobs = try await loadMetricTimingJobs(queueName: queueName)
            try Task.checkCancellation()
            guard isCurrentRefresh(requestID, queueName: queueName) else { return }
            if let loadedSnapshot = loadedSnapshots.last {
                try recordSnapshot(queueName: queueName, counts: updatedOverview.counts, nativeMetrics: loadedSnapshot.nativeMetrics)
            } else {
                try recordSnapshot(queueName: queueName, counts: updatedOverview.counts)
            }
            metricTimingJobsByQueue[cacheKey(queueName)] = timingJobs
            metricTimingJobs = timingJobs
            statusMessage = "Recorded \(queueName) metrics snapshot"
        case .flowGraph:
            if let ref = flowReference {
                let flow = try await engine.getJobFlow(ref)
                guard isCurrentRefresh(requestID, queueName: queueName) else { return }
                jobFlow = flow
            }
            statusMessage = "Refreshed \(queueName)"
        }
    }

    private func loadSelectedJobDetail() async {
        await runLoading(.jobDetail) {
            try await loadSelectedJobDetailThrowing()
        }
    }

    private func loadSelectedJobDetailThrowing() async throws {
        guard let selectedJob else { return }
        let jobID = selectedJob.id
        let inspection = inspectionRequestID
        let detail = try await engine.getJobDetail(
            queueName: selectedJob.queueName,
            prefix: selectedJobPrefix ?? activePrefix,
            jobID: selectedJob.id,
            state: selectedJob.state
        )
        try Task.checkCancellation()
        guard inspection == inspectionRequestID, self.selectedJob?.id == jobID, self.selectedJob?.queueName == selectedJob.queueName else { return }
        selectedJobDetail = detail
    }

    private func resetSelectedJob() {
        inspectionRequestID += 1
        selectedJobPrefix = nil
        selectedJobDetailTask?.cancel()
        selectedJobDetailTask = nil
        selectedJobLogTask?.cancel()
        selectedJobLogTask = nil
        selectedJob = nil
        selectedJobDetail = nil
        selectedJobLogs = .empty
        isLoadingSelectedJobLogs = false
        isStreamingSelectedJobLogs = false
    }

    private func loadSelectedJobLogs(streamIfActive: Bool) async {
        await loadLatestSelectedJobLogs(showLoading: true)
        guard streamIfActive else { return }

        isStreamingSelectedJobLogs = true
        defer { isStreamingSelectedJobLogs = false }

        while !Task.isCancelled, selectedJob?.state == .active, selectedJobDetail?.finishedOn == nil {
            do {
                try await Task.sleep(nanoseconds: activeJobLogRefreshInterval)
            } catch {
                return
            }
            await loadLatestSelectedJobLogs(showLoading: false)
        }
    }

    private func loadLatestSelectedJobLogs(showLoading: Bool) async {
        guard let selectedJob else { return }
        let jobID = selectedJob.id
        let inspection = inspectionRequestID
        if showLoading {
            isLoadingSelectedJobLogs = true
        }
        defer {
            if showLoading {
                isLoadingSelectedJobLogs = false
            }
        }

        do {
            let logs = try await engine.getJobLogs(
                queueName: selectedJob.queueName,
                prefix: selectedJobPrefix ?? activePrefix,
                jobID: selectedJob.id,
                start: nil,
                limit: jobLogPageSize
            )
            try Task.checkCancellation()
            guard inspection == inspectionRequestID, self.selectedJob?.id == jobID, self.selectedJob?.queueName == selectedJob.queueName else { return }
            let mergedLogs = mergeLogs(selectedJobLogs, with: logs)
            if mergedLogs != selectedJobLogs {
                selectedJobLogs = mergedLogs
            }
        } catch is CancellationError {
            return
        } catch {
            lastError = error.localizedDescription
            statusMessage = error.localizedDescription
        }
    }

    private func loadOlderSelectedJobLogs(before firstLogID: Int) async {
        guard let selectedJob else { return }
        let jobID = selectedJob.id
        let inspection = inspectionRequestID
        let start = max(0, firstLogID - jobLogPageSize - 1)
        isLoadingSelectedJobLogs = true
        defer { isLoadingSelectedJobLogs = false }

        do {
            let logs = try await engine.getJobLogs(
                queueName: selectedJob.queueName,
                prefix: selectedJobPrefix ?? activePrefix,
                jobID: selectedJob.id,
                start: start,
                limit: firstLogID - start - 1
            )
            try Task.checkCancellation()
            guard inspection == inspectionRequestID, self.selectedJob?.id == jobID, self.selectedJob?.queueName == selectedJob.queueName else { return }
            let mergedLogs = mergeLogs(selectedJobLogs, with: logs)
            if mergedLogs != selectedJobLogs {
                selectedJobLogs = mergedLogs
            }
        } catch is CancellationError {
            return
        } catch {
            lastError = error.localizedDescription
            statusMessage = error.localizedDescription
        }
    }

    private func performJobAction(
        _ action: JobActionKind,
        job: JobSummary,
        clearsSelection: Bool = false,
        operation: () async throws -> String
    ) async {
        guard canWrite, activeJobAction == nil else { return }
        beginLoading(.jobAction)
        activeJobAction = action
        lastError = nil
        defer {
            activeJobAction = nil
            endLoading(.jobAction)
        }

        do {
            let message = try await operation()
            try await refreshRunsAfterMutation(queueName: job.queueName)
            if clearsSelection {
                resetSelectedJob()
            } else if selectedJob?.id == job.id {
                try await reloadSelectedJobAfterMutation()
            }
            statusMessage = message
        } catch is CancellationError {
            return
        } catch {
            lastError = error.localizedDescription
            statusMessage = error.localizedDescription
        }
    }

    private func performJobAction(
        _ action: JobActionKind,
        queueName: String,
        operation: () async throws -> String
    ) async {
        guard canWrite, activeJobAction == nil else { return }
        beginLoading(.jobAction)
        activeJobAction = action
        lastError = nil
        defer {
            activeJobAction = nil
            endLoading(.jobAction)
        }

        do {
            let message = try await operation()
            try await refreshRunsAfterMutation(queueName: queueName)
            statusMessage = message
        } catch is CancellationError {
            return
        } catch {
            lastError = error.localizedDescription
            statusMessage = error.localizedDescription
        }
    }

    func retryJobs(_ jobs: [JobSummary]) async {
        await performBulkJobAction(.retry, jobs: jobs.filter(Self.canRetry)) { job in
            try await engine.retryJob(queueName: job.queueName, prefix: activePrefix, jobID: job.id, state: job.state)
        }
    }

    func removeJobs(_ jobs: [JobSummary], removeChildren: Bool) async {
        await performBulkJobAction(.remove, jobs: jobs.filter(Self.canRemove), clearsSelectedJob: true) { job in
            try await engine.removeJob(queueName: job.queueName, prefix: activePrefix, jobID: job.id, removeChildren: removeChildren)
        }
    }

    func promoteJobs(_ jobs: [JobSummary]) async {
        await performBulkJobAction(.promote, jobs: jobs.filter(Self.canPromote)) { job in
            try await engine.promoteJob(queueName: job.queueName, prefix: activePrefix, jobID: job.id)
        }
    }

    private func performBulkJobAction(
        _ action: JobActionKind,
        jobs: [JobSummary],
        clearsSelectedJob: Bool = false,
        operation: (JobSummary) async throws -> Void
    ) async {
        guard (activeConnection == nil || isConnected), !isReadOnly, activeJobAction == nil, let queueName = jobs.first?.queueName else { return }
        beginLoading(.jobAction)
        activeJobAction = action
        lastError = nil
        defer {
            activeJobAction = nil
            endLoading(.jobAction)
        }

        var succeededIDs: Set<String> = []
        var failures: [String] = []
        for job in jobs {
            do {
                try await operation(job)
                succeededIDs.insert(job.id)
            } catch is CancellationError {
                return
            } catch {
                failures.append("\(job.id): \(error.localizedDescription)")
            }
        }

        guard !succeededIDs.isEmpty else {
            if let firstFailure = failures.first {
                lastError = firstFailure
                statusMessage = firstFailure
            }
            return
        }

        do {
            try await refreshRunsAfterMutation(queueName: queueName)
            selectedJobIDs.subtract(succeededIDs)
            if clearsSelectedJob, let selectedJob, selectedJob.queueName == queueName, succeededIDs.contains(selectedJob.id) {
                resetSelectedJob()
            } else if let selectedJob, selectedJob.queueName == queueName, succeededIDs.contains(selectedJob.id) {
                try await reloadSelectedJobAfterMutation()
            }

            let actionName = bulkActionName(action)
            if let firstFailure = failures.first {
                let message = "\(succeededIDs.count) \(actionName), \(failures.count) failed. First failure: \(firstFailure)"
                lastError = message
                statusMessage = message
            } else {
                statusMessage = "\(actionName.capitalized) \(succeededIDs.count) jobs"
            }
        } catch is CancellationError {
            return
        } catch {
            lastError = error.localizedDescription
            statusMessage = error.localizedDescription
        }
    }

    private func refreshRunsAfterMutation(queueName: String) async throws {
        let overview = try await engine.getQueueOverview(queueName: queueName, prefix: activePrefix)
        var updatedOverview = overview
        updatedOverview.displayName = selectedQueue?.name == queueName ? selectedQueue?.displayName : overview.displayName
        updatedOverview.groupName = selectedQueue?.name == queueName ? selectedQueue?.groupName : overview.groupName
        replaceQueue(updatedOverview)
        if selectedQueue?.name == queueName {
            selectedQueue = updatedOverview
        }
        persistCurrentQueueMetadata()

        let loadedPage = try await loadJobs(queueName: queueName)
        let queryKey = runCacheKey(queueName)
        jobsByQuery[queryKey] = loadedPage.jobs
        runTotalsByQuery[queryKey] = loadedPage.total
        if selectedQueue?.name == queueName {
            jobs = loadedPage.jobs
            runTotal = loadedPage.total
            pruneSelectedJobSelection()
        }
    }

    private func pruneSelectedJobSelection() {
        selectedJobIDs.formIntersection(Set(jobs.map(\.id)))
    }

    private func bulkActionName(_ action: JobActionKind) -> String {
        switch action {
        case .retry: "retried"
        case .remove: "removed"
        case .promote: "promoted"
        case .duplicate: "duplicated"
        case .add: "added"
        case .pause: "paused"
        case .resume: "resumed"
        }
    }

    private func reloadSelectedJobAfterMutation() async throws {
        guard let selectedJob else { return }
        if let refreshedJob = jobs.first(where: { $0.id == selectedJob.id }) {
            self.selectedJob = refreshedJob
        }
        selectedJobDetail = try await engine.getJobDetail(
            queueName: selectedJob.queueName,
            prefix: selectedJobPrefix ?? activePrefix,
            jobID: selectedJob.id,
            state: selectedJob.state
        )
        selectedJobLogs = .empty
        stopSelectedJobLogStreaming()
    }

    private func mergeLogs(_ current: JobLogs, with incoming: JobLogs) -> JobLogs {
        Self.mergedLogs(current, with: incoming)
    }

    static func mergedLogs(_ current: JobLogs, with incoming: JobLogs) -> JobLogs {
        var entriesByID: [Int: JobLogEntry] = [:]
        for entry in current.entries {
            entriesByID[entry.id] = entry
        }
        for entry in incoming.entries {
            entriesByID[entry.id] = entry
        }

        return JobLogs(
            entries: entriesByID.values.sorted { $0.id < $1.id },
            total: max(current.total, incoming.total)
        )
    }

    private func loadJobs(queueName: String) async throws -> JobPage {
        if let filter = appliedJobFilter {
            let requestID = refreshRequestID
            let result = try await engine.searchJobs(queueName: queueName, prefix: activePrefix, state: selectedState, filter: filter, cursor: JobSearchCursor())
            if isCurrentRefresh(requestID, queueName: queueName) {
                searchCursor = result.next
                searchedJobCount = result.scanned
            }
            return JobPage(jobs: result.jobs, total: result.jobs.count, page: 0, pageSize: max(1, result.jobs.count))
        }
        if let selectedState {
            let page = try await engine.getJobs(
                queueName: queueName,
                prefix: activePrefix,
                state: selectedState,
                page: runPage,
                pageSize: runPageSize
            )
            return page
        }

        let fetchLimit = (runPage + 1) * runPageSize + 1
        let jobs = try await engine.getRecentJobs(
            queueName: queueName,
            prefix: activePrefix,
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

    private func loadMetricTimingJobs(queueName: String) async throws -> [JobSummary] {
        try await engine.getRecentJobs(
            queueName: queueName,
            prefix: activePrefix,
            states: [.completed, .failed],
            perStateLimit: 120,
            totalLimit: 200
        )
    }

    private static func prettyDuplicateJSON(_ rawValue: String?, fallback: String) -> String {
        guard let rawValue, !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return fallback
        }
        do {
            let object = try JSONSerialization.jsonObject(with: Data(rawValue.utf8), options: [.fragmentsAllowed])
            guard JSONSerialization.isValidJSONObject(object) else {
                return rawValue
            }
            let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            return String(data: data, encoding: .utf8) ?? rawValue
        } catch {
            return rawValue
        }
    }

    private static func duplicateOptionsJSON(_ rawValue: String?) -> String {
        guard let rawValue, !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "{}"
        }
        do {
            let object = try JSONSerialization.jsonObject(with: Data(rawValue.utf8), options: [])
            if var options = object as? [String: Any] {
                for key in ["jobId", "repeat", "repeatJobKey", "prevMillis", "parent", "parentKey", "de"] {
                    options.removeValue(forKey: key)
                }
                guard JSONSerialization.isValidJSONObject(options) else { return "{}" }
                let data = try JSONSerialization.data(withJSONObject: options, options: [.prettyPrinted, .sortedKeys])
                return String(data: data, encoding: .utf8) ?? "{}"
            }
        } catch {
            return "{}"
        }
        return "{}"
    }

    private func replaceQueue(_ queue: QueueSummary) {
        var queue = queue
        if let index = queues.firstIndex(where: { $0.name == queue.name }) {
            queue.displayName = queue.displayName ?? queues[index].displayName
            queue.groupName = queue.groupName ?? queues[index].groupName
            queues[index] = queue
        } else {
            queues.append(queue)
            queues.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    private func loadSavedQueues(for config: RedisConnectionConfig) {
        let scope = queueScope(for: config)
        let preference = workspacePreferenceStore.load(scope: scope)
        let savedInterval = preference?.refreshInterval ?? 15
        refreshInterval = [0, 5, 15, 30, 60].contains(savedInterval) ? savedInterval : 15
        if let rawSelectedView = preference?.selectedView,
           let restoredView = QueueWorkspaceView(rawValue: rawSelectedView) {
            selectedView = restoredView
        }

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
        if let selectedQueueName = preference?.selectedQueueName,
           let restoredQueue = queues.first(where: { $0.name == selectedQueueName }) {
            selectedQueue = restoredQueue
            selectedState = nil
        } else if selectedQueue == nil {
            selectedQueue = queues.first
            selectedState = nil
        }
        if let selectedQueue {
            applyCachedPanelData(for: selectedQueue.name)
        }
        statusMessage = "Loaded \(queues.count) cached queues"
    }

    private func lastActiveProfile() -> RedisConnectionProfile? {
        if let id = profileStore.loadLastActiveProfileID(),
           let profile = profiles.first(where: { $0.id == id }) {
            return profile
        }
        return profiles.last
    }

    private func resetQueueStateForNewConnection() {
        lookupJobID = ""
        flowJobID = ""
        jobFilter = JobFilter()
        lastRefreshedAt = nil
        lastRefreshError = nil
        appliedJobFilter = nil
        searchCursor = nil
        searchedJobCount = 0
        discoveryCursor = "0"
        hasDiscoveredQueues = false
        jobFlow = JobFlow()
        flowReference = nil
        selectedJobPrefix = nil
        connectionGeneration += 1
        refreshRequestID += 1
        refreshTask?.cancel()
        refreshTask = nil
        selectedJobIDs = []
        snapshots = []
        selectedJobDetailTask?.cancel()
        selectedJobDetailTask = nil
        selectedJobLogTask?.cancel()
        selectedJobLogTask = nil
        queues = []
        jobs = []
        runPage = 0
        runTotal = 0
        workers = []
        schedulers = []
        metricTimingJobs = []
        selectedView = .overview
        selectedQueue = nil
        selectedState = nil
        selectedJob = nil
        selectedJobDetail = nil
        selectedJobLogs = .empty
        isLoadingSelectedJobLogs = false
        isStreamingSelectedJobLogs = false
        activeJobAction = nil
        jobsByQuery = [:]
        runTotalsByQuery = [:]
        workersByQueue = [:]
        schedulersByQueue = [:]
        metricTimingJobsByQueue = [:]
        lastSnapshotCountsByQueue = [:]
        lastSnapshotNativeMetricsByQueue = [:]
    }

    private func persistCurrentQueueNames() {
        guard let config = activeConnection else { return }
        queueNameStore.save(queues.map(\.name), scope: queueScope(for: config))
    }

    private func persistCurrentQueueMetadata() {
        guard let config = activeConnection else { return }
        queueMetadataStore.save(queues, scope: queueScope(for: config))
    }

    private func persistCurrentWorkspacePreference() {
        guard let config = activeConnection else { return }
        let preference = QueueWorkspacePreference(
            refreshInterval: refreshInterval,
            selectedQueueName: selectedQueue?.name,
            selectedView: selectedView.rawValue
        )
        workspacePreferenceStore.save(preference, scope: queueScope(for: config))
    }

    private func queueScope(for config: RedisConnectionConfig) -> String {
        "\(config.host):\(config.port)/\(config.database):\(config.prefix)"
    }

    private func cacheKey(_ queueName: String) -> String {
        "\(activePrefix):\(queueName)"
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
        metricTimingJobs = metricTimingJobsByQueue[key] ?? []
    }

    private func applyCachedRuns(for queueName: String) {
        if appliedJobFilter != nil { jobs = []; runTotal = 0; return }
        let key = runCacheKey(queueName)
        jobs = jobsByQuery[key] ?? []
        runTotal = runTotalsByQuery[key] ?? 0
        pruneSelectedJobSelection()
    }

    private func recordSnapshot(queueName: String, counts: QueueCounts, nativeMetrics: BullMQNativeMetrics? = nil) throws {
        guard let config = activeConnection else { return }
        let previousNativeMetrics = lastSnapshotNativeMetricsByQueue[queueName]
        guard lastSnapshotCountsByQueue[queueName] != counts || previousNativeMetrics != nativeMetrics else { return }
        let snapshot = QueueMetricSnapshot(
            connectionScope: queueScope(for: config),
            queueName: queueName,
            capturedAt: Date(),
            counts: QueueCountsSnapshot(counts: counts),
            nativeMetrics: nativeMetrics
        )
        try snapshotStore.append(snapshot)
        snapshots = try snapshotStore.load(scope: queueScope(for: config))
        lastSnapshotCountsByQueue[queueName] = counts
        lastSnapshotNativeMetricsByQueue[queueName] = nativeMetrics
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
        let prefixStart = "\(activePrefix):"
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

    private func normalizedQueueGroupName(_ rawName: String?) -> String? {
        let name = rawName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? nil : name
    }

    private func runLoading(_ phase: LoadingPhase, _ operation: () async throws -> Void) async {
        let generation = connectionGeneration
        beginLoading(phase)
        lastError = nil
        defer { endLoading(phase) }
        do {
            try await operation()
        } catch is CancellationError {
            return
        } catch {
            guard phase == .connecting || generation == connectionGeneration else { return }
            if let failure = error as? BullMQDashboardError {
                switch failure {
                case .connectionLost, .notConnected:
                    isConnected = false
                    lastRefreshError = error.localizedDescription
                default: break
                }
            }
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
