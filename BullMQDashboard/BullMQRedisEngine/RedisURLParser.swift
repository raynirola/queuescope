import Foundation

enum RedisURLParser {
    static func parse(_ text: String, defaultName: String = "Local Redis", prefix: String = "bull") throws -> RedisConnectionConfig {
        guard let components = URLComponents(string: text) else {
            throw BullMQDashboardError.invalidRedisURL
        }
        guard let scheme = components.scheme?.lowercased() else {
            throw BullMQDashboardError.invalidRedisURL
        }
        guard scheme == "redis" || scheme == "rediss" else {
            throw BullMQDashboardError.unsupportedURLScheme(scheme)
        }
        guard let host = components.host, !host.isEmpty else {
            throw BullMQDashboardError.missingHost
        }

        let database: Int
        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.isEmpty {
            database = 0
        } else {
            guard let value = Int(path), value >= 0, !path.contains("/") else {
                throw BullMQDashboardError.redis("Redis database must be a non-negative integer.")
            }
            database = value
        }

        let port = components.port ?? 6379
        guard (1...65535).contains(port) else {
            throw BullMQDashboardError.redis("Redis port must be between 1 and 65535.")
        }
        guard !prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BullMQDashboardError.redis("BullMQ prefix must not be empty.")
        }

        return RedisConnectionConfig(
            profileID: nil,
            name: defaultName,
            host: host,
            port: port,
            username: components.user,
            password: components.password,
            database: database,
            useTLS: scheme == "rediss",
            prefix: prefix
        )
    }

    static func redacted(_ text: String) -> String {
        guard var components = URLComponents(string: text) else { return text }
        if components.password != nil {
            components.password = "****"
        }
        return components.string ?? text
    }
}
