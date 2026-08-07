import AppKit
import SwiftUI

struct JSONCodeEditor: NSViewRepresentable {
    @Binding var text: String
    var isEditable = true
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
        scrollView.setAccessibilityIdentifier(accessibilityIdentifier.map { "\($0).scroll" })
        scrollView.setAccessibilityLabel(accessibilityLabel)

        let textView = container.textView
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.delegate = context.coordinator
        textView.isEditable = isEditable
        textView.setAccessibilityIdentifier(accessibilityIdentifier.map { "\($0).text" })
        textView.setAccessibilityLabel(accessibilityLabel)
        container.replaceText(text, resetScrollPosition: true)
        return container
    }

    func updateNSView(_ container: JSONCodeEditorContainerView, context: Context) {
        context.coordinator.parent = self
        container.textView.isEditable = isEditable
        guard container.textView.string != text,
              !context.coordinator.isEditing else { return }
        container.replaceText(text, resetScrollPosition: true)
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
            (textView.enclosingScrollView?.superview as? JSONCodeEditorContainerView)?.updateDocumentSize()
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
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        textView.isRichText = false
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        scrollView.documentView = textView
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        updateDocumentSize()
    }

    func replaceText(_ text: String, resetScrollPosition: Bool) {
        textView.string = text
        JSONSyntaxHighlighter.apply(to: textView)
        updateDocumentSize()
        if resetScrollPosition {
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    func updateDocumentSize() {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }
        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        let inset = textView.textContainerInset
        textView.frame.size = NSSize(
            width: max(scrollView.contentSize.width, ceil(usedRect.maxX + inset.width * 2)),
            height: max(scrollView.contentSize.height, ceil(usedRect.maxY + inset.height * 2))
        )
    }
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
