import Foundation

final class MetricSnapshotStore {
    private let fileURL: URL
    private let legacyDefaults: UserDefaults
    private let maxSnapshotsPerQueue = 120
    private let maxBytes = 4 * 1024 * 1024

    init(
        fileURL: URL = URL.applicationSupportDirectory.appendingPathComponent("QueueScope/metrics-v2.json"),
        legacyDefaults: UserDefaults = .standard
    ) {
        self.fileURL = fileURL
        self.legacyDefaults = legacyDefaults
    }

    func load(scope: String) throws -> [QueueMetricSnapshot] {
        try readSnapshots().filter { $0.connectionScope == scope }
    }

    func append(_ snapshot: QueueMetricSnapshot) throws {
        guard let scope = snapshot.connectionScope, !scope.isEmpty else {
            throw BullMQDashboardError.redis("Metrics require an active connection.")
        }
        var snapshots = try readSnapshots()
        // Native minute buckets are already a history. Keep them only on the latest
        // snapshot for this queue, rather than copying the entire series 120 times.
        for index in snapshots.indices where snapshots[index].connectionScope == scope && snapshots[index].queueName == snapshot.queueName {
            snapshots[index].nativeMetrics = nil
        }
        var bounded = snapshot
        if var metrics = bounded.nativeMetrics {
            metrics.completed.data = Array(metrics.completed.data.prefix(1440))
            metrics.failed.data = Array(metrics.failed.data.prefix(1440))
            bounded.nativeMetrics = metrics
        }
        snapshots.append(bounded)
        snapshots.sort { $0.capturedAt > $1.capturedAt }
        var retained: [String: [String: Int]] = [:]
        snapshots = snapshots.filter { item in
            guard let scope = item.connectionScope else { return false }
            let count = retained[scope]?[item.queueName] ?? 0
            retained[scope, default: [:]][item.queueName] = count + 1
            return count < maxSnapshotsPerQueue
        }
        var data = try JSONEncoder().encode(snapshots)
        while data.count > maxBytes, !snapshots.isEmpty {
            snapshots.removeLast()
            data = try JSONEncoder().encode(snapshots)
        }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }

    private func readSnapshots() throws -> [QueueMetricSnapshot] {
        if let legacy = legacyDefaults.data(forKey: "queue.metric.snapshots") {
            // Old snapshots have no environment identity. Archive them losslessly,
            // but never attribute them to whichever connection is opened first.
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let archive = fileURL.deletingLastPathComponent().appendingPathComponent("metrics-legacy-\(UUID().uuidString).json")
            try legacy.write(to: archive, options: .atomic)
            legacyDefaults.removeObject(forKey: "queue.metric.snapshots")
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return try JSONDecoder().decode([QueueMetricSnapshot].self, from: Data(contentsOf: fileURL))
    }
}
