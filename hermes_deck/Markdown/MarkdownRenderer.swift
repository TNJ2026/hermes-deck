import AppKit
import Foundation
import SwiftUI

/// Inline emphasis carried down through nested spans (e.g. bold wrapping inline
/// code), so `**`code`**` renders the code chip in a bold context.
struct Emphasis: OptionSet, Hashable, Sendable {
    let rawValue: Int
    static let bold = Emphasis(rawValue: 1 << 0)
    static let italic = Emphasis(rawValue: 1 << 1)
    static let strikethrough = Emphasis(rawValue: 1 << 2)
}

enum MarkdownInline: Hashable, Sendable {
    case text(String, emphasis: Emphasis = [])
    case inlineCode(String, emphasis: Emphasis = [])
    case link(text: String, url: String, emphasis: Emphasis = [])
    case image(alt: String, url: String)
}

enum MarkdownBlock: Hashable, Sendable {
    case heading(level: Int, text: String)
    case paragraph([MarkdownInline])
    case unorderedList([[MarkdownInline]])
    case orderedList(start: Int, items: [[MarkdownInline]])
    case codeBlock(String?, String)
    case table(headers: [String], rows: [[String]])
    case thematicBreak
}

struct MarkdownRenderer: Sendable {
    func parse(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var lines = source.components(separatedBy: .newlines)

        while !lines.isEmpty {
            let line = lines.removeFirst()
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            if trimmed.hasPrefix("```") {
                let language = String(trimmed.dropFirst(3)).nilIfEmpty
                var codeLines: [String] = []
                while let next = lines.first {
                    lines.removeFirst()
                    if next.trimmingCharacters(in: .whitespaces).hasPrefix("```") { break }
                    codeLines.append(next)
                }
                blocks.append(.codeBlock(language, codeLines.joined(separator: "\n")))
                continue
            }

            if let heading = parseHeading(trimmed) {
                blocks.append(heading)
                continue
            }

            if isTableHeader(trimmed, next: lines.first) {
                let headers = splitTableRow(trimmed)
                lines.removeFirst()
                var rows: [[String]] = []
                while let next = lines.first, next.trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(splitTableRow(next))
                    lines.removeFirst()
                }
                blocks.append(.table(headers: headers, rows: rows))
                continue
            }

            if isThematicBreak(trimmed) {
                blocks.append(.thematicBreak)
                continue
            }

            if trimmed.hasPrefix("- ") {
                var items = [parseInline(String(trimmed.dropFirst(2)))]
                while let next = lines.first?.trimmingCharacters(in: .whitespaces), next.hasPrefix("- ") {
                    lines.removeFirst()
                    items.append(parseInline(String(next.dropFirst(2))))
                }
                blocks.append(.unorderedList(items))
                continue
            }

            if let first = orderedListItem(trimmed) {
                var items = [parseInline(first.content)]
                while let next = lines.first?.trimmingCharacters(in: .whitespaces), let item = orderedListItem(next) {
                    lines.removeFirst()
                    items.append(parseInline(item.content))
                }
                blocks.append(.orderedList(start: first.number, items: items))
                continue
            }

            var paragraph = trimmed
            while let next = lines.first?.trimmingCharacters(in: .whitespaces), !next.isEmpty, !next.hasPrefix("#"), !next.hasPrefix("```"), !next.hasPrefix("|"), !next.hasPrefix("- "), orderedListItem(next) == nil, !isThematicBreak(next) {
                paragraph += " " + next
                lines.removeFirst()
            }
            blocks.append(.paragraph(parseInline(paragraph)))
        }

