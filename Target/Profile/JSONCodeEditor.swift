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
            parent.text = textView.string
            (textView.enclosingScrollView?.superview as? JSONCodeEditorContainerView)?.scheduleHighlight()
            isEditing = false
        }
    }
}

final class JSONCodeEditorContainerView: NSView, NSTextStorageDelegate {
    let scrollView = NSScrollView()
    let textView = NSTextView()
    private var highlightTask: Task<Void, Never>?
    private var generation = 0
    private var dirtyRange: NSRange?
    private var previousViewportSize = NSSize.zero

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
        textView.textStorage?.delegate = self
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        if previousViewportSize != scrollView.contentSize {
            previousViewportSize = scrollView.contentSize
            updateDocumentSize()
        }
    }

    func replaceText(_ text: String, resetScrollPosition: Bool) {
        textView.string = text
        textView.textStorage?.setAttributes([.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                                           .foregroundColor: NSColor.labelColor], range: NSRange(location: 0, length: (text as NSString).length))
        updateDocumentSize()
        dirtyRange = NSRange(location: 0, length: (text as NSString).length)
        scheduleHighlight()
        if resetScrollPosition {
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        // Adjust the accumulated range when a subsequent edit shifts text.
        let length = textStorage.length
        let previous = dirtyRange.map { NSRange(location: min($0.location, length), length: min(max(0, $0.length + delta), length - min($0.location, length))) }
        dirtyRange = previous.map { NSUnionRange($0, editedRange) } ?? editedRange
    }

    func scheduleHighlight() {
        generation &+= 1
        let expectedGeneration = generation
        highlightTask?.cancel()
        highlightTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(160))
                guard let self, !Task.isCancelled else { return }
                let source = self.textView.string
                let string = source as NSString
                let requested = self.dirtyRange ?? NSRange(location: 0, length: string.length)
                let bounded = NSIntersectionRange(requested, NSRange(location: 0, length: string.length))
                let range = string.paragraphRange(for: bounded)
                let tokens = try await ProfileBackgroundWork.run { JSONSyntaxTokens.tokens(in: source, range: range) }
                guard !Task.isCancelled, self.generation == expectedGeneration, self.textView.string == source,
                      let storage = self.textView.textStorage else { return }
                storage.beginEditing()
                storage.setAttributes([.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                                       .foregroundColor: NSColor.labelColor], range: range)
                for token in tokens {
                    let color: NSColor
                    switch token.kind {
                    case .key: color = .systemBlue
                    case .string: color = .systemGreen
                    case .literal: color = .systemPurple
                    case .number: color = .systemOrange
                    }
                    storage.addAttribute(.foregroundColor, value: color, range: token.range)
                }
                storage.endEditing()
                self.dirtyRange = nil
                self.updateDocumentSize()
            } catch { }
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
