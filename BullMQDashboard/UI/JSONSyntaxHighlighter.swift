import Highlight
import SwiftUI

enum JSONSyntaxHighlighter {
    static func highlight(_ text: String) -> AttributedString {
        let highlighted = JsonSyntaxHighlightProvider.shared.highlight(text, as: .json)
        return AttributedString(highlighted)
    }
}