        return blocks
    }

    private func parseHeading(_ line: String) -> MarkdownBlock? {
        let marks = line.prefix { $0 == "#" }
        guard (1...6).contains(marks.count), line.dropFirst(marks.count).first == " " else { return nil }
        return .heading(level: marks.count, text: String(line.dropFirst(marks.count + 1)))
    }

    private func isTableHeader(_ line: String, next: String?) -> Bool {
        guard line.hasPrefix("|"), let next else { return false }
        return next.trimmingCharacters(in: .whitespaces).contains("---")
    }

    private func isThematicBreak(_ line: String) -> Bool {
        let markers = line.filter { !$0.isWhitespace }
        guard let marker = markers.first, marker == "-" || marker == "*" || marker == "_" else { return false }
        return markers.count >= 3 && markers.allSatisfy { $0 == marker }
    }

    /// Parses an ordered list item like `1. text` or `2) text`.
    private func orderedListItem(_ line: String) -> (number: Int, content: String)? {
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty, let number = Int(digits) else { return nil }
        let rest = line[digits.endIndex...]
        guard let marker = rest.first, marker == "." || marker == ")" else { return nil }
        let afterMarker = rest.dropFirst()
        guard afterMarker.first == " " else { return nil }
        return (number, String(afterMarker.dropFirst()))
    }

    private func splitTableRow(_ line: String) -> [String] {
        line.trimmingCharacters(in: CharacterSet(charactersIn: "| "))
            .components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    func parseInline(_ text: String) -> [MarkdownInline] {
        parseInline(text[...], emphasis: [])
    }

    private func parseInline(_ text: Substring, emphasis: Emphasis) -> [MarkdownInline] {
        var runs: [MarkdownInline] = []
        var index = text.startIndex
        var buffer = ""

        func flush() {
            if !buffer.isEmpty {
                runs.append(contentsOf: FilePathLink.runs(in: buffer, emphasis: emphasis))
                buffer = ""
            }
        }

        while index < text.endIndex {
            if text[index] == "`", let end = text[text.index(after: index)...].firstIndex(of: "`") {
                flush()
                runs.append(.inlineCode(String(text[text.index(after: index)..<end]), emphasis: emphasis))
                index = text.index(after: end)
                continue
            }

            if text[index] == "!", text.index(after: index) < text.endIndex, text[text.index(after: index)] == "[",
               let parsed = parseBracketLink(text, start: text.index(after: index)) {
                flush()
                runs.append(.image(alt: parsed.label, url: parsed.url))
                index = parsed.next
                continue
            }

            if text[index] == "[", let parsed = parseBracketLink(text, start: index) {
                flush()
                runs.append(.link(text: parsed.label, url: parsed.url, emphasis: emphasis))
                index = parsed.next
                continue
            }

            if let span = emphasisSpan(text, at: index) {
                flush()
                runs.append(contentsOf: parseInline(text[span.innerRange], emphasis: emphasis.union(span.style)))
                index = span.end
                continue
            }

            buffer.append(text[index])
            index = text.index(after: index)
        }

        flush()
        return runs
    }

    private struct EmphasisSpan {
        var style: Emphasis
        var innerRange: Range<Substring.Index>
        var end: Substring.Index
    }

    /// Detects an emphasis span opening at `index`: `**`/`__` bold, `~~`
    /// strikethrough, `*`/`_` italic. Requires a non-space inner edge, and
    /// underscore variants must sit at word boundaries so `snake_case` is left
    /// alone.
    private func emphasisSpan(_ text: Substring, at index: Substring.Index) -> EmphasisSpan? {
        let rest = text[index...]
        let delimiter: String
        let style: Emphasis
        if rest.hasPrefix("**") { delimiter = "**"; style = .bold }
        else if rest.hasPrefix("__") { delimiter = "__"; style = .bold }
        else if rest.hasPrefix("~~") { delimiter = "~~"; style = .strikethrough }
        else if rest.hasPrefix("*") { delimiter = "*"; style = .italic }
        else if rest.hasPrefix("_") { delimiter = "_"; style = .italic }
        else { return nil }

        let isUnderscore = delimiter.first == "_"
        if isUnderscore {
            let beforeIsBoundary = index == text.startIndex || !Self.isWordCharacter(text[text.index(before: index)])
            guard beforeIsBoundary else { return nil }
        }

        let delimiterCount = delimiter.count
        let innerStart = text.index(index, offsetBy: delimiterCount)
        guard innerStart < text.endIndex, !text[innerStart].isWhitespace else { return nil }

        guard let closeStart = findClosingDelimiter(
            text, from: innerStart, delimiter: Array(delimiter), requireWordBoundaryAfter: isUnderscore
        ) else { return nil }

        return EmphasisSpan(
            style: style,
            innerRange: innerStart..<closeStart,
            end: text.index(closeStart, offsetBy: delimiterCount)
        )
    }

    private func findClosingDelimiter(
        _ text: Substring,
        from start: Substring.Index,
        delimiter: [Character],
        requireWordBoundaryAfter: Bool
    ) -> Substring.Index? {
        var index = start
        while index < text.endIndex {
            if text[index] == delimiter[0], matchesDelimiter(text, at: index, delimiter: delimiter) {
                let afterIndex = text.index(index, offsetBy: delimiter.count)
                let before = text[text.index(before: index)]
                let innerNonEmpty = index > start
                let leftFlankOK = !before.isWhitespace
                let afterOK = !requireWordBoundaryAfter || afterIndex == text.endIndex || !Self.isWordCharacter(text[afterIndex])
                if innerNonEmpty, leftFlankOK, afterOK {
                    return index
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    private func matchesDelimiter(_ text: Substring, at index: Substring.Index, delimiter: [Character]) -> Bool {
        var cursor = index
        for character in delimiter {
            guard cursor < text.endIndex, text[cursor] == character else { return false }
            cursor = text.index(after: cursor)
        }
        return true
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    private func parseBracketLink(_ text: Substring, start: Substring.Index) -> (label: String, url: String, next: Substring.Index)? {
        guard let labelEnd = text[start...].firstIndex(of: "]") else { return nil }
        let openParen = text.index(after: labelEnd)
        guard openParen < text.endIndex, text[openParen] == "(" else { return nil }
        guard let closeParen = text[openParen...].firstIndex(of: ")") else { return nil }
        return (
            String(text[text.index(after: start)..<labelEnd]),
            String(text[text.index(after: openParen)..<closeParen]),
            text.index(after: closeParen)
        )
    }
}

/// Applies bold/italic traits from an `Emphasis` set onto a base font.
private func markdownEmphasizedFont(base: Font, emphasis: Emphasis) -> Font {
    var font = base
    if emphasis.contains(.bold) { font = font.bold() }
    if emphasis.contains(.italic) { font = font.italic() }
    return font
}

struct MarkdownView: View {
    let source: String
    private let blocks: [MarkdownBlock]

    init(_ source: String) {
        self.source = source
        self.blocks = MarkdownRenderer().parse(source)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(text)
                .font(headingFont(level))
                .fontWeight(.semibold)
        case .paragraph(let runs):
            inlineView(runs)
                .font(.body)
        case .unorderedList(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•")
                        inlineView(item)
                    }
                }
            }
        case .orderedList(let start, let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(start + index).")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        inlineView(item)
                    }
                }
            }
        case .codeBlock(let language, let code):
            MarkdownCodeBlockView(language: language, code: code)
        case .thematicBreak:
            Divider()
                .frame(maxWidth: .infinity)
        case .table(let headers, let rows):
            let totalColumns = max(2 * headers.count - 1, 1)
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow {
                        ForEach(Array(headers.enumerated()), id: \.offset) { index, header in
                            MarkdownTableCell(runs: MarkdownRenderer().parseInline(header), isHeader: true)
                            if index < headers.count - 1 {
                                Rectangle()
                                    .fill(.quaternary)
                                    .frame(width: 1)
                            }
                        }
                    }
                    
                    Divider().gridCellColumns(totalColumns)
                    
                    ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { index, cell in
                                MarkdownTableCell(runs: MarkdownRenderer().parseInline(cell), isHeader: false)
                                if index < row.count - 1 {
                                    Rectangle()
                                        .fill(.quaternary)
                                        .frame(width: 1)
                                }
                            }
                        }
                        if rowIndex < rows.count - 1 {
                            Divider().gridCellColumns(totalColumns)
                        }
                    }
                }
                .frame(minWidth: 360, alignment: .leading)
                .background(alignment: .top) {
                    Color.gray.opacity(0.12)
                        .frame(height: 34)
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(.quaternary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func inlineView(_ runs: [MarkdownInline]) -> some View {
        if runs.contains(where: { if case .image = $0 { true } else { false } }) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(inlineChunks(from: runs).enumerated()), id: \.offset) { _, chunk in
                    switch chunk {
                    case .runs(let runs):
                        inlineRunsView(runs)
                    case .image(let alt, let url):
                        markdownImage(alt: alt, url: url)
                    }
                }
            }
        } else {
            inlineRunsView(runs)
        }
    }

    @ViewBuilder
    private func inlineRunsView(_ runs: [MarkdownInline]) -> some View {
        let hasLink = runs.contains(where: \.isLink)
        Text(markdownAttributedString(for: runs))
            .conditionalTextSelection(!hasLink)
            .conditionalPointingHand(hasLink)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inlineChunks(from runs: [MarkdownInline]) -> [InlineChunk] {
        var chunks: [InlineChunk] = []
        var textRuns: [MarkdownInline] = []

        func flushTextRuns() {
            guard !textRuns.isEmpty else { return }
            chunks.append(.runs(textRuns))
            textRuns.removeAll()
        }

        for run in runs {
            switch run {
            case .image(let alt, let url):
                flushTextRuns()
                chunks.append(.image(alt: alt, url: url))
            case .text, .inlineCode, .link:
                textRuns.append(run)
            }
        }

        flushTextRuns()
        return chunks
    }

    @ViewBuilder
    private func markdownImage(alt: String, url: String) -> some View {
        if let imageURL = markdownImageURL(from: url) {
            if imageURL.isFileURL {
                if let image = NSImage(contentsOf: imageURL) {
                    renderedImage(Image(nsImage: image), alt: alt)
                } else {
                    imageFailureView(alt: alt, message: "Image unavailable")
                }
            } else {
                AsyncImage(url: imageURL, transaction: Transaction(animation: .default)) { phase in
                    switch phase {
                    case .success(let image):
                        renderedImage(image, alt: alt)
                    case .failure:
                        imageFailureView(alt: alt, message: "Image failed to load")
                    case .empty:
                        imagePlaceholderView(alt: alt)
                    @unknown default:
                        imagePlaceholderView(alt: alt)
                    }
                }
            }
        } else {
            imageFailureView(alt: alt, message: "Invalid image URL")
        }
    }

    private func renderedImage(_ image: Image, alt: String) -> some View {
        image
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity, maxHeight: 280, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .accessibilityLabel(alt.isEmpty ? "Markdown image" : alt)
    }

    private func imagePlaceholderView(alt: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(.quaternary)
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(alt.isEmpty ? "Loading markdown image" : "Loading \(alt)")
        }
        .frame(width: 220, height: 140)
    }

    private func imageFailureView(alt: String, message: String) -> some View {
        Label(alt.isEmpty ? message : "\(message): \(alt)", systemImage: "photo")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(10)
            .frame(maxWidth: 420, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }

    private func markdownImageURL(from rawURL: String) -> URL? {
        let trimmedURL = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else { return nil }

        if let url = URL(string: trimmedURL), url.scheme != nil {
            return url
        }

        if trimmedURL.hasPrefix("~") {
            return URL(fileURLWithPath: NSString(string: trimmedURL).expandingTildeInPath)
        }

        return URL(fileURLWithPath: trimmedURL)
    }

    private func markdownAttributedString(for runs: [MarkdownInline]) -> AttributedString {
        var attributedString = AttributedString()
        for run in runs {
            attributedString.append(markdownAttributedSegment(for: run, isHeader: false))
        }
        return attributedString
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title2
        case 2: .title3
        default: .headline
        }
    }
}

