import AppKit
import SwiftUI

struct JSONCodeEditor: NSViewRepresentable {
    @Binding var text: String
    var onTextChange: (String) -> Void
    var accessibilityIdentifier: String? = nil
    var accessibilityLabel: String? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> JSONCodeEditorContainerView {
        let container = JSONCodeEditorContainerView(
            accessibilityIdentifier: accessibilityIdentifier,
            accessibilityLabel: accessibilityLabel
        )
        let scrollView = container.scrollView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        scrollView.setAccessibilityIdentifier(accessibilityIdentifier.map { "\($0).scroll" })
        scrollView.setAccessibilityLabel(accessibilityLabel)

        let textView = container.textView
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.delegate = context.coordinator
        textView.string = text
        textView.setAccessibilityIdentifier(accessibilityIdentifier.map { "\($0).text" })
        textView.setAccessibilityLabel(accessibilityLabel)
        scrollView.documentView = textView
        scrollView.verticalRulerView = JSONLineNumberRulerView(textView: textView)
        JSONSyntaxHighlighter.apply(to: textView)
        return container
    }

    func updateNSView(_ container: JSONCodeEditorContainerView, context: Context) {
        let textView = container.textView
        guard textView.string != text,
              !context.coordinator.isEditing else { return }
        textView.string = text
        JSONSyntaxHighlighter.apply(to: textView)
        (container.scrollView.verticalRulerView as? JSONLineNumberRulerView)?.updateLineStarts(for: text)
        container.scrollView.verticalRulerView?.needsDisplay = true
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
            (textView.enclosingScrollView?.verticalRulerView as? JSONLineNumberRulerView)?
                .updateLineStarts(for: textView.string)
            textView.enclosingScrollView?.verticalRulerView?.needsDisplay = true
            isEditing = false
        }
    }
}

final class JSONCodeEditorContainerView: NSView {
    let scrollView = NSScrollView()
    let textView = NSTextView()

    init(accessibilityIdentifier: String?, accessibilityLabel: String?) {
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier(accessibilityIdentifier)
        setAccessibilityLabel(accessibilityLabel)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }
}

struct JSONLineNumberCalculation {
    struct VisibleLine: Equatable {
        let number: Int
        let utf16Offset: Int
    }

    static func lineStartOffsets(in text: String) -> [Int] {
        let utf16 = Array(text.utf16)
        var offsets = [0]
        var index = 0

        while index < utf16.count {
            let codeUnit = utf16[index]
            if codeUnit == 0x000D {
                index += 1
                if index < utf16.count, utf16[index] == 0x000A {
                    index += 1
                }
                offsets.append(index)
            } else if codeUnit == 0x000A || codeUnit == 0x2028 || codeUnit == 0x2029 {
                index += 1
                offsets.append(index)
            } else {
                index += 1
            }
        }

        return offsets
    }

    static func visibleLines(
        lineStartOffsets: [Int],
        textUTF16Length: Int,
        visibleRange: NSRange
    ) -> [VisibleLine] {
        guard !lineStartOffsets.isEmpty else { return [] }

        let textLength = max(0, textUTF16Length)
        let visibleStart = min(visibleRange.location, textLength)
        let remainingLength = textLength - visibleStart
        let visibleLength = min(visibleRange.length, remainingLength)
        let visibleEnd = visibleStart + visibleLength
        let firstIndex = containingLineIndex(for: visibleStart, in: lineStartOffsets)

        var lines: [VisibleLine] = []
        var index = firstIndex
        let includeOnlyContainingLine = visibleLength == 0

        while index < lineStartOffsets.count {
            let offset = lineStartOffsets[index]
            guard offset <= textLength else { break }
            if !includeOnlyContainingLine, offset >= visibleEnd, index != firstIndex { break }

            lines.append(VisibleLine(number: index + 1, utf16Offset: offset))
            if includeOnlyContainingLine { break }

            let nextIndex = index + 1
            guard nextIndex > index else { break }
            index = nextIndex
        }

        return lines
    }

    private static func containingLineIndex(for offset: Int, in lineStartOffsets: [Int]) -> Int {
        var lowerBound = 0
        var upperBound = lineStartOffsets.count

        while lowerBound < upperBound {
            let middle = lowerBound + (upperBound - lowerBound) / 2
            if lineStartOffsets[middle] <= offset {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }

        return max(0, lowerBound - 1)
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
    private var lineStartOffsets: [Int]

    init(textView: NSTextView) {
        self.textView = textView
        lineStartOffsets = JSONLineNumberCalculation.lineStartOffsets(in: textView.string)
        super.init(scrollView: textView.enclosingScrollView!, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 42
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func updateLineStarts(for text: String) {
        lineStartOffsets = JSONLineNumberCalculation.lineStartOffsets(in: text)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        let visible = textView.enclosingScrollView?.contentView.bounds ?? .zero
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let characterRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let textLength = (textView.string as NSString).length
        let lines = JSONLineNumberCalculation.visibleLines(
            lineStartOffsets: lineStartOffsets,
            textUTF16Length: textLength,
            visibleRange: characterRange
        )
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor
        ]

        for line in lines {
            let fragmentY: CGFloat
            if line.utf16Offset == textLength {
                guard layoutManager.extraLineFragmentTextContainer != nil else { continue }
                fragmentY = layoutManager.extraLineFragmentRect.minY
            } else {
                let glyph = layoutManager.glyphRange(
                    forCharacterRange: NSRange(location: line.utf16Offset, length: 0),
                    actualCharacterRange: nil
                ).location
                guard glyph < layoutManager.numberOfGlyphs else { continue }
                fragmentY = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
            }

            let y = fragmentY + textView.textContainerOrigin.y - visible.origin.y
            let label = "\(line.number)" as NSString
            label.draw(
                at: NSPoint(x: ruleThickness - label.size(withAttributes: attributes).width - 6, y: y),
                withAttributes: attributes
            )
        }
    }
}
