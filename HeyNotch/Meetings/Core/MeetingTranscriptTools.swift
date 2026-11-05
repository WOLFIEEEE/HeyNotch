import Foundation

enum MeetingTranscriptSourceFilter: String, CaseIterable, Identifiable, Sendable {
    case all, microphone, call
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .all: return "All sources"
        case .microphone: return "Microphone"
        case .call: return "Call audio"
        }
    }
    func includes(_ source: MeetingAudioSource) -> Bool {
        switch self {
        case .all: return true
        case .microphone: return source == .microphone
        case .call: return source == .call
        }
    }
}

enum MeetingTranscriptExportFormat: String, CaseIterable, Identifiable, Sendable {
    case plainText, markdown
    var id: String { rawValue }
    var displayName: String { self == .plainText ? "Plain text" : "Markdown" }
    var fileExtension: String { self == .plainText ? "txt" : "md" }
}

enum MeetingTranscriptTools {
    static func matches(_ text: String, query: String, locale: Locale = .current) -> Bool {
        let needle = searchText(query, locale: locale)
        return needle.isEmpty || searchText(text, locale: locale).contains(needle)
    }

    /// Explicit input-index tie breaking keeps simultaneous microphone/call
    /// sections stable even when sorting an archived transcript repeatedly.
    static func chronological(_ segments: [MeetingTranscriptSegment]) -> [MeetingTranscriptSegment] {
        segments.enumerated().sorted { left, right in
            let leftTime = sortableOffset(left.element.offset)
            let rightTime = sortableOffset(right.element.offset)
            return leftTime == rightTime ? left.offset < right.offset : leftTime < rightTime
        }.map(\.element)
    }

    static func filtered(_ segments: [MeetingTranscriptSegment], query: String = "",
                         source: MeetingTranscriptSourceFilter = .all,
                         locale: Locale = .current) -> [MeetingTranscriptSegment] {
        let needle = searchText(query, locale: locale)
        return chronological(segments).filter { segment in
            source.includes(segment.source) && (needle.isEmpty || searchText(segment.text, locale: locale).contains(needle))
        }
    }

    static func timestamp(_ offset: TimeInterval) -> String {
        // Invalid archive data must not trap while rendering a row or export.
        let value = offset.isFinite ? Int64(min(max(0, offset), Double(Int64.max / 2))) : 0
        return String(format: "%02lld:%02lld:%02lld", value / 3600, value / 60 % 60, value % 60)
    }

    static func attributedPassage(_ segment: MeetingTranscriptSegment) -> String {
        "[\(timestamp(segment.offset))] \(segment.source.rawValue)\(segment.isGap ? " · transcription gap" : ""): \(segment.text)"
    }

    /// Always pass the full transcript here. View filters have no role in an
    /// export; spoken words and the stored segment objects are never rewritten.
    static func export(_ segments: [MeetingTranscriptSegment], format: MeetingTranscriptExportFormat,
                       started: Date?, callSource: String, title: String = "HeyNotch meeting transcript",
                       locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale; formatter.timeZone = timeZone
        formatter.dateStyle = .medium; formatter.timeStyle = .short
        let date = started.map(formatter.string(from:)) ?? "Date not recorded"
        let ordered = chronological(segments)
        let caveat = "Source labels identify audio channels, not individual speakers."
        switch format {
        case .plainText:
            let header = "\(singleLine(title))\n\(date)\nCall audio: \(singleLine(callSource))\n\(caveat)\n"
            return header + "\n" + ordered.map(attributedPassage).joined(separator: "\n\n") + "\n"
        case .markdown:
            let header = "# \(literalMarkdown(singleLine(title)))\n\n\(literalMarkdown(date))\n\nCall audio: \(literalMarkdown(singleLine(callSource)))\n\n\(caveat)\n"
            let passages = ordered.map { segment in
                let label = "\(timestamp(segment.offset)) · \(segment.source.rawValue)\(segment.isGap ? " · transcription gap" : "")"
                return "## \(literalMarkdown(label))\n\n\(literalMarkdown(segment.text))"
            }
            return header + "\n" + passages.joined(separator: "\n\n") + "\n"
        }
    }

    /// CommonMark permits backslash escapes for ASCII punctuation. Escaping
    /// all of it prevents transcript links, HTML, image embeds, fences, tables,
    /// or headings from becoming active markup. Deliberate controls are made
    /// visible in the exported representation; original text stays untouched.
    static func literalMarkdown(_ text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return normalized.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            var output = ""
            var leadingWhitespace = true
            for scalar in line.unicodeScalars {
                let value = scalar.value
                if leadingWhitespace && value == 0x20 { output += "&#32;"; continue }
                if value == 0x09 {
                    output += "&#9;"
                    continue
                }
                leadingWhitespace = false
                if isUnsafeControl(value) {
                    output += String(format: "⟦U+%04X⟧", value)
                } else if isASCIIPunctuation(value) {
                    output.append("\\"); output.unicodeScalars.append(scalar)
                } else {
                    output.unicodeScalars.append(scalar)
                }
            }
            return output
        }.joined(separator: "  \n")
    }

    private static func searchText(_ value: String, locale: Locale) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
    }
    private static func sortableOffset(_ offset: TimeInterval) -> TimeInterval {
        offset.isFinite ? max(0, offset) : .infinity
    }
    private static func singleLine(_ value: String) -> String {
        value.split(whereSeparator: \.isNewline).joined(separator: " ⏎ ")
    }
    private static func isASCIIPunctuation(_ value: UInt32) -> Bool {
        (0x21...0x2F).contains(value) || (0x3A...0x40).contains(value) ||
        (0x5B...0x60).contains(value) || (0x7B...0x7E).contains(value)
    }
    private static func isUnsafeControl(_ value: UInt32) -> Bool {
        value < 0x20 || (0x7F...0x9F).contains(value) ||
        (0x202A...0x202E).contains(value) || (0x2066...0x2069).contains(value) ||
        value == 0x200E || value == 0x200F || value == 0x061C
    }
}