private struct MarkdownTableCell: View {
    let runs: [MarkdownInline]
    let isHeader: Bool

    var body: some View {
        Text(attributedString(for: runs))
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
    }

    private func attributedString(for runs: [MarkdownInline]) -> AttributedString {
        var attributedString = AttributedString()
        for run in runs {
            attributedString.append(markdownAttributedSegment(for: run, isHeader: isHeader))
        }
        return attributedString
    }
}

/// Matches a bare `@mention` token — a profile id or `claude`/`codex`/`gemini`.
/// The lookbehind keeps `you@host.com` and `a@b` from matching.
private let markdownMentionRegex = try? NSRegularExpression(pattern: "(?<![\\w@])@[A-Za-z0-9_-]+")

/// Tints bare `@mention` tokens blue while leaving all other styling intact.
/// Applied to plain-text Markdown runs so the highlight shows in user prompts
/// and assistant replies alike (the previous user-only `MentionHighlightedText`
/// is folded in here).
private func markdownHighlightingMentions(_ attr: AttributedString) -> AttributedString {
    guard let regex = markdownMentionRegex else { return attr }
    let plain = String(attr.characters)
    guard !plain.isEmpty else { return attr }
    var result = attr
    let ns = plain as NSString
    for match in regex.matches(in: plain, range: NSRange(location: 0, length: ns.length)) {
        guard let strRange = Range(match.range, in: plain),
              let attrRange = Range(strRange, in: result) else { continue }
        result[attrRange].foregroundColor = .blue
    }
    return result
}

