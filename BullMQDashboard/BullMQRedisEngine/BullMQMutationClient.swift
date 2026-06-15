import Foundation

struct BullMQMutationClient: Sendable {
    private let bridgePath: String
    private let nodePath: String?

    init(bridgePath: String? = nil, nodePath: String? = nil) {
        self.bridgePath = bridgePath ?? Self.defaultBridgePath()
        self.nodePath = nodePath ?? Self.defaultNodePath()
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
        let requestData = try BridgeJSON.data(from: request.dictionary)
        guard let nodePath else {
            throw BullMQDashboardError.redis("Node.js is required to run BullMQ job actions, but no node executable was found.")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: nodePath)
        process.arguments = [bridgePath]

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            try stdin.fileHandleForWriting.write(contentsOf: requestData)
            try stdin.fileHandleForWriting.close()
            process.waitUntilExit()
        } catch {
            throw BullMQDashboardError.redis("Could not run BullMQ action bridge: \(error.localizedDescription)")
        }

        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !outputData.isEmpty else {
            throw BullMQDashboardError.redis(errorText.isEmpty ? "BullMQ action bridge returned no output." : errorText)
        }

        let response = try BridgeResponse(data: outputData)
        if response.ok {
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

    private static func defaultNodePath() -> String? {
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
