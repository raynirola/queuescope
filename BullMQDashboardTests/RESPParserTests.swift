import Foundation
import XCTest
@testable import BullMQDashboard

final class RESPParserTests: XCTestCase {
    func testParsesMultipleFramesAfterRemovingFirstFrame() throws {
        var parser = RESPParser()
        parser.append(Data("+OK\r\n:42\r\n".utf8))

        XCTAssertEqual(try parser.parseNext(), .simpleString("OK"))
        XCTAssertEqual(try parser.parseNext(), .integer(42))
    }

    func testWaitsForPartialBulkStringFrame() throws {
        var parser = RESPParser()
        parser.append(Data("$5\r\nhe".utf8))
        XCTAssertNil(try parser.parseNext())

        parser.append(Data("llo\r\n".utf8))
        XCTAssertEqual(try parser.parseNext(), .bulkString("hello"))
    }

    func testParsesNestedArrayFrame() throws {
        var parser = RESPParser()
        parser.append(Data("*2\r\n$1\r\n0\r\n*2\r\n$11\r\nbull:a:meta\r\n$11\r\nbull:b:meta\r\n".utf8))

        XCTAssertEqual(
            try parser.parseNext(),
            .array([
                .bulkString("0"),
                .array([
                    .bulkString("bull:a:meta"),
                    .bulkString("bull:b:meta")
                ])
            ])
        )
    }

    func testParsesPipelinedResponsesInOrder() throws {
        var parser = RESPParser()
        parser.append(Data(":8\r\n*2\r\n$3\r\none\r\n$3\r\ntwo\r\n+OK\r\n".utf8))

        XCTAssertEqual(try parser.parseNext(), .integer(8))
        XCTAssertEqual(
            try parser.parseNext(),
            .array([
                .bulkString("one"),
                .bulkString("two")
            ])
        )
        XCTAssertEqual(try parser.parseNext(), .simpleString("OK"))
    }

    func testParsesBackToBackPipelineBatchesInOrder() throws {
        var parser = RESPParser()
        parser.append(Data(":1\r\n:2\r\n:3\r\n:4\r\n".utf8))

        XCTAssertEqual(try parser.parseNext(), .integer(1))
        XCTAssertEqual(try parser.parseNext(), .integer(2))
        XCTAssertEqual(try parser.parseNext(), .integer(3))
        XCTAssertEqual(try parser.parseNext(), .integer(4))
    }
}

