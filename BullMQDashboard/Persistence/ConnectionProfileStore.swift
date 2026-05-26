import Foundation

final class ConnectionProfileStore {
    private let key = "redis.connection.profiles"
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
}
