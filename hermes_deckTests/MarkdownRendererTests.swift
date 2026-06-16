import Foundation
import AppKit
import Testing
@testable import hermes_deck

struct MarkdownRendererTests {
    @Test
    func markdownTableKeepsCellContentWideEnoughForHorizontalScrolling() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("hermes_deck/Markdown/MarkdownRenderer.swift"),
            encoding: .utf8
        )

        #expect(source.contains(".fixedSize(horizontal: true, vertical: false)"))
        #expect(source.contains(".frame(maxWidth: .infinity, alignment: .leading)"))
    }

    @Test
    func inlineCodeUsesAttributedStringInsteadOfCustomTextKitRenderer() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("hermes_deck/Markdown/MarkdownRenderer.swift"),
            encoding: .utf8
        )

        #expect(!source.contains("MarkdownInlineFlowLayout"))
        #expect(!source.contains("MarkdownInlineTextView"))
        #expect(!source.contains("RoundedInlineTextView"))
        #expect(!source.contains("InlineCodeLayoutManager"))
    }

    @Test
    func inlineCodeBackgroundUsesNonRoundedAttributedStringBackground() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("hermes_deck/Markdown/MarkdownRenderer.swift"),
            encoding: .utf8
        )

        #expect(source.contains("codeSegment.backgroundColor = Color.secondary.opacity(0.16)"))
        #expect(!source.contains("NSBezierPath(roundedRect"))
        #expect(!source.contains(".inlineCodeBackground"))
    }

    @Test
    func parsesCodeBlocksTablesLinksImagesAndInlineCode() {
        let markdown = """
        # Title

        This has [a link](https://example.com), `inline`, and ![alt](https://example.com/a.png).

        | Name | Value |
        | --- | --- |
        | Alpha | 1 |

        ```swift
        let value = 1
        ```
        """

        let blocks = MarkdownRenderer().parse(markdown)

        #expect(blocks.contains(.heading(level: 1, text: "Title")))
        #expect(blocks.contains { if case .table = $0 { true } else { false } })
        #expect(blocks.contains { if case .codeBlock("swift", "let value = 1") = $0 { true } else { false } })
        #expect(blocks.contains { if case .paragraph(let runs) = $0 { runs.contains(.inlineCode("inline")) && runs.contains(.link(text: "a link", url: "https://example.com")) && runs.contains(.image(alt: "alt", url: "https://example.com/a.png")) } else { false } })
    }

    @Test
    func parsesNestedEmphasisIncludingInlineCode() {
        let runs = MarkdownRenderer().parseInline("**bold `code` more** and *italic* and ~~gone~~")

        #expect(runs.contains(.text("bold ", emphasis: .bold)))
        #expect(runs.contains(.inlineCode("code", emphasis: .bold)))
        #expect(runs.contains(.text(" more", emphasis: .bold)))
        #expect(runs.contains(.text("italic", emphasis: .italic)))
        #expect(runs.contains(.text("gone", emphasis: .strikethrough)))
    }

    @Test
    func leavesSnakeCaseAndLoneAsterisksUnemphasized() {
        #expect(MarkdownRenderer().parseInline("call foo_bar_baz here") == [.text("call foo_bar_baz here")])
        #expect(MarkdownRenderer().parseInline("2 * 3 * 4") == [.text("2 * 3 * 4")])
    }

    @Test
    func parsesThematicBreaks() {
        let markdown = """
        Before

        ---

        * * *

        _ _ _

        After
        """

        let blocks = MarkdownRenderer().parse(markdown)

        #expect(blocks == [
            .paragraph([.text("Before")]),
            .thematicBreak,
            .thematicBreak,
            .thematicBreak,
            .paragraph([.text("After")])
        ])
    }

    @Test
    func codeBlockClipboardCopiesCodeText() {
        let pasteboard = NSPasteboard.withUniqueName()

        CodeBlockClipboard.copy("let value = 1", pasteboard: pasteboard)

        #expect(pasteboard.string(forType: .string) == "let value = 1")
    }

    @Test
    func allCodeBlocksRenderCopyControl() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("hermes_deck/Markdown/MarkdownRenderer.swift"),
            encoding: .utf8
        )

        #expect(source.contains("private var languageLabel: String"))
        #expect(source.contains("language?.uppercased() ?? \"CODE\""))
        #expect(source.contains(".help(\"Copy code\")"))
    }

    @Test
    func codeBlockSyntaxHighlighterTokenizesSupportedLanguages() {
        let swiftTokens = CodeBlockSyntaxHighlighter.tokens(for: #"let value = "hello" // comment"#, language: "swift")
        let pythonTokens = CodeBlockSyntaxHighlighter.tokens(for: #"def run(): # comment"#, language: "python")

        #expect(swiftTokens.contains(HighlightedCodeToken(text: "let", kind: .keyword)))
        #expect(swiftTokens.contains(HighlightedCodeToken(text: #""hello""#, kind: .string)))
        #expect(swiftTokens.contains(HighlightedCodeToken(text: "// comment", kind: .comment)))
        #expect(pythonTokens.contains(HighlightedCodeToken(text: "def", kind: .keyword)))
        #expect(pythonTokens.contains(HighlightedCodeToken(text: "# comment", kind: .comment)))
    }

    @Test
    func codeBlockSyntaxHighlighterLeavesUnknownLanguagesPlain() {
        let tokens = CodeBlockSyntaxHighlighter.tokens(for: "let value = 1", language: "unknown")

        #expect(tokens == [HighlightedCodeToken(text: "let value = 1", kind: .plain)])
    }
}