@MainActor
final class RedisTransportTests: XCTestCase {
    func testPipelineErrorDoesNotLeakResponsesIntoNextCommand() async throws {
        try await withRedis { client, _ in
            do {
                _ = try await client.commands([["SET", "wrong-type", "value"], ["LLEN", "wrong-type"], ["ECHO", "stale"]])
                XCTFail("Expected WRONGTYPE")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("WRONGTYPE"))
            }
            let response = try await client.command(["ECHO", "fresh"])
            XCTAssertEqual(response.string, "fresh")
        }
    }

    func testTimeoutInvalidatesConnectionAndReconnectStartsClean() async throws {
        try await withRedis { client, config in
            do {
                _ = try await client.command(["BLPOP", "empty", "0"])
                XCTFail("Expected timeout")
            } catch { XCTAssertTrue(error.localizedDescription.contains("Timed out")) }
            do {
                _ = try await client.command(["PING"])
                XCTFail("Timed-out connection must not be reused")
            } catch { XCTAssertEqual(error as? BullMQDashboardError, .notConnected) }
            try await client.connect(config)
            let response = try await client.command(["PING"])
            XCTAssertEqual(response.string, "PONG")
        }
    }

    func testCancelledPipelineIsDrainedBeforeNextCommand() async throws {
        try await withRedis(commandTimeout: 2) { client, _ in
            let pending = Task { try await client.commands([["BLPOP", "empty", "1"], ["ECHO", "old"]]) }
            try await Task.sleep(for: .milliseconds(100))
            pending.cancel()
            do { _ = try await pending.value; XCTFail("Expected cancellation") }
            catch { XCTAssertTrue(error is CancellationError) }
            let response = try await client.command(["ECHO", "new"])
            XCTAssertEqual(response.string, "new")
        }
    }

    func testFeaturesAgainstOfficialBullMQFixture() async throws {
        try await withRedis(commandTimeout: 5) { client, config in
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            let fixture = root.appendingPathComponent("BullMQActionBridge/feature-fixture.mjs")
            let node = try XCTUnwrap(BullMQMutationClient.defaultNodePath())
            let process = Process()
            let input = Pipe()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: node)
            let package = try XCTUnwrap(Bundle.main.resourceURL).appendingPathComponent("BullMQActionBridge/node_modules/bullmq")
            process.arguments = [fixture.path, String(config.port), package.path]
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.standardError
            try process.run()
            defer {
                try? input.fileHandleForWriting.close()
                if process.isRunning { process.terminate(); process.waitUntilExit() }
            }
            let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: deadline)
            let ready = output.fileHandleForReading.availableData
            deadline.cancel()
            XCTAssertEqual(String(data: ready, encoding: .utf8), "READY\n")
            guard process.isRunning else { return XCTFail("Fixture did not start") }

            let engine = BullMQRedisEngine()
            try await engine.connect(config)
            do {
                var names: Set<String> = []
                var cursor = "0"
                repeat {
                    let page = try await engine.discoverQueues(prefix: "bull", cursor: cursor)
                    names.formUnion(page.names); cursor = page.nextCursor
                } while cursor != "0"
                XCTAssertTrue(names.isSuperset(of: ["feature-jobs", "parents", "children", "workers"]))
                var literalNames: Set<String> = []
                cursor = "0"
                repeat {
                    let page = try await engine.discoverQueues(prefix: "team[*]", cursor: cursor)
                    literalNames.formUnion(page.names); cursor = page.nextCursor
                } while cursor != "0"
                XCTAssertEqual(literalNames, ["literal"])

                let job = try await engine.findJob(queueName: "feature-jobs", prefix: "bull", jobID: "job-0")
                XCTAssertEqual(job?.name, "needle")
                XCTAssertEqual(job?.state, .waiting)
                let missing = try await engine.findJob(queueName: "feature-jobs", prefix: "bull", jobID: "absent")
                XCTAssertNil(missing)
                let filter = JobFilter(name: "NEEDLE", createdAfter: Date(timeIntervalSince1970: 1_735_689_600), createdBefore: Date(timeIntervalSince1970: 1_798_761_600))
                let first = try await engine.searchJobs(queueName: "feature-jobs", prefix: "bull", state: nil, filter: filter, cursor: JobSearchCursor())
                XCTAssertTrue(first.jobs.isEmpty)
                XCTAssertEqual(first.scanned, 500)
                let next = try XCTUnwrap(first.next)
                let second = try await engine.searchJobs(queueName: "feature-jobs", prefix: "bull", state: nil, filter: filter, cursor: next)
                XCTAssertEqual(second.jobs.map(\.id), ["job-0"])
                XCTAssertNil(second.next)
                let failures = try await engine.searchJobs(queueName: "outcomes", prefix: "bull", state: .failed, filter: JobFilter(name: "failure", error: "fixture failure"), cursor: JobSearchCursor())
                XCTAssertEqual(failures.jobs.map(\.id), ["outcome-failed"])
                let tooRecent = try await engine.searchJobs(queueName: "feature-jobs", prefix: "bull", state: .waiting, filter: JobFilter(createdAfter: Date(timeIntervalSince1970: 1_798_761_600)), cursor: JobSearchCursor())
                XCTAssertTrue(tooRecent.jobs.isEmpty)

                let workers = try await engine.getWorkers(queueName: "workers", prefix: "bull")
                XCTAssertEqual(workers.map(\.name), ["visible"])
                XCTAssertEqual(workers.first?.raw["source"], "client-list")
                let noWorkers = try await engine.getWorkers(queueName: "feature-jobs", prefix: "bull")
                XCTAssertTrue(noWorkers.isEmpty)

                let flow = try await engine.getJobFlow(JobReference(prefix: "bull", queue: "parents", jobID: "root"))
                XCTAssertEqual(Set(flow.nodes.map { $0.reference.queue }), ["parents", "children", "grandchildren"])
                XCTAssertEqual(flow.nodes.count, 4)
                XCTAssertEqual(flow.edges.count, 3)
                XCTAssertFalse(flow.truncated)
                let branch = try await engine.getJobFlow(JobReference(prefix: "bull", queue: "children", jobID: "child-a"))
                XCTAssertEqual(Set(branch.nodes.map { $0.reference.jobID }), ["root", "child-a", "grandchild"])
                let wide = try await engine.getJobFlow(JobReference(prefix: "bull", queue: "parents", jobID: "wide"))
                XCTAssertEqual(wide.nodes.count, 80)
                XCTAssertTrue(wide.truncated)

                try await engine.setQueuePaused(queueName: "feature-jobs", prefix: "bull", paused: true)
                let paused = try await engine.getQueueOverview(queueName: "feature-jobs", prefix: "bull")
                XCTAssertTrue(paused.isPaused)
                XCTAssertEqual(paused.counts.paused, 620)
                try await engine.setQueuePaused(queueName: "feature-jobs", prefix: "bull", paused: false)
                let resumed = try await engine.getQueueOverview(queueName: "feature-jobs", prefix: "bull")
                XCTAssertFalse(resumed.isPaused)
                XCTAssertEqual(resumed.counts.waiting, 620)
                var readOnly = config
                readOnly.isReadOnly = true
                try await engine.connect(readOnly)
                do {
                    try await engine.setQueuePaused(queueName: "feature-jobs", prefix: "bull", paused: true)
                    XCTFail("Read-only connection must reject queue mutations")
                } catch { XCTAssertTrue(error.localizedDescription.contains("read-only")) }
                let stillRunning = try await engine.getQueueOverview(queueName: "feature-jobs", prefix: "bull")
                XCTAssertFalse(stillRunning.isPaused)
            } catch { await engine.disconnect(); throw error }
            await engine.disconnect()
        }
    }

    private func withRedis(commandTimeout: TimeInterval = 0.2, _ operation: (RedisRESPClient, RedisConnectionConfig) async throws -> Void) async throws {
        let candidates = [ProcessInfo.processInfo.environment["REDIS_SERVER_PATH"], "/opt/homebrew/bin/redis-server", "/usr/local/bin/redis-server"].compactMap { $0 }
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("Install Redis to run local transport integration tests")
        }
        let port = Int.random(in: 20000...60000)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["--bind", "127.0.0.1", "--port", String(port), "--save", "", "--appendonly", "no"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        let config = try RedisURLParser.parse("redis://127.0.0.1:\(port)")
        let client = RedisRESPClient(commandTimeout: commandTimeout)
        var connected = false
        for _ in 0..<40 {
            guard process.isRunning else { throw BullMQDashboardError.redis("Test Redis failed to start") }
            do { try await client.connect(config); connected = true; break }
            catch { try await Task.sleep(for: .milliseconds(25)) }
        }
        XCTAssertTrue(connected)
        do { try await operation(client, config) }
        catch { await client.disconnect(); throw error }
        await client.disconnect()
    }
}

