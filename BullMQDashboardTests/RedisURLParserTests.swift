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
}