private func markdownAttributedSegment(for run: MarkdownInline, isHeader: Bool) -> AttributedString {
    var segment = AttributedString()
    switch run {
    case .text(let text, let emphasis):
        if let parsed = try? AttributedString(markdown: text) {
            segment = parsed
        } else {
            segment = AttributedString(text)
        }
        segment.font = markdownEmphasizedFont(base: .body, emphasis: isHeader ? emphasis.union(.bold) : emphasis)
        segment = markdownHighlightingMentions(segment)
    case .inlineCode(let code, let emphasis):
        var codeSegment = AttributedString(code)
        codeSegment.font = markdownEmphasizedFont(base: .system(.body, design: .monospaced), emphasis: isHeader ? emphasis.union(.bold) : emphasis)
        codeSegment.foregroundColor = Color(red: 114 / 255, green: 135 / 255, blue: 253 / 255)
        codeSegment.backgroundColor = Color.secondary.opacity(0.16)
        // Inline code that looks like a file path becomes a clickable link
        // (revealed in Finder) while keeping its code styling, plus an underline
        // to read as a link.
        if let fileURL = FilePathLink.url(for: code) {
            codeSegment.link = fileURL
            codeSegment.underlineStyle = .single
        }
        // Pad with plain (unstyled) spaces so the code chip never butts up
        // against adjacent CJK/text — the spaces carry no code background.
        segment = AttributedString(" ")
        segment.append(codeSegment)
        segment.append(AttributedString(" "))
    case .link(let text, let url, let emphasis):
        segment = AttributedString(text)
        segment.font = markdownEmphasizedFont(base: .body, emphasis: isHeader ? emphasis.union(.bold) : emphasis)
        if let actualURL = URL(string: url) {
            segment.link = actualURL
            segment.foregroundColor = .accentColor
        }
    case .image(let alt, _):
        segment = AttributedString(alt)
        segment.font = isHeader ? .body.bold() : .body
    }
    return segment
}

