import AppKit
import SwiftUI

/// Text view that keeps token colours in sync with the content and the system appearance.
final class HighlightingTextView: NSTextView {
    private var plainText = ""
    private var language: SourceLanguage = .plain
    private var highlightGeneration = 0
    var codeFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private var highlightEnabled = true

    /// Above this size the raw text is shown first and coloured on a background queue, so selecting
    /// a large decompiled type never blocks the UI on tokenizing.
    private static let asyncHighlightThreshold = 60_000

    /// Returns true when the content actually changed (callers use it to reset the scroll position).
    @discardableResult
    func setContent(_ text: String, language newLanguage: SourceLanguage) -> Bool {
        let settings = AppSettings.shared
        let styleChanged = codeFont != settings.codeFont || highlightEnabled != settings.highlightEnabled
        let changed = text != plainText || newLanguage != language || styleChanged
        plainText = text
        language = newLanguage
        codeFont = settings.codeFont
        highlightEnabled = settings.highlightEnabled
        if changed { applyHighlight() }
        return changed
    }

    /// Applies word wrap and tab width from the settings.
    func applyLayoutSettings() {
        let settings = AppSettings.shared
        let wrap = settings.wordWrap
        isHorizontallyResizable = !wrap
        textContainer?.widthTracksTextView = wrap
        textContainer?.containerSize = NSSize(
            width: wrap ? 0 : CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude)

        let spaceWidth = (" " as NSString).size(withAttributes: [.font: codeFont]).width
        let style = NSMutableParagraphStyle()
        style.defaultTabInterval = spaceWidth * CGFloat(settings.tabWidth)
        style.tabStops = []
        defaultParagraphStyle = style
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyHighlight()
    }

    private func applyHighlight() {
        highlightGeneration += 1
        let generation = highlightGeneration
        let theme = SyntaxTheme.current(for: effectiveAppearance)
        let text = plainText
        let language = highlightEnabled ? self.language : .plain
        let font = codeFont
        backgroundColor = .textBackgroundColor
        insertionPointColor = theme.plain

        guard text.utf16.count > Self.asyncHighlightThreshold else {
            textStorage?.setAttributedString(
                SyntaxHighlighter.highlighted(text, language: language, theme: theme, font: font))
            return
        }

        // Large document: paint plain text now, colour it once the tokenizer finishes.
        textStorage?.setAttributedString(NSAttributedString(
            string: text, attributes: [.font: font, .foregroundColor: theme.plain]))
        let scrollOrigin = enclosingScrollView?.contentView.bounds.origin ?? .zero
        DispatchQueue.global(qos: .userInitiated).async {
            let highlighted = SyntaxHighlighter.highlighted(text, language: language, theme: theme, font: font)
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == self.highlightGeneration else { return }
                self.textStorage?.setAttributedString(highlighted)
                // keep the reader where they were while colours arrive
                self.enclosingScrollView?.contentView.scroll(to: scrollOrigin)
                self.enclosingScrollView?.reflectScrolledClipView(self.enclosingScrollView!.contentView)
            }
        }
    }
}

/// Read-only, syntax highlighted source view. NSTextView keeps large files responsive,
/// which SwiftUI's Text does not.
struct CodeTextView: NSViewRepresentable {
    let text: String
    var language: SourceLanguage = .plain

    func makeNSView(context: Context) -> NSScrollView {
        let textView = HighlightingTextView(frame: .zero)
        textView.codeFont = AppSettings.shared.codeFont
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = false
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        // Non-contiguous layout keeps multi-megabyte decompiled types scrollable.
        textView.layoutManager?.allowsNonContiguousLayout = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                       height: CGFloat.greatestFiniteMagnitude)

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        textView.applyLayoutSettings()
        textView.setContent(text, language: language)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? HighlightingTextView else { return }
        textView.applyLayoutSettings()
        if textView.setContent(text, language: language) {
            textView.scroll(.zero)
        }
    }
}
