import Foundation

enum RESPValue: Equatable, Sendable {
    case simpleString(String)
    case bulkString(String?)
    case integer(Int)
    case array([RESPValue]?)
    case error(String)

    var string: String? {
        switch self {
        case .simpleString(let value): value
        case .bulkString(let value): value
        case .integer(let value): String(value)
        case .error(let value): value
        case .array: nil
        }
    }

    var int: Int? {
        switch self {
        case .integer(let value): value
        case .simpleString(let value): Int(value)
        case .bulkString(let value): Int(value ?? "")
        case .array, .error: nil
        }
    }
}

struct RESPParser {
    private var buffer = Data()

    mutating func append(_ data: Data) {
        buffer.append(data)
    }

    mutating func parseNext() throws -> RESPValue? {
        var cursor = buffer.startIndex
        guard let value = try parseValue(at: &cursor) else { return nil }
        buffer.removeSubrange(buffer.startIndex..<cursor)
        return value
    }

    private func parseValue(at cursor: inout Data.Index) throws -> RESPValue? {
        guard cursor < buffer.endIndex else { return nil }
        let marker = buffer[cursor]
        buffer.formIndex(after: &cursor)

        switch marker {
        case 43:
            guard let line = readLine(at: &cursor) else { return nil }
            return .simpleString(line)
        case 45:
            guard let line = readLine(at: &cursor) else { return nil }
            return .error(line)
        case 58:
            guard let line = readLine(at: &cursor), let value = Int(line) else { return nil }
            return .integer(value)
        case 36:
            guard let line = readLine(at: &cursor), let length = Int(line) else { return nil }
            if length == -1 {
                return .bulkString(nil)
            }
            guard let dataEnd = buffer.index(cursor, offsetBy: length, limitedBy: buffer.endIndex),
                  let frameEnd = buffer.index(dataEnd, offsetBy: 2, limitedBy: buffer.endIndex) else {
                return nil
            }
            let data = buffer[cursor..<dataEnd]
            cursor = frameEnd
            return .bulkString(String(data: data, encoding: .utf8) ?? "")
        case 42:
            guard let line = readLine(at: &cursor), let count = Int(line) else { return nil }
            if count == -1 {
                return .array(nil)
            }
            var values: [RESPValue] = []
            values.reserveCapacity(max(count, 0))
            for _ in 0..<count {
                guard let value = try parseValue(at: &cursor) else { return nil }
                values.append(value)
            }
            return .array(values)
        default:
            throw BullMQDashboardError.redis("Unexpected Redis response marker: \(marker).")
        }
    }

    private func readLine(at cursor: inout Data.Index) -> String? {
        var index = cursor
        while index < buffer.endIndex {
            let next = buffer.index(after: index)
            guard next < buffer.endIndex else { return nil }
            if buffer[index] == 13, buffer[next] == 10 {
                let data = buffer[cursor..<index]
                cursor = buffer.index(after: next)
                return String(data: data, encoding: .utf8)
            }
            buffer.formIndex(after: &index)
        }
        return nil
    }
}