private struct MarkdownCodeBlockView: View {
    let language: String?
    let code: String

    @State private var didCopy = false
    @State private var resetTask: Task<Void, Never>?

    private let headerBackground = Color.gray.opacity(0.12)
    private let languageColor = Color(red: 156 / 255, green: 160 / 255, blue: 176 / 255)
    private let shape = RoundedRectangle(cornerRadius: 8)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let language {
                HStack(spacing: 8) {
                    Text(language.uppercased())
                        .font(.caption2)
                        .foregroundStyle(languageColor)

                    Spacer(minLength: 12)

                    Button {
                        CodeBlockClipboard.copy(code)
                        showCopiedFeedback()
                    } label: {
                        Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(didCopy ? Color.green : Color.secondary)
                    .help("Copy code")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Rectangle().fill(headerBackground))

                Rectangle()
                    .fill(.quaternary)
                    .frame(height: 1)
            }

            ScrollView(.horizontal) {
                Text(highlightedCode)
                    .font(.system(.body, design: .monospaced))
                    .padding(10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.gray.opacity(0.12), in: shape)
        .clipShape(shape)
        .onDisappear { resetTask?.cancel() }
    }

    /// Routing blocks are plain fences leading with `@target` — tint mentions
    /// blue there so the addressed agent stands out. Language-tagged code keeps
    /// `@` tokens unstyled (Swift `@State`, Python decorators, …).
    private var highlightedCode: AttributedString {
        let attributed = CodeBlockSyntaxHighlighter.attributedString(for: code, language: language)
        guard language == nil else { return attributed }
        return markdownHighlightingMentions(attributed)
    }

    /// Flips the button to a checkmark, reverting to the copy icon after 2s.
    private func showCopiedFeedback() {
        resetTask?.cancel()
        withAnimation(.smooth(duration: 0.15)) { didCopy = true }
        resetTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            withAnimation(.smooth(duration: 0.15)) { didCopy = false }
        }
    }
}

