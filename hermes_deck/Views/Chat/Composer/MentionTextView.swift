import AppKit
import SwiftUI

/// Key the mention popup consumes while it is open.
enum MentionKeyCommand {
    case moveUp
    case moveDown
    case confirm
    case dismiss
}

/// A plain-text editor (AppKit `NSTextView`) with **atomic `@mention` tokens**.
///
/// A token is any `@alias` (alias from `aliases`) that is bounded by whitespace
/// or the string ends — i.e. a completed mention. Such a token is treated as a
/// single unit: backspacing into it deletes the whole token, and typing inside
/// it is blocked. A mention still being typed (`@cod`, or `@codex` with no
/// trailing space) stays freely editable so autocomplete works.
///
/// Wraps the input the SwiftUI composers used to drive with `TextField`,
/// reproducing: placeholder, 1–3 line vertical growth, Return-to-send, and the
/// arrow/Return/Tab/Escape handoff to the `@mention` popup.
struct MentionTextView: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var aliases: [String]
    var font: NSFont = .systemFont(ofSize: 14.5)
    var minLines: Int = 1
    var maxLines: Int = 3
    var onSubmit: () -> Void = {}
    /// Handles a key while the mention popup is open. Return `true` to consume it
    /// (suppressing the editor's default handling).
    var onKeyCommand: (MentionKeyCommand) -> Bool = { _ in false }
    var onHeightChange: (CGFloat) -> Void = { _ in }

    func makeNSView(context: Context) -> NSScrollView {
        // Manual TextKit 1 stack so the custom layout manager's `drawBackground`
        // (which paints the mention pills) runs — TextKit 2 would bypass it.
        let textStorage = NSTextStorage()
        let layoutManager = MentionLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)

        let textView = MentionNSTextView(frame: .zero, textContainer: container)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.delegate = context.coordinator
        textView.coordinator = context.coordinator
        textView.font = font
        textView.isRichText = true
        textView.importsGraphics = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 0, height: 6)
        textView.textContainer?.lineFragmentPadding = 0
        textView.string = text

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.documentView = textView

        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView

        let placeholderField = context.coordinator.placeholderLabel
        placeholderField.stringValue = placeholder
        placeholderField.isHidden = !text.isEmpty
        textView.addSubview(placeholderField)
        NSLayoutConstraint.activate([
            placeholderField.leadingAnchor.constraint(equalTo: textView.leadingAnchor),
            placeholderField.topAnchor.constraint(equalTo: textView.topAnchor, constant: textView.textContainerInset.height),
        ])
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? MentionNSTextView else { return }
        // Mid-IME composition (Chinese/Japanese marked text) the storage holds
        // uncommitted text the binding doesn't know about; the diff below would
        // wipe it and the styling pass would abort the composition. Only keep
        // the height in sync (the composition may have wrapped to a new line).
        if textView.hasMarkedText() {
            context.coordinator.updateHeight()
            return
        }
        if textView.font != font { textView.font = font }
        // Sync external text changes (autocomplete insertion, speech, clearing on
        // send) with a smart diff to preserve cursor position and Undo history.
        if textView.string != text {
            let oldString = textView.string
            let newString = text
            let oldNs = oldString as NSString
            let newNs = newString as NSString

            var prefixLen = 0
            while prefixLen < oldNs.length && prefixLen < newNs.length &&
                  oldNs.character(at: prefixLen) == newNs.character(at: prefixLen) {
                prefixLen += 1
            }

            var suffixLen = 0
            while suffixLen < (oldNs.length - prefixLen) && suffixLen < (newNs.length - prefixLen) &&
                  oldNs.character(at: oldNs.length - 1 - suffixLen) == newNs.character(at: newNs.length - 1 - suffixLen) {
                suffixLen += 1
            }

            let replaceRange = NSRange(location: prefixLen, length: oldNs.length - prefixLen - suffixLen)
            let replacement = newNs.substring(with: NSRange(location: prefixLen, length: newNs.length - prefixLen - suffixLen))

            if let storage = textView.textStorage {
                // External binding is the source of truth here. Detach the
                // delegate so the atomic-token guard can't block or rewrite a
                // programmatic diff that happens to touch a token range.
                let savedDelegate = textView.delegate
                textView.delegate = nil
                storage.beginEditing()
                storage.replaceCharacters(in: replaceRange, with: replacement)
                storage.endEditing()
                textView.delegate = savedDelegate
                let newCursorLocation = prefixLen + (replacement as NSString).length
                textView.setSelectedRange(NSRange(location: newCursorLocation, length: 0))
            }
        }
        context.coordinator.applyMentionStyling()
        context.coordinator.updateHeight()
        context.coordinator.placeholderLabel.stringValue = placeholder
        context.coordinator.syncPlaceholder()
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MentionTextView {
            didSet {
                if parent.aliases != oldValue.aliases {
                    sortedAliases = parent.aliases.sorted { $0.count > $1.count }
                }
            }
        }
        var sortedAliases: [String] = []
        weak var textView: MentionNSTextView?
        weak var scrollView: NSScrollView?
        let placeholderLabel = NSTextField(labelWithString: "")

        init(_ parent: MentionTextView) {
            self.parent = parent
            self.sortedAliases = parent.aliases.sorted { $0.count > $1.count }
            super.init()
            placeholderLabel.font = parent.font
            placeholderLabel.textColor = .placeholderTextColor
            placeholderLabel.isEditable = false
            placeholderLabel.isSelectable = false
            placeholderLabel.drawsBackground = false
            placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        }

        // MARK: Text sync

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            // During IME composition the string still contains uncommitted
            // marked text; pushing it into the binding (and restyling the
            // storage) would break the composition. Track the height only —
            // the commit fires another change that runs the full sync.
            if textView.hasMarkedText() {
                updateHeight()
                return
            }
            parent.text = textView.string
            syncPlaceholder()
            applyMentionStyling()
            updateHeight()
        }

        /// Placeholder shows only when the editor is both empty *and* unfocused,
        /// so it clears the moment the field takes focus — not only once the user
        /// starts typing. Focus transitions are pushed in from the text view's
        /// `becomeFirstResponder` / `resignFirstResponder` (the `firstResponder`
        /// check is stale during a resign, so those set visibility directly).
        func syncPlaceholder() {
            guard let textView else { return }
            let focused = textView.window?.firstResponder === textView
            placeholderLabel.isHidden = focused || !textView.string.isEmpty
        }

        /// Tags completed mention tokens with `.mentionToken` so the layout
        /// manager draws a pill behind them.
        func applyMentionStyling() {
            guard let textView, let storage = textView.textStorage else { return }
            let full = NSRange(location: 0, length: storage.length)
            // Pin to the label color rather than `textView.textColor`, whose getter
            // returns the (possibly blue) current typing/selection color and would
            // otherwise paint the whole string blue.
            let defaultColor = NSColor.textColor
            let defaultFont = textView.font ?? NSFont.systemFont(ofSize: 14.5)
            storage.beginEditing()
            storage.removeAttribute(.mentionToken, range: full)
            storage.addAttribute(.foregroundColor, value: defaultColor, range: full)
            storage.addAttribute(.font, value: defaultFont, range: full)
            for range in MentionTextView.mentionRanges(in: textView.string, sortedAliases: sortedAliases) {
                storage.addAttribute(.mentionToken, value: true, range: range)
                storage.addAttribute(.foregroundColor, value: NSColor.systemBlue, range: range)
            }
            storage.endEditing()

            // Reset typing attributes to use the default text color so newly typed text is not blue.
            var attrs = textView.typingAttributes
            attrs[.foregroundColor] = defaultColor
            attrs[.font] = defaultFont
            textView.typingAttributes = attrs
        }

        // MARK: Atomic mention enforcement

        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            let nsText = textView.string as NSString
            let tokens = MentionTextView.mentionRanges(in: textView.string, sortedAliases: sortedAliases)
            let isDeletion = (replacementString ?? "").isEmpty

            // If it's a multi-character change (like clearing the text view via `draft = ""` or cmd-A delete),
            // let it bypass the atomic token block and proceed normally.
            guard affectedCharRange.length <= 1 else { return true }

            for token in tokens {
                // The whole token plus one trailing space (so it deletes cleanly).
                var whole = token
                if NSMaxRange(token) < nsText.length,
                   nsText.substring(with: NSRange(location: NSMaxRange(token), length: 1)) == " " {
                    whole = NSRange(location: token.location, length: token.length + 1)
                }

                if isDeletion {
                    // Our own follow-up edit (deleting exactly the token) → allow,
                    // so it doesn't recurse back into this guard.
                    if affectedCharRange == whole || affectedCharRange == token { continue }
                    // A backspace/delete touching the token removes it entirely.
                    let touches = NSIntersectionRange(affectedCharRange, token).length > 0
                        || (affectedCharRange.length == 0 && affectedCharRange.location == NSMaxRange(token))
                    if touches {
                        if textView.shouldChangeText(in: whole, replacementString: "") {
                            textView.textStorage?.replaceCharacters(in: whole, with: "")
                            textView.didChangeText()
                        }
                        return false
                    }
                } else if affectedCharRange.length == 0,
                          affectedCharRange.location > token.location,
                          affectedCharRange.location < NSMaxRange(token) {
                    // Insertion strictly inside a token → block.
                    return false
                }
            }
            return true
        }

        // MARK: Selection / Caret boundary enforcement

        func textView(_ textView: NSTextView, willChangeSelectionFromCharacterRanges oldSelectedCharRanges: [NSValue], toCharacterRanges newSelectedCharRanges: [NSValue]) -> [NSValue] {
            let tokens = MentionTextView.mentionRanges(in: textView.string, sortedAliases: sortedAliases)
            guard !tokens.isEmpty else { return newSelectedCharRanges }

            return newSelectedCharRanges.map { value in
                var range = value.rangeValue

                if range.length == 0 {
                    let loc = range.location
                    for token in tokens {
                        let strictlyInside = loc > token.location && loc < NSMaxRange(token)
                        let landsOnLeftBoundary = loc == token.location
                        let landsOnRightBoundary = loc == NSMaxRange(token)

                        if let oldRange = oldSelectedCharRanges.first?.rangeValue, oldRange.length == 0 {
                            let oldLoc = oldRange.location
                            let isArrowKey = abs(loc - oldLoc) == 1

                            if isArrowKey {
                                if loc < oldLoc {
                                    // Moving left: if proposed is inside or exactly on the right boundary, jump over to start
                                    if strictlyInside || landsOnRightBoundary {
                                        range.location = token.location
                                        break
                                    }
                                } else if loc > oldLoc {
                                    // Moving right: if proposed is inside or exactly on the left boundary, jump over to end
                                    if strictlyInside || landsOnLeftBoundary {
                                        range.location = NSMaxRange(token)
                                        break
                                    }
                                }
                            } else if strictlyInside {
                                // Mouse click or large jump: snap to nearest edge
                                let distToStart = loc - token.location
                                let distToEnd = NSMaxRange(token) - loc
                                range.location = (distToStart < distToEnd) ? token.location : NSMaxRange(token)
                                break
                            }
                        } else if strictlyInside {
                            // Fallback
                            let distToStart = loc - token.location
                            let distToEnd = NSMaxRange(token) - loc
                            range.location = (distToStart < distToEnd) ? token.location : NSMaxRange(token)
                            break
                        }
                    }
                } else {
                    // Selection (length > 0): expand to enclose the whole token if intersected
                    for token in tokens {
                        let intersection = NSIntersectionRange(range, token)
                        if intersection.length > 0 {
                            let start = min(range.location, token.location)
                            let end = max(NSMaxRange(range), NSMaxRange(token))
                            range = NSRange(location: start, length: end - start)
                        }
                    }
                }

                return NSValue(range: range)
            }
        }

        // MARK: Key handling (Return to send / mention popup navigation)

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                if parent.onKeyCommand(.confirm) { return true }
                parent.onSubmit()
                return true
            case #selector(NSResponder.insertTab(_:)):
                return parent.onKeyCommand(.confirm)
            case #selector(NSResponder.moveUp(_:)):
                return parent.onKeyCommand(.moveUp)
            case #selector(NSResponder.moveDown(_:)):
                return parent.onKeyCommand(.moveDown)
            case #selector(NSResponder.cancelOperation(_:)):
                return parent.onKeyCommand(.dismiss)
            default:
                return false
            }
        }

        // MARK: Height (1–3 lines)

        var cachedHeight: CGFloat = 0

        func updateHeight() {
            guard let textView,
                  let layoutManager = textView.layoutManager,
                  let container = textView.textContainer else { return }
            layoutManager.ensureLayout(for: container)
            let used = layoutManager.usedRect(for: container).height
            let line = ceil(parent.font.ascender - parent.font.descender + parent.font.leading)
            let inset = textView.textContainerInset.height * 2
            let minH = line * CGFloat(parent.minLines) + inset
            let maxH = line * CGFloat(parent.maxLines) + inset
            let target = min(max(used + inset, minH), maxH)
            scrollView?.hasVerticalScroller = used + inset > maxH + 0.5
            if abs(cachedHeight - target) > 0.5 {
                cachedHeight = target
                let notify = parent.onHeightChange
                DispatchQueue.main.async { notify(target) }
            }
        }
    }

    /// `@alias` tokens (alias ∈ `sortedAliases`) bounded by whitespace / string edges.
    /// Expects `sortedAliases` to be sorted by length (descending) for correct matching.
    static func mentionRanges(in text: String, sortedAliases: [String]) -> [NSRange] {
        guard !sortedAliases.isEmpty else { return [] }
        let ns = text as NSString
        var ranges: [NSRange] = []
        var searchStart = 0
        while searchStart < ns.length {
            let at = ns.range(of: "@", options: [], range: NSRange(location: searchStart, length: ns.length - searchStart))
            guard at.location != NSNotFound else { break }
            // Must be preceded by whitespace or start.
            let precededOK = at.location == 0
                || CharacterSet.whitespacesAndNewlines.contains(ns.character(at: at.location - 1).unicodeScalar)
            var matched = false
            if precededOK {
                for alias in sortedAliases {
                    let tokenLen = alias.count + 1  // include '@'
                    let end = at.location + tokenLen
                    guard end <= ns.length else { continue }
                    let candidate = ns.substring(with: NSRange(location: at.location, length: tokenLen))
                    // Match the router's casing rules (see AgentMentionRouteParser)
                    // so "@Coding" both routes and renders as a token.
                    guard candidate.compare("@\(alias)", options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame else { continue }
                    // Followed by whitespace or end.
                    let followedOK = end == ns.length
                        || CharacterSet.whitespacesAndNewlines.contains(ns.character(at: end).unicodeScalar)
                    if followedOK {
                        ranges.append(NSRange(location: at.location, length: tokenLen))
                        searchStart = end
                        matched = true
                        break
                    }
                }
            }
            if !matched { searchStart = at.location + 1 }
        }
        return ranges
    }
}

