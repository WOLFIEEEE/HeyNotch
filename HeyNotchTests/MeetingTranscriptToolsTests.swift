import Foundation
import XCTest

final class MeetingTranscriptToolsTests: XCTestCase {
    private let locale = Locale(identifier: "en_US_POSIX")
    private let zone = TimeZone(secondsFromGMT: 0)!

    func testSearchIgnoresCaseDiacriticsAndWhitespaceWithoutChangingText() {
        let original = "Discuss CAFÉ\n\twith José tomorrow."
        let segment = MeetingTranscriptSegment(source: .microphone, offset: 1, text: original)
        XCTAssertEqual(MeetingTranscriptTools.filtered([segment], query: "  cafe  WITH   JOSE ", locale: locale).map(\.id), [segment.id])
        XCTAssertEqual(segment.text, original)
        XCTAssertEqual(MeetingTranscriptTools.filtered([segment], query: " \t\n", locale: locale).count, 1)
        XCTAssertTrue(MeetingTranscriptTools.matches(original, query: "CAFE with Jose", locale: locale))
        XCTAssertFalse(MeetingTranscriptTools.matches(original, query: "unrelated", locale: locale))
    }

    func testUnicodeSearchHandlesCanonicalAccentsHindiAndEmoji() {
        let segments = [
            MeetingTranscriptSegment(source: .call, offset: 1, text: "Cafe\u{301} and 日本語 👩🏽‍💻"),
            MeetingTranscriptSegment(source: .microphone, offset: 2, text: "कल सुबह डॉक्टर को फोन करना है।")
        ]
        XCTAssertEqual(MeetingTranscriptTools.filtered(segments, query: "CAFÉ", locale: locale).count, 1)
        XCTAssertEqual(MeetingTranscriptTools.filtered(segments, query: "日本語 👩🏽‍💻", locale: locale).first?.id, segments[0].id)
        XCTAssertEqual(MeetingTranscriptTools.filtered(segments, query: "डॉक्टर", locale: locale).first?.id, segments[1].id)
    }

    func testSourceFilterIncludesMatchingGapsAndCombinesWithSearch() {
        let segments = [
            MeetingTranscriptSegment(source: .microphone, offset: 1, text: "Bring the notes"),
            MeetingTranscriptSegment(source: .call, offset: 2, text: "Bring the notes tomorrow"),
            MeetingTranscriptSegment(source: .call, offset: 3, text: "Speech could not be transcribed", isGap: true)
        ]
        XCTAssertEqual(MeetingTranscriptTools.filtered(segments, source: .call).map(\.id), [segments[1].id, segments[2].id])
        XCTAssertEqual(MeetingTranscriptTools.filtered(segments, query: "NOTES", source: .microphone, locale: locale).map(\.id), [segments[0].id])
        XCTAssertTrue(MeetingTranscriptTools.filtered(segments, query: "missing words", source: .all).isEmpty)
    }

    func testChronologyPreservesInputOrderAtEqualOffsets() {
        let late = MeetingTranscriptSegment(source: .call, offset: 20, text: "Later")
        let first = MeetingTranscriptSegment(source: .microphone, offset: 1, text: "First simultaneous")
        let second = MeetingTranscriptSegment(source: .call, offset: 1, text: "Second simultaneous")
        let input = [late, second, first]
        XCTAssertEqual(MeetingTranscriptTools.chronological(input).map(\.id), [second.id, first.id, late.id])
        XCTAssertEqual(MeetingTranscriptTools.filtered(input).map(\.id), [second.id, first.id, late.id])
    }

    func testPlainTextExportRetainsOriginalSpeechAndAllChannelsAfterFiltering() {
        let raw = "  First line\nSecond line: café 👋"
        let segments = [
            MeetingTranscriptSegment(source: .call, offset: 61, text: "Remote words"),
            MeetingTranscriptSegment(source: .microphone, offset: 1, text: raw),
            MeetingTranscriptSegment(source: .call, offset: 90, text: "Missing section", isGap: true)
        ]
        _ = MeetingTranscriptTools.filtered(segments, query: "First", source: .microphone)
        let text = MeetingTranscriptTools.export(segments, format: .plainText, started: nil, callSource: "Test Call", locale: locale, timeZone: zone)
        XCTAssertTrue(text.contains(raw)); XCTAssertTrue(text.contains("Remote words"))
        XCTAssertTrue(text.contains("[00:01:30] Call audio · transcription gap: Missing section"))
        XCTAssertTrue(text.contains("Source labels identify audio channels, not individual speakers."))
        XCTAssertLessThan(text.range(of: "First line")!.lowerBound, text.range(of: "Remote words")!.lowerBound)
        XCTAssertEqual(segments[1].text, raw)
    }