enum HighlightedCodeTokenKind: Equatable, Sendable {
    case plain
    case keyword
    case string
    case comment
    case number
}

struct HighlightedCodeToken: Equatable, Sendable {
    let text: String
    let kind: HighlightedCodeTokenKind
}

enum CodeBlockSyntaxHighlighter {
    private static let swiftKeywords: Set<String> = [
        "actor", "as", "associatedtype", "async", "await", "break", "case", "catch", "class",
        "continue", "default", "defer", "deinit", "do", "else", "enum", "extension", "false",
        "for", "func", "guard", "if", "import", "in", "init", "inout", "is", "let", "nil",
        "operator", "private", "protocol", "public", "repeat", "return", "self", "static",
        "struct", "subscript", "super", "switch", "throw", "throws", "true", "try", "typealias",
        "var", "where", "while"
    ]
    private static let javascriptKeywords: Set<String> = [
        "await", "break", "case", "catch", "class", "const", "continue", "debugger", "default",
        "delete", "do", "else", "export", "extends", "false", "finally", "for", "function",
        "if", "import", "in", "instanceof", "let", "new", "null", "return", "static", "super",
        "switch", "this", "throw", "true", "try", "typeof", "undefined", "var", "void", "while",
        "with", "yield"
    ]
    private static let pythonKeywords: Set<String> = [
        "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del",
        "elif", "else", "except", "False", "finally", "for", "from", "global", "if", "import",
        "in", "is", "lambda", "None", "nonlocal", "not", "or", "pass", "raise", "return",
        "True", "try", "while", "with", "yield"
    ]
    private static let shellKeywords: Set<String> = [
        "alias", "case", "cd", "do", "done", "echo", "elif", "else", "esac", "export", "fi",
        "for", "function", "if", "in", "local", "read", "return", "set", "shift", "then",
        "unset", "until", "while"
    ]

    static func attributedString(for code: String, language: String?) -> AttributedString {
        var output = AttributedString()
        for token in tokens(for: code, language: language) {
            var segment = AttributedString(token.text)
            segment.foregroundColor = color(for: token.kind)
            output.append(segment)
        }
        return output
    }

