import Highlight
import Foundation
import SwiftUI

enum JSONSyntaxHighlighter {
    static func highlight(_ text: String) -> AttributedString {
        let highlighted = JsonSyntaxHighlightProvider.shared.highlight(text, as: .json)
        var attributed = AttributedString(highlighted)
        attributed.font = .system(size: 10, design: .monospaced)
        emphasizeObjectKeys(in: &attributed, source: text)
        return attributed
    }

    private static func emphasizeObjectKeys(in attributed: inout AttributedString, source: String) {
        let pattern = #"("(?:[^"\\]|\\.)*")\s*:"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let nsRange = NSRange(source.startIndex..<source.endIndex, in: source)

        for match in regex.matches(in: source, range: nsRange) {
            guard
                let keyRange = Range(match.range(at: 1), in: source),
                let lowerBound = AttributedString.Index(keyRange.lowerBound, within: attributed),
                let upperBound = AttributedString.Index(keyRange.upperBound, within: attributed)
            else {
                continue
            }

            attributed[lowerBound..<upperBound].font = .system(size: 10, weight: .semibold, design: .monospaced)
        }
    }
}
