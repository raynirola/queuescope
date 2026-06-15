import XCTest
@testable import BullMQDashboard

final class BullMQParsingTests: XCTestCase {
    func testParsesQueueNameFromMetaKey() {
        XCTAssertEqual(BullMQParsing.parseQueueName(fromMetaKey: "bull:email:meta", prefix: "bull"), "email")
        XCTAssertEqual(BullMQParsing.parseQueueName(fromMetaKey: "prod:video:meta", prefix: "prod"), "video")
        XCTAssertNil(BullMQParsing.parseQueueName(fromMetaKey: "bull:email:wait", prefix: "bull"))
        XCTAssertNil(BullMQParsing.parseQueueName(fromMetaKey: "other:email:meta", prefix: "bull"))
    }

    func testBuildsBullMQKeys() {
        XCTAssertEqual(BullMQParsing.key(prefix: "bull", queue: "email", suffix: "failed"), "bull:email:failed")
        XCTAssertEqual(BullMQParsing.jobKey(prefix: "bull", queue: "email", jobID: "123"), "bull:email:123")
    }

    func testPrettyPrintsJSONAndFallsBackToRaw() {
        let json = BullMQParsing.displayValue(#"{"b":2,"a":1}"#)
        XCTAssertTrue(json.text.contains("\"a\""))
        XCTAssertTrue(json.text.contains("\"b\""))

        let raw = BullMQParsing.displayValue("not-json")
        XCTAssertEqual(raw, .raw("not-json"))
    }

    func testParsesAttemptCountFromOptions() {
        XCTAssertEqual(BullMQParsing.attempts(from: #"{"attempts":3}"#), 3)
        XCTAssertEqual(BullMQParsing.attempts(from: #"{"attempts":"4"}"#), 4)
        XCTAssertNil(BullMQParsing.attempts(from: #"{"removeOnComplete":true}"#))
    }

    func testHealthClassification() {
        XCTAssertEqual(BullMQParsing.health(from: .empty), .healthy)

        var busy = QueueCounts.empty
        busy.waiting = 501
        XCTAssertEqual(BullMQParsing.health(from: busy), .busy)

        var warning = QueueCounts.empty
        warning.failed = 1
        XCTAssertEqual(BullMQParsing.health(from: warning), .warning)

        var failing = QueueCounts.empty
        failing.failed = 10
        failing.completed = 20
        XCTAssertEqual(BullMQParsing.health(from: failing), .failing)
    }

    func testQueueDisplayNameFallsBackToTitleCasedQueueName() {
        XCTAssertEqual(
            QueueSummary(name: "setup-inboxkit-mailbox-v2", prefix: "bull", counts: .empty, health: .unknown).resolvedDisplayName,
            "Setup Inboxkit Mailbox V2"
        )
        XCTAssertEqual(
            QueueSummary(name: "setup-inboxkit-mailbox-v2", displayName: "Inbox setup", prefix: "bull", counts: .empty, health: .unknown).resolvedDisplayName,
            "Inbox setup"
        )
    }

    func testQueueGroupNameUsesExplicitMetadata() {
        XCTAssertEqual(
            QueueSummary(name: "mail:send", groupName: "Transactional", prefix: "bull", counts: .empty, health: .unknown).resolvedGroupName,
            "Transactional"
        )
        XCTAssertEqual(
            QueueSummary(name: "mail:send", prefix: "bull", counts: .empty, health: .unknown).resolvedGroupName,
            "Ungrouped"
        )
    }

    func testCompactCountDisplayKeepsLargeNumbersShort() {
        XCTAssertEqual(870.compactCountDisplay, "870")
        XCTAssertEqual(1_200.compactCountDisplay, "1.2K")
        XCTAssertEqual(216_401.compactCountDisplay, "216K")
        XCTAssertEqual(573_000.compactCountDisplay, "573K")
        XCTAssertEqual(1_250_000.compactCountDisplay, "1.2M")
    }

    func testCompactDurationDisplayUsesHumanUnits() {
        XCTAssertEqual(TimeInterval(0.078).compactDurationDisplay, "78ms")
        XCTAssertEqual(TimeInterval(5.68).compactDurationDisplay, "5.7s")
        XCTAssertEqual(TimeInterval(45).compactDurationDisplay, "45s")
        XCTAssertEqual(TimeInterval(95).compactDurationDisplay, "1.5m")
        XCTAssertEqual(TimeInterval(15_623.95).compactDurationDisplay, "4.3h")
        XCTAssertEqual(TimeInterval(172_800).compactDurationDisplay, "2d")
    }

    func testThroughputRateUsesNewestNativeMetricBuckets() {
        let metrics = BullMQNativeMetrics(
            completed: BullMQMetricSeries(count: 1_180, previousTimestamp: nil, previousCount: 0, data: [60, 60, 60, 60, 60, 2, 2, 2, 2, 2]),
            failed: BullMQMetricSeries(count: 0, previousTimestamp: nil, previousCount: 0, data: [])
        )

        let rate = metrics.throughputRate(windowBucketCount: 5)

        XCTAssertEqual(rate.bucketCount, 5)
        XCTAssertEqual(rate.completedPerMinute, 60)
        XCTAssertEqual(rate.failedPerMinute, 0)
    }

    func testThroughputRateTreatsMissingSeriesBucketsAsZero() {
        let metrics = BullMQNativeMetrics(
            completed: BullMQMetricSeries(count: 10, previousTimestamp: nil, previousCount: 0, data: [10]),
            failed: BullMQMetricSeries(count: 30, previousTimestamp: nil, previousCount: 0, data: [10, 10, 10])
        )

        let rate = metrics.throughputRate(windowBucketCount: 3)

        XCTAssertEqual(rate.bucketCount, 3)
        XCTAssertEqual(rate.completedPerMinute, 10.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(rate.failedPerMinute, 10)
    }
}

@MainActor
final class AppModelRefreshTests: XCTestCase {
    func testOverviewRefreshSkipsRunsWorkersAndSchedulers() async {
        let engine = FakeBullMQEngine()
        let model = AppModel(engine: engine)
        model.selectedQueue = QueueSummary(name: "email", prefix: "bull", counts: .empty, health: .unknown)

        await model.refreshSelectedQueue(for: .overview)

        XCTAssertEqual(engine.overviewCalls, ["email"])
        XCTAssertTrue(engine.recentJobsCalls.isEmpty)
        XCTAssertTrue(engine.workerCalls.isEmpty)
        XCTAssertTrue(engine.schedulerCalls.isEmpty)
    }

    func testRunsRefreshLoadsOnlyOverviewAndRuns() async {
        let engine = FakeBullMQEngine()
        engine.recentJobs = [makeJob(id: "1", queueName: "email", state: .failed)]
        let model = AppModel(engine: engine)
        model.selectedQueue = QueueSummary(name: "email", prefix: "bull", counts: .empty, health: .unknown)

        await model.refreshSelectedQueue(for: .runs)

        XCTAssertEqual(engine.overviewCalls, ["email"])
        XCTAssertEqual(engine.recentJobsCalls, ["email"])
        XCTAssertEqual(engine.recentJobsLimits, [11])
        XCTAssertTrue(engine.workerCalls.isEmpty)
        XCTAssertTrue(engine.schedulerCalls.isEmpty)
        XCTAssertEqual(model.jobs.map(\.id), ["1"])
    }

    func testRunsUseTenItemPages() async {
        let engine = FakeBullMQEngine()
        engine.recentJobs = (1...21).map {
            makeJob(id: "\($0)", queueName: "email", state: .waiting)
        }
        let model = AppModel(engine: engine)
        model.selectedQueue = QueueSummary(name: "email", prefix: "bull", counts: .empty, health: .unknown)

        await model.refreshSelectedQueue(for: .runs)
        XCTAssertEqual(model.jobs.count, 10)
        XCTAssertTrue(model.canGoToNextRunPage)

        model.goToNextRunPage()
        try? await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(model.runPage, 1)
        XCTAssertEqual(model.jobs.count, 10)
        XCTAssertEqual(model.jobs.first?.id, "11")
    }

    func testStaleRefreshCannotOverwriteNewerQueueSelection() async {
        let engine = FakeBullMQEngine()
        engine.overviewDelayByQueue["first"] = 120_000_000
        let model = AppModel(engine: engine)
        model.selectedQueue = QueueSummary(name: "first", prefix: "bull", counts: .empty, health: .unknown)

        let staleTask = Task {
            await model.refreshSelectedQueue(for: .runs)
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        model.selectedQueue = QueueSummary(name: "second", prefix: "bull", counts: .empty, health: .unknown)
        await model.refreshSelectedQueue(for: .runs)
        await staleTask.value

        XCTAssertEqual(model.selectedQueue?.name, "second")
    }

    func testManualQueueCanUseHumanReadableDisplayName() async {
        let engine = FakeBullMQEngine()
        let model = AppModel(engine: engine)
        model.prefix = "bull"

        await model.addManualQueue(named: "bull:setup-inboxkit-mailbox-v2:meta", displayName: "Inbox setup")

        XCTAssertEqual(model.queues.first?.name, "setup-inboxkit-mailbox-v2")
        XCTAssertEqual(model.queues.first?.displayName, "Inbox setup")
        XCTAssertEqual(model.selectedQueue?.resolvedDisplayName, "Inbox setup")
    }

    func testQueueCanBeAssignedToExplicitGroup() {
        let model = AppModel(engine: FakeBullMQEngine())
        let queue = QueueSummary(name: "email", prefix: "bull", counts: .empty, health: .unknown)
        model.queues = [queue]
        model.selectedQueue = queue

        model.assignQueue(queue, toGroup: "Production")

        XCTAssertEqual(model.queues.first?.groupName, "Production")
        XCTAssertEqual(model.selectedQueue?.resolvedGroupName, "Production")
    }

    func testSelectingActiveRunDoesNotLoadLogsUntilRequested() async {
        let engine = FakeBullMQEngine()
        engine.jobDetails["1"] = makeJobDetail(id: "1", queueName: "email", state: .active)
        engine.jobLogLines["1"] = ["started"]
        let model = AppModel(engine: engine)

        model.selectJob(makeJob(id: "1", queueName: "email", state: .active))
        try? await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(engine.jobDetailCalls, ["1"])
        XCTAssertTrue(engine.jobLogCalls.isEmpty)
        XCTAssertFalse(model.isStreamingSelectedJobLogs)
        XCTAssertTrue(model.selectedJobLogs.entries.isEmpty)
    }

    func testActiveRunStreamsLogsAfterLogsAreShown() async {
        let engine = FakeBullMQEngine()
        engine.jobDetails["1"] = makeJobDetail(id: "1", queueName: "email", state: .active)
        engine.jobLogLines["1"] = ["started"]
        let model = AppModel(engine: engine)

        model.selectJob(makeJob(id: "1", queueName: "email", state: .active))
        model.showSelectedJobLogs()
        try? await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(engine.jobLogCalls.first?.jobID, "1")
        XCTAssertEqual(engine.jobLogCalls.first?.limit, 50)
        XCTAssertNil(engine.jobLogCalls.first?.start)
        XCTAssertTrue(model.isStreamingSelectedJobLogs)
        XCTAssertEqual(model.selectedJobLogs.entries.map(\.text), ["started"])

        model.clearSelectedJob()
        XCTAssertFalse(model.isStreamingSelectedJobLogs)
    }

    func testCompletedRunLoadsLogsWithoutStreamingWhenLogsAreShown() async {
        let engine = FakeBullMQEngine()
        engine.jobDetails["2"] = makeJobDetail(id: "2", queueName: "email", state: .completed)
        engine.jobLogLines["2"] = ["done"]
        let model = AppModel(engine: engine)

        model.selectJob(makeJob(id: "2", queueName: "email", state: .completed))
        model.showSelectedJobLogs()
        try? await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(engine.jobLogCalls.map(\.jobID), ["2"])
        XCTAssertFalse(model.isStreamingSelectedJobLogs)
        XCTAssertEqual(model.selectedJobLogs.entries.map(\.text), ["done"])
    }

    func testLoadOlderLogsFetchesOnlyPreviousWindow() async {
        let engine = FakeBullMQEngine()
        engine.jobDetails["3"] = makeJobDetail(id: "3", queueName: "email", state: .completed)
        engine.jobLogLines["3"] = (1...60).map { "line \($0)" }
        let model = AppModel(engine: engine)

        model.selectJob(makeJob(id: "3", queueName: "email", state: .completed))
        model.showSelectedJobLogs()
        try? await Task.sleep(nanoseconds: 30_000_000)
        model.loadOlderSelectedJobLogs()
        try? await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(engine.jobLogCalls.map(\.start), [nil, 0])
        XCTAssertEqual(engine.jobLogCalls.map(\.limit), [50, 10])
        XCTAssertEqual(model.selectedJobLogs.entries.count, 60)
        XCTAssertEqual(model.selectedJobLogs.entries.first?.text, "line 1")
        XCTAssertEqual(model.selectedJobLogs.entries.last?.text, "line 60")
    }

    func testMergingOverlappingLogWindowsDeduplicatesIDs() {
        let current = JobLogs(
            entries: [
                JobLogEntry(id: 1, text: "first"),
                JobLogEntry(id: 2, text: "second")
            ],
            total: 2
        )
        let incoming = JobLogs(
            entries: [
                JobLogEntry(id: 2, text: "second updated"),
                JobLogEntry(id: 2, text: "second latest"),
                JobLogEntry(id: 3, text: "third")
            ],
            total: 3
        )

        let merged = AppModel.mergedLogs(current, with: incoming)

        XCTAssertEqual(merged.entries.map(\.id), [1, 2, 3])
        XCTAssertEqual(merged.entries.map(\.text), ["first", "second latest", "third"])
        XCTAssertEqual(merged.total, 3)
    }

    func testJobActionStateGatesMatchBullMQSupportedStates() {
        XCTAssertTrue(AppModel.canRetry(makeJob(id: "failed", queueName: "email", state: .failed)))
        XCTAssertTrue(AppModel.canRetry(makeJob(id: "completed", queueName: "email", state: .completed)))
        XCTAssertFalse(AppModel.canRetry(makeJob(id: "waiting", queueName: "email", state: .waiting)))

        XCTAssertTrue(AppModel.canPromote(makeJob(id: "delayed", queueName: "email", state: .delayed)))
        XCTAssertFalse(AppModel.canPromote(makeJob(id: "active", queueName: "email", state: .active)))

        XCTAssertTrue(AppModel.canRemove(makeJob(id: "failed", queueName: "email", state: .failed)))
        XCTAssertFalse(AppModel.canRemove(makeJob(id: "active", queueName: "email", state: .active)))
    }

    func testDuplicateDraftStripsCopiedJobIDAndRepeatOptions() {
        let detail = JobDetail(
            id: "1",
            queueName: "email",
            state: .failed,
            fields: [
                "name": "send-email",
                "data": #"{"leadId":"lead_1"}"#,
                "opts": #"{"attempts":3,"jobId":"original","repeat":{"every":60000}}"#
            ],
            data: .empty,
            options: .empty,
            progress: .empty,
            returnValue: .empty,
            failedReason: nil,
            stacktrace: [],
            timestamp: nil,
            processedOn: nil,
            finishedOn: nil,
            attemptsMade: 0
        )

        let draft = AppModel.duplicateDraft(for: detail)

        XCTAssertEqual(draft.name, "send-email")
        XCTAssertTrue(draft.dataJSON.contains("leadId"))
        XCTAssertTrue(draft.optionsJSON.contains("attempts"))
        XCTAssertFalse(draft.optionsJSON.contains("jobId"))
        XCTAssertFalse(draft.optionsJSON.contains("repeat"))
    }

    func testDuplicateJSONValidationRejectsInvalidJSON() {
        XCTAssertNoThrow(try AppModel.parseDuplicateJSON(#"{"ok":true}"#, label: "Data"))
        XCTAssertThrowsError(try AppModel.parseDuplicateJSON("{", label: "Data"))
    }

    func testRetryRefreshesRunsAndReloadsSelectedDetail() async {
        let engine = FakeBullMQEngine()
        let job = makeJob(id: "1", queueName: "email", state: .failed)
        engine.recentJobs = [job]
        engine.jobDetails["1"] = makeJobDetail(id: "1", queueName: "email", state: .failed)
        let model = AppModel(engine: engine)
        model.selectedQueue = QueueSummary(name: "email", prefix: "bull", counts: .empty, health: .unknown)
        model.selectedView = .runs
        model.selectedJob = job
        model.selectedJobDetail = engine.jobDetails["1"]

        await model.retryJob(job)

        XCTAssertEqual(engine.retryCalls.map(\.jobID), ["1"])
        XCTAssertEqual(engine.overviewCalls, ["email"])
        XCTAssertEqual(engine.recentJobsCalls, ["email"])
        XCTAssertEqual(engine.jobDetailCalls, ["1"])
        XCTAssertEqual(model.statusMessage, "Retried job 1")
    }

    func testRemoveRefreshesRunsAndClearsSelectedJob() async {
        let engine = FakeBullMQEngine()
        let job = makeJob(id: "2", queueName: "email", state: .failed)
        engine.recentJobs = []
        let model = AppModel(engine: engine)
        model.selectedQueue = QueueSummary(name: "email", prefix: "bull", counts: .empty, health: .unknown)
        model.selectedView = .runs
        model.selectedJob = job
        model.selectedJobDetail = makeJobDetail(id: "2", queueName: "email", state: .failed)

        await model.removeJob(job)

        XCTAssertEqual(engine.removeCalls.map(\.jobID), ["2"])
        XCTAssertEqual(engine.removeCalls.map(\.removeChildren), [true])
        XCTAssertNil(model.selectedJob)
        XCTAssertNil(model.selectedJobDetail)
        XCTAssertEqual(model.statusMessage, "Removed job 2")
    }

    func testPromoteRefreshesRunsAndReloadsSelectedDetail() async {
        let engine = FakeBullMQEngine()
        let job = makeJob(id: "3", queueName: "email", state: .delayed)
        engine.recentJobs = [job]
        engine.jobDetails["3"] = makeJobDetail(id: "3", queueName: "email", state: .delayed)
        let model = AppModel(engine: engine)
        model.selectedQueue = QueueSummary(name: "email", prefix: "bull", counts: .empty, health: .unknown)
        model.selectedView = .runs
        model.selectedJob = job
        model.selectedJobDetail = engine.jobDetails["3"]

        await model.promoteJob(job)

        XCTAssertEqual(engine.promoteCalls, ["3"])
        XCTAssertEqual(engine.recentJobsCalls, ["email"])
        XCTAssertEqual(engine.jobDetailCalls, ["3"])
        XCTAssertEqual(model.statusMessage, "Promoted job 3")
    }

    func testDuplicateRefreshesRunsWithoutChangingSelection() async {
        let engine = FakeBullMQEngine()
        engine.duplicatedJobID = "4"
        let model = AppModel(engine: engine)
        model.selectedQueue = QueueSummary(name: "email", prefix: "bull", counts: .empty, health: .unknown)
        model.selectedView = .runs

        await model.duplicateJob(
            queueName: "email",
            draft: JobDuplicateDraft(
                name: "send-email",
                dataJSON: #"{"leadId":"lead_1"}"#,
                optionsJSON: #"{"attempts":3}"#
            )
        )

        XCTAssertEqual(engine.duplicateCalls.map(\.name), ["send-email"])
        XCTAssertEqual(engine.overviewCalls, ["email"])
        XCTAssertEqual(engine.recentJobsCalls, ["email"])
        XCTAssertEqual(model.statusMessage, "Duplicated job 4")
    }
}

private func makeJob(id: String, queueName: String, state: BullMQState) -> JobSummary {
    JobSummary(
        id: id,
        queueName: queueName,
        state: state,
        name: "send-email",
        timestamp: nil,
        processedOn: nil,
        finishedOn: nil,
        delayedUntil: nil,
        attemptsMade: 1,
        attempts: 3,
        failedReason: state == .failed ? "boom" : nil,
        payloadPreview: "{}"
    )
}

private func makeJobDetail(id: String, queueName: String, state: BullMQState) -> JobDetail {
    JobDetail(
        id: id,
        queueName: queueName,
        state: state,
        fields: [:],
        data: .empty,
        options: .empty,
        progress: .empty,
        returnValue: .empty,
        failedReason: nil,
        stacktrace: [],
        timestamp: nil,
        processedOn: nil,
        finishedOn: nil,
        attemptsMade: 0
    )
}

private final class FakeBullMQEngine: BullMQEngine, @unchecked Sendable {
    var overviewCalls: [String] = []
    var recentJobsCalls: [String] = []
    var recentJobsLimits: [Int] = []
    var workerCalls: [String] = []
    var schedulerCalls: [String] = []
    var jobDetailCalls: [String] = []
    var jobLogCalls: [(jobID: String, start: Int?, limit: Int)] = []
    var overviewDelayByQueue: [String: UInt64] = [:]
    var recentJobs: [JobSummary] = []
    var jobDetails: [String: JobDetail] = [:]
    var jobLogLines: [String: [String]] = [:]
    var retryCalls: [(jobID: String, state: BullMQState)] = []
    var removeCalls: [(jobID: String, removeChildren: Bool)] = []
    var promoteCalls: [String] = []
    var duplicateCalls: [(name: String, data: AnySendableJSON, options: AnySendableJSON)] = []
    var duplicatedJobID = "duplicated"

    func connect(_ config: RedisConnectionConfig) async throws {}

    func disconnect() async {}

    func getQueueOverview(queueName: String, prefix: String) async throws -> QueueSummary {
        overviewCalls.append(queueName)
        if let delay = overviewDelayByQueue[queueName] {
            try? await Task.sleep(nanoseconds: delay)
        }
        return QueueSummary(name: queueName, prefix: prefix, counts: .empty, health: .healthy)
    }

    func getJobs(queueName: String, prefix: String, state: BullMQState, page: Int, pageSize: Int) async throws -> JobPage {
        JobPage(jobs: recentJobs, total: recentJobs.count, page: page, pageSize: pageSize)
    }

    func getRecentJobs(queueName: String, prefix: String, states: [BullMQState], perStateLimit: Int, totalLimit: Int) async throws -> [JobSummary] {
        recentJobsCalls.append(queueName)
        recentJobsLimits.append(totalLimit)
        return Array(recentJobs.prefix(totalLimit))
    }

    func getJobDetail(queueName: String, prefix: String, jobID: String, state: BullMQState) async throws -> JobDetail {
        jobDetailCalls.append(jobID)
        return jobDetails[jobID] ?? makeJobDetail(id: jobID, queueName: queueName, state: state)
    }

    func getJobLogs(queueName: String, prefix: String, jobID: String, start: Int?, limit: Int) async throws -> JobLogs {
        jobLogCalls.append((jobID: jobID, start: start, limit: limit))
        let lines = jobLogLines[jobID] ?? []
        guard !lines.isEmpty else { return .empty }
        let lowerBound = start ?? max(0, lines.count - limit)
        let upperBound = min(lines.count, lowerBound + limit)
        guard lowerBound < upperBound else {
            return JobLogs(entries: [], total: lines.count)
        }
        let entries = lines[lowerBound..<upperBound].enumerated().map { offset, line in
            JobLogEntry(id: lowerBound + offset + 1, text: line)
        }
        return JobLogs(entries: entries, total: lines.count)
    }

    func retryJob(queueName: String, prefix: String, jobID: String, state: BullMQState) async throws {
        retryCalls.append((jobID: jobID, state: state))
    }

    func removeJob(queueName: String, prefix: String, jobID: String, removeChildren: Bool) async throws {
        removeCalls.append((jobID: jobID, removeChildren: removeChildren))
    }

    func promoteJob(queueName: String, prefix: String, jobID: String) async throws {
        promoteCalls.append(jobID)
    }

    func duplicateJob(queueName: String, prefix: String, name: String, data: AnySendableJSON, options: AnySendableJSON) async throws -> String {
        duplicateCalls.append((name: name, data: data, options: options))
        return duplicatedJobID
    }

    func getMetrics(queueName: String, prefix: String) async throws -> [QueueMetricSnapshot] {
        []
    }

    func getWorkers(queueName: String, prefix: String) async throws -> [WorkerSummary] {
        workerCalls.append(queueName)
        return []
    }

    func getSchedulers(queueName: String, prefix: String) async throws -> [SchedulerSummary] {
        schedulerCalls.append(queueName)
        return []
    }
}