    func testMarkdownTreatsTranscriptMarkupAsLiteralWords() {
        let raw = "# fake heading\n[open](javascript:alert(1))\n<script>alert('x')</script>\n```swift\n**bold** &amp; ![image](https://example.test/image)\n|table|"
        let segment = MeetingTranscriptSegment(source: .call, offset: 0, text: raw)
        let markdown = MeetingTranscriptTools.export([segment], format: .markdown, started: nil, callSource: "Call", locale: locale, timeZone: zone)
        XCTAssertTrue(markdown.contains("\\# fake heading"))
        XCTAssertTrue(markdown.contains("\\[open\\]\\(javascript\\:alert\\(1\\)\\)"))
        XCTAssertTrue(markdown.contains("\\<script\\>"))
        XCTAssertTrue(markdown.contains("\\`\\`\\`swift"))
        XCTAssertTrue(markdown.contains("\\*\\*bold\\*\\*"))
        XCTAssertFalse(markdown.contains("<script>")); XCTAssertFalse(markdown.contains("![image]("))
        XCTAssertEqual(segment.text, raw)
    }

    func testMarkdownMakesControlCharactersVisibleAndPreservesLanguageJoiners() {
        let raw = "Escape\u{001B}[31m\u{0000} bidi\u{202E} keep 👩🏽‍💻 and क्‍ष"
        let output = MeetingTranscriptTools.literalMarkdown(raw)
        XCTAssertFalse(output.contains("\u{001B}")); XCTAssertFalse(output.contains("\u{0000}")); XCTAssertFalse(output.contains("\u{202E}"))
        XCTAssertTrue(output.contains("⟦U+001B⟧")); XCTAssertTrue(output.contains("⟦U+202E⟧"))
        XCTAssertTrue(output.contains("👩🏽‍💻")); XCTAssertTrue(output.contains("क्‍ष"))
    }

    func testMarkdownPreservesIndentationWithoutCreatingCodeBlocksAndFlattensMetadata() {
        XCTAssertEqual(MeetingTranscriptTools.literalMarkdown("    indented\r\n\ttext"), "&#32;&#32;&#32;&#32;indented  \n&#9;text")
        let output = MeetingTranscriptTools.export([], format: .markdown, started: nil, callSource: "Call\n# injected", title: "Title\n<script>", locale: locale, timeZone: zone)
        XCTAssertTrue(output.contains("Call ⏎ \\# injected")); XCTAssertTrue(output.contains("Title ⏎ \\<script\\>"))
        XCTAssertFalse(output.contains("\n# injected")); XCTAssertFalse(output.contains("<script>"))
    }

    func testExportDateCanBeMadeDeterministicAndFormatsHaveExpectedExtensions() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let first = MeetingTranscriptTools.export([], format: .plainText, started: date, callSource: "Call", locale: locale, timeZone: zone)
        let second = MeetingTranscriptTools.export([], format: .plainText, started: date, callSource: "Call", locale: locale, timeZone: zone)
        XCTAssertEqual(first, second); XCTAssertTrue(first.contains("2027"))
        XCTAssertEqual(MeetingTranscriptExportFormat.plainText.fileExtension, "txt")
        XCTAssertEqual(MeetingTranscriptExportFormat.markdown.fileExtension, "md")
    }

    func testAttributedPassageAndMalformedTimestampsAreSafe() {
        let gap = MeetingTranscriptSegment(source: .call, offset: 3661, text: "Unavailable", isGap: true)
        XCTAssertEqual(MeetingTranscriptTools.attributedPassage(gap), "[01:01:01] Call audio · transcription gap: Unavailable")
        XCTAssertEqual(MeetingTranscriptTools.timestamp(.nan), "00:00:00")
        XCTAssertEqual(MeetingTranscriptTools.timestamp(.infinity), "00:00:00")
        XCTAssertEqual(MeetingTranscriptTools.timestamp(-4), "00:00:00")
    }
}
