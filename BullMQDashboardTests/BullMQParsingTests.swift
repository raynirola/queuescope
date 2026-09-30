import XCTest
import SwiftUI
import AppKit
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
        XCTAssertEqual(TimeInterval(95).compactDurationDisplay, "1.6m")
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
    private func makeModel(engine: BullMQEngine) -> AppModel {
        let suite = "QueueScopeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return AppModel(
            engine: engine,
            profileStore: ConnectionProfileStore(defaults: defaults, credentials: MemoryConnectionCredentials()),
            snapshotStore: MetricSnapshotStore(fileURL: directory.appendingPathComponent("metrics.json"), legacyDefaults: defaults),
            queueNameStore: QueueNameStore(defaults: defaults),
            queueMetadataStore: QueueMetadataStore(defaults: defaults),
            workspacePreferenceStore: QueueWorkspacePreferenceStore(defaults: defaults)
        )
    }

    func testReadOnlyConnectionBlocksEveryModelMutation() async {
        let engine = FakeBullMQEngine()
        let model = makeModel(engine: engine)
        model.connectionReadOnly = true
        await model.connect()
        model.connectionReadOnly = false // Editing the form must not enable the live session.
        model.selectedQueue = QueueSummary(name: "email", prefix: "bull", counts: .empty, health: .healthy)
        let failed = makeJob(id: "failed", queueName: "email", state: .failed)
        let delayed = makeJob(id: "delayed", queueName: "email", state: .delayed)
        await model.retryJob(failed)
        await model.removeJob(failed)
        await model.promoteJob(delayed)
        await model.retryJobs([failed])
        await model.removeJobs([failed], removeChildren: true)
        await model.promoteJobs([delayed])
        let draft = JobDuplicateDraft(name: "job", dataJSON: "{}", optionsJSON: "{}")
        await model.addJob(queueName: "email", draft: draft)
        await model.duplicateJob(queueName: "email", draft: draft)
        await model.setSelectedQueuePaused(true)
        XCTAssertTrue(model.isReadOnly)
        XCTAssertTrue(engine.retryCalls.isEmpty)
        XCTAssertTrue(engine.removeCalls.isEmpty)
        XCTAssertTrue(engine.promoteCalls.isEmpty)
        XCTAssertTrue(engine.addCalls.isEmpty)
        XCTAssertTrue(engine.duplicateCalls.isEmpty)
        XCTAssertTrue(engine.pauseCalls.isEmpty)
    }

    func testDiscoveryMergesWithoutOverwritingQueueMetadata() async {
        let engine = FakeBullMQEngine()
        let model = makeModel(engine: engine)
        await model.connect()
        model.queues = [QueueSummary(name: "email", displayName: "Custom", groupName: "Production", prefix: "bull", counts: .empty, health: .healthy)]
        engine.discoveredNames = ["email", "other", "other"]
        await model.discoverMoreQueues()
        XCTAssertEqual(model.queues.map(\.name), ["email", "other"])
        XCTAssertEqual(model.queues.first?.displayName, "Custom")
        XCTAssertEqual(model.queues.first?.groupName, "Production")
        XCTAssertTrue(model.hasDiscoveredQueues)
    }

    func testAutomaticRefreshHonorsDisabledBusyAndFailureStates() async {
        let engine = FakeBullMQEngine()
        let model = makeModel(engine: engine)
        await model.connect()
        model.selectedQueue = QueueSummary(name: "email", prefix: "bull", counts: .empty, health: .healthy)
        model.selectedView = .runs
        model.refreshInterval = 0
        await model.refreshAutomatically()
        XCTAssertTrue(engine.overviewCalls.isEmpty)
        model.refreshInterval = 15
        model.activeLoadingPhases = [.runs]
        await model.refreshAutomatically()
        XCTAssertTrue(engine.overviewCalls.isEmpty)
        model.activeLoadingPhases = []
        await model.refreshAutomatically()
        XCTAssertEqual(engine.overviewCalls.count, 1)
        XCTAssertNotNil(model.lastRefreshedAt)
        engine.overviewError = BullMQDashboardError.redis("offline")
        await model.refreshAutomatically()
        XCTAssertNotNil(model.lastRefreshError)
        await model.refreshAutomatically()
        XCTAssertEqual(engine.overviewCalls.count, 2)
        engine.overviewError = nil
        await model.refreshSelectedQueue()
        XCTAssertNil(model.lastRefreshError)
    }

    func testTransportFailureMarksDisconnectedAndDisablesMutations() async {
        let engine = FakeBullMQEngine()
        let model = makeModel(engine: engine)
        await model.connect()
        model.selectedQueue = QueueSummary(name: "email", prefix: "bull", counts: .empty, health: .healthy)
        engine.overviewError = BullMQDashboardError.connectionLost("Socket closed")
        await model.refreshSelectedQueue()
        XCTAssertFalse(model.isConnected)
        XCTAssertFalse(model.canWrite)
        XCTAssertNotNil(model.lastRefreshError)
    }

    func testRefreshIntervalPersistsPerConnection() async {
        let engine = FakeBullMQEngine()
        let model = makeModel(engine: engine)
        await model.connect()
        model.setRefreshInterval(30)
        await model.connect()
        XCTAssertEqual(model.refreshInterval, 30)
        model.redisURL = "redis://other-host"
        await model.connect()
        XCTAssertEqual(model.refreshInterval, 15)
    }

    func testSearchContinuationKeepsMatchesAndPausesAutomaticRefresh() async {
        let engine = FakeBullMQEngine()
        let model = makeModel(engine: engine)
        await model.connect()
        model.selectedQueue = QueueSummary(name: "email", prefix: "bull", counts: .empty, health: .healthy)
        model.selectedView = .runs
        model.jobFilter.name = "needle"
        engine.searchResult = JobSearchResult(jobs: [], next: JobSearchCursor(stateIndex: 0, offset: 500), scanned: 500)
        await model.applyJobSearch()
        XCTAssertEqual(model.searchedJobCount, 500)
        XCTAssertNotNil(model.searchCursor)
        let calls = engine.overviewCalls.count
        await model.refreshAutomatically()
        XCTAssertEqual(engine.overviewCalls.count, calls)
        engine.searchResult = JobSearchResult(jobs: [makeJob(id: "match", queueName: "email", state: .waiting)], next: nil, scanned: 120)
        await model.loadMoreSearchResults()
        XCTAssertEqual(model.jobs.map(\.id), ["match"])
        XCTAssertEqual(model.searchedJobCount, 620)
        XCTAssertNil(model.searchCursor)
        model.jobFilter = JobFilter()
        await model.applyJobSearch()
        XCTAssertNil(model.appliedJobFilter)
    }

    func testCrossNamespaceFlowNavigationUsesTheReferencedQueue() async {
        let engine = FakeBullMQEngine()
        let model = makeModel(engine: engine)
        await model.connect()
        model.selectedQueue = QueueSummary(name: "parents", prefix: "bull", counts: .empty, health: .healthy)
        engine.foundJob = makeJob(id: "child", queueName: "children", state: .waiting)
        await model.inspectJob(JobReference(prefix: "other", queue: "children", jobID: "child"))
        XCTAssertEqual(engine.lookupCalls.last?.prefix, "other")
        XCTAssertEqual(engine.lookupCalls.last?.queue, "children")
        XCTAssertEqual(model.selectedJobDetail?.queueName, "children")
        XCTAssertFalse(model.canWrite)
        await model.loadFlow()
        XCTAssertEqual(engine.flowCalls.last?.prefix, "other")
        XCTAssertEqual(engine.flowCalls.last?.jobID, "child")
        XCTAssertEqual(model.selectedView, .flowGraph)
    }

    func testSupersededLookupCannotReplaceTheInspectorOrReportMissingJob() async {
        let engine = FakeBullMQEngine()
        let model = makeModel(engine: engine)
        await model.connect()
        model.selectedQueue = QueueSummary(name: "email", prefix: "bull", counts: .empty, health: .healthy)
        engine.lookupDelayByID["old"] = 100_000_000
        engine.missingJobIDs = ["old"]
        engine.foundJob = makeJob(id: "new", queueName: "email", state: .waiting)
        let old = Task { await model.inspectJob(JobReference(prefix: "bull", queue: "email", jobID: "old")) }
        try? await Task.sleep(for: .milliseconds(20))
        await model.inspectJob(JobReference(prefix: "bull", queue: "email", jobID: "new"))
        await old.value
        XCTAssertEqual(model.selectedJobDetail?.id, "new")
        XCTAssertNil(model.lastError)
    }

    func testInspectorIdentityDistinguishesEqualJobIDsAcrossQueues() async {
        let engine = FakeBullMQEngine()
        let model = makeModel(engine: engine)
        await model.connect()
        model.selectedQueue = QueueSummary(name: "parents", prefix: "bull", counts: .empty, health: .healthy)
        engine.foundJob = makeJob(id: "1", queueName: "parents", state: .waitingChildren)
        await model.inspectJob(JobReference(prefix: "bull", queue: "parents", jobID: "1"))
        let previous = model.inspectorRevision
        XCTAssertEqual(model.inspectedJobKey, "bull:parents:1")
        engine.foundJob = makeJob(id: "1", queueName: "children", state: .waiting)
        await model.inspectJob(JobReference(prefix: "bull", queue: "children", jobID: "1"))
        XCTAssertEqual(model.inspectedJobKey, "bull:children:1")
        XCTAssertGreaterThan(model.inspectorRevision, previous)
    }

    func testFeaturePanelsRender() async throws {
        let engine = FakeBullMQEngine()
        let model = makeModel(engine: engine)
        model.connectionReadOnly = true
        await model.connect()
        var counts = QueueCounts.empty
        counts.waiting = 24; counts.failed = 3; counts.completed = 150
        model.selectedQueue = QueueSummary(name: "email", displayName: "Email delivery", prefix: "bull", counts: counts, health: .healthy)
        model.jobs = [makeJob(id: "job-1", queueName: "email", state: .failed), makeJob(id: "job-2", queueName: "email", state: .waiting)]
        model.runTotal = model.jobs.count
        model.lastRefreshedAt = .now
        for view in [QueueWorkspaceView.runs, .flowGraph] {
            if view == .flowGraph {
                let parent = JobReference(prefix: "bull", queue: "email", jobID: "parent")
                let child = JobReference(prefix: "bull", queue: "attachments", jobID: "child")
                engine.flowResult = JobFlow(nodes: [
                    JobFlowNode(reference: parent, name: "Deliver email", state: .waitingChildren, depth: 0),
                    JobFlowNode(reference: child, name: "Generate attachment", state: .active, depth: 1)
                ], edges: [JobFlowEdge(parent: parent.id, child: child.id)])
                model.flowJobID = "parent"
                await model.loadFlow()
            }
            let host = NSHostingView(rootView: QueueDashboardView(selectedView: view).environmentObject(model))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 850), styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .aqua)
            window.contentView = host
            host.frame = NSRect(x: 0, y: 0, width: 760, height: 850)
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(150))
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            window.orderOut(nil)
            try png.write(to: URL(fileURLWithPath: "/tmp/queuescope-features-\(view.rawValue).png"))
        }
    }

    func testFailureInboxFollowsQueueSelectionDuringScan() async throws {
        let engine = FakeBullMQEngine()
        let model = makeModel(engine: engine)
        await model.connect()
        let email = QueueSummary(name: "email", prefix: "bull", counts: .empty, health: .failing)
        let reports = QueueSummary(name: "reports", prefix: "bull", counts: .empty, health: .failing)
        model.queues = [email, reports]
        engine.failedJobsByQueue = [
            "email": [makeJob(id: "email-1", queueName: "email", state: .failed)],
            "reports": [makeJob(id: "report-1", queueName: "reports", state: .failed)]
        ]
        model.selectedQueue = email
        model.selectedView = .failures
        await model.scanFailures()
        XCTAssertEqual(model.failureJobs.map(\.id), ["email-1"])
        engine.failedPageDelay = 100_000_000
        let oldScan = Task { await model.scanFailures() }
        try await Task.sleep(for: .milliseconds(20))
        model.selectQueue(reports)
        XCTAssertTrue(model.failureJobs.isEmpty)
        await oldScan.value
        for _ in 0..<100 {
            if model.failureJobs.map(\.id) == ["report-1"], !model.isScanningFailures { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.failureQueueNames, ["reports"])
        XCTAssertEqual(model.failureJobs.map(\.id), ["report-1"])
        XCTAssertTrue(model.newlyObservedFailures.isEmpty)
        await model.disconnect()
    }

    func testFailureInboxScopeResetsPaginationAndKeepsAllQueuesAvailable() async throws {
        let engine = FakeBullMQEngine()
        let model = makeModel(engine: engine)
        await model.connect()
        let email = QueueSummary(name: "email", prefix: "bull", counts: .empty, health: .failing)
        let reports = QueueSummary(name: "reports", prefix: "bull", counts: .empty, health: .healthy)
        model.queues = [email, reports]
        engine.failedJobsByQueue = ["email": (0..<620).map { makeJob(id: String($0), queueName: "email", state: .failed) }, "reports": []]
        model.selectedQueue = email
        await model.scanFailures()
        XCTAssertTrue(model.failureScanHasMore)
        model.selectQueue(reports)
        XCTAssertNil(model.failureScanDate)
        await model.scanFailures()
        XCTAssertEqual(model.failureQueueNames, ["reports"])
        XCTAssertTrue(model.failureJobs.isEmpty)
        XCTAssertFalse(model.failureScanHasMore)
        model.failureInboxAllQueues = true
        await model.scanFailures()
        XCTAssertEqual(model.failureJobs.count, 500)
        model.selectQueue(email)
        XCTAssertEqual(model.failureJobs.count, 500)
        await model.scanFailures(restart: false)
        XCTAssertEqual(model.failureJobs.count, 620)
        XCTAssertFalse(model.failureScanHasMore)
        model.failureInboxAllQueues = false
        await model.scanFailures()
        XCTAssertEqual(model.failureQueueNames, ["email"])
        XCTAssertEqual(model.failureJobs.count, 500)
        XCTAssertTrue(model.newlyObservedFailures.isEmpty)
        await model.disconnect()
    }

    func testFailureInboxGroupsAcrossQueuesAndTracksNewJobs() async {
        let engine = FakeBullMQEngine()
        let model = makeModel(engine: engine)
        await model.connect()
        model.failureInboxAllQueues = true
        model.queues = ["email", "reports"].map { QueueSummary(name: $0, prefix: "bull", counts: .empty, health: .failing) }
        var first = makeJob(id: "1", queueName: "email", state: .failed)
        first.failedReason = "HTTP 429: rate limited"
        var second = first
        second.queueName = "reports"
        engine.failedJobsByQueue = ["email": [first], "reports": [second]]
        await model.scanFailures()
        XCTAssertEqual(model.failureJobs.count, 2)
        XCTAssertEqual(model.failureGroups.count, 1)
        XCTAssertEqual(model.failureGroups.first?.queues, ["email", "reports"])
        XCTAssertFalse(model.failureScanHasMore)
        XCTAssertTrue(model.newlyObservedFailures.isEmpty)
        var new = first; new.id = "2"
        engine.failedJobsByQueue["email"]?.append(new)
        await model.scanFailures()
        XCTAssertEqual(model.newlyObservedFailures, ["email:2"])
        await model.disconnect()
        XCTAssertTrue(model.failureJobs.isEmpty)
        XCTAssertNil(model.failureScanDate)
    }

    func testFailureInboxPaginatesAndRejectsDisconnectedResults() async {
        let engine = FakeBullMQEngine()
        let model = makeModel(engine: engine)
        await model.connect()
        model.queues = [QueueSummary(name: "email", prefix: "bull", counts: .empty, health: .failing)]
        engine.failedJobsByQueue = ["email": (0..<620).map { makeJob(id: String($0), queueName: "email", state: .failed) }]
        await model.scanFailures()
        XCTAssertEqual(model.failureJobs.count, 500)
        XCTAssertTrue(model.failureScanHasMore)
        model.selectWorkspaceView(.failures)
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(model.failureJobs.count, 500)
        await model.scanFailures(restart: false)
        XCTAssertEqual(model.failureJobs.count, 620)
        XCTAssertFalse(model.failureScanHasMore)
        engine.failedPageDelay = 100_000_000
        let scan = Task { await model.scanFailures() }
        try? await Task.sleep(nanoseconds: 20_000_000)
        await model.disconnect()
        await scan.value
        XCTAssertTrue(model.failureJobs.isEmpty)
        XCTAssertFalse(model.isScanningFailures)
    }

    func testOfflineDemoDoesNotConnectLiveEngineAndCanExit() async throws {
        let engine = FakeBullMQEngine()
        let model = makeModel(engine: engine)
        await model.startDemo()
        XCTAssertTrue(model.isDemo)
        XCTAssertTrue(model.isReadOnly)
        XCTAssertNil(engine.connectedConfig)
        XCTAssertEqual(model.failureGroups.count, 3)
        XCTAssertEqual(model.failureJobs.count, 18)
        await model.inspectJob(JobReference(prefix: "bull", queue: "email-delivery", jobID: "demo-1"))
        XCTAssertNotNil(model.selectedJobDetail)
        await model.connect()
        XCTAssertFalse(model.isDemo)
        XCTAssertNotNil(engine.connectedConfig)
        XCTAssertTrue(model.failureJobs.isEmpty)
    }

    func testSSHDestinationsDoNotShareSavedQueues() async {
        let engine = FakeBullMQEngine()
        let model = makeModel(engine: engine)
        model.useSSH = true
        model.sshSettings.host = "first-bastion"
        await model.connect()
        await model.addManualQueue(named: "private-queue")
        model.sshSettings.host = "second-bastion"
        await model.connect()
        XCTAssertTrue(model.queues.isEmpty)
        model.sshSettings.host = "first-bastion"
        await model.connect()
        XCTAssertEqual(model.queues.map(\.name), ["private-queue"])
    }

    func testSSHSettingsAreAppliedToConnection() async {
        let engine = FakeBullMQEngine()
        let model = makeModel(engine: engine)
        model.useSSH = true
        model.sshSettings = SSHConnectionSettings(host: "bastion", user: "developer", port: 2222, identityFile: "~/.ssh/id_ed25519")
        await model.connect()
        XCTAssertEqual(engine.connectedConfig?.ssh, model.sshSettings)
        XCTAssertEqual(model.activeConnection?.host, "127.0.0.1")
    }

    func testCompleteWindowLayoutsRender() async throws {
        let engine = FakeBullMQEngine()
        let model = makeModel(engine: engine)
        await model.connect()
        var counts = QueueCounts.empty
        counts.waiting = 24; counts.active = 12; counts.failed = 1000; counts.completed = 150
        let queue = QueueSummary(name: "campaign-stats-child", displayName: "Campaign Stats Child", prefix: "bull", counts: counts, health: .healthy)
        model.selectedQueue = queue
        model.queues = [queue]
        model.jobs = [makeJob(id: "job-1", queueName: queue.name, state: .failed)]
        model.workers = [WorkerSummary(id: "42", queueName: queue.name, name: "campaign-worker", raw: ["status": "connected", "addr": "127.0.0.1:54321", "age": "3600", "idle": "2", "cmd": "bzpopmin"])]
        model.schedulers = [SchedulerSummary(id: "daily-report", queueName: queue.name, name: "Daily report", nextRun: .now.addingTimeInterval(3600), raw: ["pattern": "0 9 * * *", "tz": "UTC"])]
        let parent = JobReference(prefix: "bull", queue: queue.name, jobID: "parent")
        let child = JobReference(prefix: "bull", queue: "attachments", jobID: "child")
        engine.flowResult = JobFlow(nodes: [JobFlowNode(reference: parent, name: "Prepare report", state: .waitingChildren, depth: 0), JobFlowNode(reference: child, name: "Create attachment", state: .active, depth: 1)], edges: [JobFlowEdge(parent: parent.id, child: child.id)])
        model.flowJobID = "parent"
        await model.loadFlow()
        model.runTotal = 1
        model.jobFilter.createdAfter = .now.addingTimeInterval(-86400)
        model.jobFilter.createdBefore = .now
        model.snapshots = [QueueMetricSnapshot(queueName: queue.name, capturedAt: .now,
            counts: QueueCountsSnapshot(waiting: 24, active: 0, delayed: 0, prioritized: 0, completed: 150, failed: 1000, paused: 0, waitingChildren: 0),
            nativeMetrics: BullMQNativeMetrics(
                completed: BullMQMetricSeries(count: 4_700_000, previousTimestamp: .now, previousCount: 0, data: Array(repeating: 27, count: 1440)),
                failed: BullMQMetricSeries(count: 328_000, previousTimestamp: .now, previousCount: 0, data: Array(repeating: 7, count: 1440))))]
        model.profiles = [RedisConnectionProfile(name: "Local Redis", redisURL: "redis://127.0.0.1:6379", prefix: "bull")]
        engine.failedJobsByQueue[queue.name] = model.jobs
        await model.scanFailures()
        model.lastRefreshedAt = .now
        for dark in [false, true] {
            let theme = dark ? "dark" : "light"
            for width in [1120, 1400] {
                for view in QueueWorkspaceView.allCases {
                    model.selectedView = view
                    try await renderLayout(AnyView(DashboardRootView().environmentObject(model)), width: width, height: 850, name: "\(theme)-window-\(width)-\(view.rawValue)", dark: dark)
                }
            }
            try await renderLayout(AnyView(ConnectionManagerView().environmentObject(model)), width: 695, height: 520, name: "\(theme)-connection", dark: dark)
            try await renderLayout(AnyView(ManualQueuePopover(queueName: .constant("report-jobs"), displayName: .constant("Report jobs"), prefix: "bull", addQueue: {})), width: 337, height: 310, name: "\(theme)-add-queue", dark: dark)
            try await renderLayout(AnyView(QueueGroupPopover(queue: queue, groupName: .constant("Reporting"), existingGroups: ["Reporting", "Notifications"], save: { _ in }, clear: {})), width: 337, height: 300, name: "\(theme)-move-queue", dark: dark)
            try await renderLayout(AnyView(QueueGroupManagementPopover(queues: [queue], existingGroups: ["Reporting", "Notifications"], createGroup: { _, _ in }, ungroupQueues: { _ in })), width: 362, height: 440, name: "\(theme)-groups", dark: dark)
            let draft = JobDuplicateDraft(name: "Generate report", dataJSON: "{\"reportId\": \"report-42\"}", optionsJSON: "{\"attempts\": 3}")
            try await renderLayout(AnyView(JobDraftSheet(title: "Add job", message: "Add a job to Campaign Stats Child.", submitTitle: "Add", draft: .constant(draft), isSubmitting: false, submit: {}, cancel: {})), width: 680, height: 620, name: "\(theme)-job-form", dark: dark)
            model.selectedJob = model.jobs.first
            var detail = makeJobDetail(id: "job-1", queueName: queue.name, state: .failed)
            detail.data = .json("{\"reportId\": \"report-42\", \"status\": \"pending\"}")
            detail.options = .json("{\"attempts\": 3}")
            detail.failedReason = "The report service did not respond before the timeout."
            detail.stacktrace = ["Error: request timed out\n    at processReport (worker.js:42:10)"]
            model.selectedJobDetail = detail
            try await renderLayout(AnyView(JobInspectorView().environmentObject(model)), width: 500, height: 850, name: "\(theme)-inspector", dark: dark)
            model.selectedJobDetail = nil
        }
    }

    func testOnboardingAndDemoLayoutsRender() async throws {
        let model = makeModel(engine: FakeBullMQEngine())
        model.useSSH = true
        model.sshSettings.host = "bastion.example.com"
        model.sshSettings.user = "developer"
        for dark in [false, true] {
            let theme = dark ? "dark" : "light"
            try await renderLayout(AnyView(ConnectionManagerView().environmentObject(model)), width: 695, height: 520, name: "\(theme)-ssh-onboarding", dark: dark)
        }
        await model.startDemo()
        for dark in [false, true] {
            let theme = dark ? "dark" : "light"
            try await renderLayout(AnyView(DashboardRootView().environmentObject(model)), width: 1120, height: 720, name: "\(theme)-demo-inbox", dark: dark)
        }
    }

    private func renderLayout(_ view: AnyView, width: Int, height: Int, name: String, dark: Bool = false) async throws {
        let rect = NSRect(x: 0, y: 0, width: width, height: height)
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        // The harness supplies an exact viewport; do not resize it to content.
        host.sizingOptions = []
        let window = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        defer {
            window.contentView = nil
            window.orderOut(nil)
        }
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        host.frame = rect
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        window.orderOut(nil)
        try png.write(to: URL(fileURLWithPath: "/tmp/queuescope-layout-\(name).png"))
    }

    func testFailedProfileSwitchDisconnectsOldSession() async {
        let engine = FakeBullMQEngine()
        let model = makeModel(engine: engine)
        await model.connect()
        XCTAssertTrue(model.isConnected)
        engine.connectShouldFail = true
        await model.connect(profile: RedisConnectionProfile(name: "Unavailable", redisURL: "redis://unavailable:6379", prefix: "other"))
        XCTAssertFalse(model.isConnected)
        XCTAssertNil(engine.connectedConfig)
        XCTAssertTrue(model.queues.isEmpty)
    }

    func testQueueLoadFromPreviousConnectionCannotPopulateNewSession() async {
        let engine = FakeBullMQEngine()
        let model = makeModel(engine: engine)
        await model.connect()
        engine.overviewDelayByQueue["old"] = 100_000_000
        let loading = Task { await model.addManualQueue(named: "old") }
        try? await Task.sleep(for: .milliseconds(20))
        await model.connect(profile: RedisConnectionProfile(name: "New", redisURL: "redis://new-host"))
        await loading.value
        XCTAssertTrue(model.queues.isEmpty)
        XCTAssertNil(model.selectedQueue)
    }

    func testMissingCredentialsCannotConnectAsTheDefaultRedisUser() async {
        let engine = FakeBullMQEngine()
        let model = makeModel(engine: engine)
        var profile = RedisConnectionProfile(name: "Missing", redisURL: "redis://localhost")
        profile.credentialsInKeychain = true
        await model.connect(profile: profile)
        XCTAssertFalse(model.isConnected)
        XCTAssertNil(engine.connectedConfig)
        XCTAssertTrue(model.lastError?.contains("are missing") == true)
    }

    func testEditingPrefixDoesNotChangeActiveSession() async {
        let engine = FakeBullMQEngine()
        let model = makeModel(engine: engine)
        await model.connect()
        model.prefix = "edited-but-not-connected"
        model.redisURL = "redis://edited-host"
        model.connectionProfileName = "Edited name"
        XCTAssertEqual(model.activeConnection?.host, "127.0.0.1")
        XCTAssertEqual(model.activeConnection?.name, "Local Redis")
        model.selectedQueue = QueueSummary(name: "email", prefix: "bull", counts: .empty, health: .unknown)
        await model.refreshSelectedQueue(for: .runs)
        XCTAssertEqual(engine.overviewPrefixes.last, "bull")
    }

    func testOverviewRefreshLoadsTimingSamplesButSkipsWorkersAndSchedulers() async {
        let engine = FakeBullMQEngine()
        let model = makeModel(engine: engine)
        model.selectedQueue = QueueSummary(name: "email", prefix: "bull", counts: .empty, health: .unknown)

        await model.refreshSelectedQueue(for: .overview)

        XCTAssertEqual(engine.overviewCalls, ["email"])
        XCTAssertEqual(engine.recentJobsCalls, ["email"])
        XCTAssertTrue(engine.workerCalls.isEmpty)
        XCTAssertTrue(engine.schedulerCalls.isEmpty)
    }

    func testRunsRefreshLoadsOnlyOverviewAndRuns() async {
        let engine = FakeBullMQEngine()
        engine.recentJobs = [makeJob(id: "1", queueName: "email", state: .failed)]
        let model = makeModel(engine: engine)
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
        let model = makeModel(engine: engine)
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
        let model = makeModel(engine: engine)
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
        let model = makeModel(engine: engine)
        model.prefix = "bull"

        await model.addManualQueue(named: "bull:setup-inboxkit-mailbox-v2:meta", displayName: "Inbox setup")

        XCTAssertEqual(model.queues.first?.name, "setup-inboxkit-mailbox-v2")
        XCTAssertEqual(model.queues.first?.displayName, "Inbox setup")
        XCTAssertEqual(model.selectedQueue?.resolvedDisplayName, "Inbox setup")
    }

    func testQueueCanBeAssignedToExplicitGroup() {
        let model = makeModel(engine: FakeBullMQEngine())
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
        let model = makeModel(engine: engine)

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
        let model = makeModel(engine: engine)

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
        let model = makeModel(engine: engine)

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
        let model = makeModel(engine: engine)

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
                "opts": #"{"attempts":3,"jobId":"original","repeat":{"every":60000},"de":{"id":"dedupe-key"},"parentKey":"bull:parent","prevMillis":1781107200000}"#
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
        XCTAssertFalse(draft.optionsJSON.contains("de"))
        XCTAssertFalse(draft.optionsJSON.contains("parentKey"))
        XCTAssertFalse(draft.optionsJSON.contains("prevMillis"))
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
        let model = makeModel(engine: engine)
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
        let model = makeModel(engine: engine)
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
        let model = makeModel(engine: engine)
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
        let model = makeModel(engine: engine)
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

    func testRunSelectionCanToggleVisibleRuns() {
        let model = makeModel(engine: FakeBullMQEngine())
        let first = makeJob(id: "1", queueName: "email", state: .failed)
        let second = makeJob(id: "2", queueName: "email", state: .completed)
        model.jobs = [first, second]

        model.toggleJobSelection(first)
        XCTAssertTrue(model.isJobSelectedForBulk(first))
        XCTAssertEqual(model.selectedVisibleJobCount, 1)

        model.toggleAllVisibleJobSelection()
        XCTAssertTrue(model.allVisibleJobsSelected)
        XCTAssertEqual(model.selectedVisibleJobCount, 2)

        model.toggleAllVisibleJobSelection()
        XCTAssertFalse(model.isJobSelectedForBulk(first))
        XCTAssertEqual(model.selectedVisibleJobCount, 0)
    }

    func testBulkRetryOnlyRetriesEligibleSelectedRunsAndRefreshesOnce() async {
        let engine = FakeBullMQEngine()
        let failed = makeJob(id: "1", queueName: "email", state: .failed)
        let completed = makeJob(id: "2", queueName: "email", state: .completed)
        let waiting = makeJob(id: "3", queueName: "email", state: .waiting)
        engine.recentJobs = [waiting]
        let model = makeModel(engine: engine)
        model.selectedQueue = QueueSummary(name: "email", prefix: "bull", counts: .empty, health: .unknown)
        model.selectedView = .runs
        model.jobs = [failed, completed, waiting]

        await model.retryJobs([failed, completed, waiting])

        XCTAssertEqual(engine.retryCalls.map(\.jobID), ["1", "2"])
        XCTAssertEqual(engine.overviewCalls, ["email"])
        XCTAssertEqual(engine.recentJobsCalls, ["email"])
        XCTAssertEqual(model.statusMessage, "Retried 2 jobs")
    }

    func testBulkPromoteOnlyPromotesDelayedRuns() async {
        let engine = FakeBullMQEngine()
        let delayed = makeJob(id: "1", queueName: "email", state: .delayed)
        let waiting = makeJob(id: "2", queueName: "email", state: .waiting)
        let model = makeModel(engine: engine)
        model.selectedQueue = QueueSummary(name: "email", prefix: "bull", counts: .empty, health: .unknown)
        model.selectedView = .runs

        await model.promoteJobs([delayed, waiting])

        XCTAssertEqual(engine.promoteCalls, ["1"])
        XCTAssertEqual(engine.overviewCalls, ["email"])
        XCTAssertEqual(engine.recentJobsCalls, ["email"])
        XCTAssertEqual(model.statusMessage, "Promoted 1 jobs")
    }

    func testBulkRemoveClearsRemovedSelectionAndSelectedJob() async {
        let engine = FakeBullMQEngine()
        let failed = makeJob(id: "1", queueName: "email", state: .failed)
        let active = makeJob(id: "2", queueName: "email", state: .active)
        let model = makeModel(engine: engine)
        model.selectedQueue = QueueSummary(name: "email", prefix: "bull", counts: .empty, health: .unknown)
        model.selectedView = .runs
        model.jobs = [failed, active]
        model.selectedJob = failed
        model.toggleJobSelection(failed)
        model.toggleJobSelection(active)

        await model.removeJobs([failed, active], removeChildren: true)

        XCTAssertEqual(engine.removeCalls.map(\.jobID), ["1"])
        XCTAssertEqual(engine.removeCalls.map(\.removeChildren), [true])
        XCTAssertNil(model.selectedJob)
        XCTAssertFalse(model.isJobSelectedForBulk(failed))
        XCTAssertFalse(model.isJobSelectedForBulk(active))
        XCTAssertEqual(model.statusMessage, "Removed 1 jobs")
    }

    func testAddJobRefreshesRuns() async {
        let engine = FakeBullMQEngine()
        engine.addedJobID = "new"
        let model = makeModel(engine: engine)
        model.selectedQueue = QueueSummary(name: "email", prefix: "bull", counts: .empty, health: .unknown)
        model.selectedView = .runs

        await model.addJob(
            queueName: "email",
            draft: JobDuplicateDraft(
                name: "send-email",
                dataJSON: #"{"leadId":"lead_1"}"#,
                optionsJSON: #"{"attempts":3,"jobId":"custom"}"#
            )
        )

        XCTAssertEqual(engine.addCalls.map(\.name), ["send-email"])
        XCTAssertEqual(engine.overviewCalls, ["email"])
        XCTAssertEqual(engine.recentJobsCalls, ["email"])
        XCTAssertEqual(model.statusMessage, "Added job new")
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
    var addCalls: [(name: String, data: AnySendableJSON, options: AnySendableJSON)] = []
    var addedJobID = "added"

    var foundJob: JobSummary?
    var lookupDelayByID: [String: UInt64] = [:]
    var missingJobIDs: Set<String> = []
    var lookupCalls: [(prefix: String, queue: String, id: String)] = []
    var flowCalls: [JobReference] = []
    var flowResult = JobFlow()
    var overviewError: Error?
    var discoveredNames: [String] = []
    var searchResult = JobSearchResult(jobs: [], next: nil, scanned: 0)
    var pauseCalls: [Bool] = []
    func discoverQueues(prefix: String, cursor: String) async throws -> QueueDiscovery { QueueDiscovery(names: discoveredNames, nextCursor: "0") }
    func findJob(queueName: String, prefix: String, jobID: String) async throws -> JobSummary? {
        lookupCalls.append((prefix, queueName, jobID))
        if let delay = lookupDelayByID[jobID] { try? await Task.sleep(nanoseconds: delay) }
        return missingJobIDs.contains(jobID) ? nil : foundJob
    }
    func searchJobs(queueName: String, prefix: String, state: BullMQState?, filter: JobFilter, cursor: JobSearchCursor) async throws -> JobSearchResult { searchResult }
    func getJobFlow(_ reference: JobReference) async throws -> JobFlow { flowCalls.append(reference); return flowResult }
    func setQueuePaused(queueName: String, prefix: String, paused: Bool) async throws { pauseCalls.append(paused) }
    var failedJobsByQueue: [String: [JobSummary]] = [:]
    var failedPageDelay: UInt64 = 0
    var connectShouldFail = false
    var connectedConfig: RedisConnectionConfig?
    var overviewPrefixes: [String] = []

    func connect(_ config: RedisConnectionConfig) async throws {
        if connectShouldFail { throw BullMQDashboardError.redis("Connection refused") }
        connectedConfig = config
    }

    func disconnect() async { connectedConfig = nil }

    func getQueueOverview(queueName: String, prefix: String) async throws -> QueueSummary {
        overviewCalls.append(queueName)
        overviewPrefixes.append(prefix)
        if let overviewError { throw overviewError }
        if let delay = overviewDelayByQueue[queueName] {
            try? await Task.sleep(nanoseconds: delay)
        }
        return QueueSummary(name: queueName, prefix: prefix, counts: .empty, health: .healthy)
    }

    func getJobs(queueName: String, prefix: String, state: BullMQState, page: Int, pageSize: Int) async throws -> JobPage {
        if failedPageDelay > 0 { try? await Task.sleep(nanoseconds: failedPageDelay) }
        let values = state == .failed ? (failedJobsByQueue[queueName] ?? recentJobs) : recentJobs
        return JobPage(jobs: Array(values.dropFirst(page * pageSize).prefix(pageSize)), total: values.count, page: page, pageSize: pageSize)
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

    func addJob(queueName: String, prefix: String, name: String, data: AnySendableJSON, options: AnySendableJSON) async throws -> String {
        addCalls.append((name: name, data: data, options: options))
        return addedJobID
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
