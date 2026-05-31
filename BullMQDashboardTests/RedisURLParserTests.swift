import XCTest
@testable import BullMQDashboard

final class RedisURLParserTests: XCTestCase {
    func testParsesPlainRedisURL() throws {
        let config = try RedisURLParser.parse("redis://user:pass@localhost:6380/2", prefix: "bull")
        XCTAssertEqual(config.host, "localhost")
        XCTAssertEqual(config.port, 6380)
        XCTAssertEqual(config.username, "user")
        XCTAssertEqual(config.password, "pass")
        XCTAssertEqual(config.database, 2)
        XCTAssertFalse(config.useTLS)
        XCTAssertEqual(config.prefix, "bull")
    }

    func testParsesTLSRedisURL() throws {
        let config = try RedisURLParser.parse("rediss://cache.example.com")
        XCTAssertEqual(config.host, "cache.example.com")
        XCTAssertEqual(config.port, 6379)
        XCTAssertEqual(config.database, 0)
        XCTAssertTrue(config.useTLS)
    }

    func testRejectsUnsupportedScheme() {
        XCTAssertThrowsError(try RedisURLParser.parse("http://localhost:6379")) { error in
            XCTAssertEqual(error as? BullMQDashboardError, .unsupportedURLScheme("http"))
        }
    }

    func testRedactsPassword() {
        XCTAssertEqual(
            RedisURLParser.redacted("redis://user:secret@localhost:6379/0"),
            "redis://user:****@localhost:6379/0"
        )
    }

    func testQueueNameStorePersistsNamesByScope() {
        let suiteName = "QueueNameStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = QueueNameStore(defaults: defaults)

        store.save(["email", "reports", "email"], scope: "local:6379/0:bull")
        store.save(["video"], scope: "prod:6379/0:bull")

        XCTAssertEqual(store.load(scope: "local:6379/0:bull"), ["email", "reports"])
        XCTAssertEqual(store.load(scope: "prod:6379/0:bull"), ["video"])
        XCTAssertEqual(store.load(scope: "missing"), [])
    }

    func testQueueMetadataStorePersistsQueueOverviewsByScope() {
        let suiteName = "QueueMetadataStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = QueueMetadataStore(defaults: defaults)
        var counts = QueueCounts.empty
        counts.waiting = 8
        counts.failed = 2

        store.save(
            [
                QueueSummary(
                    name: "email",
                    groupName: "Production",
                    prefix: "bull",
                    counts: counts,
                    health: .warning
                )
            ],
            scope: "local:6379/0:bull"
        )

        XCTAssertEqual(store.load(scope: "local:6379/0:bull").first?.name, "email")
        XCTAssertEqual(store.load(scope: "local:6379/0:bull").first?.groupName, "Production")
        XCTAssertEqual(store.load(scope: "local:6379/0:bull").first?.counts.waiting, 8)
        XCTAssertEqual(store.load(scope: "local:6379/0:bull").first?.health, .warning)
        XCTAssertEqual(store.load(scope: "missing"), [])
    }
}
