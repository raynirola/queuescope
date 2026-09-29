import Foundation
import Darwin

struct BullMQMutationClient: Sendable {
    private let bridgePath: String
    private let nodePath: String?
    private let timeout: TimeInterval

    init(bridgePath: String? = nil, nodePath: String? = nil, timeout: TimeInterval = 30) {
        self.timeout = timeout
        self.bridgePath = bridgePath ?? Self.defaultBridgePath()
        self.nodePath = nodePath ?? Self.defaultNodePath()
    }

    func setQueuePaused(config: RedisConnectionConfig, queueName: String, prefix: String, paused: Bool) async throws {
        try await run(request: BridgeRequest(redis: BridgeRedisConfig(config), queueName: queueName, prefix: prefix, action: paused ? "pause" : "resume", payload: [:]))
    }

    func retryJob(config: RedisConnectionConfig, queueName: String, prefix: String, jobID: String, state: BullMQState) async throws {
        try await run(
            request: BridgeRequest(
                redis: BridgeRedisConfig(config),
                queueName: queueName,
                prefix: prefix,
                action: "retry",
                payload: [
                    "jobID": jobID,
                    "state": state.rawValue
                ]
            )
        )
    }

    func removeJob(config: RedisConnectionConfig, queueName: String, prefix: String, jobID: String, removeChildren: Bool) async throws {
        try await run(
            request: BridgeRequest(
                redis: BridgeRedisConfig(config),
                queueName: queueName,
                prefix: prefix,
                action: "remove",
                payload: [
                    "jobID": jobID,
                    "removeChildren": removeChildren
                ]
            )
        )
    }

    func promoteJob(config: RedisConnectionConfig, queueName: String, prefix: String, jobID: String) async throws {
        try await run(
            request: BridgeRequest(
                redis: BridgeRedisConfig(config),
                queueName: queueName,
                prefix: prefix,
                action: "promote",
                payload: ["jobID": jobID]
            )
        )
    }

    func duplicateJob(
        config: RedisConnectionConfig,
        queueName: String,
        prefix: String,
        name: String,
        data: AnySendableJSON,
        options: AnySendableJSON
    ) async throws -> String {
        let response = try await run(
            request: BridgeRequest(
                redis: BridgeRedisConfig(config),
                queueName: queueName,
                prefix: prefix,
                action: "duplicate",
                payload: [
                    "name": name,
                    "data": data.value,
                    "options": options.value
                ]
            )
        )
        guard let jobID = response.result?["jobID"]?.stringValue, !jobID.isEmpty else {
            throw BullMQDashboardError.redis("BullMQ action bridge did not return a duplicated job id.")
        }
        return jobID
    }

    func addJob(
        config: RedisConnectionConfig,
        queueName: String,
        prefix: String,
        name: String,
        data: AnySendableJSON,
        options: AnySendableJSON
    ) async throws -> String {
        let response = try await run(
            request: BridgeRequest(
                redis: BridgeRedisConfig(config),
                queueName: queueName,
                prefix: prefix,
                action: "add",
                payload: [
                    "name": name,
                    "data": data.value,
                    "options": options.value
                ]
            )
        )
        guard let jobID = response.result?["jobID"]?.stringValue, !jobID.isEmpty else {
            throw BullMQDashboardError.redis("BullMQ action bridge did not return an added job id.")
        }
        return jobID
    }

