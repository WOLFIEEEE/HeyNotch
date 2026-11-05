import CoreFoundation
import Foundation

struct AutomationArguments {
    let values: [String: Any]
    func only(_ keys: Set<String>) throws {
        guard Set(values.keys).isSubset(of: keys) else { throw AutomationFailure.invalid }
    }
    func string(_ name: String, required: Bool = true, maximum: Int = 2_048, allowEmpty: Bool = false) throws -> String? {
        guard let value = values[name] else {
            if required { throw AutomationFailure.invalid }; return nil
        }
        guard let text = value as? String, text.utf8.count <= maximum,
              allowEmpty || !text.isEmpty, !text.contains("\u{0}") else { throw AutomationFailure.invalid }
        return text
    }
    func bool(_ name: String, required: Bool = false) throws -> Bool? {
        guard let value = values[name] else {
            if required { throw AutomationFailure.invalid }; return nil
        }
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw AutomationFailure.invalid }
        return number.boolValue
    }
    func integer(_ name: String, required: Bool = true, range: ClosedRange<Int>) throws -> Int? {
        guard let value = values[name] else {
            if required { throw AutomationFailure.invalid }; return nil
        }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
              number.doubleValue >= Double(range.lowerBound), number.doubleValue <= Double(range.upperBound) else { throw AutomationFailure.invalid }
        return number.intValue
    }
    func uuid(_ name: String) throws -> UUID {
        guard let text = try string(name, maximum: 36), text.count == 36,
              let value = UUID(uuidString: text) else { throw AutomationFailure.invalid }
        return value
    }
    func revision() throws -> String {
        let value = try string("expectedRevision", maximum: 64)!
        guard value.count == 64, value.allSatisfy({ "0123456789abcdef".contains($0) }) else { throw AutomationFailure.invalid }
        return value
    }
    func title(required: Bool) throws -> String? {
        guard let value = try string("title", required: required, maximum: 4_096) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AutomationFailure.invalid }
        return trimmed
    }
    func alarm(default defaultValue: TaskAlarmChoice) throws -> TaskAlarmChoice {
        guard let value = try string("alarm", required: false, maximum: 10) else { return defaultValue }
        switch value {
        case "off": return .off
        case "atDue": return .atDue
        case "keep": return .keep
        default: throw AutomationFailure.invalid
        }
    }
    func due() throws -> TaskDue? {
        guard let raw = values["due"] else { return nil }
        guard let object = raw as? [String: Any] else { throw AutomationFailure.invalid }
        let fields = AutomationArguments(values: object)
        try fields.only(["year", "month", "day", "hour", "minute", "timeZoneIdentifier"])
        let year = try fields.integer("year", range: 1...9_999)!
        let month = try fields.integer("month", range: 1...12)!
        let day = try fields.integer("day", range: 1...31)!
        let hour = try fields.integer("hour", required: false, range: 0...23)
        let minute = try fields.integer("minute", required: false, range: 0...59)
        let zoneName = try fields.string("timeZoneIdentifier", required: false, maximum: 128)
        guard (hour == nil && minute == nil && zoneName == nil) || (hour != nil && minute != nil && zoneName != nil) else { throw AutomationFailure.invalid }
        var calendar = Calendar.current
        var canonicalZone: String?
        if let zoneName {
            guard let zone = TimeZone(identifier: zoneName) else { throw AutomationFailure.invalid }
            calendar.timeZone = zone; canonicalZone = zone.identifier
        }
        let due = TaskDue(year: year, month: month, day: day, hour: hour, minute: minute, timeZoneIdentifier: canonicalZone)
        guard let date = due.date(in: calendar), TaskDue.from(date, hasTime: due.hasTime, calendar: calendar) == due else {
            throw AutomationFailure(code: "invalid_date", message: "Use a valid calendar date and an existing local time in the specified time zone.")
        }
        return due
    }
}
