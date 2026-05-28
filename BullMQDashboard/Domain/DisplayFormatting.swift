import Foundation

extension Int {
    var compactCountDisplay: String {
        let absoluteValue = abs(self)
        let sign = self < 0 ? "-" : ""

        switch absoluteValue {
        case 0..<1_000:
            return "\(self)"
        case 1_000..<1_000_000:
            return sign + compactValue(Double(absoluteValue) / 1_000, suffix: "K")
        case 1_000_000..<1_000_000_000:
            return sign + compactValue(Double(absoluteValue) / 1_000_000, suffix: "M")
        default:
            return sign + compactValue(Double(absoluteValue) / 1_000_000_000, suffix: "B")
        }
    }

    private func compactValue(_ value: Double, suffix: String) -> String {
        if value >= 100 || value.rounded(.down) == value {
            return "\(Int(value.rounded(.down)))\(suffix)"
        }
        return String(format: "%.1f%@", value, suffix)
    }
}

extension TimeInterval {
    var compactDurationDisplay: String {
        let duration = max(0, self)

        switch duration {
        case 0..<1:
            return "\(Int((duration * 1_000).rounded()))ms"
        case 1..<10:
            return String(format: "%.1fs", duration)
        case 10..<60:
            return "\(Int(duration.rounded()))s"
        case 60..<3_600:
            return compactDuration(value: duration / 60, suffix: "m")
        case 3_600..<86_400:
            return compactDuration(value: duration / 3_600, suffix: "h")
        case 86_400..<2_592_000:
            return compactDuration(value: duration / 86_400, suffix: "d")
        case 2_592_000..<31_536_000:
            return compactDuration(value: duration / 2_592_000, suffix: "mo")
        default:
            return compactDuration(value: duration / 31_536_000, suffix: "y")
        }
    }

    private func compactDuration(value: Double, suffix: String) -> String {
        if value >= 10 || value.rounded(.down) == value {
            return "\(Int(value.rounded(.down)))\(suffix)"
        }
        return String(format: "%.1f%@", value, suffix)
    }
}