    @discardableResult
    private func run(request: BridgeRequest) async throws -> BridgeResponse {
        guard !request.redis.config.isReadOnly else { throw BullMQDashboardError.redis("This connection is read-only.") }
        let requestData = try BridgeJSON.data(from: request.dictionary)
        guard let nodePath else {
            throw BullMQDashboardError.redis("Node.js is required to run BullMQ job actions, but no node executable was found.")
        }
        let runner = BridgeProcess(nodePath: nodePath, bridgePath: bridgePath)
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do { continuation.resume(returning: try runner.run(input: requestData, timeout: timeout)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: {
            runner.stop(reason: "cancelled")
        }
        let outputData = result.output
        let errorText = String(data: result.errors, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !outputData.isEmpty else {
            throw BullMQDashboardError.redis("BullMQ action bridge returned no result. The action outcome is unknown; refresh the job before retrying. \(errorText.prefix(4096))")
        }

        let response: BridgeResponse
        do { response = try BridgeResponse(data: outputData) }
        catch {
            throw BullMQDashboardError.redis("BullMQ action bridge returned invalid output. The action outcome is unknown; refresh the job before retrying.")
        }
        if response.ok {
            guard result.exitCode == 0 else {
                throw BullMQDashboardError.redis("BullMQ action bridge exited unexpectedly. The action outcome is unknown; refresh the job before retrying.")
            }
            return response
        }

        let message = response.error?.isEmpty == false ? response.error! : errorText
        throw BullMQDashboardError.redis(message.isEmpty ? "BullMQ action bridge failed." : message)
    }

    private static func defaultBridgePath(sourceFilePath: String = #filePath) -> String {
        if let override = ProcessInfo.processInfo.environment["BULLMQ_ACTION_BRIDGE_PATH"], !override.isEmpty {
            return override
        }

        if let resourcePath = Bundle.main.path(forResource: "bridge", ofType: "mjs", inDirectory: "BullMQActionBridge") {
            return resourcePath
        }

        let sourceURL = URL(fileURLWithPath: sourceFilePath)
        let repoRoot = sourceURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return repoRoot
            .appendingPathComponent("BullMQActionBridge")
            .appendingPathComponent("bridge.mjs")
            .path
    }

    static func defaultNodePath() -> String? {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["BULLMQ_NODE_PATH"], !override.isEmpty, FileManager.default.isExecutableFile(atPath: override) {
            return override
        }

        for path in ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"] where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }

        guard let home = environment["HOME"] else { return nil }
        let nvmVersionsURL = URL(fileURLWithPath: home)
            .appendingPathComponent(".nvm")
            .appendingPathComponent("versions")
            .appendingPathComponent("node")
        guard let versions = try? FileManager.default.contentsOfDirectory(at: nvmVersionsURL, includingPropertiesForKeys: nil) else {
            return nil
        }

        return versions
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending }
            .map { $0.appendingPathComponent("bin").appendingPathComponent("node").path }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

private struct BridgeRedisConfig {
    let config: RedisConnectionConfig

    init(_ config: RedisConnectionConfig) {
        self.config = config
    }

    var dictionary: [String: Any] {
        var value: [String: Any] = [
            "host": config.host,
            "port": config.port,
            "database": config.database,
            "useTLS": config.useTLS
        ]
        if let username = config.username {
            value["username"] = username
        }
        if let password = config.password {
            value["password"] = password
        }
        return value
    }
}

private struct BridgeRequest {
    var redis: BridgeRedisConfig
    var queueName: String
    var prefix: String
    var action: String
    var payload: [String: Any]

    var dictionary: [String: Any] {
        [
            "redis": redis.dictionary,
            "queueName": queueName,
            "prefix": prefix,
            "action": action,
            "payload": payload
        ]
    }
}

private struct BridgeResponse {
    var ok: Bool
    var result: [String: BridgeJSONValue]?
    var error: String?

    init(data: Data) throws {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any], let ok = dictionary["ok"] as? Bool else {
            throw BullMQDashboardError.redis("BullMQ action bridge returned invalid JSON.")
        }
        self.ok = ok
        if let result = dictionary["result"] as? [String: Any] {
            self.result = result.mapValues(BridgeJSONValue.init)
        }
        self.error = dictionary["error"] as? String
    }
}

private struct BridgeJSONValue {
    var rawValue: Any

    var stringValue: String? {
        rawValue as? String
    }
}

private enum BridgeJSON {
    static func data(from value: Any) throws -> Data {
        guard JSONSerialization.isValidJSONObject(value) else {
            throw BullMQDashboardError.redis("BullMQ action bridge request is not valid JSON.")
        }
        return try JSONSerialization.data(withJSONObject: value)
    }
}

// Process and pipe I/O run off Swift's cooperative executor. The lock protects
// launch/cancellation and pipe buffers shared by the dedicated I/O queues.
private final class BridgeProcess: @unchecked Sendable {
    private let process = Process()
    private let lock = NSLock()
    private var stoppedReason: String?
    private var output = Data()
    private var errors = Data()
    private let outputLimit = 1_048_576

    init(nodePath: String, bridgePath: String) {
        process.executableURL = URL(fileURLWithPath: nodePath)
        process.arguments = [bridgePath]
    }

    func stop(reason: String) {
        lock.lock()
        defer { lock.unlock() }
        if stoppedReason == nil { stoppedReason = reason }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    func run(input: Data, timeout: TimeInterval) throws -> (output: Data, errors: Data, exitCode: Int32) {
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        lock.lock()
        if stoppedReason != nil {
            lock.unlock()
            throw BullMQDashboardError.redis("BullMQ action cancelled before launch.")
        }
        do { try process.run() }
        catch {
            lock.unlock()
            throw BullMQDashboardError.redis("Could not run BullMQ action bridge: \(error.localizedDescription)")
        }
        lock.unlock()

        let deadline = DispatchWorkItem { [self] in stop(reason: "timed out") }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        defer { deadline.cancel() }
        let io = DispatchGroup()
        for (pipe, isError) in [(stdout, false), (stderr, true)] {
            io.enter()
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                defer { try? pipe.fileHandleForReading.close(); io.leave() }
                do {
                    while let chunk = try pipe.fileHandleForReading.read(upToCount: 65536), !chunk.isEmpty {
                        lock.lock()
                        let count = isError ? errors.count : output.count
                        if count + chunk.count <= outputLimit {
                            if isError { errors.append(chunk) } else { output.append(chunk) }
                        }
                        lock.unlock()
                        if count + chunk.count > outputLimit {
                            stop(reason: "exceeded the output limit")
                            break
                        }
                    }
                } catch { stop(reason: "failed while reading output") }
            }
        }
        io.enter()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            defer { try? stdin.fileHandleForWriting.close(); io.leave() }
            do { try stdin.fileHandleForWriting.write(contentsOf: input) }
            catch { stop(reason: "failed while sending input") }
        }
        process.waitUntilExit()
        io.wait()
        lock.lock()
        defer { lock.unlock() }
        if let stoppedReason {
            throw BullMQDashboardError.redis("BullMQ action \(stoppedReason). The action outcome is unknown; refresh the job before retrying.")
        }
        return (output, errors, process.terminationStatus)
    }
}
