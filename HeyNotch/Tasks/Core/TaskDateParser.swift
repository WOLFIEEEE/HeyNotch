import Foundation

struct TaskDateParser {
    let now: Date
    var calendar: Calendar
    let locale: Locale

    init(now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current, timeZone: TimeZone = .current) {
        self.now = now; self.calendar = calendar; self.calendar.timeZone = timeZone; self.locale = locale
    }

    func parse(_ text: String) -> TaskDraft {
        let original = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var draft = TaskDraft(title: original, sourceText: original)
        guard !original.isEmpty else { return draft }
        let value = original.replacingOccurrences(of: "’", with: "'")
        if first(#"\b(every|each|daily|weekly|monthly|yearly|weekdays|weekends)\b"#, value) != nil {
            draft.reviewReasons = ["Recurring reminders are not created from voice yet. Choose a one-off date, or create the recurrence in Apple Reminders."]
            return draft
        }
        let duration = first(#"\bin\s+(\d+|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|half)\s+(minutes?|hours?|days?|weeks?)\b"#, value)
        let relative = all(#"\b(day after tomorrow|tomorrow|today|tonight)\b"#, value)
        let weekdays = all(#"\b(?:(next|this)\s+)?(sunday|monday|tuesday|wednesday|thursday|friday|saturday)\b(?!'s)"#, value)
        let monthDay = first(#"\bon\s+the\s+(\d{1,2})(?:st|nd|rd|th)?\b"#, value)
        let iso = first(#"\b(?:on\s+)?(\d{4})-(\d{2})-(\d{2})\b"#, value)
        let count = (duration == nil ? 0 : 1) + relative.count + weekdays.count + (monthDay == nil ? 0 : 1) + (iso == nil ? 0 : 1)
        guard count <= 1 else {
            draft.reviewReasons = ["More than one date was mentioned. Choose the intended due date."]; return draft
        }
        var date: Date?
        var hasTime = false
        var consumed: [NSRange] = []
        func field(_ match: NSTextCheckingResult, _ index: Int) -> String {
            guard index < match.numberOfRanges, let range = Range(match.range(at: index), in: value) else { return "" }
            return String(value[range]).lowercased()
        }
        if let monthDay, !(1...31).contains(Int(field(monthDay, 1)) ?? 0) {
            draft.reviewReasons = ["Choose a day of the month from 1 through 31."]; return draft
        }
        if let duration {
            let numbers: [String: Double] = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "half": 0.5]
            let number = Double(field(duration, 1)) ?? numbers[field(duration, 1)] ?? 0
            guard number > 0, number <= 10_000 else { draft.reviewReasons = ["Choose a shorter, valid relative date."]; return draft }
            let unit = field(duration, 2)
            if unit.hasPrefix("hour") || unit.hasPrefix("minute") {
                date = now.addingTimeInterval(number * (unit.hasPrefix("hour") ? 3600 : 60)); hasTime = true
            } else {
                date = calendar.date(byAdding: .day, value: Int(number * (unit.hasPrefix("week") ? 7 : 1)), to: calendar.startOfDay(for: now))
            }
            consumed.append(duration.range)
        } else if let relative = relative.first {
            let term = field(relative, 1)
            let days = term == "day after tomorrow" ? 2 : term == "tomorrow" ? 1 : 0
            date = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: now))
            consumed.append(relative.range)
            if term == "tonight" { draft.reviewReasons.append("Choose a time for tonight.") }
        } else if let weekday = weekdays.first {
            let names = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
            let target = (names.firstIndex(of: field(weekday, 2)) ?? 0) + 1
            var days = (target - calendar.component(.weekday, from: now) + 7) % 7
            if days == 0 { days = 7 }
            date = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: now))
            consumed.append(weekday.range)
            if field(weekday, 1) == "next" { draft.reviewReasons.append("‘Next’ weekday can mean different weeks. Check the proposed date.") }
        } else if let monthDay, let day = Int(field(monthDay, 1)), (1...31).contains(day) {
            let start = calendar.startOfDay(for: now)
            for offset in 0...12 {
                guard let month = calendar.date(byAdding: .month, value: offset, to: start) else { continue }
                var components = calendar.dateComponents([.year, .month], from: month); components.day = day
                if let candidate = calendar.date(from: components), calendar.component(.day, from: candidate) == day, candidate >= start {
                    date = candidate; break
                }
            }
            consumed.append(monthDay.range)
        } else if let iso {
            let components = DateComponents(year: Int(field(iso, 1)), month: Int(field(iso, 2)), day: Int(field(iso, 3)))
            if let candidate = calendar.date(from: components),
               calendar.dateComponents([.year, .month, .day], from: candidate) == components { date = candidate; consumed.append(iso.range) }
            else { draft.reviewReasons.append("That date does not exist. Choose a valid date.") }
        }
        let times = all(#"\bat\s+(\d{1,2})(?::(\d{2}))?\s*(a\.?m\.?|p\.?m\.?)?\b"#, value)
        if times.count > 1 {
            draft.reviewReasons.append("More than one time was mentioned. Choose the intended time.")
        } else if let time = times.first {
            let h = Int(field(time, 1)) ?? -1, m = Int(field(time, 2)) ?? 0
            let suffix = field(time, 3).replacingOccurrences(of: ".", with: "")
            let ambiguous = suffix.isEmpty && (1...12).contains(h) && field(time, 2).isEmpty
            if ambiguous { draft.reviewReasons.append("‘At \(h)’ needs AM or PM. Choose a time, or keep a date-only reminder.") }
            else if !(0...23).contains(h) || !(0...59).contains(m) || (!suffix.isEmpty && !(1...12).contains(h)) {
                draft.reviewReasons.append("Choose a valid time.")
            } else if hasTime { draft.reviewReasons.append("Both a relative duration and a clock time were given. Choose one.") }
            else {
                let hour = suffix == "pm" ? h % 12 + 12 : suffix == "am" ? h % 12 : h
                let day = date ?? calendar.startOfDay(for: now)
                let base = calendar.startOfDay(for: day).addingTimeInterval(-1)
                var parts = calendar.dateComponents([.year, .month, .day], from: day); parts.hour = hour; parts.minute = m; parts.second = 0
                let first = calendar.nextDate(after: base, matching: parts, matchingPolicy: .strict, repeatedTimePolicy: .first)
                let last = calendar.nextDate(after: base, matching: parts, matchingPolicy: .strict, repeatedTimePolicy: .last)
                if let first, first == last, calendar.isDate(first, inSameDayAs: day) {
                    date = first; hasTime = true; consumed.append(time.range)
                    if count == 0 && first < now { date = calendar.date(byAdding: .day, value: 1, to: first) }
                } else { draft.reviewReasons.append("This local time is missing or repeated because of a clock change. Choose a valid time.") }
            }
        }
        if let part = first(#"\b(morning|afternoon|evening|noon|midnight)\b"#, value) {
            draft.reviewReasons.append("Choose an exact time for ‘\(field(part, 1))’, or keep a date-only reminder.")
        }
        if date == nil && count == 0 && times.isEmpty,
           let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
           !detector.matches(in: original, range: NSRange(original.startIndex..., in: original)).isEmpty {
            // NSDataDetector uses the system clock/locale. It is only an ambiguity signal;
            // never let it override our injected reference date or silently guess a year.
            draft.reviewReasons.append("This date expression needs review. Choose the date below.")
        }
        if let date {
            draft.due = .from(date, hasTime: hasTime, calendar: calendar)
            if date < (hasTime ? now : calendar.startOfDay(for: now)) { draft.reviewReasons.append("The proposed due date is in the past.") }
        }
        // Only remove confidently recognized scheduling phrases; preserve all other title text.
        let title = NSMutableString(string: original)
        for range in consumed.sorted(by: { $0.location > $1.location }) { title.replaceCharacters(in: range, with: "") }
        draft.title = String(title).replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ",.;")))
        if draft.title.isEmpty { draft.title = original; draft.reviewReasons.append("Add a task title.") }
        return draft
    }

    private func first(_ pattern: String, _ value: String) -> NSTextCheckingResult? { all(pattern, value).first }
    private func all(_ pattern: String, _ value: String) -> [NSTextCheckingResult] {
        (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]))?.matches(in: value, range: NSRange(value.startIndex..., in: value)) ?? []
    }
}
