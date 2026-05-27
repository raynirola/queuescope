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
        engine.recentJobs = [
            JobSummary(
                id: "1",
                queueName: "email",
                state: .failed,
                name: "send-email",
                timestamp: nil,
                processedOn: nil,
                finishedOn: nil,
                delayedUntil: nil,
                attemptsMade: 1,
                attempts: 3,
                failedReason: "boom",
                payloadPreview: "{}"
            )
        ]
        let model = AppModel(engine: engine)
        model.selectedQueue = QueueSummary(name: "email", prefix: "bull", counts: .empty, health: .unknown)

        await model.refreshSelectedQueue(for: .runs)

        XCTAssertEqual(engine.overviewCalls, ["email"])
        XCTAssertEqual(engine.recentJobsCalls, ["email"])
        XCTAssertTrue(engine.workerCalls.isEmpty)
        XCTAssertTrue(engine.schedulerCalls.isEmpty)
        XCTAssertEqual(model.jobs.map(\.id), ["1"])
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
}

private final class FakeBullMQEngine: BullMQEngine, @unchecked Sendable {
    var overviewCalls: [String] = []
    var recentJobsCalls: [String] = []
    var workerCalls: [String] = []
    var schedulerCalls: [String] = []
    var overviewDelayByQueue: [String: UInt64] = [:]
    var recentJobs: [JobSummary] = []

    func connect(_ config: RedisConnectionConfig) async throws {}

    func disconnect() async {}

    func discoverQueues(prefix: String) async throws -> [QueueSummary] {
        []
    }

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
        return Array(recentJobs.prefix(totalLimit))
    }

    func getJobDetail(queueName: String, prefix: String, jobID: String, state: BullMQState) async throws -> JobDetail {
        JobDetail(
            id: jobID,
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
