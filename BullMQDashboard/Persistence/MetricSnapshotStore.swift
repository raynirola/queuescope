import Foundation

final class MetricSnapshotStore {
    private let key = "queue.metric.snapshots"
    private let defaults: UserDefaults
    private let maxSnapshotsPerQueue = 120

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> [QueueMetricSnapshot] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([QueueMetricSnapshot].self, from: data)) ?? []
    }

    func append(_ snapshot: QueueMetricSnapshot) {
        var snapshots = load()
        snapshots.append(snapshot)
        let grouped = Dictionary(grouping: snapshots, by: \.queueName)
        snapshots = grouped.values.flatMap { queueSnapshots in
            queueSnapshots
                .sorted { $0.capturedAt > $1.capturedAt }
                .prefix(maxSnapshotsPerQueue)
        }
        guard let data = try? JSONEncoder().encode(snapshots) else { return }
        defaults.set(data, forKey: key)
    }
}
