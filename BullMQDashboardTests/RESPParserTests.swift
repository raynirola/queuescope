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
}
