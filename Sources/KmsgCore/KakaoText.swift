import Foundation

/// A clock time read from a KakaoTalk label such as "오후 5:10" or "17:10".
public struct ClockTime: Equatable, Sendable {
    /// The label text exactly as matched, e.g. "오후 5:10".
    public var raw: String
    /// 0-23.
    public var hour: Int
    /// 0-59.
    public var minute: Int

    public init(raw: String, hour: Int, minute: Int) {
        self.raw = raw
        self.hour = hour
        self.minute = minute
    }

    /// 24-hour "HH:mm".
    public var hhmm: String {
        String(format: "%02d:%02d", hour, minute)
    }
}

/// Text patterns used by KakaoTalk for Mac 26.x (Korean UI).
public enum KakaoText {
    public static let unreadPrefix = "안읽음"
    public static let pinnedSuffix = ", 핀 설정됨"

    // MARK: Date separators

    /// Parses a transcript date separator ("2026년 11월 23일 일요일") into "2026-11-23".
    public static func dateSeparator(_ raw: String) -> String? {
        let parts = raw.split(whereSeparator: { $0.isWhitespace })
        guard parts.count == 4 else { return nil }
        guard
            let year = number(parts[0], suffix: "년", digits: 4...4),
            let month = number(parts[1], suffix: "월", digits: 1...2),
            let day = number(parts[2], suffix: "일", digits: 1...2)
        else {
            return nil
        }
        let weekday = parts[3]
        guard weekday.count == 3, weekday.hasSuffix("요일") else { return nil }
        guard (1...12).contains(month), (1...31).contains(day) else { return nil }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    private static func number(_ token: Substring, suffix: String, digits: ClosedRange<Int>) -> Int? {
        guard token.hasSuffix(suffix) else { return nil }
        let body = token.dropLast(suffix.count)
        guard digits.contains(body.count), body.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(body)
    }

    // MARK: Times

    /// A time label at the very start of `text` ("오후 5:10, 안읽음 2" -> 17:10).
    public static func leadingTime(_ text: String) -> ClockTime? {
        let chars = Array(text)
        var start = 0
        while start < chars.count, chars[start].isWhitespace {
            start += 1
        }
        return parseTime(chars, at: start)?.time
    }

    /// The first time label anywhere in `text`.
    public static func firstTime(in text: String) -> ClockTime? {
        let chars = Array(text)
        var index = 0
        while index < chars.count {
            let startsMeridiem = chars[index] == "오"
            let startsDigits = isASCIIDigit(chars[index]) && (index == 0 || !isASCIIDigit(chars[index - 1]))
            if startsMeridiem || startsDigits, let parsed = parseTime(chars, at: index) {
                return parsed.time
            }
            index += 1
        }
        return nil
    }

    /// True when `text` is a complete time label and nothing else ("오후 3:10", "15:10").
    public static func isTimeOnly(_ text: String) -> Bool {
        let chars = Array(text.kmsgTrimmed)
        guard let parsed = parseTime(chars, at: 0) else { return false }
        return parsed.end == chars.count
    }

    private static func parseTime(_ chars: [Character], at start: Int) -> (time: ClockTime, end: Int)? {
        var index = start
        var meridiem: Int?
        if index + 1 < chars.count, chars[index] == "오" {
            if chars[index + 1] == "전" {
                meridiem = 0
            } else if chars[index + 1] == "후" {
                meridiem = 1
            } else {
                return nil
            }
            index += 2
            while index < chars.count, chars[index].isWhitespace {
                index += 1
            }
        }

        let hourStart = index
        while index < chars.count, isASCIIDigit(chars[index]), index - hourStart < 2 {
            index += 1
        }
        guard index > hourStart, index < chars.count, chars[index] == ":" else { return nil }
        guard let hour = Int(String(chars[hourStart..<index])) else { return nil }
        index += 1

        guard index + 1 < chars.count else { return nil }
        guard isASCIIDigit(chars[index]), isASCIIDigit(chars[index + 1]) else { return nil }
        guard let minute = Int(String(chars[index...(index + 1)])) else { return nil }
        index += 2
        if index < chars.count, isASCIIDigit(chars[index]) {
            return nil
        }
        guard (0...59).contains(minute) else { return nil }

        let hour24: Int
        if let meridiem {
            guard (0...12).contains(hour) else { return nil }
            hour24 = (hour % 12) + (meridiem == 1 ? 12 : 0)
        } else {
            guard (0...23).contains(hour) else { return nil }
            hour24 = hour
        }

        let raw = String(chars[start..<index])
        return (ClockTime(raw: raw, hour: hour24, minute: minute), index)
    }

    private static func isASCIIDigit(_ character: Character) -> Bool {
        character.isASCII && character.isNumber
    }

    // MARK: Message meta labels

    /// The meta label KakaoTalk places next to a message bubble: a time, an unread
    /// counter, or both ("오후 5:10", "안읽음 2", "오후 5:10, 안읽음 2").
    public static func isMetaLabel(_ text: String) -> Bool {
        leadingTime(text) != nil || text.kmsgTrimmed.hasPrefix(unreadPrefix)
    }

    /// The N of "안읽음 N" anywhere in `text`.
    public static func unreadCount(in text: String) -> Int? {
        guard let range = text.range(of: unreadPrefix) else { return nil }
        let rest = text[range.upperBound...].drop(while: { $0.isWhitespace })
        let digits = rest.prefix(while: { $0.isASCII && $0.isNumber })
        return digits.isEmpty ? nil : Int(digits)
    }

    // MARK: Chat list labels

    /// Digits with optional "+" or "," only ("3", "999+", "1,024").
    public static func isCountLike(_ text: String) -> Bool {
        let trimmed = text.kmsgTrimmed
        guard !trimmed.isEmpty else { return false }
        return trimmed.allSatisfy { $0.isNumber || $0 == "+" || $0 == "," }
    }

    /// Leading integer of a count-like badge ("999+" -> 999).
    public static func leadingCount(_ text: String) -> Int? {
        let digits = text.kmsgTrimmed.prefix(while: { $0.isASCII && $0.isNumber })
        return digits.isEmpty ? nil : Int(digits)
    }

    /// "9명" -> 9.
    public static func memberCount(_ text: String) -> Int? {
        let trimmed = text.kmsgTrimmed
        guard trimmed.hasSuffix("명") else { return nil }
        let digits = trimmed.dropLast()
        guard !digits.isEmpty, digits.allSatisfy({ ($0.isASCII && $0.isNumber) || $0 == "," }) else { return nil }
        return Int(digits.filter { $0 != "," })
    }

    /// Chat-list time labels: "오후 3:10", "15:10", "11월 23일", "2025. 11. 3.", "어제", "그저께".
    public static func isChatListTimeLabel(_ text: String) -> Bool {
        var trimmed = text.kmsgTrimmed
        if trimmed.hasSuffix(pinnedSuffix) {
            trimmed = String(trimmed.dropLast(pinnedSuffix.count)).kmsgTrimmed
        }
        if trimmed == "어제" || trimmed == "그저께" {
            return true
        }
        if isTimeOnly(trimmed) {
            return true
        }
        if trimmed.range(of: #"^\d{1,2}월 \d{1,2}일$"#, options: .regularExpression) != nil {
            return true
        }
        return trimmed.range(of: #"^\d{4}[.-] ?\d{1,2}[.-] ?\d{1,2}\.?$"#, options: .regularExpression) != nil
    }
}
