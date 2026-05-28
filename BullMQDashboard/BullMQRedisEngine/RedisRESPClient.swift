import Foundation
import Network

actor RedisRESPClient {
    private var connection: NWConnection?
    private var parser = RESPParser()
    private let commandGate = AsyncCommandGate()
    private let connectTimeout: TimeInterval = 12
    private let commandTimeout: TimeInterval = 12

    func connect(_ config: RedisConnectionConfig) async throws {
        let parameters: NWParameters = config.useTLS ? .tls : .tcp
        let connection = NWConnection(
            host: NWEndpoint.Host(config.host),
            port: NWEndpoint.Port(rawValue: UInt16(config.port)) ?? 6379,
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
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
    }

    func command(_ parts: [String]) async throws -> RESPValue {
        try await commands([parts])[0]
    }

    func commands(_ commands: [[String]]) async throws -> [RESPValue] {
        guard let connection else { throw BullMQDashboardError.notConnected }
        guard !commands.isEmpty else { return [] }
        await commandGate.wait()
        defer {
            Task { await commandGate.signal() }
        }

        let payload = encode(commands)
        try await send(payload, on: connection)

        var responses: [RESPValue] = []
        responses.reserveCapacity(commands.count)

        while responses.count < commands.count {
            if let parsed = try parser.parseNext() {
                if case .error(let message) = parsed {
                    throw BullMQDashboardError.redis(message)
                }
                responses.append(parsed)
                continue
            }
            let chunk = try await receive(on: connection)
            parser.append(chunk)
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
