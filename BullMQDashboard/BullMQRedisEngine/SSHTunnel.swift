import Foundation
import Darwin
import AppKit

struct SSHConnectionSettings: Codable, Equatable, Sendable {
    var host = ""
    var user = ""
    var port = 22
    var identityFile = ""

    func arguments(localPort: Int, redisHost: String, redisPort: Int, controlPath: String) throws -> [String] {
        let allowedHost = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_:")
        guard !host.isEmpty, !host.hasPrefix("-"), host.unicodeScalars.allSatisfy(allowedHost.contains),
              (1...65535).contains(port), (1...65535).contains(redisPort),
              !redisHost.isEmpty, redisHost.unicodeScalars.allSatisfy(allowedHost.contains),
              user.isEmpty || (!user.hasPrefix("-") && user.unicodeScalars.allSatisfy(CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-").contains)) else {
            throw BullMQDashboardError.redis("Enter a valid SSH host or config alias, username, and port.")
        }
        let destination = redisHost.contains(":") ? "[\(redisHost)]" : redisHost
        var args = ["-N", "-T", "-M", "-S", controlPath,
                    "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
                    "-o", "ExitOnForwardFailure=yes", "-o", "ConnectTimeout=10",
                    "-o", "ConnectionAttempts=1", "-o", "ServerAliveInterval=15",
                    "-o", "ServerAliveCountMax=2", "-o", "ControlPersist=no",
                    "-p", String(port), "-L", "127.0.0.1:\(localPort):\(destination):\(redisPort)"]
        if !user.isEmpty { args += ["-l", user] }
        if !identityFile.isEmpty { args += ["-i", NSString(string: identityFile).expandingTildeInPath] }
        return args + [host]
    }
}

/// Owns one OpenSSH process. Its forward is loopback-only and dies with the session.
actor SSHTunnel {
    private var process: Process?
    private var directory: URL?
    private var terminationObserver: NSObjectProtocol?
    private let configurationFile: String?

    init(configurationFile: String? = nil) { self.configurationFile = configurationFile }

    func start(_ settings: SSHConnectionSettings, redisHost: String, redisPort: Int) async throws -> Int {
        await stop()
        let localPort = try Self.availablePort()
        // Short path: Unix-domain control sockets have a small path limit.
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("qs-\(UUID().uuidString.prefix(8))")
        let control = directory.appendingPathComponent("ssh").path
        let arguments = (configurationFile.map { ["-F", $0] } ?? []) + (try settings.arguments(localPort: localPort, redisHost: redisHost, redisPort: redisPort, controlPath: control))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
        let log = directory.appendingPathComponent("error")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close() }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        task.arguments = arguments
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice
        task.standardError = output
        process = task
        do {
            try task.run()
            terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
                if task.isRunning { task.terminate() }
            }
            for _ in 0..<120 {
                try Task.checkCancellation()
                guard task.isRunning else {
                    let detail = (try? String(contentsOf: log, encoding: .utf8)) ?? "SSH exited."
                    throw BullMQDashboardError.redis("SSH tunnel failed: \(detail.prefix(2000)). Verify the host in Terminal first, then load your key with ssh-add. QueueScope uses known hosts and key/agent authentication; it never asks for an SSH password.")
                }
                if FileManager.default.fileExists(atPath: control) { return localPort }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            throw BullMQDashboardError.redis("SSH tunnel timed out. Check the SSH host, port, VPN, and key access.")
        } catch {
            await stop()
            throw error
        }
    }

    func stop() async {
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
        terminationObserver = nil
        let old = process
        process = nil
        if let old, old.isRunning {
            old.terminate()
            for _ in 0..<20 {
                if !old.isRunning { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            if old.isRunning { kill(old.processIdentifier, SIGKILL) }
        }
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }

    private static func availablePort() throws -> Int {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw BullMQDashboardError.redis("Could not allocate a local SSH port.") }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let found = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &size) }
        }
        guard bound == 0, found == 0 else { throw BullMQDashboardError.redis("Could not allocate a local SSH port.") }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}
