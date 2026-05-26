import XCTest
@testable import BullMQDashboard

final class BullMQParsingTests: XCTestCase {
    func testParsesQueueNameFromMetaKey() {
        XCTAssertEqual(BullMQParsing.parseQueueName(fromMetaKey: "bull:email:meta", prefix: "bull"), "email")
        XCTAssertEqual(BullMQParsing.parseQueueName(fromMetaKey: "prod:video:meta", prefix: "prod"), "video")
        XCTAssertNil(BullMQParsing.parseQueueName(fromMetaKey: "bull:email:wait", prefix: "bull"))
        XCTAssertNil(BullMQParsing.parseQueueName(fromMetaKey: "other:email:meta", prefix: "bull"))
    }

    func testBuildsBullMQKeys() {
        XCTAssertEqual(BullMQParsing.key(prefix: "bull", queue: "email", suffix: "failed"), "bull:email:failed")
        XCTAssertEqual(BullMQParsing.jobKey(prefix: "bull", queue: "email", jobID: "123"), "bull:email:123")
    }

    func testPrettyPrintsJSONAndFallsBackToRaw() {
        let json = BullMQParsing.displayValue(#"{"b":2,"a":1}"#)
        XCTAssertTrue(json.text.contains("\"a\""))
        XCTAssertTrue(json.text.contains("\"b\""))

        let raw = BullMQParsing.displayValue("not-json")
        XCTAssertEqual(raw, .raw("not-json"))
    }

    func testParsesAttemptCountFromOptions() {
        XCTAssertEqual(BullMQParsing.attempts(from: #"{"attempts":3}"#), 3)
        XCTAssertEqual(BullMQParsing.attempts(from: #"{"attempts":"4"}"#), 4)
        XCTAssertNil(BullMQParsing.attempts(from: #"{"removeOnComplete":true}"#))
    }

    func testHealthClassification() {
        XCTAssertEqual(BullMQParsing.health(from: .empty), .healthy)

        var busy = QueueCounts.empty
        busy.waiting = 501
        XCTAssertEqual(BullMQParsing.health(from: busy), .busy)

        var warning = QueueCounts.empty
        warning.failed = 1
        XCTAssertEqual(BullMQParsing.health(from: warning), .warning)

        var failing = QueueCounts.empty
        failing.failed = 10
        failing.completed = 20
        XCTAssertEqual(BullMQParsing.health(from: failing), .failing)
    }
}