@MainActor
final class MutationProcessTests: XCTestCase {
    private func withBridge(_ source: String, timeout: TimeInterval = 2, operation: (BullMQMutationClient) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("QueueScopeBridgeTests.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("bridge.mjs")
        try source.write(to: file, atomically: true, encoding: .utf8)
        try await operation(BullMQMutationClient(bridgePath: file.path, timeout: timeout))
    }

    private func add(_ client: BullMQMutationClient) async throws -> String {
        try await client.addJob(config: RedisURLParser.parse("redis://localhost"), queueName: "test", prefix: "bull", name: "test", data: AnySendableJSON([:]), options: AnySendableJSON([:]))
    }

    func testDrainsBothPipesBeforeWaitingForExit() async throws {
        try await withBridge("""
        for await (const chunk of process.stdin) {}
        process.stderr.write('x'.repeat(500000));
        process.stdout.write(' '.repeat(500000) + JSON.stringify({ok:true,result:{jobID:'new'}}));
        """) { client in
            let result = try await add(client)
            XCTAssertEqual(result, "new")
        }
    }

    func testTimeoutTerminatesBridgeAndReportsUnknownOutcome() async throws {
        let start = Date()
        try await withBridge("setInterval(() => {}, 1000)", timeout: 0.3) { client in
            do { _ = try await add(client); XCTFail("Expected timeout") }
            catch {
                XCTAssertTrue(error.localizedDescription.contains("timed out"))
                XCTAssertTrue(error.localizedDescription.contains("outcome is unknown"))
            }
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    func testCancellationTerminatesBridge() async throws {
        try await withBridge("setInterval(() => {}, 1000)", timeout: 10) { client in
            let task = Task { try await self.add(client) }
            try await Task.sleep(for: .milliseconds(200))
            let start = Date()
            task.cancel()
            do { _ = try await task.value; XCTFail("Expected cancellation") }
            catch { XCTAssertTrue(error.localizedDescription.contains("cancelled")) }
            XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        }
    }

    func testReadOnlyRejectsEveryBridgeMutationBeforeLaunchingNode() async throws {
        var config = try RedisURLParser.parse("redis://localhost")
        config.isReadOnly = true
        let client = BullMQMutationClient(bridgePath: "/nonexistent", nodePath: "/usr/bin/false")
        let operations: [() async throws -> Void] = [
            { try await client.retryJob(config: config, queueName: "test", prefix: "bull", jobID: "1", state: .failed) },
            { try await client.removeJob(config: config, queueName: "test", prefix: "bull", jobID: "1", removeChildren: true) },
            { try await client.promoteJob(config: config, queueName: "test", prefix: "bull", jobID: "1") },
            { _ = try await client.addJob(config: config, queueName: "test", prefix: "bull", name: "job", data: AnySendableJSON([:]), options: AnySendableJSON([:])) },
            { _ = try await client.duplicateJob(config: config, queueName: "test", prefix: "bull", name: "job", data: AnySendableJSON([:]), options: AnySendableJSON([:])) },
            { try await client.setQueuePaused(config: config, queueName: "test", prefix: "bull", paused: true) },
            { try await client.setQueuePaused(config: config, queueName: "test", prefix: "bull", paused: false) }
        ]
        for operation in operations {
            do { try await operation(); XCTFail("Read-only mutation was accepted") }
            catch { XCTAssertTrue(error.localizedDescription.contains("read-only")) }
        }
    }

    func testMissingResultReportsUnknownOutcome() async throws {
        try await withBridge("for await (const chunk of process.stdin) {}") { client in
            do { _ = try await add(client); XCTFail("Expected missing result") }
            catch { XCTAssertTrue(error.localizedDescription.contains("outcome is unknown")) }
        }
    }

    func testExcessiveOutputTerminatesBridge() async throws {
        try await withBridge("for await (const chunk of process.stdin) {}\nprocess.stdout.write('x'.repeat(2000000));") { client in
            do { _ = try await add(client); XCTFail("Expected output limit") }
            catch { XCTAssertTrue(error.localizedDescription.contains("output limit")) }
        }
    }
}
