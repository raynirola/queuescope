import Foundation
import Security

protocol ConnectionCredentialStore {
    func read(id: UUID) throws -> String?
    func write(_ url: String, id: UUID) throws
    func delete(id: UUID) throws
}

struct KeychainConnectionCredentials: ConnectionCredentialStore {
    private let service = "dev.ray.QueueScope.redis-connections"

    func read(id: UUID) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let url = String(data: data, encoding: .utf8) else {
            throw BullMQDashboardError.redis("Could not read Redis credentials from Keychain (\(status)).")
        }
        return url
    }

    func write(_ url: String, id: UUID) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString
        ]
        let data = Data(url.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw BullMQDashboardError.redis("Could not save Redis credentials to Keychain (\(status)).")
        }
    }

    func delete(id: UUID) throws {
        let status = SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString
        ] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw BullMQDashboardError.redis("Could not delete Redis credentials from Keychain (\(status)).")
        }
    }
}

#if DEBUG
// Development binaries are rebuilt frequently and cannot rely on stable Keychain trust.
// Keep this store and its profile metadata separate from release credentials.
struct DevelopmentConnectionCredentials: ConnectionCredentialStore {
    let defaults: UserDefaults
    private func key(_ id: UUID) -> String { "redis.development.credentials.\(id.uuidString)" }
    func read(id: UUID) throws -> String? { defaults.string(forKey: key(id)) }
    func write(_ url: String, id: UUID) throws { defaults.set(url, forKey: key(id)) }
    func delete(id: UUID) throws { defaults.removeObject(forKey: key(id)) }
}
#endif

final class ConnectionProfileStore {
    private let key: String
    private let lastActiveProfileIDKey: String
    private let defaults: UserDefaults
    private let credentials: any ConnectionCredentialStore

    init(defaults: UserDefaults = .standard, credentials: (any ConnectionCredentialStore)? = nil) {
        self.defaults = defaults
        #if DEBUG
        if credentials == nil {
            self.credentials = DevelopmentConnectionCredentials(defaults: defaults)
            key = "redis.development.profiles"
            lastActiveProfileIDKey = "redis.development.lastActiveProfileID"
            return
        }
        #endif
        self.credentials = credentials ?? KeychainConnectionCredentials()
        key = "redis.connection.profiles"
        lastActiveProfileIDKey = "redis.connection.lastActiveProfileID"
    }

    func load() throws -> [RedisConnectionProfile] {
        guard let data = defaults.data(forKey: key) else { return [] }
        var profiles = try JSONDecoder().decode([RedisConnectionProfile].self, from: data)
        var needsMigration = false
        for index in profiles.indices {
            let url = URLComponents(string: profiles[index].redisURL)
            if url?.user != nil || url?.password != nil {
                needsMigration = true
            } else if let storedURL = try credentials.read(id: profiles[index].id) {
                profiles[index].redisURL = storedURL
            } else if profiles[index].credentialsInKeychain {
                // Keep missing entries visible so they can be removed/recreated.
                // The app refuses to connect without their saved credentials.
                continue
            }
            profiles[index].credentialsInKeychain = false
        }
        // Preserve the original preferences if any Keychain write fails.
        if needsMigration { try save(profiles) }
        return profiles
    }

    func save(_ profiles: [RedisConnectionProfile]) throws {
        let data = try JSONEncoder().encode(profiles)
        for profile in profiles where !profile.credentialsInKeychain {
            try credentials.write(profile.redisURL, id: profile.id)
        }
        defaults.set(data, forKey: key)
    }

    func delete(_ profile: RedisConnectionProfile) throws {
        guard let data = defaults.data(forKey: key) else { return }
        let profiles = try JSONDecoder().decode([RedisConnectionProfile].self, from: data).filter { $0.id != profile.id }
        let updated = try JSONEncoder().encode(profiles)
        try credentials.delete(id: profile.id)
        defaults.set(updated, forKey: key)
    }

    func loadLastActiveProfileID() -> UUID? {
        guard let rawID = defaults.string(forKey: lastActiveProfileIDKey) else { return nil }
        return UUID(uuidString: rawID)
    }

    func saveLastActiveProfileID(_ id: UUID) { defaults.set(id.uuidString, forKey: lastActiveProfileIDKey) }
    func clearLastActiveProfileID() { defaults.removeObject(forKey: lastActiveProfileIDKey) }
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
    var refreshInterval: Int? = nil
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
