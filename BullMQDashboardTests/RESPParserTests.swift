import Foundation
import XCTest
@testable import BullMQDashboard

final class RESPParserTests: XCTestCase {
    func testParsesMultipleFramesAfterRemovingFirstFrame() throws {
        var parser = RESPParser()
        parser.append(Data("+OK\r\n:42\r\n".utf8))

        XCTAssertEqual(try parser.parseNext(), .simpleString("OK"))
        XCTAssertEqual(try parser.parseNext(), .integer(42))
    }

    func testWaitsForPartialBulkStringFrame() throws {
        var parser = RESPParser()
        parser.append(Data("$5\r\nhe".utf8))
        XCTAssertNil(try parser.parseNext())

        parser.append(Data("llo\r\n".utf8))
        XCTAssertEqual(try parser.parseNext(), .bulkString("hello"))
    }

    func testParsesNestedArrayFrame() throws {
        var parser = RESPParser()
        parser.append(Data("*2\r\n$1\r\n0\r\n*2\r\n$11\r\nbull:a:meta\r\n$11\r\nbull:b:meta\r\n".utf8))

        XCTAssertEqual(
            try parser.parseNext(),
            .array([
                .bulkString("0"),
                .array([
                    .bulkString("bull:a:meta"),
                    .bulkString("bull:b:meta")
                ])
            ])
        )
    }

    func testParsesPipelinedResponsesInOrder() throws {
        var parser = RESPParser()
        parser.append(Data(":8\r\n*2\r\n$3\r\none\r\n$3\r\ntwo\r\n+OK\r\n".utf8))

        XCTAssertEqual(try parser.parseNext(), .integer(8))
        XCTAssertEqual(
            try parser.parseNext(),
            .array([
                .bulkString("one"),
                .bulkString("two")
            ])
        )
        XCTAssertEqual(try parser.parseNext(), .simpleString("OK"))
    }

    func testParsesBackToBackPipelineBatchesInOrder() throws {
        var parser = RESPParser()
        parser.append(Data(":1\r\n:2\r\n:3\r\n:4\r\n".utf8))

        XCTAssertEqual(try parser.parseNext(), .integer(1))
        XCTAssertEqual(try parser.parseNext(), .integer(2))
        XCTAssertEqual(try parser.parseNext(), .integer(3))
        XCTAssertEqual(try parser.parseNext(), .integer(4))
    }
}
