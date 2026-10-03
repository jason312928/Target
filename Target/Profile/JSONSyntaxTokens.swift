import Foundation

/// Pure token ranges can be computed off the main thread. One expression gives
/// strings precedence, so numbers and literals inside a string keep its color.
enum JSONSyntaxTokens {
    enum Kind: Sendable { case key, string, literal, number }
    struct Token: Sendable {
        let range: NSRange
        let kind: Kind
    }
    private static let expression = try! NSRegularExpression(
        pattern: #"("(?:\\.|[^"\\])*"\s*:)|("(?:\\.|[^"\\])*")|(\b(?:true|false|null)\b)|(-?\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b)"#
    )

    static func tokens(in text: String, range: NSRange) -> [Token] {
        let length = (text as NSString).length
        guard range.location <= length, range.length <= length - range.location else { return [] }
        return expression.matches(in: text, range: range).map { match in
            let kind: Kind = match.range(at: 1).location != NSNotFound ? .key
                : match.range(at: 2).location != NSNotFound ? .string
                : match.range(at: 3).location != NSNotFound ? .literal : .number
            return Token(range: match.range, kind: kind)
        }
    }
}
