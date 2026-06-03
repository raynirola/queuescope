import Foundation

final class ConnectionProfileStore {
    private let key = "redis.connection.profiles"
    private let lastActiveProfileIDKey = "redis.connection.lastActiveProfileID"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> [RedisConnectionProfile] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([RedisConnectionProfile].self, from: data)) ?? []
    }

    func save(_ profiles: [RedisConnectionProfile]) {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        defaults.set(data, forKey: key)
    }

    func loadLastActiveProfileID() -> UUID? {
        guard let rawID = defaults.string(forKey: lastActiveProfileIDKey) else { return nil }
        return UUID(uuidString: rawID)
    }

    func saveLastActiveProfileID(_ id: UUID) {
        defaults.set(id.uuidString, forKey: lastActiveProfileIDKey)
    }

    func clearLastActiveProfileID() {
        defaults.removeObject(forKey: lastActiveProfileIDKey)
    }
}

final class QueueNameStore {
    private let key = "redis.connection.queue.names"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load(scope: String) -> [String] {
        storedNames()[scope] ?? []
    }

    func save(_ names: [String], scope: String) {
        var stored = storedNames()
        stored[scope] = Array(Set(names)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        guard let data = try? JSONEncoder().encode(stored) else { return }
        defaults.set(data, forKey: key)
    }

    private func storedNames() -> [String: [String]] {
        guard let data = defaults.data(forKey: key) else { return [:] }
        return (try? JSONDecoder().decode([String: [String]].self, from: data)) ?? [:]
    }
}

final class QueueMetadataStore {
    private let key = "redis.connection.queue.metadata"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load(scope: String) -> [QueueSummary] {
        storedQueues()[scope] ?? []
    }

    func save(_ queues: [QueueSummary], scope: String) {
        var stored = storedQueues()
        stored[scope] = queues.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        guard let data = try? JSONEncoder().encode(stored) else { return }
        defaults.set(data, forKey: key)
    }

    private func storedQueues() -> [String: [QueueSummary]] {
        guard let data = defaults.data(forKey: key) else { return [:] }
        return (try? JSONDecoder().decode([String: [QueueSummary]].self, from: data)) ?? [:]
    }
}

struct QueueWorkspacePreference: Codable, Equatable {
    var selectedQueueName: String?
    var selectedView: String
}

final class QueueWorkspacePreferenceStore {
    private let key = "redis.connection.workspace.preference"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load(scope: String) -> QueueWorkspacePreference? {
        storedPreferences()[scope]
    }

    func save(_ preference: QueueWorkspacePreference, scope: String) {
        var stored = storedPreferences()
        stored[scope] = preference
        guard let data = try? JSONEncoder().encode(stored) else { return }
        defaults.set(data, forKey: key)
    }

    private func storedPreferences() -> [String: QueueWorkspacePreference] {
        guard let data = defaults.data(forKey: key) else { return [:] }
        return (try? JSONDecoder().decode([String: QueueWorkspacePreference].self, from: data)) ?? [:]
    }
}