    static func tokens(for code: String, language: String?) -> [HighlightedCodeToken] {
        guard let definition = languageDefinition(for: language) else {
            return [HighlightedCodeToken(text: code, kind: .plain)]
        }

        var tokens: [HighlightedCodeToken] = []
        var index = code.startIndex
        while index < code.endIndex {
            if let commentPrefix = definition.commentPrefixes.first(where: { code[index...].hasPrefix($0) }) {
                let start = index
                index = code.index(index, offsetBy: commentPrefix.count)
                while index < code.endIndex, code[index] != "\n" {
                    index = code.index(after: index)
                }
                tokens.append(HighlightedCodeToken(text: String(code[start..<index]), kind: .comment))
                continue
            }

            if definition.stringDelimiters.contains(code[index]) {
                let delimiter = code[index]
                let start = index
                index = code.index(after: index)
                var isEscaped = false
                while index < code.endIndex {
                    let character = code[index]
                    index = code.index(after: index)
                    if character == delimiter, !isEscaped {
                        break
                    }
                    isEscaped = character == "\\" && !isEscaped
                    if character != "\\" {
                        isEscaped = false
                    }
                }
                tokens.append(HighlightedCodeToken(text: String(code[start..<index]), kind: .string))
                continue
            }

            if code[index].isNumber {
                let start = index
                index = code.index(after: index)
                while index < code.endIndex, code[index].isNumber || code[index] == "." {
                    index = code.index(after: index)
                }
                tokens.append(HighlightedCodeToken(text: String(code[start..<index]), kind: .number))
                continue
            }

            if code[index].isIdentifierStart {
                let start = index
                index = code.index(after: index)
                while index < code.endIndex, code[index].isIdentifierPart {
                    index = code.index(after: index)
                }
                let text = String(code[start..<index])
                tokens.append(HighlightedCodeToken(text: text, kind: definition.keywords.contains(text) ? .keyword : .plain))
                continue
            }

            let start = index
            index = code.index(after: index)
            tokens.append(HighlightedCodeToken(text: String(code[start..<index]), kind: .plain))
        }
        return mergeAdjacentPlainTokens(tokens)
    }

    private static func mergeAdjacentPlainTokens(_ tokens: [HighlightedCodeToken]) -> [HighlightedCodeToken] {
        tokens.reduce(into: []) { merged, token in
            if token.kind == .plain, var last = merged.last, last.kind == .plain {
                last = HighlightedCodeToken(text: last.text + token.text, kind: .plain)
                merged[merged.count - 1] = last
            } else {
                merged.append(token)
            }
        }
    }

    private static func languageDefinition(for language: String?) -> LanguageDefinition? {
        switch language?.lowercased() {
        case "swift": LanguageDefinition(keywords: swiftKeywords, commentPrefixes: ["//"], stringDelimiters: ["\"", "'"])
        case "js", "jsx", "javascript", "ts", "tsx", "typescript":
            LanguageDefinition(keywords: javascriptKeywords, commentPrefixes: ["//"], stringDelimiters: ["\"", "'", "`"])
        case "py", "python":
            LanguageDefinition(keywords: pythonKeywords, commentPrefixes: ["#"], stringDelimiters: ["\"", "'"])
        case "bash", "sh", "shell", "zsh":
            LanguageDefinition(keywords: shellKeywords, commentPrefixes: ["#"], stringDelimiters: ["\"", "'"])
        default:
            nil
        }
    }

    private static func color(for kind: HighlightedCodeTokenKind) -> Color {
        switch kind {
        case .plain:
            .primary
        case .keyword:
            Color(red: 136 / 255, green: 57 / 255, blue: 239 / 255)
        case .string:
            Color(red: 64 / 255, green: 160 / 255, blue: 43 / 255)
        case .comment:
            .secondary
        case .number:
            Color(red: 223 / 255, green: 142 / 255, blue: 29 / 255)
        }
    }
}

private struct LanguageDefinition {
    let keywords: Set<String>
    let commentPrefixes: [String]
    let stringDelimiters: Set<Character>
}

private extension Character {
    var isIdentifierStart: Bool {
        isLetter || self == "_"
    }

    var isIdentifierPart: Bool {
        isIdentifierStart || isNumber
    }
}

enum CodeBlockClipboard {
    static func copy(_ code: String, pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(code, forType: .string)
    }
}

