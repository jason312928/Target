import AppKit
import SwiftUI

struct JSONCodeEditor: NSViewRepresentable {
    @Binding var text: String
    var onTextChange: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        let textView = NSTextView()
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.delegate = context.coordinator
        textView.string = text
        scrollView.documentView = textView
        scrollView.verticalRulerView = JSONLineNumberRulerView(textView: textView)
        JSONSyntaxHighlighter.apply(to: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView,
              textView.string != text,
              !context.coordinator.isEditing else { return }
        textView.string = text
        JSONSyntaxHighlighter.apply(to: textView)
        scrollView.verticalRulerView?.needsDisplay = true
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: JSONCodeEditor
        var isEditing = false

        init(_ parent: JSONCodeEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            isEditing = true
            let selection = textView.selectedRange()
            JSONSyntaxHighlighter.apply(to: textView)
            textView.setSelectedRange(selection)
            parent.text = textView.string
            parent.onTextChange(textView.string)
            textView.enclosingScrollView?.verticalRulerView?.needsDisplay = true
            isEditing = false
        }
    }
}

private enum JSONSyntaxHighlighter {
    static func apply(to textView: NSTextView) {
        let string = textView.string as NSString
        let fullRange = NSRange(location: 0, length: string.length)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.labelColor
        ]
        textView.textStorage?.setAttributes(attributes, range: fullRange)
        apply(#""(?:\\.|[^"\\])*"\s*:"#, color: .systemBlue, to: textView)
        apply(#""(?:\\.|[^"\\])*""#, color: .systemGreen, to: textView)
        apply(#"\b(?:true|false|null)\b"#, color: .systemPurple, to: textView)
        apply(#"-?\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b"#, color: .systemOrange, to: textView)
    }

    private static func apply(_ pattern: String, color: NSColor, to textView: NSTextView) {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return }
        let range = NSRange(textView.string.startIndex..., in: textView.string)
        expression.enumerateMatches(in: textView.string, range: range) { match, _, _ in
            guard let match else { return }
            textView.textStorage?.addAttribute(.foregroundColor, value: color, range: match.range)
        }
    }
}

private final class JSONLineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView!, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 42
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        NSColor.secondaryLabelColor.set()
        let visible = textView.enclosingScrollView?.contentView.bounds ?? .zero
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let characterRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let text = textView.string as NSString
        var lineStart = 0
        var lineEnd = 0
        var contentsEnd = 0
        text.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: 0, length: 0))
        var line = 1
        while lineStart < characterRange.location {
            text.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: lineEnd, length: 0))
            line += 1
        }
        while lineStart < NSMaxRange(characterRange) {
            let glyph = layoutManager.glyphRange(forCharacterRange: NSRange(location: lineStart, length: 0), actualCharacterRange: nil).location
            let y = layoutManager.location(forGlyphAt: glyph).y + textView.textContainerOrigin.y - visible.origin.y
            let label = "\(line)" as NSString
            label.draw(at: NSPoint(x: ruleThickness - label.size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)]).width - 6, y: y), withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor])
            guard lineEnd > lineStart else { break }
            text.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: lineEnd, length: 0))
            line += 1
        }
    }
}
