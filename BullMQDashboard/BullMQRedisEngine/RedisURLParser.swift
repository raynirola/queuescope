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
            database = Int(path) ?? 0
        }

        return RedisConnectionConfig(
            profileID: nil,
            name: defaultName,
            host: host,
            port: components.port ?? 6379,
            username: components.user?.removingPercentEncoding,
            password: components.password?.removingPercentEncoding,
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