private enum InlineChunk: Hashable {
    case runs([MarkdownInline])
    case image(alt: String, url: String)
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

private extension MarkdownInline {
    var isLink: Bool {
        switch self {
        case .link:
            return true
        // Inline code that resolves to a file path is rendered as a link too.
        case .inlineCode(let code, _):
            return FilePathLink.url(for: code) != nil
        default:
            return false
        }
    }
}

private extension View {
    @ViewBuilder
    func conditionalPointingHand(_ enabled: Bool) -> some View {
        if enabled {
            self.onHover { inside in
                if inside {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
        } else {
            self
        }
    }

    @ViewBuilder
    func conditionalTextSelection(_ enabled: Bool) -> some View {
        if enabled {
            self.textSelection(.enabled)
        } else {
            self.textSelection(.disabled)
        }
    }
}

/// Detects file-path tokens in markdown text/inline-code and turns them into
/// `hermesfile:` links that reveal the file in Finder when clicked.
enum FilePathLink {
    static let scheme = "hermesfile"

    /// Splits `text` into plain runs and path-link runs.
    static func runs(in text: String, emphasis: Emphasis) -> [MarkdownInline] {
        var runs: [MarkdownInline] = []
        var plain = ""
        var token = ""

        func flushPlain() {
            if !plain.isEmpty {
                runs.append(.text(plain, emphasis: emphasis))
                plain = ""
            }
        }
        // Trailing sentence punctuation shouldn't be swallowed into the path.
        let trailingPunctuation: Set<Character> = [".", ",", ";", ":", "!", "?", ")", "]", "}", "'", "\""]

        func endToken() {
            guard !token.isEmpty else { return }
            var core = token
            var trailing = ""
            while let last = core.last, trailingPunctuation.contains(last) {
                trailing.insert(last, at: trailing.startIndex)
                core.removeLast()
            }
            if let url = url(for: core) {
                flushPlain()
                runs.append(.link(text: core, url: url.absoluteString, emphasis: emphasis))
                plain += trailing
            } else {
                plain += token
            }
            token = ""
        }

        for character in text {
            if character == " " || character == "\n" || character == "\t" {
                endToken()
                plain.append(character)
            } else {
                token.append(character)
            }
        }
        endToken()
        flushPlain()
        return runs
    }

    /// A `hermesfile:` URL for `raw` if it looks like a file path, else `nil`.
    static func url(for raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard isLikelyPath(trimmed),
              let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return nil
        }
        return URL(string: "\(scheme):\(encoded)")
    }

    /// Heuristic: only absolute (`/…`) or home (`~`, `~/…`) tokens are treated as
    /// file paths. Relative tokens (`./`, `../`), mid-string slashes, and bare
    /// `name.ext` are intentionally ignored, so only clearly rooted paths become
    /// links and ordinary prose never does.
    static func isLikelyPath(_ string: String) -> Bool {
        guard !string.isEmpty, !string.contains("://"), !string.contains(" ") else { return false }
        return string.hasPrefix("/") || string == "~" || string.hasPrefix("~/")
    }

    /// Resolves the raw path (expanding `~` and relative paths against
    /// `baseDirectory`) and reveals it in Finder. Returns whether handled.
    @MainActor
    static func reveal(_ url: URL, baseDirectory: URL?) -> Bool {
        guard url.scheme == scheme else { return false }
        let encoded = String(url.absoluteString.dropFirst("\(scheme):".count))
        guard let raw = encoded.removingPercentEncoding, !raw.isEmpty else { return true }

        let fileURL: URL
        if raw.hasPrefix("/") {
            fileURL = URL(fileURLWithPath: raw)
        } else if raw == "~" || raw.hasPrefix("~/") {
            let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
            fileURL = URL(fileURLWithPath: home + raw.dropFirst(1))
        } else if let baseDirectory {
            fileURL = baseDirectory.appendingPathComponent(raw)
        } else {
            fileURL = URL(fileURLWithPath: raw)
        }

        let standardized = fileURL.standardizedFileURL
        if FileManager.default.fileExists(atPath: standardized.path(percentEncoded: false)) {
            NSWorkspace.shared.activateFileViewerSelecting([standardized])
        } else {
            // Fall back to revealing the parent directory if it exists.
            let parent = standardized.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: parent.path(percentEncoded: false)) {
                NSWorkspace.shared.activateFileViewerSelecting([standardized])
            }
        }
        return true
    }
}

extension View {
    /// Intercepts `hermesfile:` link taps inside this subtree, revealing the
    /// file in Finder (relative paths resolve against `baseDirectory`). Other
    /// URLs fall through to the system handler.
    func fileLinkHandler(baseDirectory: URL?) -> some View {
        environment(\.openURL, OpenURLAction { url in
            FilePathLink.reveal(url, baseDirectory: baseDirectory) ? .handled : .systemAction
        })
    }
}