/// `NSTextView` subclass that hosts a placeholder label and reports its
/// preferred (clamped) height as `intrinsicContentSize`.
final class MentionNSTextView: NSTextView {
    weak var coordinator: MentionTextView.Coordinator?

    override func didChangeText() {
        super.didChangeText()
        coordinator?.updateHeight()
    }

    // IME composition (marked text) doesn't go through `didChangeText`, but it
    // can still wrap onto a new line at the field's right edge — grow the field
    // so the uncommitted text stays visible instead of being clipped.
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        coordinator?.updateHeight()
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        // Gaining focus → hide the placeholder immediately (the field is empty
        // here; if it had text it would already be hidden).
        if ok { coordinator?.placeholderLabel.isHidden = true }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        // Losing focus → restore the placeholder if the field is empty. The
        // window's `firstResponder` still points at self during resign, so set
        // visibility from the text alone rather than via `syncPlaceholder()`.
        if ok { coordinator?.placeholderLabel.isHidden = !string.isEmpty }
        return ok
    }
}

private extension UInt16 {
    var unicodeScalar: Unicode.Scalar { Unicode.Scalar(self) ?? Unicode.Scalar(0) }
}

extension NSAttributedString.Key {
    static let mentionToken = NSAttributedString.Key("hermesMentionToken")
}

/// Layout manager that paints a rounded pill behind each `.mentionToken` range.
/// Requires the TextKit 1 stack (TextKit 2 routes drawing elsewhere and would
/// bypass this override).
final class MentionLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let textStorage, let container = textContainers.first else { return }
        let charRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        textStorage.enumerateAttribute(.mentionToken, in: charRange) { value, range, _ in
            guard value != nil else { return }
            let tokenGlyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let rect = boundingRect(forGlyphRange: tokenGlyphs, in: container)
                .offsetBy(dx: origin.x, dy: origin.y)
                .insetBy(dx: -2, dy: -1)
            let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
            NSColor.systemBlue.withAlphaComponent(0.14).setFill()
            path.fill()
        }
    }
}
