import Foundation
import Network
import Security

actor RedisRESPClient {
    private var connection: NWConnection?
    private var parser = RESPParser()
    private let commandGate = AsyncCommandGate()
    private let connectTimeout: TimeInterval = 12
    private let commandTimeout: TimeInterval

    init(commandTimeout: TimeInterval = 12) {
        self.commandTimeout = commandTimeout
    }

    func connect(_ config: RedisConnectionConfig) async throws {
        disconnect()
        guard let port = UInt16(exactly: config.transportPort ?? config.port), port > 0, config.database >= 0 else {
            throw BullMQDashboardError.invalidRedisURL
        }
        let parameters: NWParameters
        if config.useTLS {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, config.host)
            parameters = NWParameters(tls: tls)
        } else {
            parameters = .tcp
        }
        let connection = NWConnection(
            host: NWEndpoint.Host(config.transportHost ?? config.host),
            port: NWEndpoint.Port(rawValue: port) ?? 6379,
            using: parameters
        )
        self.connection = connection

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = AsyncCompletionGate()
            let timeout = DispatchWorkItem {
                gate.complete {
                    connection.stateUpdateHandler = nil
                    connection.cancel()
                    continuation.resume(throwing: BullMQDashboardError.redis("Timed out connecting to Redis. Check the host, port, network, and TLS setting."))
                }
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + connectTimeout, execute: timeout)

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    gate.complete {
                        connection.stateUpdateHandler = nil
                        continuation.resume()
                    }
                case .waiting(let error):
                    gate.complete {
                        connection.stateUpdateHandler = nil
                        connection.cancel()
                        continuation.resume(throwing: BullMQDashboardError.redis(error.localizedDescription))
                    }
                case .failed(let error):
                    gate.complete {
                        connection.stateUpdateHandler = nil
                        continuation.resume(throwing: BullMQDashboardError.redis(error.localizedDescription))
                    }
                case .cancelled:
                    gate.complete {
                        connection.stateUpdateHandler = nil
                        continuation.resume(throwing: BullMQDashboardError.redis("Redis connection was cancelled."))
                    }
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }

        do {
            if let password = config.password, !password.isEmpty {
                if let username = config.username, !username.isEmpty {
                    _ = try await command(["AUTH", username, password])
                } else {
                    _ = try await command(["AUTH", password])
                }
            }
            if config.database > 0 {
                _ = try await command(["SELECT", String(config.database)])
            }
        } catch {
            disconnect()
            throw error
        }
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
        parser = RESPParser()
    }

    func command(_ parts: [String]) async throws -> RESPValue {
        try await commands([parts])[0]
    }

    func commands(_ commands: [[String]]) async throws -> [RESPValue] {
        guard !commands.isEmpty else { return [] }
        try Task.checkCancellation()
        await commandGate.wait()
        defer { Task { await commandGate.signal() } }
        try Task.checkCancellation()
        guard let connection else { throw BullMQDashboardError.notConnected }

        var responses: [RESPValue] = []
        responses.reserveCapacity(commands.count)
        do {
            try await send(encode(commands), on: connection)
            while responses.count < commands.count {
                guard self.connection === connection else { throw BullMQDashboardError.notConnected }
                if let parsed = try parser.parseNext() {
                    // A Redis error is still one reply. Drain the whole pipeline before throwing.
                    responses.append(parsed)
                    continue
                }
                let chunk = try await receive(on: connection)
                guard self.connection === connection else { throw BullMQDashboardError.notConnected }
                parser.append(chunk)
            }
        } catch {
            // After a timeout, cancellation or malformed frame we cannot associate
            // future replies with commands safely. Require an explicit reconnect.
            if self.connection === connection { disconnect() }
            if error is CancellationError { throw error }
            throw BullMQDashboardError.connectionLost(error.localizedDescription)
        }
        // Once sent, even a cancelled caller must consume its full batch. This
        // keeps normal view changes from disconnecting a healthy shared session.
        try Task.checkCancellation()
        for response in responses {
            if case .error(let message) = response { throw BullMQDashboardError.redis(message) }
        }
        return responses
    }

    private func encode(_ commands: [[String]]) -> Data {
        var data = Data()
        for command in commands {
            data.append(encode(command))
        }
        return data
    }

    private func encode(_ parts: [String]) -> Data {
        var data = Data("*\(parts.count)\r\n".utf8)
        for part in parts {
            let bytes = Data(part.utf8)
            data.append(Data("$\(bytes.count)\r\n".utf8))
            data.append(bytes)
            data.append(Data("\r\n".utf8))
        }
        return data
    }

    private func send(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = AsyncCompletionGate()
            let timeout = DispatchWorkItem {
                gate.complete {
                    connection.cancel()
                    continuation.resume(throwing: BullMQDashboardError.redis("Timed out sending command to Redis."))
                }
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + commandTimeout, execute: timeout)

            connection.send(content: data, completion: .contentProcessed { error in
                gate.complete {
                    if let error {
                        continuation.resume(throwing: BullMQDashboardError.redis(error.localizedDescription))
                    } else {
                        continuation.resume()
                    }
                }
            })
        }
    }

    private func receive(on connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let gate = AsyncCompletionGate()
            let timeout = DispatchWorkItem {
                gate.complete {
                    connection.cancel()
                    continuation.resume(throwing: BullMQDashboardError.redis("Timed out waiting for Redis response."))
                }
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + commandTimeout, execute: timeout)

            connection.receive(minimumIncompleteLength: 1, maximumLength: 131_072) { data, _, isComplete, error in
                gate.complete {
                    if let error {
                        continuation.resume(throwing: BullMQDashboardError.redis(error.localizedDescription))
                        return
                    }
                    if let data, !data.isEmpty {
                        continuation.resume(returning: data)
                        return
                    }
                    if isComplete {
                        continuation.resume(throwing: BullMQDashboardError.redis("Redis closed the connection."))
                        return
                    }
                    continuation.resume(throwing: BullMQDashboardError.redis("Redis returned an empty response."))
                }
            }
        }
    }
}

private actor AsyncCommandGate {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if !isLocked {
            isLocked = true
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func signal() {
        if waiters.isEmpty {
            isLocked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

private final class AsyncCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isComplete = false

    func complete(_ operation: () -> Void) {
        lock.lock()
        guard !isComplete else {
            lock.unlock()
            return
        }
        isComplete = true
        lock.unlock()
        operation()
    }
}
