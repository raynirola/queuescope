import Foundation

enum BullMQParsing {
    static let maxPreviewCharacters = 180
    static let maxDisplayCharacters = 40_000

    static func parseQueueName(fromMetaKey key: String, prefix: String) -> String? {
        let start = "\(prefix):"
        let end = ":meta"
        guard key.hasPrefix(start), key.hasSuffix(end) else { return nil }
        let withoutPrefix = key.dropFirst(start.count)
        let name = withoutPrefix.dropLast(end.count)
        guard !name.isEmpty else { return nil }
        return String(name)
    }

    static func key(prefix: String, queue: String, suffix: String) -> String {
        "\(prefix):\(queue):\(suffix)"
    }

    static func jobKey(prefix: String, queue: String, jobID: String) -> String {
        "\(prefix):\(queue):\(jobID)"
    }

    static func displayValue(_ raw: String?) -> DisplayValue {
        guard let raw, !raw.isEmpty else { return .empty }
        let capped = cap(raw, limit: maxDisplayCharacters)
        guard let data = capped.data(using: .utf8) else { return .raw(capped) }
        guard JSONSerialization.isValidJSONObjectFromStringData(data) else { return .raw(capped) }
        if let object = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: pretty, encoding: .utf8) {
            return .json(cap(text, limit: maxDisplayCharacters))
        }
        return .raw(capped)
    }

    static func preview(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "" }
        let normalized = raw.replacingOccurrences(of: "\n", with: " ")
        return cap(normalized, limit: maxPreviewCharacters)
    }

    static func int(_ raw: String?) -> Int {
        guard let raw else { return 0 }
        return Int(raw) ?? 0
    }

    static func dateFromMilliseconds(_ raw: String?) -> Date? {
        guard let raw, let milliseconds = Double(raw), milliseconds > 0 else { return nil }
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }

    static func attempts(from optionsRaw: String?) -> Int? {
        intOption("attempts", from: optionsRaw)
    }

    static func delay(from optionsRaw: String?) -> Int? {
        intOption("delay", from: optionsRaw)
    }

    private static func intOption(_ key: String, from optionsRaw: String?) -> Int? {
        guard let optionsRaw, let data = optionsRaw.data(using: .utf8) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let value = object[key] as? Int {
            return value
        }
        if let value = object[key] as? String {
            return Int(value)
        }
        return nil
    }

    static func stacktrace(_ raw: String?) -> [String] {
        guard let raw, !raw.isEmpty else { return [] }
        let capped = cap(raw, limit: maxDisplayCharacters)
        guard let data = capped.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [String] else {
            return [capped]
        }
        return array.map { cap($0, limit: maxDisplayCharacters) }
    }

    static func health(from counts: QueueCounts) -> QueueHealth {
        if counts.failed > 0, counts.failed >= max(5, counts.completed / 10) {
            return .failing
        }
        if counts.failed > 0 {
            return .warning
        }
        if counts.waiting + counts.delayed + counts.prioritized > 500 {
            return .busy
        }
        return .healthy
    }

    static func cap(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "\n... truncated"
    }
}

private extension JSONSerialization {
    static func isValidJSONObjectFromStringData(_ data: Data) -> Bool {
        (try? JSONSerialization.jsonObject(with: data)) != nil
    }
}
